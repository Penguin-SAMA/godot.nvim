-- Run from an isolated scratch Godot project with this repository on runtimepath.
local root = assert(vim.env.BRIDGE_TEST_PROJECT)
local mode = assert(vim.env.BRIDGE_TEST_MODE)
local ok, err = require('godot.bridge_install').run(root)
assert(ok, err)
assert(vim.uv.fs_stat(root .. '/addons/nvim_bridge/scene_structure.gd'), mode .. ': helper was not installed')
local source = vim.api.nvim_get_runtime_file('addons/nvim_bridge/scene_actions.gd', false)[1]
assert(vim.deep_equal(vim.fn.readfile(source, 'b'), vim.fn.readfile(root .. '/addons/nvim_bridge/scene_actions.gd', 'b')),
  mode .. ': installed bridge does not match bundled bridge')
print(mode .. ' installer fixture passed')
