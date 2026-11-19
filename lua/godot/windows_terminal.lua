-- Called only by the short-lived Windows external-editor launcher.
local ffi = require("ffi")
ffi.cdef([[
  int __stdcall FreeConsole(void);
  int __stdcall AttachConsole(unsigned long);
  intptr_t __stdcall GetConsoleWindow(void);
  unsigned long __stdcall GetConsoleTitleW(uint16_t *, unsigned long);
  unsigned long __stdcall GetConsoleTitleA(char *, unsigned long);
  int __stdcall SetConsoleTitleW(const uint16_t *);
  int __stdcall SetConsoleTitleA(const char *);
  intptr_t __stdcall CreateMutexA(void *, int, const char *);
  unsigned long __stdcall WaitForSingleObject(intptr_t, unsigned long);
  int __stdcall ReleaseMutex(intptr_t);
  int __stdcall CloseHandle(intptr_t);
  intptr_t __stdcall GetAncestor(intptr_t, unsigned int);
  int __stdcall GetWindowTextA(intptr_t, char *, int);
  int __stdcall GetClassNameA(intptr_t, char *, int);
  intptr_t __stdcall GetForegroundWindow(void);
  int __stdcall IsIconic(intptr_t);
  int __stdcall IsWindowVisible(intptr_t);
  int __stdcall ShowWindow(intptr_t, int);
  int __stdcall SetForegroundWindow(intptr_t);
]])
local kernel, user = ffi.load("kernel32"), ffi.load("user32")
local M = {}

-- WT exposes tab selection through UI Automation. Search only inside the
-- target console's owning HWND. Neither user tab names nor indices are unique
-- or stable, so briefly mark this console and require an exact match.
local select_tab = [[
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
$root = [Windows.Automation.AutomationElement]::FromHandle([IntPtr]([long]$env:GODOT_NVIM_HWND))
$name = [Windows.Automation.PropertyCondition]::new(
    [Windows.Automation.AutomationElement]::NameProperty, $env:GODOT_NVIM_TAB)
$type = [Windows.Automation.PropertyCondition]::new(
    [Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::TabItem)
$match = [Windows.Automation.AndCondition]::new($type, $name)
$tab = $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $match)
if (!$tab) { exit 1 }
$selection = $tab.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern)
if (!$selection.Current.IsSelected) { $selection.Select() }
for ($i = 0; !$selection.Current.IsSelected -and $i -lt 20; $i++) { Start-Sleep -Milliseconds 15 }
if (!$selection.Current.IsSelected) { exit 1 }
# Selecting a TabItem can leave keyboard focus in the tab strip. The
# terminal's accessibility peer exposes its text surface as TermControl.
$surface = [Windows.Automation.PropertyCondition]::new(
    [Windows.Automation.AutomationElement]::ClassNameProperty, 'TermControl')
$visible = [Windows.Automation.PropertyCondition]::new(
    [Windows.Automation.AutomationElement]::IsOffscreenProperty, $false)
$panes = $root.FindAll([Windows.Automation.TreeScope]::Descendants,
    [Windows.Automation.AndCondition]::new($surface, $visible))
if ($panes.Count -eq 1 -and $panes[0].Current.IsKeyboardFocusable) { $panes[0].SetFocus() }
]]

local function select_console_tab(window, console)
  -- Two rapid callbacks for one tab must restore the same original title.
  local lock = kernel.CreateMutexA(nil, 0, "Local\\godot-nvim-tab-" .. tonumber(console))
  if lock == 0 then return false end
  local wait = kernel.WaitForSingleObject(lock, 5000)
  if wait ~= 0 and wait ~= 128 then -- WAIT_OBJECT_0 or WAIT_ABANDONED
    kernel.CloseHandle(lock)
    return false
  end
  local original = ffi.new("uint16_t[32768]")
  kernel.GetConsoleTitleW(original, 32768)
  local marker = "godot.nvim-" .. vim.uv.os_getpid() .. "-" .. vim.uv.hrtime()
  local selected = false
  if kernel.SetConsoleTitleA(marker) ~= 0 then
    local ok, result = pcall(function()
      -- WT mirrors the active tab into its window caption. When it shows
      -- our unique marker, the correct tab is already active.
      local caption = ffi.new("char[1024]")
      if vim.wait(140, function()
        user.GetWindowTextA(window, caption, 1024)
        return ffi.string(caption):find(marker, 1, true) ~= nil
      end, 10) then return true end
      local process = vim.system({ "powershell.exe", "-NoProfile", "-NonInteractive", "-Command", select_tab }, {
        env = { GODOT_NVIM_HWND = tostring(tonumber(window)), GODOT_NVIM_TAB = marker },
      }):wait(5000)
      return process.code == 0
    end)
    selected = ok and result
    local current = ffi.new("char[256]")
    kernel.GetConsoleTitleA(current, 256)
    if ffi.string(current) == marker then kernel.SetConsoleTitleW(original) end
  end
  kernel.ReleaseMutex(lock)
  kernel.CloseHandle(lock)
  return selected
end

local function focus_console()
  local console = kernel.GetConsoleWindow()
  local window = user.GetAncestor(console, 3) -- GA_ROOTOWNER
  local previous = user.GetForegroundWindow()
  local class = ffi.new("char[256]")
  user.GetClassNameA(window, class, 256)
  if ffi.string(class) == "CASCADIA_HOSTING_WINDOW_CLASS" then
    if not select_console_tab(window, console) then return end
  elseif window ~= console or ffi.string(class) ~= "ConsoleWindowClass" or user.IsWindowVisible(window) == 0 then
    return
  end
  -- A callback can take a moment to find an inactive tab. Respect a newer
  -- foreground choice made while Windows Terminal was resolving it.
  local foreground = user.GetForegroundWindow()
  if user.GetAncestor(foreground, 3) == window then return end
  if foreground ~= previous then return end
  if user.IsIconic(window) ~= 0 then user.ShowWindow(window, 9) end -- SW_RESTORE
  user.SetForegroundWindow(window)
end

function M.focus(pid)
  kernel.FreeConsole()
  if kernel.AttachConsole(pid) == 0 then return end
  pcall(focus_console)
  -- Neovim restores the launcher's own console title when it exits.
  -- Detach first so that cleanup cannot rename the destination tab.
  kernel.FreeConsole()
end

return M
