local M = {}
local scene = require("godot.scene_index")
local semantic = require("godot.semantic")
local docs = require("godot.docs")
local options = function() return require("godot.config").options end
local function warn(message) vim.notify("godot.nvim: " .. message, vim.log.levels.WARN) end

local function line_at(buf, row)
  return vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
end

local function enable_completion(client, buf)
  local provider = client.server_capabilities.completionProvider
  if provider and options().native_completion ~= false and not package.loaded["blink.cmp"] and not package.loaded.cmp then
    local completeopt = vim.api.nvim_get_option_value("completeopt", { buf = buf })
    if completeopt == "" then completeopt = vim.go.completeopt end
    if completeopt == vim.api.nvim_get_option_info2("completeopt", {}).default then
      vim.bo[buf].completeopt = completeopt .. ",menuone,noselect"
    end
    local chars = provider.triggerCharacters or {}
    -- Native autotrigger normally opens only after punctuation. Typing a
    -- symbol prefix should also offer classes, shader built-ins and snippets.
    if client.name ~= "godot-scene" then
      for ch in ("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_"):gmatch(".") do
        if not vim.tbl_contains(chars, ch) then table.insert(chars, ch) end
      end
      provider.triggerCharacters = chars
    end
    vim.lsp.completion.enable(true, client.id, buf, { autotrigger = true })
  end
end

-- In-process RPC uses UTF-8, matching Tree-sitter byte offsets. Complete every
-- request (including shutdown and errors) through the same client lifecycle.
local function local_server(capabilities, handlers)
  return function(dispatch)
    local closed, serial = false, 0
    local function exit()
      if not closed then
        closed = true
        dispatch.on_exit(0, 0)
      end
    end
    return {
      request = function(method, params, callback, replied)
        serial = serial + 1
        local id = serial
        vim.schedule(function()
          local ok, result = true, nil
          if method == "initialize" then
            result = { capabilities = vim.tbl_extend("force", { positionEncoding = "utf-8" }, capabilities) }
          elseif handlers[method] then
            local buf = vim.uri_to_bufnr(params.textDocument.uri)
            if vim.api.nvim_buf_is_loaded(buf) then ok, result = pcall(handlers[method], buf, params.position) end
          end
          if ok then callback(nil, result, id) else callback({ code = -32603, message = tostring(result) }, nil, id) end
          if replied then replied(id) end
        end)
        return true, id
      end,
      notify = function(method)
        if method == "exit" then exit() end
        return true
      end,
      is_closing = function() return closed end,
      terminate = exit,
    }
  end
end

local function start_local(buf, root, ft)
  local is_scene = ft == "gdresource"
  local name = is_scene and "godot-scene" or "godot-semantic"
  local existing = vim.lsp.get_clients({ name = name, bufnr = buf })[1]
  if existing then return end
  local lang = is_scene and "godot_resource" or "gdscript"
  vim.treesitter.language.register(lang, ft)
  local parser = vim.treesitter.get_parser(buf, lang, { error = false })
  if not parser then
    vim.notify_once("godot.nvim: install the " .. lang .. " Tree-sitter parser (:checkhealth godot)", vim.log.levels.WARN)
    return
  end
  pcall(vim.treesitter.start, buf, lang)
  local api
  local capabilities, handlers
  if is_scene then
    capabilities = { completionProvider = { triggerCharacters = { '"' } }, definitionProvider = true, hoverProvider = true }
    handlers = {
      ["textDocument/completion"] = scene.completion,
      ["textDocument/definition"] = function(b, pos) return scene.definition(b, pos, root) end,
      ["textDocument/hover"] = function(b, pos)
        local class = scene.type_at(b, pos)
        if not class or not class:match("^[A-Z][%w_]*$") then return end
        local text = api and docs.lookup(api, class) or string.format(
          "**%s**\n\n[Godot class reference](https://docs.godotengine.org/en/stable/classes/class_%s.html)", class, class:lower())
        if text then return { contents = { kind = "markdown", value = text } } end
      end,
    }
  else
    capabilities = { semanticTokensProvider = semantic.provider }
    handlers = { ["textDocument/semanticTokens/full"] = function(b) return semantic.tokens(b, api) end }
  end
  local id = vim.lsp.start({
    name = name, root_dir = root, cmd = local_server(capabilities, handlers), on_attach = enable_completion,
  }, { bufnr = buf })
  if id then
    docs.load(function(loaded, err)
      api = loaded
      if err then vim.notify_once("godot.nvim: " .. err, vim.log.levels.WARN) end
      local client = vim.lsp.get_client_by_id(id)
      if loaded and not is_scene and client and client.initialized then
        for b in pairs(client.attached_buffers) do vim.lsp.semantic_tokens.force_refresh(b) end
      end
    end, is_scene)
  end
end

-- Godot omits the replacement range on $ and % node paths. Define it once for
-- both native completion and completion plugins. '%' is already in the buffer.
local function node_edits(params, result, encoding)
  if not result or result == vim.NIL then return end
  local pos = params.position
  local buf = vim.uri_to_bufnr(params.textDocument.uri)
  if not vim.api.nvim_buf_is_loaded(buf) then return end
  local line = line_at(buf, pos.line)
  local col = vim.str_byteindex(line, encoding, pos.character, false)
  local sigil, start, prefix = line:sub(1, col):match("([%%$])()([%w_/]*)$")
  if not sigil then return end
  local items = result.items or result
  local range = { start = { line = pos.line, character = vim.str_utfindex(line, encoding, start - 1, false) }, ["end"] = pos }
  for i = #items, 1, -1 do
    local item = items[i]
    if not item.textEdit then
      local insert = item.insertText or item.label
      if sigil == "%" and prefix == "" and not vim.startswith(insert, "%") then
        table.remove(items, i)
      else
        if sigil == "%" then insert = insert:gsub("^%%", "") end
        item.textEdit = { newText = insert, range = range }
        item.filterText = insert
      end
    end
  end
end

-- Godot 4.7's uri_file_decode accepts uppercase hex digits. Neovim emits
-- lowercase escapes, so e.g. Chinese paths otherwise open phantom documents.
local function engine_uri(uri)
  if type(uri) ~= "string" then return uri end
  return (uri:gsub("%%%x%x", string.upper))
end

local function engine_params(p)
  if type(p) ~= "table" then return p end
  if p.textDocument and p.textDocument.uri then
    return vim.tbl_extend("force", p, {
      textDocument = vim.tbl_extend("force", p.textDocument, { uri = engine_uri(p.textDocument.uri) }),
    })
  end
  if p.rootUri then
    local folders = vim.deepcopy(p.workspaceFolders)
    if type(folders) == "table" then
      for _, folder in ipairs(folders) do folder.uri = engine_uri(folder.uri) end
    end
    return vim.tbl_extend("force", p, { rootUri = engine_uri(p.rootUri), workspaceFolders = folders })
  end
  return p
end

local function attach_gd(buf, root)
  require("godot.session").ensure(root, "language", function(err, session)
    if err then warn(tostring(err)); return end
    if not vim.api.nvim_buf_is_loaded(buf) or vim.bo[buf].filetype ~= "gdscript" then return end
    if require("godot.project").root(vim.api.nvim_buf_get_name(buf)) ~= root then return end
    local port = session.lsp_port
    local encoding = "utf-16"
    local function connect(dispatch, config)
      local rpc = vim.lsp.rpc.connect("127.0.0.1", port)(dispatch, config)
      local request, notify = rpc.request, rpc.notify
      rpc.notify = function(method, params) return notify(method, engine_params(params)) end
      rpc.request = function(method, params, callback, replied)
        params = engine_params(params)
        if method ~= "textDocument/completion" then return request(method, params, callback, replied) end
        return request(method, params, function(e, res, id)
          if not e then node_edits(params, res, encoding) end
          callback(e, res, id)
        end, replied)
      end
      return rpc
    end
    vim.lsp.start({
      name = "godot-gdscript", root_dir = root, cmd = connect, godot_port = port, godot_pid = session.pid,
      on_init = function(client)
        encoding = client.offset_encoding
        local chars = client.server_capabilities.completionProvider.triggerCharacters
        for _, char in ipairs({ "%", "/" }) do
          if not vim.tbl_contains(chars, char) then table.insert(chars, char) end
        end
      end,
      on_attach = enable_completion,
      handlers = { ["gdscript/capabilities"] = function() end,
        ["gdscript/show_native_symbol"] = function(_, symbol)
          if symbol and symbol.detail then docs.preview(docs.native(symbol)) end
        end },
    }, { bufnr = buf, reuse_client = function(client, config)
      return not client:is_stopped() and client.name == config.name and client.root_dir == root
        and client.config.godot_port == port and client.config.godot_pid == session.pid
    end })
  end)
end

local function attach_shader(buf, root)
  pcall(vim.treesitter.start, buf, "gdshader")
  local dir = vim.fs.dirname(vim.api.nvim_buf_get_name(buf))
  local workspace = root or vim.fs.root(buf, ".git") or dir
  local exe = options().shader_lsp
  if vim.fn.executable(exe) ~= 1 then
    vim.notify_once("godot.nvim: gdshader-lsp executable unavailable: " .. exe, vim.log.levels.WARN)
    return
  end
  local publish = vim.lsp.handlers["textDocument/publishDiagnostics"]
  local shader = require("godot.shader")
  local encoding, legacy = "utf-16", false
  local responses = {
    ["textDocument/definition"] = function(params, result)
      return require("godot.shader_definition").correct(root, params, result, encoding, legacy)
    end,
    ["textDocument/completion"] = function(params, result) return shader.completion(params, result, encoding) end,
  }
  local function command(dispatch)
    local rpc = vim.lsp.rpc.start({ exe, "--stdio", "--log-path", "none" }, dispatch, { cwd = workspace })
    local request, notify = rpc.request, rpc.notify
    rpc.notify = function(method, params)
      return notify(method, legacy and shader.legacy_params(params) or params)
    end
    rpc.request = function(method, params, callback, replied)
      local outgoing = legacy and shader.legacy_params(params) or params
      local adapt = responses[method]
      if not adapt then return request(method, outgoing, callback, replied) end
      return request(method, outgoing, function(err, result, id)
        if not err then result = adapt(params, result) end
        callback(err, result, id)
      end, replied)
    end
    return rpc
  end
  vim.lsp.start({
    name = "gdshader-lsp", cmd = command, root_dir = workspace,
    on_init = function(client)
      encoding = client.offset_encoding
      legacy = client.server_info and client.server_info.name == "gdshader-lsp" and client.server_info.version == "0.3.1"
      if legacy then
        client.flags.allow_incremental_sync = false
        responses["textDocument/formatting"] = shader.legacy_format
        responses["textDocument/rename"] = shader.legacy_rename
        responses["workspace/symbol"] = shader.legacy_symbols
        shader.open_overloads(client)
        -- The release implements both requests but omits them from initialize.
        client.server_capabilities.definitionProvider = true
        client.server_capabilities.hoverProvider = true
      end
    end,
    on_attach = enable_completion,
    handlers = { ["textDocument/publishDiagnostics"] = function(err, params, ctx, config)
      if params and params.uri and vim.fn.has("win32") == 1 then
        params.uri = params.uri:gsub("%%5[cC]", "/"):gsub("%%3[aA]", ":")
      end
      if legacy and params and params.uri and params.diagnostics then
        if shader.is_overload_file(params.uri) then return end
        shader.legacy_diagnostics(params, encoding)
      end
      return publish(err, params, ctx, config)
    end },
  }, { bufnr = buf })
end

local function gd_definition(buf)
  local client = vim.lsp.get_clients({ bufnr = buf, name = "godot-gdscript" })[1]
  if not client then return vim.lsp.buf.definition() end
  local win, cursor = vim.api.nvim_get_current_win(), vim.api.nvim_win_get_cursor(0)
  local params = vim.lsp.util.make_position_params(win, client.offset_encoding)
  client:request("textDocument/definition", params, function(err, result)
    if vim.api.nvim_get_current_win() ~= win or vim.api.nvim_get_current_buf() ~= buf
      or not vim.deep_equal(cursor, vim.api.nvim_win_get_cursor(win)) then return end
    if err then warn(err.message); return end
    if type(result) ~= "table" or not next(result) then return M.doc(buf) end
    if result.uri or result.targetUri or #result == 1 then
      vim.lsp.util.show_document(result[1] or result, client.offset_encoding, { focus = true })
    else
      vim.fn.setqflist({}, " ", { title = "Godot definitions", items = vim.lsp.util.locations_to_items(result, client.offset_encoding) })
      vim.cmd.copen()
    end
  end, buf)
end

function M.definition(buf)
  if vim.bo[buf].filetype == "gdscript" then return gd_definition(buf) end
  return vim.lsp.buf.definition()
end

function M.attach(buf, root)
  if buf == 0 then buf = vim.api.nvim_get_current_buf() end
  local ft = vim.bo[buf].filetype
  if ft == "gdscript" or ft == "gdresource" then
    start_local(buf, root, ft)
    if ft == "gdscript" then attach_gd(buf, root) end
  elseif ft == "gdshader" then
    attach_shader(buf, root)
  else
    return
  end
  vim.api.nvim_buf_call(buf, function()
    if vim.fn.maparg("gd", "n") == "" then
      vim.keymap.set("n", "gd", function()
        M.definition(buf)
      end, { buffer = buf, desc = "Godot definition" })
    end
  end)
end

function M.doc(buf, query)
  if buf == 0 then buf = vim.api.nvim_get_current_buf() end
  if not query or query == "" then
    query = vim.api.nvim_buf_call(buf, function()
      local word = vim.fn.expand("<cword>")
      local before = vim.api.nvim_get_current_line():sub(1, vim.api.nvim_win_get_cursor(0)[2] + 1)
      local owner = before:match("([A-Z][%w_]*)%.[%w_]*$")
      return owner and (owner .. "." .. word) or word
    end)
  end
  local base
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    base = line:match("^%s*extends%s+([%w_]+)")
    if base then break end
  end
  local class, member = query:match("^([%w_]+)%.([%w_]+)$")
  local function cached()
    docs.load(function(api, err)
      if not vim.api.nvim_buf_is_valid(buf) or vim.api.nvim_get_current_buf() ~= buf then return end
      local text = api and docs.lookup(api, query, base)
      if text then docs.preview(text) else warn(err or ("No official documentation for " .. query)) end
    end)
  end
  local client = vim.lsp.get_clients({ bufnr = buf, name = "godot-gdscript" })[1]
  if client and (class or base) then
    local sent = client:request("textDocument/nativeSymbol", { native_class = class or base, symbol_name = member or query }, function(_, result)
      if result and result ~= vim.NIL and result.detail and result.documentation and result.documentation ~= "" then
        if vim.api.nvim_get_current_buf() == buf then docs.preview(docs.native(result)) end
      else
        cached()
      end
    end, buf)
    if sent then return end
  end
  cached()
end

function M.format(buf)
  if buf == 0 then buf = vim.api.nvim_get_current_buf() end
  local ft, opts = vim.bo[buf].filetype, options()
  local cmd
  if ft == "gdscript" then
    cmd = { opts.gdscript_formatter, "--stdout" }
  elseif ft == "gdshader" then
    cmd = { opts.clang_format, "--assume-filename=shader.cpp",
      "--style={BasedOnStyle: LLVM, UseTab: Always, IndentWidth: 4, TabWidth: 4, SortIncludes: Never}" }
  else
    warn("Godot saves the scene format")
    return
  end
  if vim.fn.executable(cmd[1]) ~= 1 then warn("Formatter unavailable: " .. cmd[1]); return end
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  vim.system(cmd, { stdin = table.concat(lines, "\n") .. "\n", text = true,
    cwd = vim.fs.dirname(vim.api.nvim_buf_get_name(buf)), timeout = 15000,
  }, vim.schedule_wrap(function(result)
    if ft == "gdscript" and result.code == 2 then return end
    if result.code ~= 0 then
      warn(vim.trim(result.stderr or "") ~= "" and vim.trim(result.stderr) or ("Formatter exited " .. result.code))
      return
    end
    if not vim.api.nvim_buf_is_loaded(buf) then return end
    if vim.api.nvim_buf_get_changedtick(buf) ~= tick then warn("Buffer changed while formatting, retry :GodotFormat"); return end
    local formatted = vim.split(result.stdout:gsub("\n$", ""), "\n", { plain = true })
    if not vim.deep_equal(lines, formatted) then vim.api.nvim_buf_set_lines(buf, 0, -1, false, formatted) end
  end))
end
return M
