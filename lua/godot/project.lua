local M = {}
local uv = vim.uv
local win = vim.fn.has("win32") == 1

function M.normalize(path)
  return vim.fs.normalize(uv.fs_realpath(path) or path)
end

function M.key(path)
  local normalized = M.normalize(path)
  return win and normalized:lower() or normalized
end

function M.root(path)
  if not path or path == "" then return end
  local root = vim.fs.root(path, "project.godot")
  return root and M.normalize(root)
end

function M.directory(root)
  local dir = require("godot.config").options.state_dir .. "/" .. vim.fn.sha256(M.key(root))
  vim.fn.mkdir(dir, "p", 448)
  return dir
end

function M.read(path)
  local file = io.open(path, "rb")
  if not file then return end
  local content = file:read("*a")
  file:close()
  local ok, data = pcall(vim.json.decode, content)
  if ok and type(data) == "table" then return data end
end

function M.write(path, data)
  local temp = path .. "." .. uv.os_getpid() .. ".tmp"
  local f = assert(io.open(temp, "wb"))
  local wrote, why = f:write(vim.json.encode(data))
  f:close()
  assert(wrote, why)
  assert(uv.fs_rename(temp, path))
end

function M.alive(pid)
  return type(pid) == "number" and pid > 0 and uv.kill(pid, 0) ~= nil
end

function M.lock(root, name)
  local file = M.directory(root) .. "/" .. name .. ".lock"
  local fd = uv.fs_open(file, "wx", 384)
  if not fd then
    local s = M.read(file)
    local stat = uv.fs_stat(file)
    if (s and not M.alive(s.pid)) or (not s and stat and os.time() - stat.mtime.sec > 5) then
      uv.fs_unlink(file)
    end
    return
  end
  uv.fs_write(fd, vim.json.encode({ pid = uv.os_getpid() }), 0)
  uv.fs_close(fd)
  return function() uv.fs_unlink(file) end
end

-- Leases are per Neovim process. The external-editor helper uses the same
-- records to route a file to an instance which already has this project open.
local tracked = {}
function M.track(root)
  local key = M.key(root)
  if tracked[key] then return end
  local address = vim.v.servername
  if address == "" then address = vim.fn.serverstart() end
  local pid = uv.os_getpid()
  local path = M.directory(root) .. "/client-" .. pid .. ".json"
  M.write(path, { pid = pid, server = address, root = root })
  tracked[key] = path
end

function M.untrack(root)
  local key = M.key(root)
  if tracked[key] then
    uv.fs_unlink(tracked[key])
    tracked[key] = nil
  end
end

function M.clients(root)
  local dir = M.directory(root)
  local clients = {}
  for name in vim.fs.dir(dir) do
    if name:match("^client%-%d+%.json$") then
      local path = dir .. "/" .. name
      local client = M.read(path)
      if client and M.alive(client.pid) and type(client.server) == "string" then
        table.insert(clients, client)
      elseif client then
        uv.fs_unlink(path)
      end
    end
  end
  return clients
end
return M

