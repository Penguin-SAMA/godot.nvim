local M = {}
local project = require("godot.project")
local session = require("godot.session")
local enabled, last_root

function M.root(buf)
  buf = buf or 0
  return vim.b[buf].godot_root or project.root(vim.api.nvim_buf_get_name(buf))
end

local function attach(buf)
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then return end
  local ft = vim.bo[buf].filetype
  if ft ~= "gdscript" and ft ~= "gdresource" and ft ~= "gdshader" then return end
  local root = M.root(buf)
  if root then
    last_root = root
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
  local record = project.read(root .. "/.godot/godot-nvim-editor.json")
  if record and type(record.root) == "string" and record.mode == "editor"
      and project.key(record.root) == project.key(root) and project.alive(record.pid) then
    require("godot.bridge").subscribe(root, record)
  end
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

function M.enable(defer_attach)
  if enabled then return end
  enabled = true
  vim.filetype.add({ extension = {
    gd = "gdscript", tscn = "gdresource", tres = "gdresource",
    gdshader = "gdshader", gdshaderinc = "gdshader",
  } })
  vim.treesitter.language.register("godot_resource", "gdresource")
  local group = vim.api.nvim_create_augroup("GodotNvim", { clear = true })
  require("godot.toolbar").setup(group)
  vim.api.nvim_create_autocmd("FileType", { group = group, pattern = { "gdscript", "gdresource", "gdshader" },
    callback = function(e) attach(e.buf) end })
  vim.api.nvim_create_autocmd({ "BufEnter", "FocusGained" }, { group = group, callback = function(e)
    local root = M.root(e.buf)
    if root then
      last_root = root
      if vim.bo[e.buf].buftype == "" then subscribe(root) end
    end
  end })
  vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = function()
    local debugger = package.loaded["godot.debug"]
    if debugger then debugger.shutdown() end
    session.release_all()
  end })
  vim.api.nvim_create_user_command("GodotMenu", function() require("godot.menu").open() end,
    { desc = "打开 Godot.nvim 快捷菜单" })
  require("godot.menu").setup()
  local function command(name, action, opts)
    vim.api.nvim_create_user_command(name, function(args)
      local root = M.root()
      if not root then return notify_error("Open a file inside a Godot project first.") end
      local ok, why = pcall(action, root, args.args)
      if not ok then notify_error(why) end
    end, opts or {})
  end
  command("GodotReconnect", reconnect)
  vim.api.nvim_create_user_command("GodotFormat", function()
    require("godot.editing").format(vim.api.nvim_get_current_buf())
  end, {})
  vim.api.nvim_create_user_command("GodotDoc", function(args)
    require("godot.editing").doc(vim.api.nvim_get_current_buf(), args.args)
  end, { nargs = "?" })
  command("GodotOpen", function(root)
    session.ensure(root, "editor", function(err, s)
      if err then return notify_error(err) end
      if vim.uv.fs_stat(root .. "/addons/nvim_bridge/plugin.cfg") then
        require("godot.bridge").call(root, "ping", {}, function(why) notify_error(why) end)
      end
      vim.notify("Godot editor · " .. s.root)
    end)
  end)
  command("GodotTree", function(root, arg) require("godot.tree").open(root, arg) end, { nargs = "?", complete = "file" })
  command("GodotBridgeInstall", function(root) require("godot.bridge").install(root) end)
  command("GodotResource", function(root, arg) require("godot.bridge").resource(root, arg) end, { nargs = "?" })
  command("GodotExternalEditor", function(root) require("godot.external").configure(root) end)
  for _, spec in ipairs({ { "GodotRun", false }, { "GodotDebug", true } }) do
    command(spec[1], function(root, scene) require("godot.debug").start(root, scene, spec[2]) end, { nargs = "?", complete = "file" })
  end
  local debug_actions = { "continue", "frames", "step_into", "step_out", "step_over", "toggle_breakpoint" }
  vim.api.nvim_create_user_command("GodotDebugAction", function(args)
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
  command("GodotStop", function(root) require("godot.debug").stop(root) end)
  command("GodotOutput", function(root) require("godot.debug").output(root) end)
  -- Plugin managers can load on FileType after the event has already fired.
  local function attach_open_buffers()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) then attach(buf) end
    end
    local current = M.root()
    if current and vim.bo.buftype == "" then subscribe(current) end
  end
  -- A plugin manager can source plugin/godot.lua just before setup(opts).
  -- Commands are available immediately; attach with the configured engine.
  if defer_attach then vim.schedule(attach_open_buffers) else attach_open_buffers() end
end

function M.health_root()
  return M.root() or last_root or project.root(vim.fn.getcwd())
end

function M.setup(opts)
  require("godot.config").setup(opts)
  M.enable()
  require("godot.toolbar").refresh()
end
return M

