local project = require("godot.project")
local index = require("godot.scene_index")
local M = {}
local windows = vim.fn.has("win32") == 1

-- A new, unsaved file has no realpath. Its parent may still be reached by a
-- Windows short name or junction, so resolve the nearest existing ancestor.
local function canonical(path)
  path = vim.fs.normalize(path)
  local real = vim.uv.fs_realpath(path)
  if real then return vim.fs.normalize(real) end
  local dir = vim.fs.dirname(path)
  if dir == path then return path end
  return vim.fs.joinpath(canonical(dir), vim.fs.basename(path))
end

-- These two functions run in libuv's worker pool, without access to buffers.
local function list_scenes(root, packed, win)
  local overlays = vim.mpack.decode(packed)
  local dirs, files = { root }, {}
  while #dirs > 0 do
    local dir = table.remove(dirs)
    local uv = vim.uv
    if not uv.fs_stat(dir .. "/.gdignore") and (dir == root or not uv.fs_stat(dir .. "/project.godot")) then
      local scan, err = uv.fs_scandir(dir)
      if not scan then return nil, err end
      while true do
        local name, kind = uv.fs_scandir_next(scan)
        if not name then break end
        local path = dir:gsub("/$", "") .. "/" .. name
        local folded = win and name:lower() or name
        if kind == "directory" and name:sub(1, 1) ~= "." then
          dirs[#dirs + 1] = path
        elseif kind == "file" and folded:match("%.tscn$") then
          files[win and path:lower() or path] = path
        end
      end
      -- A newly named, edited scene may have no on-disk directory entry yet.
      for _, path in ipairs(overlays[win and dir:lower() or dir] or {}) do
        local key = win and path:lower() or path
        files[key] = files[key] or path
      end
    end
  end
  return vim.mpack.encode(files)
end

local function read_scene(path)
  local uv = vim.uv
  local fd, err, code = uv.fs_open(path, "r", 0)
  if not fd then
    if code == "ENOENT" then return "" end -- The scene disappeared during enumeration.
    return nil, err
  end
  local stat, stat_err = uv.fs_fstat(fd)
  local source
  if stat then source, err = uv.fs_read(fd, stat.size, 0) end
  uv.fs_close(fd)
  if not source then return nil, stat_err or err end
  -- Many scenes contain no scripts. Avoid handing their geometry, animation,
  -- or tile-map data to the parser when a node binding is impossible.
  if not source:find("script", 1, true) or not source:find("ExtResource", 1, true) then return "" end
  return source
end

-- callback(error, scenes) runs on the editor thread. The result contains
-- direct node attachments only, in sorted res:// order.
function M.find(root, script, callback)
  root = project.normalize(root)
  local root_prefix = project.key(root):gsub("/$", "") .. "/"
  local target = project.key(canonical(script))
  if not vim.startswith(target, root_prefix) then return callback("Script is outside the Godot project.", {}) end

  local buffers, overlays = {}, {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if name:lower():match("%.tscn$") and vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified then
      local path = canonical(name)
      local key = windows and path:lower() or path
      if vim.startswith(key, root_prefix) then
        local dir = vim.fs.dirname(key)
        overlays[dir] = overlays[dir] or {}
        table.insert(overlays[dir], path)
        buffers[key] = buf
      end
    end
  end

  local files, position, path = {}, 0, nil
  local matches = {}
  local advance
  local function inspect(err, data)
    if err then return callback(("Cannot read %s: %s"):format(path, err), {}) end
    for script_path in pairs(data and data.scripts or {}) do
      local file = index.resource_file(root, path, script_path)
      if file and project.key(file) == target then
        matches[#matches + 1] = "res://" .. path:sub(#root_prefix + 1)
        break
      end
    end
    vim.schedule(advance)
  end
  local reader = vim.uv.new_work(read_scene, vim.schedule_wrap(function(source, err)
    if not source or source == "" then return inspect(err) end
    index.parse_text(source, inspect)
  end))
  advance = function()
    position = position + 1
    path = files[position]
    if not path then
      table.sort(matches)
      return callback(nil, matches)
    end
    local buf = buffers[windows and path:lower() or path]
    if buf and vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified then
      local source = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      index.parse_text(source, inspect)
    else
      reader:queue(path)
    end
  end
  vim.uv.new_work(list_scenes, vim.schedule_wrap(function(packed, err)
    if not packed then return callback(err, {}) end
    files = vim.tbl_values(vim.mpack.decode(packed))
    advance()
  end)):queue(root, vim.mpack.encode(overlays), windows)
end

return M
