local M = {}
local uv = vim.uv
local project = require("godot.project")
local config = require("godot.config")
local clients = {}
local connecting = {}
local installations = {}
local activation_hint = "Enable Neovim Bridge under Project Settings > Plugins (Addons), or reopen this Godot project."
local changing = {
  add_node = true,
  rename_node = true,
  delete_node = true,
  reparent_node = true,
  attach_script = true,
  connect_signal = true,
  undo = true,
}

local function report(err)
  vim.notify("godot.nvim: " .. err, vim.log.levels.WARN)
end

function M.status(root)
  if not config.enabled("bridge") then return { state = "disabled" } end
  return (root and installations[project.key(root)]) or { state = "pending", message = "Open a Godot project" }
end

function M.prepare(root, retry)
  if not config.enabled("bridge") then return end
  local key = project.key(root)
  local status = installations[key]
  if status and (not retry or status.state == "pending") then return status.state == "ready", status.message end
  status = { state = "pending" }
  installations[key] = status
  local success, ok, err = pcall(require("godot.bridge_install").run, root)
  if not success then err, ok = tostring(ok), nil end
  status.state = ok and "ready" or "failed"
  status.path = root .. "/addons/nvim_bridge"
  status.message = err
  if ok then
    local session = require("godot.session")
    if not session.advertised_editor(root) then
      session.find_editor(root, function(editor)
        if installations[key] == status and config.enabled("bridge") and editor and not session.advertised_editor(root) then
          vim.notify("Godot is already open for " .. root .. ". " .. activation_hint)
        end
      end)
    end
  else
    report(tostring(err) .. " Retry with :GodotBridgeInstall.")
  end
  return ok, err
end

function M.install(root)
  if not config.require_feature("bridge") then return end
  local ok, err = M.prepare(root, true)
  if ok then vim.notify("Godot bridge configured for " .. root) end
  return ok, err
end

local function resource_name(root, file)
  local prefix = project.key(root) .. "/"
  if project.key(file):sub(1, #prefix) == prefix then
    return "res://" .. project.normalize(file):sub(#project.normalize(root) + 2)
  end
end

local function file_name(root, path)
  if type(path) ~= "string" or not vim.startswith(path, "res://") then return end
  local rel = path:sub(7)
  if rel == "" or rel:find("[:\\%c]") then return end
  for part in (rel .. "/"):gmatch("(.-)/") do
    if part == "" or part == "." or part == ".." then return end
  end
  local file = vim.fs.joinpath(root, rel)
  local stat = uv.fs_stat(file)
  if resource_name(root, file) and stat and stat.type == "file" then return file end
end

local function modified(root)
  local result = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified then
      local file = vim.api.nvim_buf_get_name(buf)
      local name = file ~= "" and resource_name(root, file)
      if name then result[#result + 1] = name end
    end
  end
  return result
end

local function stop(c, err)
  if c.dead then return end
  c.dead = true
  if clients[c.key] == c then clients[c.key] = nil end
  if c.run_controls then vim.cmd.redrawtabline(); vim.cmd.redrawstatus() end
  if not c.socket:is_closing() then c.socket:close() end
  for id, cb in pairs(c.pending) do
    c.pending[id] = nil
    cb(err)
  end
  for _, cb in ipairs(c.waiting) do cb(err) end
  c.waiting = {}
end

local function send(c, method, params, callback)
  if c.dead then return callback("Godot bridge disconnected") end
  c.seq = c.seq + 1
  local id = c.seq
  c.pending[id] = callback
  c.socket:write(vim.json.encode({ id = id, method = method, params = params }) .. "\n", vim.schedule_wrap(function(err)
    if err then stop(c, "Godot bridge disconnected: " .. err) end
  end))
  vim.defer_fn(function()
    if c.pending[id] then stop(c, "Godot did not answer " .. method .. ". Check the editor for an open dialog.") end
  end, 15000)
end

local function update_run_state(c, state)
  if type(state) == "table" then
    c.run_state = state
    vim.cmd.redrawtabline()
    vim.cmd.redrawstatus()
  end
end

local function receive(c, msg)
  if type(msg) ~= "table" then return stop(c, "Invalid bridge response") end
  if msg.event == "run_state" and c.ready and c.run_controls then
    update_run_state(c, msg.data)
    return
  end
  if msg.event == "open_file" and c.ready and type(msg.data) == "table" then
    local file = file_name(c.root, msg.data.path)
    if file then
      local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(file))
      if not ok then report(err) end
    end
    return
  end
  local cb = c.pending[msg.id]
  if cb then
    c.pending[msg.id] = nil
    cb(msg.error, msg.result)
  end
end

local function connect(s, token, callback)
  local key = project.key(s.root)
  local c = clients[key]
  if c and (c.pid ~= s.pid or c.port ~= s.bridge_port) then
    stop(c, "Godot editor changed")
    c = nil
  end
  if c then
    if c.ready then callback(nil, c) else table.insert(c.waiting, callback) end
    return
  end
  c = { root = s.root, key = key, pid = s.pid, port = s.bridge_port, socket = uv.new_tcp(),
    waiting = { callback }, seq = 0, pending = {}, bytes = "" }
  clients[key] = c
  c.socket:connect("127.0.0.1", c.port, vim.schedule_wrap(function(err)
    if c.dead then return end
    if err then return stop(c, "Cannot reach the project bridge: " .. err) end
    c.socket:read_start(vim.schedule_wrap(function(read_err, chunk)
      if c.dead then return end
      if not chunk or read_err then return stop(c, "Godot editor disconnected") end
      c.bytes = c.bytes .. chunk
      while true do
        local nl = c.bytes:find("\n", 1, true)
        if not nl then break end
        local ok, msg = pcall(vim.json.decode, c.bytes:sub(1, nl - 1))
        c.bytes = c.bytes:sub(nl + 1)
        if not ok then return stop(c, "Invalid bridge JSON") end
        receive(c, msg)
      end
      if #c.bytes > 16 * 1024 * 1024 then stop(c, "Godot bridge response is too large") end
    end))
    send(c, "hello", { token = token, watch_run = s.mode == "editor" }, function(why, hello)
      if why or type(hello) ~= "table" or type(hello.root) ~= "string"
          or project.key(hello.root) ~= key or hello.pid ~= s.pid or hello.mode ~= s.mode then
        return stop(c, why or "Godot bridge project identity did not match")
      end
      c.ready = true
      c.run_controls = hello.run_controls == true
      local waiting = c.waiting
      c.waiting = {}
      for _, cb in ipairs(waiting) do cb(nil, c) end
    end)
  end))
end

function M.connected(root)
  if not config.enabled("bridge") then return false end
  local c = clients[project.key(root)]
  return c ~= nil and c.ready == true
end

function M.disable()
  installations = {}
  for _, c in pairs(clients) do stop(c, "Godot bridge disabled") end
end

function M.run_state(key)
  local c = clients[key]
  return c and c.run_state
end

local function request(c, method, params, callback)
  if method == "run_action" and not c.run_controls then
    return callback("Update the project bridge with :GodotBridgeInstall, then reopen its Godot editor.")
  end
  params = vim.deepcopy(params or {})
  if changing[method] then params.modified = modified(c.root) end
  send(c, method, next(params) and params or vim.empty_dict(), function(err, result)
    if not err and method == "run_action" then update_run_state(c, result) end
    if not err and changing[method] then
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) and not vim.bo[buf].modified and vim.bo[buf].buftype == "" then
          local file = vim.api.nvim_buf_get_name(buf)
          if file ~= "" and resource_name(c.root, file) then
            vim.api.nvim_buf_call(buf, function() vim.cmd("silent checktime " .. buf) end)
          end
        end
      end
    end
    callback(err, result)
  end)
end

local function with_session(root, s, callback)
  if not config.enabled("bridge") then return callback("Enable opts.features.bridge to use the Godot bridge.") end
  if s and s.mode == "editor" and not s.bridge_port then return callback(activation_hint) end
  local key = project.key(root)
  if not s or type(s.root) ~= "string" or project.key(s.root) ~= key or type(s.pid) ~= "number"
      or type(s.bridge_port) ~= "number" or s.bridge_port < 1 or s.bridge_port > 65535 then
    return callback("Invalid bridge record for this project")
  end
  local client = clients[key]
  if client and client.ready and client.pid == s.pid and client.port == s.bridge_port then
    return callback(nil, client)
  end
  local target = key .. "#" .. s.pid .. ":" .. s.bridge_port
  if connecting[target] then
    table.insert(connecting[target], callback)
    return
  end
  connecting[target] = { callback }
  local function finish(err, c)
    local waiting = connecting[target]
    connecting[target] = nil
    for _, cb in ipairs(waiting) do cb(err, c) end
  end
  local file = root .. "/.godot/godot-nvim-bridge-" .. s.pid .. ".key"
  local deadline = uv.now() + 5500
  local function try()
    if not config.enabled("bridge") then return finish("Godot bridge disabled") end
    local f = io.open(file, "rb")
    local token
    if f then token = f:read("*a"); f:close() end
    if not token or not token:match("^%x+$") then
      if uv.now() < deadline then return vim.defer_fn(try, 150) end
      return finish("Godot bridge is inactive. Enable Neovim Bridge in project settings and restart Godot.")
    end
    require("godot.ports").owners(function(owners)
      if not config.enabled("bridge") then return finish("Godot bridge disabled") end
      if owners[s.bridge_port] ~= s.pid then
        return finish("Bridge port does not belong to this Godot editor")
      end
      connect(s, token, finish)
    end)
  end
  try()
end

function M.subscribe(root, session, callback)
  if not config.enabled("bridge") or not session or session.mode ~= "editor" then return end
  with_session(root, session, callback or function() end)
end

function M.call(root, method, params, callback)
  callback = callback or function(err) if err then report(err) end end
  if not config.enabled("bridge") then return callback("Enable opts.features.bridge to use the Godot bridge.") end
  local client = clients[project.key(root)]
  if method == "run_action" and client and client.ready and client.run_controls then
    return request(client, method, params, callback)
  end
  if not uv.fs_stat(root .. "/addons/nvim_bridge/plugin.cfg") then
    return callback("Install the project bridge with :GodotBridgeInstall first.")
  end
  require("godot.session").ensure(root, method == "resolve" and "language" or "editor", function(err, s)
    if err then return callback(err) end
    with_session(root, s, function(why, c)
      if why then return callback(why) end
      request(c, method, params, callback)
    end)
  end)
end

local function under_cursor()
  local line, col = vim.api.nvim_get_current_line(), vim.api.nvim_win_get_cursor(0)[2] + 1
  local from = 1
  while from <= #line do
    local first = line:find("[ru][ei][sd]://", from)
    if not first then break end
    local quote = line:sub(first - 1, first - 1)
    local last
    if quote == "'" or quote == '"' then
      last = (line:find(quote, first + 6, true) or (#line + 1)) - 1
    else
      last = (line:find("[%s\"'%)%]%}>;,]", first + 6) or (#line + 1)) - 1
    end
    if first <= col and col <= last + 1 then return line:sub(first, last) end
    from = last + 1
  end
end

function M.resource(root, arg, callback)
  local path = arg ~= "" and arg or nil
  path = path or under_cursor()
  callback = callback or function(err) if err then report(err) end end
  if not path then return callback("Place the cursor on a res:// or uid:// resource.") end
  local function open(res)
    local file = file_name(root, res)
    if not file then return callback("Cannot locate resource: " .. path) end
    local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(file))
    callback(not ok and tostring(err) or nil, file)
  end
  if vim.startswith(path, "res://") then return open(path) end
  if not path:match("^uid://[a-z0-9]+$") then return callback("Cannot locate resource: " .. path) end
  if M.connected(root) then
    request(clients[project.key(root)], "resolve", { path = path }, function(err, data)
      if err then return callback(err) end
      open(data.path)
    end)
    return
  end
  local script = vim.api.nvim_get_runtime_file("scripts/resolve_uid.gd", false)[1]
  require("godot.session").engine(root, function(why, executable)
    if why then return callback(why) end
    local ok, err = pcall(vim.system, { executable, "--headless", "--path", root, "--script", script, "--", path },
      { cwd = root, text = true, timeout = 15000 }, vim.schedule_wrap(function(proc)
        local res = (proc.stdout or ""):match("GODOT_NVIM_RESOURCE=([^\r\n]+)")
        if proc.code ~= 0 or not res then return callback("Cannot locate resource: " .. path .. ". Open or import the project in Godot.") end
        open(res)
      end))
    if not ok then callback(tostring(err)) end
  end)
end

return M
