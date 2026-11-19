-- Godot invokes this with nvim --headless -u NONE -i NONE -l <script> ...
local base = vim.fs.dirname(vim.fs.dirname(vim.fs.abspath(arg[0])))
vim.opt.runtimepath:prepend(base)
local state_dir, file = arg[1], arg[2]
assert(state_dir and file, "Expected state directory, file, line and column")
require("godot.config").setup({ state_dir = state_dir })
local project = require("godot.project")
file = project.normalize(file)
local line = math.max(1, math.floor(tonumber(arg[3]) or 1))
local col = math.max(1, math.floor(tonumber(arg[4]) or 1))
local root = project.root(file)
for _, client in ipairs(root and project.clients(root) or {}) do
  local transport = client.server:match(":%d+$") and "tcp" or "pipe"
  local ok, channel = pcall(vim.fn.sockconnect, transport, client.server, { rpc = true })
  if ok and channel > 0 then
    local called, opened = pcall(vim.rpcrequest, channel, "nvim_exec_lua",
      "local pid, path, row, col = ...; return vim.uv.os_getpid() == pid and require('godot.external').open_file(path, row, col)",
      { client.pid, file, line, col })
    vim.fn.chanclose(channel)
    if called and opened then
      if type(opened) == "table" and opened.tui_pid then
        -- Godot started this process from the foreground editor. Windows
        -- grants that caller the right to activate another application's UI.
        pcall(function() require("godot.windows_terminal").focus(opened.tui_pid) end)
      end
      return
    end
  end
end

-- The callback runs without a terminal. Start a visible Neovim session on
-- cold open; pass the filename as data even if it contains shell syntax.
local position = ("+call setcursorcharpos(%d,%d)"):format(line, col)
if vim.fn.has("win32") == 1 then
  local ps = [[
$ErrorActionPreference = 'Stop'
$arguments = '"' + $env:GODOT_NVIM_POSITION + '" -- "' + $env:GODOT_NVIM_FILE + '"'
Start-Process -FilePath $env:GODOT_NVIM_PROGRAM -ArgumentList $arguments
]]
  local result = vim.system({ "powershell.exe", "-NoProfile", "-NonInteractive", "-Command", ps }, {
    env = { GODOT_NVIM_PROGRAM = vim.v.progpath, GODOT_NVIM_POSITION = position, GODOT_NVIM_FILE = file },
  }):wait()
  assert(result.code == 0, result.stderr)
else
  local terminal = vim.fn.exepath("x-terminal-emulator")
  assert(terminal ~= "", "Start Neovim in this project to receive Godot callbacks")
  vim.fn.jobstart({ terminal, "-e", vim.v.progpath, position, "--", file }, { detach = true })
end

