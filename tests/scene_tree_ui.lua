vim.opt.runtimepath:prepend('.')
local api = vim.api
local root = vim.fn.tempname()
local scene = 'res://fixture.scn'
vim.fn.mkdir(root, 'p')
vim.fn.writefile({}, root .. '/fixture.scn')
api.nvim_create_autocmd('VimLeavePre', { callback = function() vim.fn.delete(root, 'rf') end })
local function node(path, children)
  return { path = path, name = path:match('[^/]+$'), type = 'Node', children = children or {} }
end
local fixture = node('.', { node('Left', {
  node('Left/Target', { node('Left/Target/Child') }), node('Left/TargetExtra'),
}), node('Right') })
fixture.scene, fixture.name = scene, 'Root'
local calls, fail = {}, false
package.loaded['godot.bridge'] = {
  call = function(directory, method, args, callback)
    assert(directory == root)
    calls[#calls + 1] = { method, vim.deepcopy(args) }
    if fail then return callback('Fixture rejected edit') end
    callback(nil, method == 'scene_tree' and fixture or {})
  end,
}
local function eq(expected, actual)
  assert(vim.deep_equal(expected, actual), ('Expected %s, got %s'):format(vim.inspect(expected), vim.inspect(actual)))
end
local function open()
  local view = require('godot.tree').open(root)
  eq(scene, view.scene)
  calls = {}
  return view
end
local view = open()
local prompt, notices
vim.ui.input = function(opts, cb) prompt = { opts = opts, accept = cb } end
vim.ui.select = function(items, opts, cb) prompt = { items = items, opts = opts, accept = cb } end
vim.notify = function(message) notices = message end
local function press(key, path)
  prompt = nil
  for row, item in pairs(view.rows) do
    if item.path == path then api.nvim_win_set_cursor(view.win, { row, 0 }); break end
  end
  local mapping = vim.fn.maparg(key, 'n', false, true)
  eq(1, mapping.buffer)
  mapping.callback()
  return prompt
end
local target = 'Left/Target'
local function no_calls() eq({}, calls) end
local function expect_edit(method, args)
  args.scene = scene
  eq({ { method, args }, { 'scene_tree', { scene = scene } } }, calls)
  calls = {}
end
local rename = press('R', target)
eq('Target', rename.opts.default)
rename.accept(nil)
press('R', target).accept('Target')
press('R', target).accept('')
no_calls()
press('R', target).accept('Renamed')
expect_edit('rename_node', { node = target, name = 'Renamed' })

local delete = press('d', target)
assert(delete.opts.prompt:find(target, 1, true) and delete.opts.prompt:find('subtree', 1, true))
eq('Cancel', delete.items[1])
eq(2, #delete.items)
delete.accept(delete.items[1], 1)
press('d', target).accept(nil)
no_calls()
delete = press('d', target)
delete.accept(delete.items[2], 2)
expect_edit('delete_node', { node = target })

local move = press('m', target)
eq({ '.', 'Left/TargetExtra', 'Right' }, vim.tbl_map(move.opts.format_item, move.items))
move.accept(nil)
no_calls()
move = press('m', target)
move.accept(move.items[2], 2)
expect_edit('reparent_node', { node = target, parent = 'Left/TargetExtra' })

for _, key in ipairs({ 'R', 'd', 'm' }) do
  eq(nil, press(key, '.'))
end
no_calls()

for _, key in ipairs({ 'R', 'd', 'm' }) do
  local stale = press(key, target)
  press('r', target)
  eq({ { 'scene_tree', { scene = scene } } }, calls)
  calls = {}
  stale.accept(stale.items and stale.items[2] or 'Stale', 2)
  no_calls()
end

fail = true
press('R', target).accept('Rejected')
eq({ { 'rename_node', { scene = scene, node = target, name = 'Rejected' } } }, calls)
eq('godot.nvim: Fixture rejected edit', notices)
fail = false
calls = {}

local dismissed = press('R', target)
local buf = view.buf
press('q', target)
assert(not api.nvim_buf_is_valid(buf))
dismissed.accept('Closed')
no_calls()
for _, key in ipairs({ 'R', 'd', 'm' }) do
  eq(nil, vim.fn.maparg(key, 'n', false, true).buffer)
end
print('Scene tree UI tests passed')
