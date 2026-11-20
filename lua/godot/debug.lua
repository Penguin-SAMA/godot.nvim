local M = {}
local project = require("godot.project")
local output = require("godot.output")
local features = require("godot.config")
local adapter = "godot.nvim"
local active = {}
local registrations = {}

local function warn(message)
  vim.notify("Godot: " .. message, vim.log.levels.WARN)
end

local function debugger()
  if not features.require_feature("dap") then return end
  local tool = require("godot.tools").status("dap")
  if tool.state ~= "ready" then
    warn(tool.message or "nvim-dap is being prepared. Retry the command when it is ready.")
    return
  end
  local ok, dap = pcall(require, "dap")
  if ok then return dap end
  warn("Could not load nvim-dap: " .. tostring(dap))
end

local function scene_path(root, scene)
  if not scene or scene == "" or scene == "main" then return "main" end
  if scene == "current" then
    local file = vim.api.nvim_buf_get_name(0)
    if not file:lower():match("%.t?scn$") then return "current" end
    scene = file
  end
  if vim.startswith(scene, "res://") then scene = root .. "/" .. scene:sub(7) end
  if not scene:match("^[/\\]") and not scene:match("^%a:[/\\]") then scene = root .. "/" .. scene end
  local path = project.normalize(scene)
  local rel = vim.fs.relpath(root, path)
  if not rel or not rel:lower():match("%.t?scn$") or vim.fn.filereadable(path) == 0 then
    return nil, "Select an existing .tscn or .scn scene in " .. root
  end
  return "res://" .. rel
end

local function owned(session)
  if session.config.type ~= adapter then return end
  local entry = active[session.config.project]
  if entry and entry.session == session then return entry end
end

local function terminate(session)
  -- Godot acknowledges the request before the game exits. Keep this connection
  -- until its terminated event so the next launch cannot receive that event.
  session:request("terminate", vim.empty_dict(), function() end)
  vim.defer_fn(function()
    if not session.closed then session:disconnect({ terminateDebuggee = true }) end
  end, 5000)
end

local function related(stop, diagnostic)
  if not diagnostic or diagnostic.paired then return false end
  local a, b = stop.location, diagnostic.location
  local same_source = a and b and a.path == b.path and a.line == b.line
  if a and b and not same_source then return false end
  local message = stop.text or stop.description
  if message == diagnostic.message or message == diagnostic.code then return true end
  return (not message or message:lower() == "exception") and same_source
end

local function append_error(root, message, target)
  return output.append(root, message, target and target.path, target and target.line)
end

local function exception(session, entry, body)
  local root = session.config.project
  local stop = { text = body.text, description = body.description, diagnostics = {} }
  -- A Godot error and its stopped event may be delivered in either order.
  -- Consume at most one partner per stop; later identical errors have their own rows.
  local prior = entry.last_error
  if prior and vim.uv.now() - prior.time >= 1000 then prior = nil end
  entry.exception, entry.last_error = stop, nil
  session:request_with_timeout("stackTrace", { threadId = body.threadId or 1 }, 3000, function(_, response)
    if not owned(session) then return end
    for _, frame in ipairs(response and response.stackFrames or {}) do
      stop.location = output.script_location(root, frame.source and frame.source.path, frame.line)
      if stop.location then break end
    end
    local match
    for _, candidate in ipairs(stop.diagnostics) do
      if related(stop, candidate) then match = candidate; break end
    end
    if not match and related(stop, prior) then match = prior end
    stop.diagnostics = nil
    if match then
      stop.paired, match.paired = true, true
      output.link(match.record, match.location or stop.location)
    else
      stop.record = append_error(root, "Error: " .. (stop.text or stop.description or "Script exception"), stop.location)
    end
  end)
end

local function godot_error(session, entry, data)
  if type(data) ~= "table" or type(data[8]) ~= "string" then return end
  local root = session.config.project
  -- OutputError contains the engine origin in fields 5–7, followed by
  -- (file, function, line) triples beginning at field 12.
  local target
  for i = 12, #data - 2, 3 do
    target = output.script_location(root, data[i], data[i + 2])
    if target then break end
  end
  target = target or output.script_location(root, data[5], data[7])
  local message = type(data[9]) == "string" and data[9] ~= "" and data[9] or data[8]
  if data[10] == true then
    append_error(root, "Warning: " .. message, target)
    return
  end
  local diagnostic = { code = data[8], message = message, location = target, time = vim.uv.now() }
  local stop = entry.exception
  if stop and stop.record and not stop.paired and related(stop, diagnostic) then
    stop.paired, entry.last_error = true, nil
    local detail = stop.text ~= message and ("Error: " .. message) or nil
    output.link(stop.record, target or stop.location, detail)
    return
  end
  diagnostic.record = append_error(root, "Error: " .. message, target)
  entry.last_error = diagnostic
  if stop and stop.diagnostics and (not stop.text or related(stop, diagnostic)) then
    table.insert(stop.diagnostics, diagnostic)
  end
end

local function configure(dap)
  if dap.adapters[adapter] then return end
  local function register(target, callback)
    target[adapter] = callback
    registrations[target] = callback
  end
  register(dap.adapters, function(connect, config)
    if not features.require_feature("dap") then return end
    local root = config.project
    if active[root] then
      warn("A game is starting or running in " .. root .. ". Stop it with :GodotStop.")
      return
    end
    local entry = {}
    active[root] = entry
    local purpose = config.scene == "current" and "debug_current" or "debug"
    require("godot.session").ensure(root, purpose, function(err, instance)
      if active[root] ~= entry then return end
      if err or (config.scene == "current" and instance.mode == "headless") then
        active[root] = nil
        warn(err or "Open a scene in Neovim or start the Godot editor to run its current scene.")
        return
      end
      output.append(root, (config.noDebug and "Run " or "Debug ") .. config.scene)
      connect({ type = "server", id = "godot", host = "127.0.0.1", port = instance.dap_port })
    end)
  end)

  register(dap.listeners.on_session, function(_, session)
    if not session or session.config.type ~= adapter then return end
    local root = session.config.project
    local entry = active[root]
    if not entry or entry.session then return end
    entry.session = session
    session.on_close[adapter] = function()
      if active[root] == entry then
        active[root] = nil
        if entry.restart then vim.schedule(entry.restart) end
      end
    end
    -- nvim-dap broadcasts every buffer's breakpoints to every session.
    -- Godot rejects sources outside the connected editor's project.
    local send = session.set_breakpoints
    session.set_breakpoints = function(self, breakpoints, done)
      local local_breakpoints = {}
      for buf, points in pairs(breakpoints) do
        local path = vim.api.nvim_buf_get_name(buf)
        if vim.fs.relpath(root, project.normalize(path)) then local_breakpoints[buf] = points end
      end
      return send(self, local_breakpoints, done)
    end
  end)

  register(dap.listeners.before.launch, function(session, err)
    -- nvim-dap closes a failed launch in its response handler.
    if err and owned(session) then
      output.append(session.config.project, "Could not launch " .. session.config.scene .. ": " .. tostring(err))
    end
  end)
  register(dap.listeners.after.launch, function(session, err)
    local entry = owned(session)
    if not entry or err then return end
    entry.launched = true
    if entry.stopping then terminate(session) end
  end)
  register(dap.listeners.after.event_output, function(session, body)
    if owned(session) and body.category ~= "telemetry" then
      output.append(session.config.project, body.output, body.source and body.source.path, body.line)
    end
  end)
  register(dap.listeners.before.event_stopped, function(session, body)
    -- Godot also stops on script errors during a plain run. Leave the output
    -- window focused until the user chooses a source location.
    local entry = owned(session)
    if not entry then return end
    if session.config.noDebug then body.preserveFocusHint = true end
    if body.reason == "exception" then
      exception(session, entry, body)
    else
      entry.exception, entry.last_error = nil, nil
    end
  end)
  local function resumed(session)
    local entry = owned(session)
    if entry then entry.exception, entry.last_error = nil, nil end
  end
  register(dap.listeners.after.event_continued, resumed)
  register(dap.listeners.after["continue"], function(session, err) if not err then resumed(session) end end)
  register(dap.listeners.after["event_godot/custom_data"], function(session, event)
    local entry = owned(session)
    if entry and event.message == "error" then godot_error(session, entry, event.data) end
  end)
end

function M.start(root, scene, debugging)
  local dap = debugger()
  if not dap then return end
  root = project.normalize(root)
  local target, err = scene_path(root, scene)
  if not target then return warn(err) end
  configure(dap)
  local config = {
    type = adapter,
    request = "launch",
    name = "Godot " .. target .. " (" .. root .. ")",
    scene = target,
    project = root,
    noDebug = not debugging,
    ["godot/custom_data"] = true,
  }
  local function run()
    if features.enabled("dap") then dap.run(config, { new = true, filetype = "gdscript" }) end
  end
  local entry = active[root]
  if entry and entry.stopping then entry.restart = run else run() end
end

local function stop(root)
  root = project.normalize(root)
  local entry = active[root]
  if not entry then return warn("No game is running in " .. root) end
  if not entry.session then
    active[root] = nil
  elseif entry.stopping then
    entry.restart = nil
  else
    entry.stopping = true
    if entry.launched then terminate(entry.session) end
  end
end

function M.stop(root)
  if features.require_feature("dap") then stop(root) end
end

function M.output(root)
  if not features.require_feature("dap") then return end
  return output.open(project.normalize(root))
end

function M.control(root, action)
  local dap = debugger()
  if not dap then return end
  if action == "toggle_breakpoint" then return dap.toggle_breakpoint() end
  local entry = active[project.normalize(root)]
  local session = entry and entry.session
  if not session or session.closed or not session.stopped_thread_id then
    return warn("No paused Godot debug session in " .. root)
  end
  dap.set_session(session)
  if action == "frames" then
    local widgets = require("dap.ui.widgets")
    return widgets.centered_float(widgets.frames)
  end
  dap[action]()
end

function M.shutdown()
  for root, entry in pairs(active) do
    entry.restart = nil
    stop(root)
  end
  if next(active) then vim.wait(2000, function() return next(active) == nil end, 20) end
  -- A slow launch might still be waiting for its response when the feature is
  -- turned off. Disconnect it before removing the normal launch listeners.
  for _, entry in pairs(active) do
    if entry.session and not entry.launched and not entry.session.closed then
      entry.session:disconnect({ terminateDebuggee = true })
    end
  end
  for target, callback in pairs(registrations) do
    if target[adapter] == callback then target[adapter] = nil end
  end
  registrations = {}
end

return M
