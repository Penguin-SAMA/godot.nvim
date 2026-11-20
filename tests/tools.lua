-- Offline state/selection tests. Run with nvim --headless -u NONE -l tests/tools.lua.
vim.opt.rtp:prepend(vim.fn.getcwd())
local tmp = vim.fs.normalize(vim.fn.tempname())
vim.fn.mkdir(tmp, "p")
tmp = vim.fs.normalize(assert(vim.uv.fs_realpath(tmp)))
vim.env.XDG_DATA_HOME = tmp .. "/data"
local config = require("godot.config")
local project = require("godot.project")
local tools = require("godot.tools")
local ids = { "scene_tree", "dap", "shader_lsp", "gdscript_formatter", "clang_format" }
local features = { scene_tree = false, dap = false, shader_lsp = false, formatting = false }
local function setup(opts)
  config.setup(vim.tbl_extend("force", { state_dir = tmp .. "/state", features = features }, opts or {}))
  tools.setup()
end
local calls, events = {}, {}
vim.system = function(args, _, callback)
  calls[#calls + 1] = { args = args, callback = callback }
end
vim.api.nvim_create_autocmd("User", { pattern = "GodotToolsReady", callback = function(e) events[#events + 1] = e.data end })
setup()
for _, id in ipairs(ids) do assert(tools.status(id).state == "disabled") end
assert(#calls == 0 and not package.loaded.dap)
features.formatting = true
local nvim = vim.v.progpath
setup({ clang_format = nvim, gdscript_formatter = tmp .. "/missing" })
assert(tools.status("clang_format").state == "ready")
assert(tools.status("gdscript_formatter").state == "failed")
assert(#calls == 0, "An explicit missing override must report its error")
features.formatting, features.dap = false, true
package.loaded.dap = { listeners = {} }
setup()
assert(tools.status("dap").message:find("restart Neovim", 1, true))
assert(#calls == 0, "An already loaded incompatible nvim-dap must not be shadowed")
features.dap = false
package.loaded.dap = nil

if vim.fn.has("win32") == 1 and jit.arch == "x64" then
  local pkgs = project.read("scripts/dependencies-windows.json").packages
  local function pkg_for(version)
    for _, pkg in ipairs(pkgs) do if pkg.id == "shader_lsp" and pkg.version == version then return pkg end end
  end
  local candidate = tmp .. "/candidate.exe"
  vim.fn.writefile({}, candidate)
  local exepath = vim.fn.exepath
  vim.fn.exepath = function(name)
    if name == "gdshader-lsp" then return candidate end
    return exepath(name)
  end
  local function game(name, version)
    local root = tmp .. "/" .. name
    vim.fn.mkdir(root, "p")
    vim.fn.writefile({ "[application]", ('config/features=PackedStringArray("%s")'):format(version) }, root .. "/project.godot")
    return root
  end
  local old = game("old", "4.6")
  local another = game("another", "4.5")
  local modern = game("modern", "4.7")
  local early = game("early", "4.4")
  features.formatting, features.shader_lsp = false, true
  setup()
  for _, root in ipairs({ old, another, modern }) do assert(tools.status("shader_lsp", root).state == "pending") end
  assert(tools.status("shader_lsp", early).state == "failed")
  assert(#calls == 1 and calls[1].args[1] == "certutil.exe", "Check the candidate once for all roots")
  local legacy = pkg_for("0.2.6")
  local latest = pkg_for("0.3.2")
  calls[1].callback({ code = 0, stdout = latest.sha256 .. "\n" })
  assert(vim.wait(2000, function() return #calls == 2 and tools.path("shader_lsp", modern) == candidate end))
  local installer = calls[2]
  assert(installer.args[#installer.args] == legacy.version)
  installer.callback({ code = 1, stderr = "offline" })
  assert(vim.wait(2000, function() return tools.status("shader_lsp", old).state == "failed" end))
  assert(tools.status("shader_lsp", another).message == "offline")
  tools.retry()
  assert(#calls == 3 and tools.status("shader_lsp", old).state == "pending")

  local store
  for i, arg in ipairs(calls[3].args) do if arg == "-Store" then store = calls[3].args[i + 1] end end
  assert(store and project.key(store):find(project.key(tmp), 1, true) == 1, "Test store must be isolated")
  local dir = vim.fs.joinpath(store, "shader_lsp", legacy.version .. "-" .. legacy.sha256:sub(1, 12))
  local exe = vim.fs.joinpath(dir, legacy.path)
  vim.fn.mkdir(vim.fs.dirname(exe), "p")
  vim.fn.writefile({}, exe)
  project.write(dir .. "/installed.json", { sha256 = legacy.sha256 })
  calls[3].callback({ code = 0 })
  assert(vim.wait(2000, function() return tools.path("shader_lsp", old) == exe end))
  assert(tools.path("shader_lsp", another) == exe)
  assert(#events >= 4, "Notify each waiting project on download or verified PATH reuse")
  game("old", "4.7")
  assert(tools.path("shader_lsp", old) == candidate, "Re-evaluate a changed project requirement")
  setup({ shader_lsp = nvim })
  assert(tools.status("shader_lsp", early).path and #calls == 3, "Explicit shader override wins")

  local parser
  for _, pkg in ipairs(pkgs) do if pkg.id == "scene_tree" then parser = pkg end end
  local parser_dir = vim.fs.joinpath(store, parser.id, parser.version .. "-" .. parser.sha256:sub(1, 12))
  local parser_path = vim.fs.joinpath(parser_dir, parser.path)
  vim.fn.mkdir(vim.fs.dirname(parser_path), "p")
  vim.fn.writefile({}, parser_path)
  project.write(parser_dir .. "/installed.json", { sha256 = parser.sha256 })
  local loaded = false
  vim.treesitter.language.add = function(_, opts)
    if opts then assert(opts.path == parser_path); loaded = true end
    return loaded
  end
  features.shader_lsp, features.scene_tree = false, true
  setup()
  assert(tools.path("scene_tree") == parser_path and loaded)
  setup()
  assert(tools.path("scene_tree") == parser_path, "Managed parser path was forgotten after setup")
end
vim.fn.delete(tmp, "rf")
print("PASS offline tool flags, overrides, compatible reuse, deduplication and retry")
