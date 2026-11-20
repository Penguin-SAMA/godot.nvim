-- nvim --headless -u NONE -i NONE -l tests/feature_config.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local config = require("godot.config")
config.setup({ features = { dap = true, formatting = false } })
assert(config.options.features.scene_tree == true and config.options.features.bridge == true)
assert(config.options.features.shader_lsp == true and config.options.features.formatting == false)
assert(config.options.features.dap == true)
config.setup({})
assert(config.options.features.dap == false and config.options.features.formatting == true)
assert(not pcall(config.setup, { features = { dap = "false" } }))

local root = vim.fs.normalize(vim.fn.tempname())
vim.fn.mkdir(root, "p")
local file = root .. "/project.godot"
vim.fn.writefile({ "config_version=5", "[application]", 'config/name="Feature test"' }, file)
local bridge = require("godot.bridge")
local notified = {}
vim.notify = function(msg) notified[#notified + 1] = msg end
config.setup({ features = { bridge = false } })
bridge.prepare(root)
assert(not vim.uv.fs_stat(root .. "/addons"))
local buf = vim.fn.bufadd(file)
vim.fn.bufload(buf)
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "; unsaved" })
config.setup({})
bridge.prepare(root)
assert(not vim.uv.fs_stat(root .. "/addons"))
assert(bridge.status(root).state == "failed")
vim.bo[buf].modified = false
assert(bridge.install(root))
local addon = root .. "/addons/nvim_bridge/plugin.gd"
local before = vim.uv.fs_stat(addon).mtime
bridge.prepare(root)
assert(vim.deep_equal(before, vim.uv.fs_stat(addon).mtime))
vim.fn.writefile({ "custom plugin" }, addon)
assert(not bridge.install(root))
assert(vim.fn.readfile(addon)[1] == "custom plugin")
assert(bridge.status(root).message:find("differs", 1, true))
vim.api.nvim_buf_delete(buf, { force = true })
vim.fn.delete(root, "rf")
print("PASS feature defaults, partial overrides, bridge installation, conflicts and retry")
