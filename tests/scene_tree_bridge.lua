vim.opt.runtimepath:prepend('.')
local api, uv = vim.api, vim.uv
local root = vim.fn.tempname()
local server = uv.new_tcp()
local peer
api.nvim_create_autocmd('VimLeavePre', { callback = function()
  if peer then peer:close() end
  server:close()
  vim.fn.delete(root, 'rf')
end })

local pid = uv.os_getpid()
vim.fn.mkdir(root .. '/.godot', 'p')
vim.fn.mkdir(root .. '/addons/nvim_bridge', 'p')
vim.fn.writefile({ 'abc123' }, root .. '/.godot/godot-nvim-bridge-' .. pid .. '.key', 'b')
vim.fn.writefile({}, root .. '/addons/nvim_bridge/plugin.cfg')
root = require('godot.project').normalize(root)
local function load(name)
  local path = root .. '/' .. name
  vim.fn.writefile({ 'original' }, path)
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  vim.bo[buf].autoread = true
  return buf, path
end
local dirty = load('dirty.tscn')
api.nvim_buf_set_lines(dirty, 0, -1, false, { 'unsaved edits' })
local clean, clean_path = load('clean.tscn')

assert(server:bind('127.0.0.1', 0))
local port = server:getsockname().port
local received
local bytes = ''
assert(server:listen(1, function(err)
  assert(not err, err)
  peer = uv.new_tcp()
  assert(server:accept(peer))
  peer:read_start(vim.schedule_wrap(function(read_err, chunk)
    assert(not read_err, read_err)
    if not chunk then return end
    bytes = bytes .. chunk
    while true do
      local newline = bytes:find('\n', 1, true)
      if not newline then break end
      local request = vim.json.decode(bytes:sub(1, newline - 1))
      bytes = bytes:sub(newline + 1)
      local result = {}
      if request.method == 'hello' then
        assert(request.params.token == 'abc123')
        result = { root = root, pid = pid, mode = 'editor' }
      else
        received = request
        -- Change the file size each time so the check also works on coarse timestamps.
        vim.fn.writefile({ request.method }, clean_path, 'a')
      end
      peer:write(vim.json.encode({ id = request.id, result = result }) .. '\n')
    end
  end))
end))

-- Replace editor discovery only; exercise bridge.call through the real TCP request/response path.
package.loaded['godot.session'] = { ensure = function(directory, mode, callback)
  assert(directory == root and mode == 'editor')
  callback(nil, { root = root, pid = pid, bridge_port = port, mode = mode })
end }
package.loaded['godot.ports'] = { owners = function(callback) callback({ [port] = pid }) end }
local bridge = require('godot.bridge')
local failures = {}
local function expect(ok, message)
  if not ok then failures[#failures + 1] = message end
end
local cases = {
  { 'rename_node', { node = 'Target', name = 'Renamed' } },
  { 'delete_node', { node = 'Target' } },
  { 'reparent_node', { node = 'Target', parent = 'Destination' } },
}
for _, case in ipairs(cases) do
  local method, params = unpack(case)
  params.scene = 'res://clean.tscn'
  local done, response_err, lines
  bridge.call(root, method, params, function(err)
    response_err = err
    lines = api.nvim_buf_get_lines(clean, 0, -1, false)
    done = true
  end)
  assert(vim.wait(3000, function() return done end), method .. ': timed out')
  assert(not response_err, response_err)
  assert(received and received.method == method, method .. ': request not received')
  expect(vim.deep_equal({ 'res://dirty.tscn' }, received.params.modified),
    method .. ': request must include the unsaved project buffer')
  expect(lines[#lines] == method, method .. ': clean buffer must reload before the callback')
  expect(vim.bo[dirty].modified and api.nvim_buf_get_lines(dirty, 0, -1, false)[1] == 'unsaved edits',
    method .. ': unsaved edits must be preserved')
end
assert(#failures == 0, '\n' .. table.concat(failures, '\n'))
print('Scene tree bridge mutation hooks passed')
