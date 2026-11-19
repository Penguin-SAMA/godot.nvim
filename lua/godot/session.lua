local project = require("godot.project")
local ports = require("godot.ports")
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
      and project.alive(data.pid) and data.mode == mode then
    return data
  end
end

local function candidates(root, purpose)
  local list, seen = {}, {}
  local editor_only = purpose == "editor" or purpose == "debug_current"
  local function add(file, mode)
    local s = record(root, file, mode)
    if s and not seen[s.pid] then
      seen[s.pid] = true
      list[#list + 1] = s
    end
  end
  -- The addon also advertises editors launched from the Godot project manager.
  add(root .. "/.godot/godot-nvim-editor.json", "editor")
  add(path(root, "editor"), "editor")
  for _, s in ipairs(observed[project.key(root)] or {}) do
    if project.alive(s.pid) and not seen[s.pid] and (not editor_only or s.mode == "editor") then
      seen[s.pid] = true
      list[#list + 1] = s
    end
  end
  if not editor_only then add(path(root, "headless"), "headless") end
  return list
end

-- Only protect the short read/spawn/publish sequence across nvim instances.
-- The (possibly lengthy) project import and service startup run outside the lock.
local function lock(root)
  local file = project.directory(root) .. "/session.lock"
  local fd = uv.fs_open(file, "wx", 384)
  if not fd then
    local s = project.read(file)
    local stat = uv.fs_stat(file)
    if (s and not project.alive(s.pid)) or (not s and stat and os.time() - stat.mtime.sec > 5) then
      uv.fs_unlink(file)
    end
    return
  end
  uv.fs_write(fd, vim.json.encode({ pid = uv.os_getpid() }), 0)
  uv.fs_close(fd)
  return function() uv.fs_unlink(file) end
end

function M.track(root)
  project.track(root)
  tracked[project.key(root)] = root
end

local function launch(root, mode)
  local options = require("godot.config").options
  local executable = vim.fn.exepath(options.executable)
  assert(executable ~= "", "Godot executable not found: " .. options.executable)
  executable = project.normalize(executable)
  -- The official Windows console launcher forks the actual editor. Track
  -- the listener-owning binary so lifecycle checks use the right PID.
  local editor_exe, suffix = executable:gsub("_[Cc][Oo][Nn][Ss][Oo][Ll][Ee]%.[Ee][Xx][Ee]$", ".exe")
  if suffix > 0 and uv.fs_stat(editor_exe) then executable = editor_exe end
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

function M.ensure(root, purpose, callback)
  if closing then return callback("Neovim is closing") end
  M.track(root)
  local key = project.key(root) .. "#" .. purpose
  if pending[key] then
    table.insert(pending[key], callback)
    return
  end
  pending[key] = { callback }
  local timeout = require("godot.config").options.startup_timeout
  local deadline = uv.now() + timeout
  local spawned, discovery_grace
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
      local release = lock(root)
      if release then
        local ok, result = pcall(function()
          M.track(root)
          local list = candidates(root, purpose)
          for _, s in ipairs(list) do
            if ready(s, purpose, owners) then return s end
          end
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
          if spawned and not project.alive(spawned.pid) then
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
          if not spawned then spawned = launch(root, mode) end
        end)
        release()
        if not ok then return finish(tostring(result)) end
        if result then return finish(nil, result) end
      end
      vim.defer_fn(poll, 200)
    end)
  end
  if #candidates(root, purpose) == 0 then
    require("godot.discovery").find(root, function(found)
      observed[project.key(root)] = found
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
    local release = lock(root)
    if not release then
      vim.wait(500, function() release = lock(root); return release ~= nil end, 15)
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

