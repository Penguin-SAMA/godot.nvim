local uv = vim.uv
local project = require("godot.project")
local M = {}
local cfg = "res://addons/nvim_bridge/plugin.cfg"
local files = { "plugin.cfg", "plugin.gd", "scene_actions.gd" }
-- Exact bytes distributed before external script attachment was fixed.
local previous = { ["scene_actions.gd"] = "213da130603f2427f3162b1088fa2ee6ac3e6566e18e1c27df0844b7bad798ad" }

local function read(path)
  local f = io.open(path, "rb")
  if not f then return end
  local contents = f:read("*a")
  f:close()
  return contents
end

-- Move the actual file aside before validating it, then publish exclusively.
-- A concurrent saver can replace the destination at either point.
local function install_file(source, dest, expected)
  if not expected then return uv.fs_copyfile(source, dest, { excl = true }) end
  local fd, backup = uv.fs_mkstemp(dest .. ".XXXXXX")
  if not fd then return nil, backup end
  uv.fs_close(fd)
  local moved, err = uv.fs_rename(dest, backup)
  if not moved then uv.fs_unlink(backup); return nil, err end
  local saved = uv.fs_lstat(backup)
  if saved and saved.type == "file" and read(backup) == expected then
    local copied, why, code = uv.fs_copyfile(source, dest, { excl = true })
    if copied and read(backup) == expected then
      uv.fs_unlink(backup)
      return true
    end
    if code ~= "EEXIST" then err = why end
  end
  err = err or ("Add-on changed during installation: " .. dest)
  -- Link restores the original without replacing a newer save at dest.
  local restored = uv.fs_link(backup, dest)
  if not restored and saved and saved.type == "file" and not uv.fs_lstat(dest) then
    restored = uv.fs_copyfile(backup, dest, { excl = true })
  end
  if restored then
    uv.fs_unlink(backup)
  else
    err = err .. ". Previous file retained at " .. backup
  end
  return nil, err
end

-- Keep comments, other add-ons, encoding and newline style in project.godot.
-- Refuse unfamiliar syntax so a future serialization format cannot be damaged.
local function enable(original)
  local eol = original:find("\r\n", 1, true) and "\r\n" or "\n"
  local data = "\n" .. original
  local start, title_end = data:find("\n[ \t]*%[editor_plugins%][^\n]*\n")
  if not start then
    return original .. eol .. "[editor_plugins]" .. eol .. 'enabled=PackedStringArray("' .. cfg .. '")' .. eol
  end
  local next_section = data:find("\n[ \t]*%[", title_end)
  local section = data:sub(title_end, next_section or #data)
  local key_start, key_end = section:find("\n[ \t]*enabled[ \t]*=[ \t]*")
  if not key_start then
    return (data:sub(1, title_end) .. 'enabled=PackedStringArray("' .. cfg .. '")' .. eol .. data:sub(title_end + 1)):sub(2)
  end
  local value = section:sub(key_end + 1)
  local after, close
  if value:match("^PackedStringArray%s*%(") then
    close = ")"
    after = value:find("%(")
  elseif value:match("^%[") then
    after, close = 1, "]"
  else
    return nil, "Cannot safely update editor_plugins/enabled. Enable Neovim Bridge in Godot's Plugins settings."
  end
  local i, needs_comma = after + 1, false
  while i <= #value do
    local c = value:sub(i, i)
    if c == close then
      local offset = title_end - 1 + key_end + i
      local extra = (needs_comma and ", " or "") .. '"' .. cfg .. '"'
      return (data:sub(1, offset - 1) .. extra .. data:sub(offset)):sub(2)
    elseif c == "," then
      needs_comma, i = false, i + 1
    elseif c:match("%s") then
      i = i + 1
    elseif c == '"' then
      local j = i + 1
      while j <= #value and value:sub(j, j) ~= '"' do
        j = j + (value:sub(j, j) == "\\" and 2 or 1)
      end
      if value:sub(i + 1, j - 1) == cfg then return original end
      i, needs_comma = j + 1, true
    else
      break
    end
  end
  return nil, "Cannot parse editor_plugins/enabled. Enable Neovim Bridge in Godot's Plugins settings."
end

function M.run(root)
  local project_file = root .. "/project.godot"
  local modified = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buf].modified then
      modified[project.key(vim.api.nvim_buf_get_name(buf))] = true
    end
  end
  if modified[project.key(project_file)] then return nil, "Save the modified project.godot buffer before installing" end
  local original = read(project_file)
  if not original then return nil, "Cannot read " .. project_file end
  local updated, err = enable(original .. (original:match("\n$") and "" or "\n"))
  if not updated then return nil, err end
  local source = vim.api.nvim_get_runtime_file("addons/nvim_bridge/plugin.cfg", false)[1]
  if not source then return nil, "Bundled Godot add-on is missing" end
  source = vim.fs.dirname(source)
  local target = root .. "/addons/nvim_bridge"
  for _, dir in ipairs({ root .. "/addons", target }) do
    if uv.fs_lstat(dir) and not vim.startswith(project.key(dir), project.key(root) .. "/") then
      return nil, "Add-on directory points outside this project: " .. dir
    end
  end
  if updated ~= original and uv.fs_lstat(project_file).type == "link" then
    return nil, "Enable the bridge in Godot's Plugins settings for this linked project.godot"
  end
  local pending, changed = {}, {}
  for _, name in ipairs(files) do
    local dest = target .. "/" .. name
    local bundled = read(source .. "/" .. name)
    if not bundled then return nil, "Bundled Godot add-on is missing " .. name end
    local stat = uv.fs_lstat(dest)
    local existing = stat and read(dest)
    if existing ~= bundled then
      if stat and (stat.type ~= "file" or not existing or not previous[name] or vim.fn.sha256(existing) ~= previous[name]) then
        return nil, "Existing add-on file differs: " .. dest
      end
      if modified[project.key(dest)] then return nil, "Save the modified add-on buffer before installing: " .. dest end
      pending[#pending + 1] = { name = name, dest = dest, existing = existing }
    end
  end
  vim.fn.mkdir(target, "p")
  for _, file in ipairs(pending) do
    local ok, why = install_file(source .. "/" .. file.name, file.dest, file.existing)
    if not ok then return nil, why end
    changed[project.key(file.dest)] = true
  end
  if original ~= updated then
    local fd, temp = uv.fs_mkstemp(project_file .. ".XXXXXX")
    if not fd then return nil, temp end
    local bytes, why = uv.fs_write(fd, updated, 0)
    uv.fs_close(fd)
    if bytes ~= #updated or read(project_file) ~= original then
      uv.fs_unlink(temp)
      return nil, why or "project.godot changed during installation. Retry the command."
    end
    uv.fs_chmod(temp, uv.fs_stat(project_file).mode)
    local ok
    ok, why = uv.fs_rename(temp, project_file)
    if not ok then uv.fs_unlink(temp); return nil, why end
    changed[project.key(project_file)] = true
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and changed[project.key(vim.api.nvim_buf_get_name(buf))] then
      vim.api.nvim_buf_call(buf, function() vim.cmd.checktime() end)
    end
  end
  return true
end

return M
