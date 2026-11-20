-- An editor opened from Explorer can supply LSP and DAP before the addon is
-- installed. Windows does not publish its project directory alongside the
-- socket; match the editor command line and verify the actual listener PID.
local project = require("godot.project")
local M = {}
local function argv(command)
  local result, argument, quoted = {}, "", false
  for c in (command .. " "):gmatch(".") do
    if c == '"' then
      quoted = not quoted
    elseif c:match("%s") and not quoted then
      if argument ~= "" then result[#result + 1] = argument; argument = "" end
    else
      argument = argument .. c
    end
  end
  return result
end

local function describe(root, process, advertised)
  if type(process.command) ~= "string" or type(process.exe) ~= "string" then return end
  local args = argv(process.command)
  local editor, dir, headless, lsp, dap = false, nil, false, 6005, 6006
  for i = 2, #args do
    local item = args[i]
    if item == "--" or item == "++" then break end
    if item == "--editor" or item == "-e" then editor = true
    elseif item == "--headless" then headless = true
    elseif item == "--path" then dir = args[i + 1]
    elseif item == "--lsp-port" then lsp = tonumber(args[i + 1])
    elseif item == "--dap-port" then dap = tonumber(args[i + 1])
    elseif item:lower():match("[/\\]project%.godot$") then
      editor, dir = true, vim.fs.dirname(vim.fs.normalize(item))
    end
  end
  -- A relative --path is relative to the other process's cwd, not ours.
  if advertised and process.pid == advertised.pid and not dir then
    -- Project-manager launches do not always include --path. The live add-on
    -- record identifies the editor, and Windows supplies the actual binary.
    return vim.tbl_extend("force", advertised, { executable = process.exe })
  end
  if not editor or not dir then return end
  local absolute = dir:match("^%a:[/\\]") or dir:match("^[/\\][/\\]")
  if not absolute or project.key(dir) ~= project.key(root) then return end
  return { root = root, pid = process.pid, executable = process.exe, version = process.version,
    mode = headless and "headless" or "editor", lsp_port = lsp, dap_port = dap }
end

function M.find(root, callback, advertised)
  if vim.fn.has("win32") ~= 1 then return callback({}) end
  local script = [[
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$found = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'Godot%.exe'" | ForEach-Object {
  if ($_.ExecutablePath -and $_.CommandLine) {
    $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($_.ExecutablePath)
    if ($info.ProductName -eq 'Godot Engine') {
      @{pid=$_.ProcessId;exe=$_.ExecutablePath;command=$_.CommandLine;version=$info.ProductVersion}
    }
  }
})
ConvertTo-Json -InputObject $found -Compress
]]
  local shell = vim.fn.exepath("pwsh.exe")
  if shell == "" then shell = "powershell.exe" end
  vim.system({ shell, "-NoProfile", "-NonInteractive", "-Command", script },
    { text = true, timeout = 15000 }, vim.schedule_wrap(function(res)
      local found = {}
      local ok, list = pcall(vim.json.decode, res.stdout or "")
      if res.code == 0 and ok and type(list) == "table" then
        for _, p in ipairs(list) do
          local s = describe(root, p, advertised)
          if s then found[#found + 1] = s end
        end
      end
      callback(found)
    end))
end
return M

