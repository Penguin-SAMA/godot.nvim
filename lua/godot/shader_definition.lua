local M = {}

local function resolve(root, file, include)
  local base = vim.fs.dirname(file)
  if vim.startswith(include, "res://") then base, include = root, include:sub(7) end
  local path = vim.fs.normalize(vim.fs.joinpath(base, include))
  if vim.fs.relpath(root, path) then return path end
end

local function contents(path)
  local buf = vim.fn.bufnr(path)
  if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  end
  local file = io.open(path, "rb")
  if not file then return end
  local source = file:read("*a")
  file:close()
  return source
end

local function declarations(source, name)
  local includes, matches = {}, {}
  local ok, parser = pcall(vim.treesitter.get_string_parser, source, "gdshader")
  if ok and parser then
    local tree = parser:parse()[1]
    if tree then
      for node in tree:root():iter_children() do
        if node:type() == "preproc_include" then
          local path = node:field("path")[1]
          if path then
            local include = vim.treesitter.get_node_text(path, source):match('^"(.-)"$')
            if include then table.insert(includes, include) end
          end
        elseif node:type() == "function_definition" then
          local id = node:field("declarator")[1]
          if id and vim.treesitter.get_node_text(id, source) == name then
            local row, byte = id:range()
            table.insert(matches, { row, byte })
          end
        end
      end
      return includes, matches
    end
  end
  for row, line in ipairs(vim.split(source, "\n", { plain = true })) do
    local path = line:match('^%s*#%s*include%s*"([^"]+)"')
    if path then table.insert(includes, path) end
    local ty, pos = line:match("^%s*([%w_]+)%s+()" .. name .. "%s*%(")
    if ty and ty ~= "return" then table.insert(matches, { row - 1, pos - 1 }) end
  end
  return includes, matches
end

-- Some gdshader-lsp versions report include-local rows against the caller URI.
-- Verify the reported origin first. Follow only this shader's actual includes.
function M.correct(root, params, result, encoding)
  local buf = vim.uri_to_bufnr(params.textDocument.uri)
  if not vim.api.nvim_buf_is_loaded(buf) then return result end
  local file = vim.fs.normalize(vim.api.nvim_buf_get_name(buf))
  local pos = params.position
  local line = vim.api.nvim_buf_get_lines(buf, pos.line, pos.line + 1, false)[1] or ""
  local byte = vim.str_byteindex(line, encoding, pos.character, false)
  local include = line:match('^%s*#%s*include%s*"([^"]+)"')
  if include then
    local path = resolve(root, file, include)
    if path and vim.fn.filereadable(path) == 1 then
      local zero = { line = 0, character = 0 }
      return { uri = vim.uri_from_fname(path), range = { start = zero, ["end"] = zero } }
    end
    return result
  end
  local name = (line:sub(1, byte):match("[%w_]*$") or "") .. (line:sub(byte + 1):match("^([%w_]*)%s*%(") or "")
  if name == "" or not line:find("%f[%w_]" .. name .. "%s*%(") then return result end
  local hit = type(result) == "table" and (result.uri and result or result[1])
  if hit and hit.uri and vim.fs.normalize(vim.uri_to_fname(hit.uri)) ~= file then return result end
  local visited, matches = {}, {}
  local function walk(path, primary)
    local key = vim.fn.has("win32") == 1 and path:lower() or path
    if visited[key] then return end
    visited[key] = true
    local source = contents(path)
    if not source then return end
    local includes, found = declarations(source, name)
    if primary and #found > 0 then return end
    for _, location in ipairs(found) do
      local row, col = unpack(location)
      local lines = vim.split(source, "\n", { plain = true })
      local start = vim.str_utfindex(lines[row + 1], encoding, col, false)
      table.insert(matches, { uri = vim.uri_from_fname(path), range = {
        start = { line = row, character = start }, ["end"] = { line = row, character = start + #name },
      } })
    end
    for _, child in ipairs(includes) do
      local nested = resolve(root, path, child)
      if nested then walk(nested, false) end
    end
  end
  walk(file, true)
  return #matches > 0 and matches or result
end

return M
