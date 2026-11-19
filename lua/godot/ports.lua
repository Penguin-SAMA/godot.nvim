local M = {}
local uv = vim.uv
function M.allocate(count)
  local sockets, ports = {}, {}
  local ok, err = pcall(function()
    for _ = 1, count do
      local socket = assert(uv.new_tcp())
      table.insert(sockets, socket)
      assert(socket:bind("127.0.0.1", 0))
      assert(socket:listen(1, function() end))
      table.insert(ports, socket:getsockname().port)
    end
  end)
  for _, socket in ipairs(sockets) do socket:close() end
  assert(ok, err)
  return ports
end

-- Comparing PIDs is important: connecting to a default port establishes TCP
-- reachability but says nothing about which project's editor is listening.
local function parse(res, windows)
  local map = {}
  if res.code ~= 0 then return map end
  for line in (res.stdout or ""):gmatch("[^\r\n]+") do
    local port, pid
    if windows then
      -- The wildcard foreign endpoint identifies a listener in all locales.
      port, pid = line:match("^%s*TCP%s+[%d%.]+:(%d+)%s+0%.0%.0%.0:0%s+%S+%s+(%d+)")
    else
      pid, port = line:match("^%S+%s+(%d+).-%sTCP%s+.-:(%d+)%s+%(LISTEN%)")
    end
    if port then map[tonumber(port)] = tonumber(pid) end
  end
  return map
end

function M.owners(callback)
  local windows = vim.fn.has("win32") == 1
  local args = windows and { "netstat.exe", "-ano", "-p", "TCP" }
    or { "lsof", "-nP", "-iTCP", "-sTCP:LISTEN" }
  if callback then
    return vim.system(args, { text = true, timeout = 3500 }, vim.schedule_wrap(function(res)
      callback(parse(res, windows))
    end))
  end
  return parse(vim.system(args, { text = true }):wait(3500), windows)
end
return M

