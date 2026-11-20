-- Run with nvim --headless -u NONE -l tests/engine.lua from the plugin root.
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.env.GODOT_NVIM_EXECUTABLE = nil
local config = require("godot.config")
config.setup({})
assert(not config.options.executable, "An unconfigured project must prompt before launching Godot")

local engine = require("godot.engine")
local tmp = vim.fs.normalize(vim.fn.tempname())
vim.fn.mkdir(tmp, "p")
tmp = require("godot.project").normalize(tmp)
local versions = {}
local suffix = vim.fn.has("win32") == 1 and ".exe" or ""
local function binary(dir, version)
  vim.fn.mkdir(tmp .. "/" .. dir, "p")
  local path = tmp .. "/" .. dir .. "/godot" .. suffix
  vim.fn.writefile({}, path)
  vim.uv.fs_chmod(path, 493)
  versions[path] = version
  return path
end
local old = binary("engines/old", "4.7.2.stable.official.hash")
local beta = binary("other/beta", "4.8.beta3.official.hash")
local mono = binary("other/mono", "4.8.beta3.mono.official.hash")
local stable = binary("other/stable", "4.8.stable.official.hash")
local root = tmp .. "/My Game"
vim.fn.mkdir(root .. "/.godothub", "p")
vim.fn.writefile({ "[application]", 'config/features=PackedStringArray("4.8")' }, root .. "/project.godot")
local pin = root .. "/.godothub/.godotrc"
local function choose()
  local done, err, exe
  engine.resolve(root, function(e, path) done, err, exe = true, e, path end)
  assert(vim.wait(3000, function() return done end))
  return exe, err
end
vim.system = function(args, _, cb)
  assert(args[2] == "--version" and versions[args[1]], vim.inspect(args))
  vim.schedule(function() cb({ code = 0, stdout = versions[args[1]] .. "\n" }) end)
end
vim.ui.input = function() error("unexpected path prompt") end
vim.ui.select = function() error("unexpected version picker") end
config.setup({ godot_path = { tmp .. "/engines", tmp .. "/other" }, executable = old })
vim.fn.writefile({ "# version", "4.8-beta3 no-dotnet" }, pin)
assert(choose() == beta)
vim.fn.writefile({ "4.8-beta3 dotnet" }, pin)
assert(choose() == mono)
vim.fn.delete(pin)
vim.ui.select = function(items, _, cb)
  assert(#items == 3)
  for _, item in ipairs(items) do if item.path == stable then return cb(item) end end
end
assert(choose() == stable)
config.setup({})
local reply, count = nil, 0
vim.ui.input = function(_, cb) count = count + 1; reply = cb end
local calls = 0
local function cancelled(err, path) assert(err and not path); calls = calls + 1 end
engine.resolve(root, cancelled)
engine.resolve(root, cancelled)
assert(vim.wait(3000, function() return reply ~= nil end))
assert(count == 1)
reply(nil)
assert(calls == 2)
vim.ui.input = function(_, cb) cb(old) end
local wrong, reason = choose()
assert(not wrong and reason and reason:find("No matching", 1, true))
vim.ui.input = function(_, cb) cb(beta) end
assert(choose() == beta)
vim.ui.input = function() error("project choice was forgotten") end
assert(choose() == beta)
-- A live advertised editor takes precedence even when its version is not
-- installed in the configured directories. No scan or path prompt is needed.
config.setup({ godot_path = tmp .. "/absent", state_dir = tmp .. "/state" })
vim.fn.mkdir(root .. "/.godot", "p")
local project = require("godot.project")
local session = require("godot.session")
local pid = vim.uv.os_getpid()
project.write(root .. "/.godot/godot-nvim-editor.json", {
  root = root, pid = pid, mode = "editor", lsp_port = 6005,
})
require("godot.ports").owners = function(cb) cb({ [6005] = pid }) end
local reused
session.ensure(root, "editor", function(err, instance)
  assert(not err, err)
  reused = instance
end)
assert(reused and reused.pid == pid)
project.untrack(root)
vim.fn.delete(tmp, "rf")
print("PASS project engine matching, choice, cancellation and retry")
