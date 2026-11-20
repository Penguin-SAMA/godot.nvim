if vim.g.loaded_godot_nvim then return end
vim.g.loaded_godot_nvim = true
-- lazy.nvim can source this file immediately before calling setup(opts).
-- Let that configuration take effect before any default tool or project installs.
require("godot").enable(true)

