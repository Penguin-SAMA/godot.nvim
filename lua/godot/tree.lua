local bridge = require("godot.bridge")
local project = require("godot.project")
local outline = require("godot.outline")
local sidebar = require("godot.sidebar")
local api = vim.api
local M = {}
local views = {}

local function warn(message)
  vim.notify("godot.nvim: " .. message, vim.log.levels.WARN)
end

local function resource(root, path)
  if not path or path == "" then return end
  local absolute
  if vim.startswith(path, "res://") then
    absolute = vim.fs.joinpath(root, path:sub(7))
  else
    absolute = vim.fs.abspath(path)
  end
  if not vim.startswith(path, "res://") and vim.fn.isabsolutepath(path) == 0
      and not vim.startswith(project.key(absolute), project.key(root) .. "/") then
    absolute = vim.fs.joinpath(root, path)
  end
  if vim.startswith(project.key(absolute), project.key(root) .. "/") then
    return "res://" .. project.normalize(absolute):sub(#project.normalize(root) + 2)
  end
end

local function components(path)
  return path == "." and {} or vim.split(path, "/", { plain = true })
end

local function reference(node, owner)
  if node.path == owner.path then return "self" end
  local from, to = components(owner.path), components(node.path)
  local first = 1
  while first <= #from and from[first] == to[first] do first = first + 1 end
  local parts = {}
  for _ = first, #from do parts[#parts + 1] = ".." end
  for i = first, #to do parts[#parts + 1] = to[i] end
  if node.unique then parts = { node.name } end
  local path = table.concat(parts, "/")
  for _, part in ipairs(parts) do
    if not part:match("^[%a_][%w_]*$") then
      path = vim.json.encode(path)
      break
    end
  end
  return (node.unique and "%" or "$") .. path
end

local reserved = {}
for word in ("if elif else for while match when break continue pass return class class_name extends is in as self super "
  .. "signal func static const enum var breakpoint preload await yield assert void PI TAU INF NAN null true false "
  .. "and or not namespace trait"):gmatch("%S+") do reserved[word] = true end

local function varname(node)
  local name = node.variable or node.name:gsub("(%l)(%u)", "%1_%2"):gsub("(%a)(%d)", "%1_%2"):lower()
  name = name:gsub("[^%w_]", "_")
  if not name:match("^[%a_]") or reserved[name] or name:match("^_+$") then name = "node_" .. name end
  return name
end

local function drop(view, node, pos, declaration)
  if not vim.api.nvim_win_is_valid(pos.winid) or pos.line < 1 then return end
  local buf = vim.api.nvim_win_get_buf(pos.winid)
  local file = vim.api.nvim_buf_get_name(buf)
  if not file:match("%.gd$") or vim.bo[buf].readonly or not vim.bo[buf].modifiable then return end
  local target = resource(view.root, file)
  local owners = {}
  for _, item in ipairs(view.nodes) do
    if item.script == target then owners[#owners + 1] = item end
  end
  if #owners == 0 then return warn("Drop onto a GDScript attached to a node in this scene.") end
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local function insert(owner)
    if not owner or not vim.api.nvim_buf_is_valid(buf) or vim.api.nvim_buf_get_changedtick(buf) ~= tick then return end
    local row = math.min(pos.line, vim.api.nvim_buf_line_count(buf)) - 1
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local ref = reference(node, owner)
    if declaration then
      -- A member declaration dropped inside a method belongs above that method.
      local insertion = row
      if lines[row + 1]:match("^%s") or lines[row + 1] == "" then
        for i = row + 1, 1, -1 do
          if lines[i]:match("^%S") and not lines[i]:match("^#") then
            if lines[i]:match(":%s*$") or lines[row + 1]:match("^%s+%S") then insertion = i - 1 end
            break
          end
        end
      end
      while insertion > 0 and (lines[insertion]:match("^@[%w_]+%s*$")
          or lines[insertion]:match("^@[%w_]+%b()%s*$")) do insertion = insertion - 1 end
      for i, line in ipairs(lines) do
        if line:match("^extends%s") or line:match("^class_name%s") then insertion = math.max(insertion, i) end
      end
      vim.api.nvim_buf_set_lines(buf, insertion, insertion, false,
        { ("@onready var %s: %s = %s"):format(varname(node), node.type or "Node", ref) })
    else
      local col = math.min(pos.column - 1, #lines[row + 1])
      vim.api.nvim_buf_set_text(buf, row, col, row, col, { ref })
    end
  end
  if #owners == 1 then return insert(owners[1]) end
  vim.ui.select(owners, { prompt = "Generate a path relative to", format_item = function(item) return item.path end }, insert)
end

local function call(view, method, args, callback)
  args.scene = view.scene
  bridge.call(view.root, method, args, function(err, result)
    if err then return warn(err) end
    if vim.api.nvim_buf_is_valid(view.buf) then callback(result) end
  end)
end

local function read_scene(root, scene, done)
  local file = scene and vim.startswith(scene, "res://") and (root .. "/" .. scene:sub(7))
  local buf = file and vim.fn.bufnr(file)
  local modified = buf and buf ~= -1 and vim.bo[buf].modified
  if file and not modified and not vim.uv.fs_stat(file) then return done("Scene not found: " .. scene) end
  local has_bridge = vim.uv.fs_stat(root .. "/addons/nvim_bridge/plugin.cfg")
  local editor = has_bridge and project.read(root .. "/.godot/godot-nvim-editor.json")
  if file and file:lower():match("%.tscn$") and (modified or not (editor and project.alive(editor.pid))) then
    local nodes, err = require("godot.scene_index").file_nodes(file, root)
    if nodes and #nodes > 0 then return done(nil, nodes, scene) end
    if modified or not has_bridge then
      return done(("Could not read nodes in %s: %s"):format(scene, err or "Scene has no root node"))
    end
  end
  bridge.call(root, "scene_tree", { scene = scene }, function(err, info)
    if err then return done(err) end
    local nodes = {}
    local saved
    local function add(node)
      -- A bridge can report a script's class_name (e.g. Player) as its type.
      -- Recover its native icon without losing the class used for @onready.
      if node.script and node.script ~= "" and not node.native_type and not require("godot.node_icons").known(node.type)
          and info.scene and info.scene:match("^res://.*%.tscn$") then
        if not saved then
          saved = {}
          local disk_nodes = require("godot.scene_index").file_nodes(root .. "/" .. info.scene:sub(7), root)
          for _, item in ipairs(disk_nodes or {}) do saved[item.path] = item end
        end
        local match = saved[node.path]
        if match and match.script == node.script then node.native_type = match.type end
      end
      nodes[#nodes + 1] = node
      for _, child in ipairs(node.children) do add(child) end
    end
    add(info)
    done(nil, nodes, info.scene)
  end)
end

local function refresh(view)
  view.revision = view.revision + 1
  local revision = view.revision
  read_scene(view.root, view.scene, function(err, nodes)
    if views[view.buf] ~= view or revision ~= view.revision then return end
    if err then return warn(err) end
    outline.render(view, nodes)
  end)
end

local function mappings(view)
  local function map(key, desc, cb, extra)
    vim.keymap.set("n", key, cb, vim.tbl_extend("force", { buffer = view.buf, desc = desc, silent = true }, extra or {}))
  end
  views[view.buf] = view
  vim.api.nvim_create_autocmd("BufWipeout", { buffer = view.buf, once = true,
    callback = function() views[view.buf] = nil end })
  local function selected()
    return view.rows[vim.api.nvim_win_get_cursor(0)[1]]
  end
  local function change(method, args)
    call(view, method, args, function() refresh(view) end)
  end
  map("a", "Add Child Node", function()
    local parent = selected()
    if not parent then return end
    call(view, "creatable_types", {}, function(types)
      vim.ui.select(types, { prompt = "Child node type" }, function(kind)
        if not kind then return end
        vim.ui.input({ prompt = "Node name: ", default = kind }, function(name)
          if name and name ~= "" then change("add_node", { parent = parent.path, type = kind, name = name }) end
        end)
      end)
    end)
  end)
  map("s", "Attach or Create Script", function()
    local node = selected()
    if not node then return end
    local base = (view.scene or "res://main.tscn"):match("^(.*[/])")
    vim.ui.input({ prompt = "Script resource: ", default = base .. varname(node) .. ".gd" }, function(path)
      if path and path ~= "" then change("attach_script", { node = node.path, script_path = path }) end
    end)
  end)
  map("c", "Connect Signal", function()
    local src = selected()
    if not src then return end
    call(view, "signals", { node = src.path }, function(signals)
      vim.ui.select(signals, { prompt = "Signal", format_item = function(sig) return sig.name end }, function(sig)
        if not sig then return end
        local targets = vim.tbl_filter(function(node) return node.script and node.script:match("%.gd$") end, view.nodes)
        if #targets == 0 then return warn("Attach a GDScript to a destination node first.") end
        vim.ui.select(targets, { prompt = "Callback destination", format_item = function(node) return node.path end }, function(dst)
          if not dst then return end
          vim.ui.input({ prompt = "Callback: ", default = "_on_" .. varname(src) .. "_" .. sig.name }, function(method)
            if method and method ~= "" then
              change("connect_signal", { source = src.path, target = dst.path, signal = sig.name, method = method })
            end
          end)
        end)
      end)
    end)
  end)
  map("u", "Undo Scene Change", function() change("undo", {}) end)
  map("r", "Refresh Scene Tree", function() refresh(view) end)
  map("q", "Close Scene Tree", function() sidebar.close(view.win) end)
  local function fold(how) return function() outline.fold(view, how) end end
  map("za", "Toggle Branch", fold("toggle"))
  map("h", "Collapse or Go to Parent", fold("close"))
  map("l", "Expand or Go to Child", fold("open"))
  map("<Left>", "Collapse or Go to Parent", fold("close"))
  map("<Right>", "Expand or Go to Child", fold("open"))
  map("<CR>", "Open Attached Script", function()
    local node = selected()
    if not node or not node.script or node.script == "" then return end
    if vim.api.nvim_win_is_valid(view.origin) then vim.api.nvim_set_current_win(view.origin) end
    bridge.resource(view.root, node.script)
  end)
  local function insert_at_cursor(declaration)
    local node = selected()
    if not node then return end
    local scripts = {}
    for _, item in ipairs(view.nodes) do
      if item.script then scripts[item.script] = true end
    end
    local windows = {}
    local function insert(win)
      if not win or not vim.api.nvim_win_is_valid(win) then return end
      local pos = vim.api.nvim_win_get_cursor(win)
      drop(view, node, { winid = win, line = pos[1], column = pos[2] + 1 }, declaration)
    end
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local file = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
      if file:match("%.gd$") and scripts[resource(view.root, file)] then
        if win == view.origin then return insert(win) end
        windows[#windows + 1] = win
      end
    end
    if #windows == 0 then return warn("Open a script attached to this scene in a split first.") end
    if #windows == 1 then return insert(windows[1]) end
    vim.ui.select(windows, { prompt = "Choose Script Window", format_item = function(win)
      return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
    end }, insert)
  end
  map("i", "Insert Node Path at Cursor", function() insert_at_cursor(false) end)
  map("I", "Insert @onready Declaration", function() insert_at_cursor(true) end)
  local dragged, disclosure
  for _, prefix in ipairs({ "", "C-" }) do
    map("<" .. prefix .. "LeftMouse>", "Pick up a scene node", function()
      local pos = vim.fn.getmousepos()
      dragged = pos.winid == view.win and view.rows[pos.line] or nil
      disclosure = dragged and prefix == "" and outline.is_disclosure(view, pos.line, pos.column)
      return "<LeftMouse>"
    end, { expr = true })
    map("<" .. prefix .. "LeftDrag>", "Drag a scene node", function() end)
    map("<" .. prefix .. "LeftRelease>", "Insert node reference or declaration", function()
      local pos = vim.fn.getmousepos()
      if dragged and pos.winid ~= view.win then drop(view, dragged, pos, prefix == "C-") end
      if disclosure and pos.winid == view.win and dragged == view.rows[pos.line]
          and outline.is_disclosure(view, pos.line, pos.column) then
        api.nvim_win_set_cursor(view.win, { pos.line, 0 })
        outline.fold(view, "toggle")
      end
      dragged, disclosure = nil, nil
    end)
  end
end

local function present(view, nodes, tab)
  for _, win in ipairs(api.nvim_tabpage_list_wins(tab)) do
    local current = views[api.nvim_win_get_buf(win)]
    if current and current.root == view.root and current.scene == view.scene then
      current.revision = current.revision + 1
      current.origin = view.origin
      api.nvim_set_current_win(win)
      outline.render(current, nodes)
      return current
    end
  end
  local buf = api.nvim_create_buf(false, true)
  view.buf = buf
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.b[buf].godot_root = view.root
  mappings(view)
  vim.bo[buf].filetype = "godot_scene_tree"
  view.win, view.origin = sidebar.show(buf, view.origin)
  vim.wo[view.win].number, vim.wo[view.win].relativenumber, vim.wo[view.win].wrap = false, false, false
  vim.wo[view.win].signcolumn, vim.wo[view.win].foldcolumn = "no", "0"
  vim.wo[view.win].cursorline = true
  outline.render(view, nodes)
  return view
end

function M.open(root, arg)
  local source, origin, tab = api.nvim_get_current_buf(), api.nvim_get_current_win(), api.nvim_get_current_tabpage()
  local file = api.nvim_buf_get_name(source)
  local previous = views[source]
  local view = { root = root, origin = previous and previous.origin or origin, nodes = {}, rows = {}, revision = 0 }
  local request = (vim.t[tab].godot_tree_request or 0) + 1
  vim.t[tab].godot_tree_request = request
  local function pending()
    return api.nvim_get_current_tabpage() == tab and vim.t[tab].godot_tree_request == request
      and api.nvim_win_is_valid(origin) and api.nvim_win_get_buf(origin) == source
  end
  local function finish(err, nodes, scene)
    if not pending() then return end
    if err then return warn(err) end
    view.scene = scene
    view = present(view, nodes, tab)
  end
  local function load(scene)
    if pending() then read_scene(root, scene, finish) end
  end
  local path = arg and arg ~= "" and arg or (file:lower():match("%.t?scn$") and file)
  if path then
    local scene = path:match("^uid://") and path or resource(root, path)
    if not scene then return finish("Choose a scene in " .. root) end
    load(scene)
  elseif file:lower():match("%.gd$") then
    require("godot.scene_lookup").find(root, file, function(err, scenes)
      if not pending() then return end
      if err then return finish(err) end
      if #scenes == 0 then
        return finish("No .tscn scene uses the script " .. (resource(root, file) or file))
      end
      if #scenes == 1 then return load(scenes[1]) end
      vim.ui.select(scenes, { prompt = "Choose a Scene Using This Script" }, function(scene)
        if scene then load(scene) end
      end)
    end)
  else
    load(previous and previous.scene or nil)
  end
  return view
end

return M
