local M = {}
local defaults = {
  features = { scene_tree = true, bridge = true, dap = false, shader_lsp = true, formatting = true },
  executable = vim.env.GODOT_NVIM_EXECUTABLE,
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
  local paths = opts and opts.godot_path
  if paths ~= nil and type(paths) ~= "string" then
    assert(type(paths) == "table" and vim.islist(paths), "godot_path must be a directory or a list of directories")
    for _, path in ipairs(paths) do
      assert(type(path) == "string" and path ~= "", "godot_path entries must be nonempty strings")
    end
  end
  local features = opts and opts.features
  if features ~= nil then
    assert(type(features) == "table", "godot.nvim: opts.features must be a table")
    for name, value in pairs(features) do
      assert(defaults.features[name] ~= nil, "godot.nvim: unknown feature " .. tostring(name))
      assert(type(value) == "boolean", "godot.nvim: features." .. name .. " must be true or false")
    end
  end
  M.options = vim.tbl_extend("force", vim.deepcopy(defaults), opts or {})
  M.options.features = vim.tbl_extend("force", defaults.features, features or {})
end

function M.enabled(name)
  return M.options.features[name] == true
end

function M.require_feature(name)
  if M.enabled(name) then return true end
  vim.notify("godot.nvim: enable opts.features." .. name .. " to use this feature.", vim.log.levels.INFO)
  return false
end
return M

