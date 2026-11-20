local config = require("godot.config")
local project = require("godot.project")
local M = {}

local features = {
  scene_tree = "scene_tree", dap = "dap", shader_lsp = "shader_lsp",
  gdscript_formatter = "formatting", clang_format = "formatting",
}
local commands = { shader_lsp = "gdshader-lsp", gdscript_formatter = "gdscript-formatter", clang_format = "clang-format" }
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))))
local store = vim.fs.joinpath(vim.fn.stdpath("data"), "godot.nvim", "tools")
local windows_x64 = vim.fn.has("win32") == 1 and jit and jit.arch == "x64"
local manifest, states, jobs, hashes = nil, {}, {}, {}
local managed_parser

local function result(state, message, path)
  return { state = state, message = message, path = path }
end

local function dap_commands(dap)
  if type(dap) ~= "table" or type(dap.listeners) ~= "table" or type(dap.listeners.on_session) ~= "table"
      or type(dap.set_session) ~= "function" or type(dap.run) ~= "function" then
    error("The loaded nvim-dap lacks required session APIs. Update nvim-dap and restart Neovim.")
  end
  if vim.fn.exists(":DapContinue") ~= 0 then return end
  local script = vim.api.nvim_get_runtime_file("plugin/dap.lua", false)[1]
  if script then vim.cmd.source(vim.fn.fnameescape(script)) end
end

local function existing(id)
  if id == "scene_tree" then
    local ok, loaded = pcall(vim.treesitter.language.add, "godot_resource")
    if ok and loaded then
      local path = managed_parser or vim.api.nvim_get_runtime_file("parser/godot_resource.*", false)[1]
      return result("ready", "Loaded godot_resource parser", path)
    end
  elseif id == "dap" then
    local available, dap = pcall(require, "dap")
    if available then
      local ok, why = pcall(dap_commands, dap)
      if not ok then return result("failed", tostring(why)) end
      local file = vim.api.nvim_get_runtime_file("lua/dap.lua", false)[1]
      return result("ready", "Loaded nvim-dap", file and vim.fs.dirname(vim.fs.dirname(file)))
    end
  else
    local cmd = config.options[id]
    local path = type(cmd) == "string" and vim.fn.exepath(cmd) or ""
    if path ~= "" then return result("ready", "Using " .. path, path) end
    if cmd ~= commands[id] then return result("failed", "Configured executable is unavailable: " .. tostring(cmd)) end
  end
end

local function package_for(id, root)
  manifest = manifest or project.read(vim.fs.joinpath(plugin, "scripts", "dependencies-windows.json"))
  if not manifest then return nil, "Cannot read the godot.nvim Windows dependency manifest" end
  local version
  if id == "shader_lsp" and root then
    local session = require("godot.session").status(root)
    local want = require("godot.engine").requirement(root)
    local value = type(session.version) == "string" and session.version or want.pin or want.series or ""
    version = value:match("^(%d+%.%d+%.%d+)") or value:match("^(%d+%.%d+)")
  end
  for _, pkg in ipairs(manifest.packages) do
    if pkg.id == id then
      if id ~= "shader_lsp" or (not version and pkg.default) then return pkg end
      if version and (not pkg.godotMin or vim.version.ge(version, pkg.godotMin))
          and (not pkg.godotMaxExclusive or vim.version.lt(version, pkg.godotMaxExclusive)) then return pkg end
    end
  end
  return nil, "No pinned " .. id .. " package for Godot " .. (version or "(unknown version)")
end

local function activate(pkg, path)
  if pkg.id == "scene_tree" then
    local ok, err = vim.treesitter.language.add("godot_resource", { path = path })
    if not ok then error(err or "Cannot load godot_resource") end
    managed_parser = path
  elseif pkg.id == "dap" then
    if not vim.tbl_contains(vim.opt.runtimepath:get(), path) then vim.opt.runtimepath:append(path) end
    dap_commands(require("dap"))
  elseif vim.fn.executable(path) ~= 1 then
    error("Installed executable unavailable: " .. path)
  end
  return result("ready", "Managed " .. pkg.id .. " " .. pkg.version, path)
end

local function published(dir, pkg)
  local marker = project.read(dir .. "/installed.json")
  if not marker or marker.sha256 ~= pkg.sha256 then return end
  local path = vim.fs.joinpath(dir, pkg.path)
  if vim.uv.fs_stat(pkg.id == "dap" and path .. "/lua/dap.lua" or path) then return path end
end

local function install(pkg, dir, done)
  if jobs[dir] then
    table.insert(jobs[dir], done)
    return
  end
  jobs[dir] = { done }
  local function finish(err)
    local callbacks = jobs[dir]
    jobs[dir] = nil
    for _, cb in ipairs(callbacks) do cb(err) end
  end
  local ps = vim.fn.exepath("powershell.exe")
  if ps == "" then ps = "pwsh.exe" end
  local argv = { ps, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
    vim.fs.joinpath(plugin, "scripts", "install-windows-tool.ps1"), "-Store", store, "-Id", pkg.id, "-Version", pkg.version }
  local ok, err = pcall(vim.system, argv, { text = true, timeout = 300000 }, vim.schedule_wrap(function(res)
    if res.code == 0 then return finish() end
    local why = vim.trim(res.stderr or "")
    finish(why ~= "" and why or ("Installer exited with code " .. res.code))
  end))
  if not ok then finish(tostring(err)) end
end

local function announce(id, root, path)
  vim.api.nvim_exec_autocmds("User", { pattern = "GodotToolsReady", modeline = false, data = { id = id, root = root, path = path } })
end

-- Both upstream shader servers advertise the same version over LSP. Hash the
-- PATH candidate off the UI thread and share its result across open projects.
local function shader_hash(path, done)
  local stat = vim.uv.fs_stat(path)
  if not stat then return done(nil) end
  local key = table.concat({ path, stat.size, stat.mtime.sec, stat.mtime.nsec }, ":")
  local cached = hashes[key]
  if cached then
    if cached.waiters then table.insert(cached.waiters, done) else done(cached.hash) end
    return
  end
  cached = { waiters = { done } }
  hashes[key] = cached
  local function finish(hash)
    local waiters = cached.waiters
    cached.waiters, cached.hash = nil, hash
    if not hash then hashes[key] = nil end
    for _, cb in ipairs(waiters) do cb(hash, true) end
  end
  local ok = pcall(vim.system, { "certutil.exe", "-hashfile", path, "SHA256" }, { text = true, timeout = 15000 },
    vim.schedule_wrap(function(res)
      if res.code == 0 then
        for line in (res.stdout or ""):gmatch("[^\r\n]+") do
          local digest = line:gsub("%s", "")
          if #digest == 64 and digest:match("^%x+$") then return finish(digest:lower()) end
        end
      end
      finish(nil)
    end))
  if not ok then finish(nil) end
end

local function managed(entry, key, pkg, notify)
  local id = pkg.id
  local dir = vim.fs.joinpath(store, id, pkg.version .. "-" .. pkg.sha256:sub(1, 12))
  local function finish(why, path, emit)
    if states[key] ~= entry or not config.enabled(features[id]) then return end
    if path then
      local ok, activated = pcall(activate, pkg, path)
      if ok then
        entry.status = activated
        if emit then announce(id, entry.root, path) end
        return
      end
      why = tostring(activated)
    end
    entry.status = result("failed", why or ("Package is incomplete: " .. dir))
  end
  local path = published(dir, pkg)
  if path then return finish(nil, path, notify) end
  entry.status = result("pending", "Installing " .. id .. " " .. pkg.version)
  install(pkg, dir, function(why) finish(why, not why and published(dir, pkg), true) end)
end

function M.status(id, root)
  local feature = assert(features[id], "Unknown Godot tool: " .. tostring(id))
  if not config.enabled(feature) then return result("disabled", "Disabled by opts.features." .. feature) end
  root = id == "shader_lsp" and root or nil
  local check_shader = windows_x64 and id == "shader_lsp" and config.options[id] == commands[id]
  local pkg, err
  if check_shader then pkg, err = package_for(id, root) end
  local key = id .. "\n" .. (root or "")
  local entry = states[key]
  if entry and entry.shader_package == pkg and entry.error == err then return entry.status end
  entry = { id = id, root = root, shader_package = pkg, error = err, status = result("pending", "Locating " .. id) }
  states[key] = entry
  local found = existing(id)
  if check_shader and not pkg then
    entry.status = result("failed", err)
  elseif check_shader and found then
    entry.status = result("pending", "Checking compatibility of " .. found.path)
    shader_hash(found.path, function(hash, notify)
      if states[key] ~= entry or not config.enabled(feature) then return end
      if hash == pkg.sha256 then
        entry.status = found
        if notify then announce(id, root, found.path) end
      else
        managed(entry, key, pkg, notify)
      end
    end)
  elseif found then
    entry.status = found
  elseif not windows_x64 then
    entry.status = result("failed", "Install " .. (commands[id] or (id == "dap" and "nvim-dap" or "the godot_resource parser"))
      .. " for this platform. Automatic installation supports Windows x64.")
  else
    if not pkg then pkg, err = package_for(id, root) end
    if pkg then managed(entry, key, pkg) else entry.status = result("failed", err) end
  end
  return entry.status
end

function M.path(id, root)
  return M.status(id, root).path
end

function M.setup()
  states = {}
  local root = project.root(vim.api.nvim_buf_get_name(0)) or project.root(vim.fn.getcwd())
  for id in pairs(features) do M.status(id, root) end
end

function M.retry()
  local failed = {}
  for key, entry in pairs(states) do
    if entry.status.state == "failed" then
      failed[#failed + 1] = entry
      states[key] = nil
    end
  end
  for _, entry in ipairs(failed) do
    local status = M.status(entry.id, entry.root)
    if status.state == "ready" then announce(entry.id, entry.root, status.path) end
  end
end

return M
