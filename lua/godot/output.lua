local M = {}
local api = vim.api
local project = require("godot.project")
local panels = {}

local function location(root, path, line)
  if type(path) ~= "string" or not tonumber(line) or tonumber(line) < 1 then return end
  if vim.startswith(path, "res://") then path = root .. "/" .. path:sub(7) end
  local relative = vim.fs.relpath(root, project.normalize(path))
  if relative then return { path = root .. "/" .. relative, relative = relative, line = tonumber(line) } end
end

local function jump(panel)
  local target = panel.locations[api.nvim_win_get_cursor(0)[1]]
  if not target then return end
  if vim.fn.filereadable(target.path) == 0 then
    vim.notify("Godot source file is missing: " .. target.path, vim.log.levels.WARN)
    return
  end
  local prev = vim.fn.win_getid(vim.fn.winnr("#"))
  if prev ~= 0 and api.nvim_win_get_buf(prev) ~= panel.buf then api.nvim_set_current_win(prev) end
  vim.cmd("drop " .. vim.fn.fnameescape(target.path))
  api.nvim_win_set_cursor(0, { math.min(target.line, api.nvim_buf_line_count(0)), 0 })
end

local function get_panel(root)
  local key = project.key(root)
  local panel = panels[key]
  if panel and api.nvim_buf_is_valid(panel.buf) then return panel end
  local buf = api.nvim_create_buf(false, true)
  panel = { buf = buf, count = 0, trimmed = 0, locations = {} }
  panels[key] = panel
  api.nvim_buf_set_name(buf, "godot-output://" .. root)
  vim.b[buf].godot_root = root
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].filetype = "godotoutput"
  vim.bo[buf].modifiable = false
  vim.keymap.set("n", "<CR>", function() jump(panel) end, { buffer = buf, desc = "Open Godot source location" })
  return panel
end

function M.append(root, message, path, line)
  if not message or message == "" then return end
  local panel = get_panel(root)
  local buf = panel.buf
  local target = location(root, path, line)
  local lines = vim.split(message:gsub("\r\n", "\n"):gsub("\n$", ""), "\n", { plain = true })
  local first = panel.trimmed + panel.count + 1
  local follow = {}
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if api.nvim_win_get_cursor(win)[1] >= math.max(1, panel.count) then table.insert(follow, win) end
  end
  for i, text in ipairs(lines) do
    local file, row = text:match("(res://.-%.%w+):(%d+)")
    panel.locations[panel.count + i] = target or location(root, file, row)
  end
  if target then lines[1] = ("%s:%d  %s"):format(target.relative, target.line, lines[1]) end
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, panel.count, -1, false, lines)
  panel.count = panel.count + #lines
  if panel.count > 5500 then
    local trimmed = panel.count - 5000
    api.nvim_buf_set_lines(buf, 0, trimmed, false, {})
    local remaining = {}
    for index, value in pairs(panel.locations) do
      if index > trimmed then remaining[index - trimmed] = value end
    end
    panel.locations = remaining
    panel.count = 5000
    panel.trimmed = panel.trimmed + trimmed
  end
  vim.bo[buf].modifiable = false
  for _, win in ipairs(follow) do api.nvim_win_set_cursor(win, { panel.count, 0 }) end
  return { panel = panel, first = first, length = #lines }
end

function M.script_location(root, path, line)
  if type(path) ~= "string" or not (path:lower():match("%.gd$") or path:lower():match("%.cs$")) then return end
  local src = location(root, path, line)
  if src and vim.fn.filereadable(src.path) == 1 then return src end
end

-- A stack response can arrive after the diagnostic was printed and scrolled.
function M.link(record, target, detail)
  if not record or (not target and not detail) then return end
  local panel = record.panel
  local row = record.first - panel.trimmed
  if row < 1 or not api.nvim_buf_is_loaded(panel.buf) then return end
  if panel.locations[row] and not detail then return end
  local line = detail or api.nvim_buf_get_lines(panel.buf, row - 1, row, false)[1]
  if not line then return end
  target = target or panel.locations[row]
  if target then
    for i = row, row + record.length - 1 do panel.locations[i] = target end
    line = ("%s:%d  %s"):format(target.relative, target.line, line)
  end
  vim.bo[panel.buf].modifiable = true
  api.nvim_buf_set_lines(panel.buf, row - 1, row, false, { (line:gsub("[\r\n]+", " ")) })
  vim.bo[panel.buf].modifiable = false
end

function M.jump(root)
  local panel = panels[project.key(root)]
  if panel and api.nvim_get_current_buf() == panel.buf then jump(panel) end
end

function M.open(root)
  local buf = get_panel(root).buf
  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    vim.cmd("botright 12split")
    api.nvim_win_set_buf(0, buf)
    api.nvim_win_set_cursor(0, { api.nvim_buf_line_count(buf), 0 })
  else
    api.nvim_set_current_win(win)
  end
  return buf
end

return M
