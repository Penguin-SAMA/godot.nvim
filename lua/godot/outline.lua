local api = vim.api
local icons = require("godot.node_icons")
local ns = api.nvim_create_namespace("godot.scene.outline")
local M = {}

local function highlights()
  for name, color in pairs({
    Node = { "#e0e0e0", 253 }, Node2D = { "#8da5f3", 111 },
    Node3D = { "#fc7f7f", 210 }, Control = { "#8eef97", 120 },
  }) do
    api.nvim_set_hl(0, "GodotTree" .. name, { fg = color[1], ctermfg = color[2], default = true })
  end
  api.nvim_set_hl(0, "GodotTreeDisclosure", { link = "NonText", default = true })
  api.nvim_set_hl(0, "GodotTreeClass", { link = "Comment", default = true })
  api.nvim_set_hl(0, "GodotTreeUnique", { link = "Special", default = true })
end
highlights()
api.nvim_create_autocmd("ColorScheme", {
  group = api.nvim_create_augroup("GodotSceneOutline", { clear = true }), callback = highlights,
})

local function parent_path(path)
  if path ~= "." then return path:match("^(.*)/[^/]+$") or "." end
end

local function has_window(view)
  return view.win and api.nvim_win_is_valid(view.win) and api.nvim_win_get_buf(view.win) == view.buf
end

local function selected(view)
  if view.rows and has_window(view) then
    return view.rows[api.nvim_win_get_cursor(view.win)[1]]
  end
end

local function draw(view, wanted)
  local tree = view.outline
  local lines, marks = {}, {}
  view.rows, tree.row_for, tree.arrows = {}, {}, {}
  local function mark(row, start, finish, group)
    marks[#marks + 1] = { row - 1, start, finish, group }
  end
  local function visit(node, depth)
    local path = node.path
    local row = #lines + 1
    view.rows[row], tree.row_for[path] = node, row
    local indent = string.rep("  ", depth)
    local prefix = indent .. "  "
    if tree.children[path] then
      local arrow = tree.collapsed[path] and "▸" or "▾"
      prefix = indent .. arrow .. " "
      tree.arrows[row] = { #indent + 1, #indent + #arrow }
      mark(row, #indent, #indent + #arrow, "GodotTreeDisclosure")
    end
    local icon = icons.get(node)
    local line = prefix .. icon[1] .. " "
    mark(row, #prefix, #prefix + #icon[1], icon[2])
    if node.unique then
      mark(row, #line, #line + 1, "GodotTreeUnique")
      line = line .. "%"
    end
    line = line .. node.name
    local class = node.type or node.native_type or (node.instance and "PackedScene") or "Node"
    if class ~= node.name then
      mark(row, #line + 2, #line + 2 + #class, "GodotTreeClass")
      line = line .. "  " .. class
    end
    lines[row] = line
    if tree.children[path] and not tree.collapsed[path] then
      for _, child in ipairs(tree.children[path]) do visit(child, depth + 1) end
    end
  end
  for _, root in ipairs(tree.roots) do visit(root, 0) end

  vim.bo[view.buf].modifiable = true
  api.nvim_buf_set_lines(view.buf, 0, -1, false, lines)
  api.nvim_buf_clear_namespace(view.buf, ns, 0, -1)
  for _, m in ipairs(marks) do
    api.nvim_buf_set_extmark(view.buf, ns, m[1], m[2], { end_col = m[3], hl_group = m[4] })
  end
  vim.bo[view.buf].modified, vim.bo[view.buf].modifiable = false, false
  if has_window(view) then
    while wanted and not tree.row_for[wanted] do wanted = parent_path(wanted) end
    api.nvim_win_set_cursor(view.win, { tree.row_for[wanted] or 1, 0 })
  end
end

function M.render(view, nodes)
  if not api.nvim_buf_is_valid(view.buf) then return end
  local tree = view.outline
  local previous
  if tree and tree.scene == view.scene then
    previous = selected(view)
  else
    tree = { scene = view.scene, collapsed = {} }
    view.outline = tree
  end
  view.nodes = nodes
  tree.roots, tree.children, tree.parent = {}, {}, {}
  local known = {}
  for _, node in ipairs(nodes) do known[node.path] = true end
  for _, node in ipairs(nodes) do
    local parent = parent_path(node.path)
    -- An override inside an instanced scene can omit intermediate nodes in the .tscn.
    while parent and not known[parent] do parent = parent_path(parent) end
    if parent then
      tree.parent[node.path] = parent
      tree.children[parent] = tree.children[parent] or {}
      table.insert(tree.children[parent], node)
    else
      table.insert(tree.roots, node)
    end
  end
  for path in pairs(tree.collapsed) do
    if not tree.children[path] then tree.collapsed[path] = nil end
  end
  draw(view, previous and previous.path)
end

-- Both row and byte_column are 1-based, as returned by getmousepos().
function M.is_disclosure(view, row, byte_column)
  local range = view.outline and view.outline.arrows[row]
  return range ~= nil and byte_column >= range[1] and byte_column <= range[2]
end

function M.fold(view, action)
  local node = selected(view)
  if not node then return end
  local tree, path = view.outline, node.path
  local children, closed = tree.children[path], tree.collapsed[path]
  if children and (action == "toggle" or (action == "open" and closed) or (action == "close" and not closed)) then
    tree.collapsed[path] = not closed or nil
    draw(view, path)
    return
  end
  local target
  if action == "open" and children then target = children[1].path end
  if action == "close" then target = tree.parent[path] end
  if target then api.nvim_win_set_cursor(view.win, { tree.row_for[target], 0 }) end
end

return M
