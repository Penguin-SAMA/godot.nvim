local M = {}
local api = vim.api
local config = require("godot.config")
local prefix = "<leader>G"
local categories = { p = "Project", e = "Editing", s = "Scene Tree", r = "Run", d = "Debug" }
local godot_files = { gdscript = true, gdresource = true, gdshader = true }
local which_key
local bindings = {}

local function command(name, arg)
  return function()
    api.nvim_cmd({ cmd = name, args = arg and { arg } or {}, magic = { file = false, bar = false } }, {})
  end
end

local health = { "h", "Check Health", command("checkhealth", "godot") }

local function missing_project()
  vim.notify("Open a file in a directory containing project.godot or one of its subdirectories.", vim.log.levels.WARN,
    { title = "godot.nvim" })
end

local function groups(root, buf)
  local ft = vim.bo[buf].filetype
  if not root and not godot_files[ft] then return { { "p", categories.p, { health } } } end
  local function project_action(key, label, name, arg)
    if not root then return { key, label .. " (requires project)", missing_project } end
    return { key, label, command(name, arg) }
  end
  local editing = {
    { "h", "Show Docs at Cursor", command("GodotDoc") },
    project_action("g", "Open Resource at Cursor", "GodotResource"),
  }
  if config.enabled("formatting") and (ft == "gdscript" or ft == "gdshader") then
    table.insert(editing, { "f", "Format File", command("GodotFormat") })
  end
  local result = {
    { "p", categories.p, { health, project_action("o", "Open Godot Editor", "GodotOpen") } },
    { "e", categories.e, editing },
  }
  if config.enabled("scene_tree") then
    table.insert(result, { "s", categories.s, { project_action("o", "Open Scene Tree", "GodotTree") } })
  end
  if not config.enabled("dap") then return result end
  local debug = {
    project_action("m", "Debug Main Scene", "GodotDebug", "main"),
    project_action("g", "Continue", "GodotDebugAction", "continue"),
  }
  if ft == "gdscript" then
    table.insert(debug, { "b", "Toggle Breakpoint", command("GodotDebugAction", "toggle_breakpoint") })
  end
  table.insert(result, { "r", categories.r, {
      project_action("m", "Run Main Scene", "GodotRun", "main"),
      project_action("c", "Run Current Scene", "GodotRun", "current"),
      project_action("s", "Stop Game", "GodotStop"),
      project_action("o", "Open Output", "GodotOutput"),
  } })
  table.insert(result, { "d", categories.d, debug })
  return result
end

function M.setup()
  local group = api.nvim_create_augroup("GodotNvimKeys", { clear = true })
  local function clear(buf)
    if bindings[buf] and api.nvim_buf_is_valid(buf) then
      for _, lhs in ipairs(bindings[buf].keys) do
        pcall(vim.keymap.del, "n", lhs, { buffer = buf })
      end
    end
    bindings[buf] = nil
  end
  for buf in pairs(bindings) do clear(buf) end
  local ok, wk = pcall(require, "which-key")
  if not ok or type(wk.add) ~= "function" then
    which_key = nil
    if vim.fn.maparg(prefix, "n") == "" then
      vim.keymap.set("n", prefix, "<Cmd>GodotMenu<CR>", { silent = true, desc = "Open Godot Menu" })
    end
    return
  end
  if which_key ~= wk then
    if vim.fn.maparg(prefix, "n") == "<Cmd>GodotMenu<CR>" then vim.keymap.del("n", prefix) end
    local spec = { { prefix, group = "Godot", icon = { icon = "", color = "blue" } } }
    for key, name in pairs(categories) do
      spec[#spec + 1] = { prefix .. key, group = name }
    end
    wk.add(spec)
    which_key = wk
  end
  local health_key = prefix .. "p" .. health[1]
  vim.keymap.set("n", health_key, health[3], { desc = health[2], silent = true })

  local function update(buf)
    local root, ft = require("godot").root(buf), vim.bo[buf].filetype
    local previous = bindings[buf]
    if previous then
      if previous.root == root and previous.ft == ft then return end
      clear(buf)
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
    local title = group and (" Godot · " .. group .. " ") or " Godot "
    local footer = group and " BS Back · Esc Close " or " Esc Close "
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
    map("<CR>", function() choose(items[api.nvim_win_get_cursor(win)[1]]) end, "Select")
    map("<BS>", function() if group then show(home) else close() end end, "Back")
    map("<Esc>", close, "Close Menu")
    map("q", close, "Close Menu")
    api.nvim_create_autocmd("WinLeave", { buffer = buf, once = true, callback = function()
      vim.schedule(function()
        if api.nvim_win_is_valid(win) and api.nvim_get_current_win() ~= win then close() end
      end)
    end })
  end
  show(home)
end

return M

