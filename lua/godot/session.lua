local project = require("godot.project")
local ports = require("godot.ports")
local process = require("godot.process")
local uv = vim.uv
local M = {}
local tracked, pending, children, observed = {}, {}, {}, {}
local closing = false

local function path(root, mode)
  return project.directory(root) .. "/" .. mode .. ".json"
end

local function record(root, file, mode)
  local data = project.read(file)
  if data and type(data.root) == "string" and project.key(data.root) == project.key(root)
      and data.mode == mode and process.matches(data, file) then
    return data
  end
end

function M.advertised_editor(root)
  return record(root, root .. "/.godot/godot-nvim-editor.json", "editor")
end

local function candidates(root, purpose)
  local list, seen = {}, {}
  local editor_only = purpose == "editor" or purpose == "debug_current"
  local function add(s)
    if s and not seen[s.pid] then
      seen[s.pid] = true
      list[#list + 1] = s
    end
  end
  -- The addon also advertises editors launched from the Godot project manager.
  add(M.advertised_editor(root))
  add(record(root, path(root, "editor"), "editor"))
  for _, s in ipairs(observed[project.key(root)] or {}) do
    if not seen[s.pid] and (not editor_only or s.mode == "editor") and process.matches(s) then
      seen[s.pid] = true
      list[#list + 1] = s
    end
  end
  if not editor_only then add(record(root, path(root, "headless"), "headless")) end
  return list
end

-- Only protect the short read/spawn/publish sequence across nvim instances.
-- The (possibly lengthy) project import and service startup run outside the lock.
function M.track(root)
  project.track(root)
  tracked[project.key(root)] = root
end

local function launch(root, mode, executable)
  local available = ports.allocate(4)
  local s = {
    root = root, mode = mode, lsp_port = available[1], dap_port = available[2],
    bridge_port = available[3], created = os.time(), executable = executable,
  }
  local args = {
    executable, "--editor", "--path", root, "--lsp-port", tostring(s.lsp_port),
    "--dap-port", tostring(s.dap_port), "--debug-server", "tcp://127.0.0.1:" .. available[4],
  }
  if mode == "headless" then table.insert(args, "--headless") end
  local proc = vim.system(args, {
    cwd = root, env = { NVIM_BRIDGE_PORT = tostring(s.bridge_port),
      GODOT_NVIM_LSP_PORT = tostring(s.lsp_port), GODOT_NVIM_DAP_PORT = tostring(s.dap_port) },
    detach = true, stdout = false, stderr = false,
  }, function()
    vim.schedule(function()
      if s.pid then children[s.pid] = nil end
    end)
  end)
  s.pid = proc.pid
  s.started_us = process.started_us(s.pid)
  children[s.pid] = proc
  local saved, why = pcall(project.write, path(root, mode), s)
  if not saved then
    proc:kill(15)
    error("Could not record the new Godot process: " .. tostring(why))
  end
  return s
end

local function ready(s, purpose, owners)
  if purpose == "editor" then
    return s.mode == "editor" and (owners[s.bridge_port] == s.pid
      or owners[s.lsp_port] == s.pid or owners[s.dap_port] == s.pid)
  end
  local port = purpose:match("^debug") and s.dap_port or s.lsp_port
  return owners[port] == s.pid
end

function M.status(root)
  local list = candidates(root, "language")
  return list[1] or { root = root, mode = "disconnected" }
end

function M.instances(root)
  return candidates(root, "language")
end

-- Coalesce discovery when opening a script requests both language service and docs.
local discovering = {}
local function discover(root, callback)
  local key = project.key(root)
  if discovering[key] then
    table.insert(discovering[key], callback)
    return
  end
  discovering[key] = { callback }
  require("godot.discovery").find(root, function(found)
    -- Managed sessions already have a record with the bridge port and process
    -- start time. A partial discovery result must not shadow that record.
    local unmanaged = {}
    for _, s in ipairs(found) do
      local managed = record(root, path(root, s.mode), s.mode)
      if not managed or managed.pid ~= s.pid then
        s.started_us = process.started_us(s.pid)
        unmanaged[#unmanaged + 1] = s
      end
    end
    observed[key] = unmanaged
    local waiters = discovering[key]
    discovering[key] = nil
    for _, cb in ipairs(waiters) do cb(found) end
  end, M.advertised_editor(root))
end

function M.find_editor(root, callback)
  local current = candidates(root, "editor")[1]
  if current then return callback(current) end
  discover(root, function() callback(candidates(root, "editor")[1]) end)
end

-- Only launch paths supplied by OS discovery, our local state or the user.
-- The add-on record in the project can identify a session but cannot nominate a binary.
local function running_engine(root, mode)
  local s = record(root, path(root, mode), mode)
  if s and s.executable then return s.executable end
  for _, instance in ipairs(observed[project.key(root)] or {}) do
    if instance.mode == mode and process.matches(instance) then return instance.executable end
  end
end

local function choose_engine(root, callback, cached_only)
  local exe = running_engine(root, "editor") or running_engine(root, "headless")
  if exe then return callback(nil, exe) end
  require("godot.engine").resolve(root, callback, cached_only)
end

function M.engine(root, callback, cached_only)
  if not root then return require("godot.engine").resolve(nil, callback, cached_only) end
  if cached_only or running_engine(root, "editor") then return choose_engine(root, callback, cached_only) end
  discover(root, function() choose_engine(root, callback) end)
end

function M.ensure(root, purpose, callback)
  if closing then return callback("Neovim is closing") end
  require("godot.bridge").prepare(root)
  M.track(root)
  local key = project.key(root) .. "#" .. purpose
  if pending[key] then
    table.insert(pending[key], callback)
    return
  end
  pending[key] = { callback }
  local timeout = require("godot.config").options.startup_timeout
  local deadline = uv.now() + timeout
  local spawned, discovery_grace, executable
  local needs_engine = {}
  local function finish(err, s)
    local waiters = pending[key] or {}
    pending[key] = nil
    for _, notify in ipairs(waiters) do
      local ok, why = pcall(notify, err, s)
      if not ok then vim.notify(tostring(why), vim.log.levels.ERROR) end
    end
  end
  local function poll()
    if closing then return finish("Neovim is closing") end
    if uv.now() >= deadline then
      return finish("Godot " .. purpose .. " timed out for " .. root .. ". Run :checkhealth godot, then :GodotReconnect.")
    end
    ports.owners(function(owners)
      if closing then return finish("Neovim is closing") end
      local release = project.lock(root, "session")
      if release then
        local ok, result = pcall(function()
          M.track(root)
          local list = candidates(root, purpose)
          for _, s in ipairs(list) do
            if ready(s, purpose, owners) then return s end
          end
          -- The GUI already exists. Wait for its listeners instead of starting a second one.
          if purpose == "editor" and #list > 0 then return end
          -- A manually opened GUI may still be importing assets. Give its
          -- unoccupied service port time to start before launching a helper.
          if discovery_grace and uv.now() < discovery_grace then
            for _, s in ipairs(list) do
              local port = purpose:match("^debug") and s.dap_port or s.lsp_port
              if port and not owners[port] then return end
            end
          end
          if purpose == "debug_current" then
            error("Open a .tscn in Neovim or open the scene in Godot with an active debug service.")
          end
          if spawned and not process.matches(spawned) then
            error("Godot exited during startup for " .. root .. ". Check the configured executable and project.")
          end
          local mode = purpose == "editor" and "editor" or "headless"
          local prior = record(root, path(root, mode), mode)
          if prior then
            if (os.time() - (prior.created or 0)) * 1000 < timeout then return end
            -- Its other service can still be in use. Never overwrite the
            -- ownership record of a live editor when one listener is down.
            error(("Godot PID %d is still running for %s, but its %s service is unavailable. "
              .. "Close that editor and retry, or inspect :checkhealth godot."):format(prior.pid, root, purpose))
          end
          if not executable then return needs_engine end
          if not spawned then spawned = launch(root, mode, executable) end
        end)
        release()
        if not ok then return finish(tostring(result)) end
        if result == needs_engine then
          -- User input may take arbitrarily long. Resume outside the lock, then
          -- check again for an editor opened while the picker was visible.
          return choose_engine(root, function(err, exe)
            if err then return finish(err) end
            executable = exe
            discover(root, function(found)
              deadline = uv.now() + timeout
              if #found > 0 then discovery_grace = uv.now() + 6000 end
              poll()
            end)
          end)
        end
        if result then return finish(nil, result) end
      end
      vim.defer_fn(poll, 200)
    end)
  end
  if #candidates(root, "editor") == 0 then
    discover(root, function(found)
      if #found > 0 then discovery_grace = uv.now() + 6000 end
      poll()
    end)
  else
    poll()
  end
end

function M.release_all()
  closing = true
  for _, root in pairs(tracked) do
    local release = project.lock(root, "session")
    if not release then
      vim.wait(500, function() release = project.lock(root, "session"); return release ~= nil end, 15)
    end
    project.untrack(root)
    if release then
      if #project.clients(root) == 0 then
        local file = path(root, "headless")
        local s = record(root, file, "headless")
        if s then
          local own_handle = children[s.pid]
          local listening = not own_handle and ports.owners() or {}
          if own_handle or listening[s.lsp_port] == s.pid or listening[s.dap_port] == s.pid
              or listening[s.bridge_port] == s.pid then
            uv.kill(s.pid, 15)
            uv.fs_unlink(file)
          end
        end
      end
      release()
    end
  end
  tracked = {}
end
return M

