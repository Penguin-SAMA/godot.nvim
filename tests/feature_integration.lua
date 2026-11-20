-- nvim --headless -u NONE -i NONE -l tests/feature_integration.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local root = vim.fs.normalize(vim.fn.tempname())
vim.fn.mkdir(root, "p")
vim.fn.writefile({ "config_version=5" }, root .. "/project.godot")
vim.fn.writefile({ "[node name=\"Root\" type=\"Node\"]" }, root .. "/main.tscn")
vim.fn.writefile({ "float intensity = 1.0;" }, root .. "/main.gdshaderinc")
vim.cmd.edit(vim.fn.fnameescape(root .. "/main.gdshaderinc"))
local shader = api.nvim_get_current_buf()

local messages, tool_calls, requests = {}, {}, {}
vim.notify = function(message) messages[#messages + 1] = message end
local paths = { clang_format = "managed/clang-format", shader_lsp = "managed/gdshader-lsp" }
local pending = { dap = true }
local function tool(id)
  tool_calls[id] = (tool_calls[id] or 0) + 1
  if pending[id] then return { state = "pending", message = "Installing " .. id } end
  return { state = "ready", path = paths[id] }
end
package.loaded["godot.tools"] = { setup = function() end, status = tool, path = function(id) return tool(id).path end }
package.loaded["godot.session"] = { track = function() end, advertised_editor = function() end, release_all = function() end }
local connected = false
package.loaded["godot.bridge"] = {
  prepare = function() return true end, disable = function() end,
  connected = function() return connected end,
  run_state = function() return {} end,
  call = function(_, method, _, done)
    requests[#requests + 1] = method
    done(nil, method == "scene_tree" and { path = ".", name = "Live root", children = {}, scene = "res://main.tscn" } or {})
  end,
}
package.loaded["godot.scene_index"] = { file_nodes = function()
  return { { path = ".", type = "Node", name = "Offline root" } }
end }
local dap_loaded = 0
package.preload.dap = function()
  dap_loaded = dap_loaded + 1
  local function listeners()
    return setmetatable({}, { __index = function(t, k) t[k] = {}; return t[k] end })
  end
  return {
    adapters = {}, listeners = { before = listeners(), after = listeners(), on_session = {} },
    toggle_breakpoint = function() requests[#requests + 1] = "breakpoint" end,
    run = function() requests[#requests + 1] = "dap_run" end,
  }
end
package.loaded["which-key"] = { add = function() end }
local clients, starts, stopped = {}, 0, 0
vim.lsp.start = function(opts, start_opts)
  assert(opts.name == "gdshader-lsp" and start_opts.bufnr == shader)
  if #clients == 0 then
    starts = starts + 1
    clients[1] = {
      config = opts, server_capabilities = { documentFormattingProvider = true },
      stop = function() clients = {}; stopped = stopped + 1 end,
    }
    opts.on_init(clients[1])
  end
  return 42
end
vim.lsp.get_clients = function() return clients end

local godot = require("godot")
local function setup(features) godot.setup({ features = features }) end
local function mapped(lhs) return vim.fn.maparg(lhs, "n", false, true).buffer == 1 end
setup({ shader_lsp = false, bridge = false, dap = false })
assert(vim.bo[shader].filetype == "gdshader", "Recognize a shader include opened before plugin setup")
assert(mapped("<leader>Gef") and mapped("<leader>Gso"))
assert(not mapped("<leader>Grm") and not mapped("<leader>Gdm"))
assert(starts == 0 and not tool_calls.shader_lsp)
assert(require("godot.toolbar").render() == "")
require("godot.toolbar").click(1, 1, "l")
assert(#requests == 0)
vim.cmd.GodotRun("main")
require("godot.debug").control(root, "toggle_breakpoint")
assert(messages[#messages]:find("features.dap", 1, true) and dap_loaded == 0 and not tool_calls.dap)

local system = vim.system
local formatted
vim.system = function(cmd, opts, cb)
  formatted = cmd
  cb({ code = 0, stdout = opts.stdin })
end
vim.cmd.GodotFormat()
vim.system = system
assert(formatted[1] == paths.clang_format)

vim.cmd.GodotTree("res://main.tscn")
local tree = api.nvim_get_current_buf()
assert(vim.bo.filetype == "godot_scene_tree" and api.nvim_get_current_line():find("Offline root", 1, true))
assert(mapped("<CR>") and mapped("i") and not mapped("R") and #requests == 0)
pending.shader_lsp = true
setup({ shader_lsp = true, bridge = true, dap = true, formatting = false })
assert(starts == 0 and mapped("R"))
pending.shader_lsp = false
api.nvim_exec_autocmds("User", { pattern = "GodotToolsReady", data = { id = "shader_lsp", root = root } })
assert(mapped("R") and starts == 1 and clients[1].server_capabilities.documentFormattingProvider == false)
assert(require("godot.toolbar").render() ~= "")
require("godot.toolbar").click(1, 1, "l")
assert(requests[1] == "run_action" and dap_loaded == 0)
vim.cmd.GodotDebugAction("toggle_breakpoint")
assert(messages[#messages] == "Godot: Installing dap" and dap_loaded == 0)
pending.dap = false
vim.cmd.GodotDebugAction("toggle_breakpoint")
assert(dap_loaded == 1 and requests[2] == "breakpoint")
vim.cmd.GodotRun("main")
local dap = package.loaded.dap
assert(requests[3] == "dap_run" and dap.adapters["godot.nvim"] and dap.listeners.before.launch["godot.nvim"])

-- A project can already contain the addon while its editor is closed.
vim.fn.mkdir(root .. "/addons/nvim_bridge", "p")
vim.fn.writefile({}, root .. "/addons/nvim_bridge/plugin.cfg")
pending.scene_tree = true
vim.cmd.GodotTree("res://main.tscn")
assert(#requests == 3 and messages[#messages]:find("Installing scene_tree", 1, true))
connected = true
vim.cmd.GodotTree("res://main.tscn")
assert(requests[4] == "scene_tree" and api.nvim_get_current_line():find("Live root", 1, true))
pending.scene_tree, connected = false, false

setup({ bridge = false, dap = true, formatting = true })
assert(api.nvim_get_current_buf() == tree and not mapped("R") and mapped("i"))
assert(api.nvim_get_current_line():find("Offline root", 1, true))
assert(clients[1].server_capabilities.documentFormattingProvider == true)
setup({ scene_tree = false, bridge = false, shader_lsp = false, formatting = false })
assert(not api.nvim_buf_is_valid(tree) and api.nvim_get_current_buf() == shader and stopped == 1)
assert(not dap.adapters["godot.nvim"] and not dap.listeners.before.launch["godot.nvim"])
assert(not mapped("gd") and not mapped("<leader>Gef") and not mapped("<leader>Grm") and not mapped("<leader>Gso"))
assert(require("godot.toolbar").render() == "")
local before = tool_calls.clang_format
vim.cmd.GodotFormat()
assert(messages[#messages]:find("features.formatting", 1, true) and tool_calls.clang_format == before)

local get_parser = vim.treesitter.get_parser
vim.treesitter.get_parser = function() error("Scene parser used with features.scene_tree disabled") end
vim.cmd.edit(vim.fn.fnameescape(root .. "/main.tscn"))
vim.bo.filetype = "gdresource"
require("godot.editing").attach(0, root)
vim.treesitter.get_parser = get_parser
assert(not mapped("gd"))

-- Exercise the built-in menu after removing which-key.
package.loaded["which-key"] = nil
package.preload["which-key"] = function() error("unavailable") end
require("godot.menu").setup()
vim.cmd.GodotMenu()
local labels = table.concat(api.nvim_buf_get_lines(0, 0, -1, false), "\n")
assert(labels:find("Editing") and not labels:find("Scene Tree") and not labels:find("Debug") and not labels:find("Run"))
vim.fn.delete(root, "rf")
print("PASS independent features, offline scene tree, toolbar, DAP preparation and repeated setup")
