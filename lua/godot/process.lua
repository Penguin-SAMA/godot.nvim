local project = require("godot.project")
local M = {}

-- Windows can recycle a PID while an editor record is still on disk.
-- Query the process directly: this also runs while polling during imports.
if jit and jit.os == "Windows" then
  local ffi = require("ffi")
  if not pcall(ffi.typeof, "godot_filetime") then
    ffi.cdef[[
      typedef struct { uint32_t low, high; } godot_filetime;
      void * __stdcall OpenProcess(unsigned long access, int inherit, unsigned long pid);
      int __stdcall GetProcessTimes(void *process, godot_filetime *creation, godot_filetime *exit_time,
                                    godot_filetime *kernel, godot_filetime *user);
      int __stdcall CloseHandle(void *handle);
    ]]
  end
  local kernel = ffi.load("kernel32")
  function M.started_us(pid)
    local handle = kernel.OpenProcess(0x1000, 0, pid) -- PROCESS_QUERY_LIMITED_INFORMATION
    if handle == nil then return end
    local times = ffi.new("godot_filetime[4]")
    local ok = kernel.GetProcessTimes(handle, times, times + 1, times + 2, times + 3)
    kernel.CloseHandle(handle)
    if ok ~= 0 then
      local ticks = ffi.new("uint64_t", times[0].high) * 4294967296 + times[0].low
      -- FILETIME counts 100 ns intervals since 1601. Unix microseconds fit exactly in Lua numbers.
      return tonumber((ticks - 116444736000000000) / 10)
    end
  end
else
  function M.started_us() return nil end
end

function M.matches(record, file)
  if not project.alive(record.pid) then return false end
  local started = M.started_us(record.pid)
  if started and record.started_us then return record.started_us == started end
  -- Older plugin versions and the editor addon publish their record after the process starts.
  if started and file then
    local stat = vim.uv.fs_stat(file)
    if not stat or started > stat.mtime.sec * 1000000 + math.floor(stat.mtime.nsec / 1000) then return false end
  end
  -- Copying a legacy record can change its mtime. If its launch time also differs,
  -- check the executable before accepting the PID.
  if vim.fn.has("win32") == 1 and type(record.executable) == "string"
      and (not started or started >= ((record.created or 0) + 1) * 1000000) then
    local ok, info = pcall(vim.api.nvim_get_proc, record.pid)
    return ok and type(info) == "table" and type(info.name) == "string"
      and info.name:lower() == vim.fs.basename(record.executable):lower()
  end
  return true
end

return M
