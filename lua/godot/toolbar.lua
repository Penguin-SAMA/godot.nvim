local M = {}
local api = vim.api
local project = require("godot.project")
local bridge = require("godot.bridge")
local actions = { "main", "pause", "stop", "current", "custom" }
local fallback = { "▶", "Ⅱ", "■", "▷", "…", "↻" }
local busy = {}
local root, key, winbar, right_area

local function highlights()
  local dark = vim.o.background == "dark"
  -- Only change the glyph foreground. The surrounding bar supplies the background.
  api.nvim_set_hl(0, "GodotRunIcon", { fg = dark and "#e0e0e0" or "#404040", ctermfg = dark and 253 or 238, default = true })
  api.nvim_set_hl(0, "GodotRunDisabled", { fg = dark and "#777777" or "#999999", ctermfg = dark and 243 or 247, default = true })
  api.nvim_set_hl(0, "GodotRunActive", { fg = dark and "#80aeff" or "#3666a3", ctermfg = dark and 111 or 25, default = true })
end

local function disabled(action, state)
  return (action == "pause" and not state.can_pause) or (action == "stop" and not state.can_stop)
end

function M.render()
  if not root then return "" end
  local state = bridge.run_state(key) or {}
  local official = require("godot.config").options.scene_icons == "godot"
  local parts = {}
  for i, action in ipairs(actions) do
    local index = state.mode == action and 6 or i -- The running scene's button becomes Reload.
    local glyph = official and vim.fn.nr2char(0xF4100 + index - 1) or fallback[index]
    local active = state.mode == action or (action == "pause" and state.paused)
    local hl = disabled(action, state) and "GodotRunDisabled" or active and "GodotRunActive" or "GodotRunIcon"
    parts[i] = ("%%#%s#%%%d@v:lua.require'godot.toolbar'.click@ %s %%T"):format(hl, i, glyph)
  end
  return table.concat(parts) .. "%*"
end

function M.click(i, _, button)
  local target = require("godot").root()
  local action = actions[i]
  if button ~= "l" or not action or not target then return end
  local target_key = project.key(target)
  if target_key ~= key or busy[key] or disabled(action, bridge.run_state(key) or {}) then return end
  local params = { action = action }
  if action == "current" then
    local file = api.nvim_buf_get_name(0)
    if file:lower():match("%.t?scn$") then
      params.scene = "res://" .. project.normalize(file):sub(#project.normalize(target) + 2)
    end
  end
  busy[target_key] = true
  bridge.call(target, "run_action", params, function(err)
    busy[target_key] = nil
    if err then vim.notify("godot.nvim: " .. err, vim.log.levels.WARN) end
  end)
end

local function bufferline_visible()
  local cfg = package.loaded["bufferline.config"]
  if not cfg or not cfg.options or not vim.o.tabline:find("bufferline", 1, true) then return false end
  local areas = cfg.options.custom_areas or {}
  cfg.options.custom_areas = areas
  if not right_area or areas.right ~= right_area then
    local original = areas.right
    right_area = function()
      local items = original and vim.list_slice(original() or {}) or {}
      if root then items[#items + 1] = { text = M.render() } end
      return items
    end
    areas.right = right_area
  end
  return vim.o.showtabline == 2 or (vim.o.showtabline == 1 and #api.nvim_list_tabpages() > 1)
end

local function top_window()
  local best, row, col
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if api.nvim_win_get_config(win).relative == "" and vim.bo[api.nvim_win_get_buf(win)].buftype == "" then
      local pos = vim.fn.win_screenpos(win)
      if not best or pos[1] < row or (pos[1] == row and pos[2] > col) then
        best, row, col = win, pos[1], pos[2]
      end
    end
  end
  return best
end

function M.refresh()
  root = require("godot.config").options.toolbar ~= false and require("godot").root() or nil
  key = root and project.key(root)
  local win = root and not bufferline_visible() and top_window() or nil
  -- A new split inherits its parent's window-local winbar.
  if winbar then
    for _, other in ipairs(api.nvim_list_wins()) do
      if other ~= winbar.win and vim.wo[other].winbar == winbar.value then
        api.nvim_set_option_value("winbar", winbar.previous, { win = other, scope = "local" })
      end
    end
  end
  if winbar and (winbar.win ~= win or not api.nvim_win_is_valid(winbar.win)
      or vim.wo[winbar.win].winbar ~= winbar.value) then
    if api.nvim_win_is_valid(winbar.win) and vim.wo[winbar.win].winbar == winbar.value then
      api.nvim_set_option_value("winbar", winbar.previous, { win = winbar.win, scope = "local" })
    end
    winbar = nil
  end
  if win and not winbar then
    local previous = api.nvim_get_option_value("winbar", { win = win, scope = "local" })
    local prefix = previous ~= "" and previous or vim.go.winbar
    if vim.startswith(prefix, "%!") then prefix = "%{%" .. prefix:sub(3) .. "%}" end
    local value = prefix .. "%=%{%v:lua.require'godot.toolbar'.render()%}"
    vim.wo[win].winbar = value
    winbar = { win = win, previous = previous, value = value }
  end
  vim.cmd.redrawtabline()
end

function M.setup(group)
  highlights()
  api.nvim_create_autocmd("ColorScheme", { group = group, callback = highlights })
  local pending = false
  local function refresh()
    if pending then return end
    pending = true
    vim.schedule(function() pending = false; M.refresh() end)
  end
  api.nvim_create_autocmd({ "BufEnter", "BufFilePost", "WinEnter", "WinClosed", "WinResized", "TabEnter", "VimEnter" },
    { group = group, callback = refresh })
  api.nvim_create_autocmd("User", { group = group, pattern = { "LazyLoad", "VeryLazy" }, callback = refresh })
  api.nvim_create_autocmd("OptionSet", { group = group, pattern = { "tabline", "showtabline" }, callback = refresh })
  refresh()
end

return M
