local api = vim.api
local M = {}
local scenes = {}
local group = api.nvim_create_augroup("GodotSceneSidebar", { clear = true })

local function visible(scene)
  return scene and api.nvim_win_is_valid(scene.win) and api.nvim_win_get_buf(scene.win) == scene.buf
end

local function vertical(picker)
  local root = picker.layout and picker.layout.root
  return root and (root.opts.position == "left" or root.opts.position == "right")
end

local function explorer()
  if not package.loaded["snacks.picker"] then return end
  for _, picker in ipairs(Snacks.picker.get({ source = "explorer" })) do
    if vertical(picker) then return picker end
  end
end

local function geometry()
  if _G.Snacks and (Snacks.config.explorer.enabled or package.loaded["snacks.picker"]) then
    local config = Snacks.picker.config
    local box = config.layout(config.get({ source = "explorer" })).layout
    if box.position == "left" or box.position == "right" then
      local root = Snacks.win({ position = box.position, width = box.width, show = false })
      return box.position, root:dim().width
    end
  end
  return "left", 27
end

-- Snacks creates the split behind its floating list. Capture the scene width
-- before that split opens, then finish the swap after Snacks builds its layout.
api.nvim_create_autocmd("FileType", {
  group = group,
  pattern = "snacks_layout_box",
  callback = function(ev)
    local tab = api.nvim_get_current_tabpage()
    local scene = scenes[tab]
    if not visible(scene) or not package.loaded["snacks.picker"] then return end
    for _, picker in ipairs(Snacks.picker.get({ source = "explorer", tab = false })) do
      if vertical(picker) and picker.layout.root.buf == ev.buf then
        local width = api.nvim_win_get_width(scene.win)
        vim.schedule(function()
          if picker.closed or not visible(scene) or scenes[tab] ~= scene then return end
          local root = picker.layout.root
          if not root or not root:valid() or api.nvim_win_get_tabpage(root.win) ~= tab then return end
          api.nvim_win_close(scene.win, false)
          api.nvim_win_set_width(root.win, width)
          picker.layout:update()
        end)
        return
      end
    end
  end,
})

-- Returns the scene window and its backing editor window.
function M.show(buf, origin)
  local tab = api.nvim_get_current_tabpage()
  local scene = scenes[tab]
  if not visible(scene) then scene = nil end
  if not origin or not api.nvim_win_is_valid(origin) or api.nvim_win_get_tabpage(origin) ~= tab then
    origin = api.nvim_get_current_win()
  end
  if scene and origin == scene.win then origin = scene.origin end
  local picker = explorer()
  local restore, side, width
  if picker then
    local root = picker.layout.root
    side, width = root.opts.position, api.nvim_win_get_width(root.win)
    if not origin or not api.nvim_win_is_valid(origin) or origin == root.win
        or api.nvim_win_get_config(origin).relative ~= "" then origin = picker.main end
    local cwd, layout = picker:cwd(), vim.deepcopy(picker.resolved_layout)
    picker:close()
    -- Picker teardown is scheduled. Release the split now so it doesn't
    -- compete for columns with the scene, even on a narrow screen.
    picker.layout:close()
    restore = vim.tbl_extend("force", picker.init_opts, { cwd = cwd, layout = layout })
  end
  local win
  if scene then
    win = scene.win
    restore = restore or scene.restore
    api.nvim_win_set_buf(win, buf)
    api.nvim_set_current_win(win)
  else
    if not side then side, width = geometry() end
    win = api.nvim_open_win(buf, true, { win = -1, split = side, width = width })
  end
  vim.wo[win].winfixwidth = true
  local state = { win = win, buf = buf, origin = origin, restore = restore }
  scenes[tab] = state
  api.nvim_create_autocmd("BufWinLeave", { group = group, buffer = buf, once = true, callback = function()
    if scenes[tab] == state then scenes[tab] = nil end
  end })
  return win, origin
end

function M.close(win)
  win = (not win or win == 0) and api.nvim_get_current_win() or win
  if not api.nvim_win_is_valid(win) then return end
  local tab = api.nvim_win_get_tabpage(win)
  local scene = scenes[tab]
  if not visible(scene) or scene.win ~= win then return end
  local width = api.nvim_win_get_width(win)
  if vim.fn.winlayout(api.nvim_tabpage_get_number(tab))[1] == "leaf" then
    api.nvim_win_set_buf(win, api.nvim_create_buf(true, false))
    vim.wo[win].winfixwidth = false
  else
    api.nvim_win_close(win, false)
  end
  if scene.restore and tab == api.nvim_get_current_tabpage()
      and #Snacks.picker.get({ source = "explorer" }) == 0 then
    scene.restore.layout.layout.width = width
    Snacks.picker.explorer(scene.restore)
  end
end

return M
