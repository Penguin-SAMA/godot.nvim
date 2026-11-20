local M = {}
local project = require("godot.project")
local session = require("godot.session")
local config = require("godot.config")
local enabled, started, group, last_root
local extensions = { gd = "gdscript", tscn = "gdresource", tres = "gdresource",
  gdshader = "gdshader", gdshaderinc = "gdshader" }

function M.root(buf)
  buf = buf or 0
  return vim.b[buf].godot_root or project.root(vim.api.nvim_buf_get_name(buf))
end

local function attach(buf)
  if not started or not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then return end
  local ft = vim.bo[buf].filetype
  if ft ~= "gdscript" and ft ~= "gdresource" and ft ~= "gdshader" then return end
  local root = M.root(buf)
  if root then
    last_root = root
    require("godot.bridge").prepare(root)
    session.track(root)
  elseif ft ~= "gdshader" or vim.api.nvim_buf_get_name(buf) == "" then
    return
  end
  require("godot.editing").attach(buf, root)
end

local function notify_error(err)
  if err then vim.notify(tostring(err), vim.log.levels.ERROR, { title = "godot.nvim" }) end
end

local function subscribe(root)
  if not started or not config.enabled("bridge") then return end
  if not require("godot.bridge").prepare(root) then return end
  local record = session.advertised_editor(root)
  if record then require("godot.bridge").subscribe(root, record) end
end

local function reconnect(root)
  local buffers = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "gdscript"
        and M.root(buf) == root then
      table.insert(buffers, buf)
    end
  end
  for _, client in ipairs(vim.lsp.get_clients({ name = "godot-gdscript" })) do
    if project.key(client.config.root_dir) == project.key(root) then client:stop(true) end
  end
  vim.defer_fn(function()
    for _, buf in ipairs(buffers) do attach(buf) end
  end, 80)
end

local function attach_open_buffers()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local ft = extensions[vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":e")]
      if ft and vim.bo[buf].buftype == "" and vim.bo[buf].filetype == "" then
        -- Native packages can load after the initial buffer's filetype detection.
        vim.bo[buf].filetype = ft -- FileType calls attach().
      else
        attach(buf)
      end
    end
  end
  local current = M.health_root()
  if current then subscribe(current) end
end

local function start()
  if started then return end
  started = true
  require("godot.menu").setup()
  require("godot.toolbar").setup(group)
  require("godot.tools").setup()
  attach_open_buffers()
end

function M.enable(defer_start)
  if enabled then return end
  enabled = true
  vim.filetype.add({ extension = extensions })
  group = vim.api.nvim_create_augroup("GodotNvim", { clear = true })
  vim.api.nvim_create_autocmd("FileType", { group = group, pattern = { "gdscript", "gdresource", "gdshader" },
    callback = function(e) attach(e.buf) end })
  vim.api.nvim_create_autocmd({ "BufEnter", "FocusGained" }, { group = group, callback = function(e)
    local root = M.root(e.buf)
    if root then
      last_root = root
      if vim.bo[e.buf].buftype == "" then subscribe(root) end
    end
  end })
  vim.api.nvim_create_autocmd("DirChanged", { group = group, callback = function()
    local root = project.root(vim.fn.getcwd())
    if root then subscribe(root) end
  end })
  vim.api.nvim_create_autocmd("User", { group = group, pattern = "GodotToolsReady", callback = function(e)
    local id = e.data and e.data.id
    local ft = ({ shader_lsp = "gdshader", scene_tree = "gdresource" })[id]
    if not ft then return end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == ft then attach(buf) end
    end
  end })
  vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = function()
    local debugger = package.loaded["godot.debug"]
    if debugger then debugger.shutdown() end
    session.release_all()
  end })
  vim.api.nvim_create_user_command("GodotMenu", function() start(); require("godot.menu").open() end,
    { desc = "Open Godot Menu" })
  local function command(name, action, opts, feature)
    vim.api.nvim_create_user_command(name, function(args)
      start()
      if feature and not config.require_feature(feature) then return end
      local root = M.root()
      if not root then return notify_error("Open a file inside a Godot project first.") end
      local ok, why = pcall(action, root, args.args)
      if not ok then notify_error(why) end
    end, opts or {})
  end
  command("GodotReconnect", reconnect)
  vim.api.nvim_create_user_command("GodotFormat", function()
    start()
    if not config.require_feature("formatting") then return end
    require("godot.editing").format(vim.api.nvim_get_current_buf())
  end, {})
  vim.api.nvim_create_user_command("GodotDoc", function(args)
    start()
    require("godot.editing").doc(vim.api.nvim_get_current_buf(), args.args)
  end, { nargs = "?" })
  command("GodotOpen", function(root)
    session.ensure(root, "editor", function(err, s)
      if err then return notify_error(err) end
      if config.enabled("bridge") and s.bridge_port and require("godot.bridge").status(root).state == "ready" then
        require("godot.bridge").call(root, "ping", {}, function(why) notify_error(why) end)
      end
      vim.notify("Godot editor · " .. s.root)
    end)
  end)
  command("GodotTree", function(root, arg) require("godot.tree").open(root, arg) end, { nargs = "?", complete = "file" }, "scene_tree")
  command("GodotBridgeInstall", function(root) require("godot.bridge").install(root) end, nil, "bridge")
  command("GodotResource", function(root, arg) require("godot.bridge").resource(root, arg) end, { nargs = "?" })
  command("GodotExternalEditor", function(root) require("godot.external").configure(root) end, nil, "bridge")
  for _, spec in ipairs({ { "GodotRun", false }, { "GodotDebug", true } }) do
    command(spec[1], function(root, scene) require("godot.debug").start(root, scene, spec[2]) end,
      { nargs = "?", complete = "file" }, "dap")
  end
  local debug_actions = { "continue", "frames", "step_into", "step_out", "step_over", "toggle_breakpoint" }
  vim.api.nvim_create_user_command("GodotDebugAction", function(args)
    start()
    if not config.require_feature("dap") then return end
    local action = args.args
    if not vim.list_contains(debug_actions, action) then
      return notify_error("可用调试操作：" .. table.concat(debug_actions, ", "))
    end
    local root = M.root()
    if not root and action ~= "toggle_breakpoint" then return notify_error("请先打开 Godot 项目中的文件。") end
    require("godot.debug").control(root, action)
  end, { nargs = 1, complete = function(lead)
    return vim.tbl_filter(function(action) return vim.startswith(action, lead) end, debug_actions)
  end })
  command("GodotStop", function(root) require("godot.debug").stop(root) end, nil, "dap")
  command("GodotOutput", function(root) require("godot.debug").output(root) end, nil, "dap")
  vim.api.nvim_create_user_command("GodotToolsRetry", function()
    start()
    require("godot.tools").retry()
  end, {})
  if defer_start then vim.schedule(start) else start() end
end

function M.health_root()
  return M.root() or last_root or project.root(vim.fn.getcwd())
end

function M.setup(opts)
  config.setup(opts)
  if not enabled then return M.enable() end
  if not started then return start() end
  if not config.enabled("bridge") and package.loaded["godot.bridge"] then require("godot.bridge").disable() end
  if not config.enabled("dap") and package.loaded["godot.debug"] then require("godot.debug").shutdown() end
  require("godot.tools").setup()
  if package.loaded["godot.editing"] then require("godot.editing").reconfigure() end
  if package.loaded["godot.tree"] then require("godot.tree").reconfigure() end
  require("godot.menu").setup()
  require("godot.toolbar").refresh()
  attach_open_buffers()
end
return M

