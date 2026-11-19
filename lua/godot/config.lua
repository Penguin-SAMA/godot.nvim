local M = {}
local defaults = {
  executable = vim.env.GODOT_NVIM_EXECUTABLE or "godot",
  shader_lsp = "gdshader-lsp",
  gdscript_formatter = "gdscript-formatter",
  clang_format = "clang-format",
  scene_icons = "nerd",
  toolbar = true,
  state_dir = vim.fn.stdpath("state") .. "/godot.nvim",
  startup_timeout = 45000,
}
M.options = vim.deepcopy(defaults)
function M.setup(opts)
  M.options = vim.tbl_extend("force", vim.deepcopy(defaults), opts or {})
end
return M

