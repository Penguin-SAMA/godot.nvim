local M = {}
local api = vim.api
local prefix = "<leader>G"
local categories = { p = "项目与连接", e = "编辑与导航", s = "场景树", r = "运行与输出", d = "调试" }
local godot_files = { gdscript = true, gdresource = true, gdshader = true }
local which_key

local function command(name, arg)
  return function()
    api.nvim_cmd({ cmd = name, args = arg and { arg } or {}, magic = { file = false, bar = false } }, {})
  end
end

local health = { "h", "检查环境与连接", command("checkhealth", "godot") }

local function missing_project()
  vim.notify("请打开 Godot 项目中的文件。插件从文件所在目录向上查找 project.godot。", vim.log.levels.WARN,
    { title = "godot.nvim" })
end

local function groups(root, buf)
  local ft = vim.bo[buf].filetype
  if not root and not godot_files[ft] then return { { "p", categories.p, { health } } } end
  local function project_action(key, label, name, arg)
    if not root then return { key, label .. "（需项目）", missing_project } end
    return { key, label, command(name, arg) }
  end
  local editing = {
    { "h", "光标处的官方文档", command("GodotDoc") },
    project_action("g", "打开光标处的资源", "GodotResource"),
  }
  if ft == "gdscript" or ft == "gdshader" then
    table.insert(editing, { "f", "格式化当前文件", command("GodotFormat") })
  end
  local debug = {
    project_action("m", "调试主场景", "GodotDebug", "main"),
    project_action("g", "继续执行", "GodotDebugAction", "continue"),
  }
  if ft == "gdscript" then
    table.insert(debug, { "b", "切换当前行断点", command("GodotDebugAction", "toggle_breakpoint") })
  end
  return {
    { "p", categories.p, { health, project_action("o", "打开 Godot 编辑器", "GodotOpen") } },
    { "e", categories.e, editing },
    { "s", categories.s, { project_action("o", "打开当前场景树", "GodotTree") } },
    { "r", categories.r, {
      project_action("m", "运行主场景", "GodotRun", "main"),
      project_action("c", "运行当前场景", "GodotRun", "current"),
      project_action("s", "停止游戏", "GodotStop"),
      project_action("o", "打开输出面板", "GodotOutput"),
    } },
    { "d", categories.d, debug },
  }
end

function M.setup()
  local ok, wk = pcall(require, "which-key")
  if not ok or type(wk.add) ~= "function" then
    if vim.fn.maparg(prefix, "n") == "" then
      vim.keymap.set("n", prefix, "<Cmd>GodotMenu<CR>", { silent = true, desc = "Godot.nvim 菜单" })
    end
    return
  end
  which_key = wk
  local spec = { { prefix, group = "Godot.nvim" } }
  for key, name in pairs(categories) do
    spec[#spec + 1] = { prefix .. key, group = name }
  end
  wk.add(spec)
  local health_key = prefix .. "p" .. health[1]
  vim.keymap.set("n", health_key, health[3], { desc = health[2], silent = true })

  local bindings = {}
  local function update(buf)
    local root, ft = require("godot").root(buf), vim.bo[buf].filetype
    local previous = bindings[buf]
    if previous then
      if previous.root == root and previous.ft == ft then return end
      for _, lhs in ipairs(previous.keys) do
        pcall(vim.keymap.del, "n", lhs, { buffer = buf })
      end
      bindings[buf] = nil
    end
    if not root and not godot_files[ft] then return end
    local keys = {}
    for _, group in ipairs(groups(root, buf)) do
      for _, action in ipairs(group[3]) do
        local lhs = prefix .. group[1] .. action[1]
        if lhs ~= health_key then
          vim.keymap.set("n", lhs, action[3], { buffer = buf, desc = action[2], silent = true })
          keys[#keys + 1] = lhs
        end
      end
    end
    bindings[buf] = { root = root, ft = ft, keys = keys }
  end
  local group = api.nvim_create_augroup("GodotNvimKeys", { clear = true })
  api.nvim_create_autocmd({ "BufEnter", "BufFilePost", "FileType" }, {
    group = group, callback = function(event) update(event.buf) end,
  })
  api.nvim_create_autocmd("BufWipeout", {
    group = group, callback = function(event) bindings[event.buf] = nil end,
  })
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(buf) then update(buf) end
  end
end

function M.open()
  if which_key then return which_key.show({ keys = prefix, mode = "n" }) end
  if vim.bo.filetype == "godot_menu" then return end
  local origin, source = api.nvim_get_current_win(), api.nvim_get_current_buf()
  local home = groups(require("godot").root(source), source)
  local win
  local function close()
    if win and api.nvim_win_is_valid(win) then api.nvim_win_close(win, true) end
  end
  local function show(items, group)
    local buf = api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "godot_menu"
    local title = group and (" Godot.nvim · " .. group .. " ") or " Godot.nvim "
    local footer = group and " BS 返回 · Esc 关闭 " or " Esc 关闭 "
    local width = math.max(vim.fn.strdisplaywidth(title), vim.fn.strdisplaywidth(footer))
    local lines = {}
    for _, item in ipairs(items) do
      local text = ("  %s   %s"):format(item[1], item[2])
      lines[#lines + 1] = text
      width = math.max(width, vim.fn.strdisplaywidth(text) + 2)
    end
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    width = math.min(width, math.max(1, vim.o.columns - 2))
    local rows = math.max(1, vim.o.lines - vim.o.cmdheight - 2)
    local height = math.min(#items, rows)
    local opts = {
      relative = "editor", style = "minimal", border = "rounded", title = title, footer = footer,
      width = width, height = height, col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)),
      row = math.max(0, math.floor((rows - height) / 2)),
    }
    if win then
      api.nvim_win_set_buf(win, buf)
      api.nvim_win_set_config(win, opts)
    else
      win = api.nvim_open_win(buf, true, opts)
    end
    vim.wo[win].cursorline = true
    vim.wo[win].wrap = false
    api.nvim_win_set_cursor(win, { 1, 0 })
    local function choose(item)
      if type(item[3]) == "table" then return show(item[3], item[2]) end
      close()
      if api.nvim_win_is_valid(origin) and api.nvim_win_get_buf(origin) == source then
        api.nvim_set_current_win(origin)
        item[3]()
      end
    end
    local function map(lhs, action, desc)
      vim.keymap.set("n", lhs, action, { buffer = buf, nowait = true, silent = true, desc = desc })
    end
    for _, item in ipairs(items) do
      map(item[1], function() choose(item) end, item[2])
    end
    map("<CR>", function() choose(items[api.nvim_win_get_cursor(win)[1]]) end, "选择")
    map("<BS>", function() if group then show(home) else close() end end, "返回")
    map("<Esc>", close, "关闭菜单")
    map("q", close, "关闭菜单")
    api.nvim_create_autocmd("WinLeave", { buffer = buf, once = true, callback = function()
      vim.schedule(function()
        if api.nvim_win_is_valid(win) and api.nvim_get_current_win() ~= win then close() end
      end)
    end })
  end
  show(home)
end

return M

