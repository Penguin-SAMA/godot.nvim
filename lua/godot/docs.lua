local M = {}
local caches = {}
local function index(entries)
  local result = {}
  for _, item in ipairs(entries or {}) do
    result[item.name] = item
  end
  return result
end

local function read(path)
  local f = io.open(path, "rb")
  if not f then return end
  local raw = f:read("*a")
  f:close()
  local ok, data = pcall(vim.json.decode, raw)
  if not ok or type(data) ~= "table" or not data.classes or not data.header then return end
  local api = { classes = {}, utility = index(data.utility_functions), singletons = index(data.singletons) }
  for _, list in ipairs({ data.classes, data.builtin_classes or {} }) do
    for _, class in ipairs(list) do
      class.builtin = list == data.builtin_classes
      class.symbols = {}
      for _, pair in ipairs({
        { "methods", "method" }, { "properties", "property" }, { "members", "property" },
        { "signals", "event" }, { "constants", "enumMember" }, { "enums", "enum" },
      }) do
        for _, member in ipairs(class[pair[1]] or {}) do
          member.kind = pair[2]
          class.symbols[member.name] = member
          if member.kind == "enum" then
            for _, value in ipairs(member.values or {}) do
              value.kind = "enumMember"
              class.symbols[value.name] = value
            end
          end
        end
      end
      api.classes[class.name] = class
    end
  end
  return api
end

-- Each executable revision has its own cache. The dump's cwd is private, since
-- Godot always writes the same filename and multiple editors may start together.
local function load_executable(exe, callback, cached_only)
  exe = vim.uv.fs_realpath(exe) or exe
  local stat = vim.uv.fs_stat(exe)
  if not stat then return callback(nil, not cached_only and ("Godot executable unavailable: " .. exe) or nil) end
  local key = vim.fn.sha256(table.concat({ exe, stat.size, stat.mtime.sec, stat.mtime.nsec }, ":"))
  local cache = caches[key]
  if cache then
    if cache.api then callback(cache.api) else table.insert(cache.waiters, callback) end
    return
  end
  cache = { waiters = { callback } }
  caches[key] = cache
  local function finish(api, err)
    cache.api = api
    if not api then caches[key] = nil end
    local waiters = cache.waiters
    cache.waiters = nil
    for _, cb in ipairs(waiters) do cb(api, err) end
  end
  local dir = vim.fs.joinpath(vim.fn.stdpath("cache"), "godot.nvim", "docs")
  vim.fn.mkdir(dir, "p")
  local target = vim.fs.joinpath(dir, key .. ".json")
  local cached = read(target)
  if cached then return finish(cached) end
  if cached_only then return finish(nil) end
  local work, temp_err = vim.uv.fs_mkdtemp(vim.fs.joinpath(dir, "dump-XXXXXX"))
  if not work then return finish(nil, temp_err) end
  local ok, launch_err = pcall(vim.system, { exe, "--headless", "--dump-extension-api-with-docs" }, {
    cwd = work, text = true, timeout = 45000,
  }, vim.schedule_wrap(function(result)
    local path = vim.fs.joinpath(work, "extension_api.json")
    local api = result.code == 0 and read(path) or nil
    if api then vim.uv.fs_rename(path, target) end
    vim.fn.delete(work, "rf")
    finish(api, not api and ("Godot API dump failed: " .. vim.trim(result.stderr or "")) or nil)
  end))
  if not ok then
    vim.fn.delete(work, "rf")
    finish(nil, tostring(launch_err))
  end
end

function M.load(callback, cached_only, root)
  root = root or require("godot").health_root()
  require("godot.session").engine(root, function(err, exe)
    if not exe then return callback(nil, not cached_only and err or nil) end
    load_executable(exe, callback, cached_only)
  end, cached_only)
end

function M.member(api, class_name, symbol)
  local class = api.classes[class_name]
  while class do
    if class.symbols[symbol] then return class.symbols[symbol], class.name end
    class = api.classes[class.inherits]
  end
end

local function markdown(text)
  return vim.trim((text or "")
    :gsub("%[codeblock%]", "\n```gdscript\n"):gsub("%[/codeblock%]", "\n```\n")
    :gsub("%[gdscript%]", "\n```gdscript\n"):gsub("%[/gdscript%]", "\n```\n")
    :gsub("%[csharp%]", "\n```csharp\n"):gsub("%[/csharp%]", "\n```\n")
    :gsub("%[/?codeblocks%]", ""):gsub("%[/?code%]", "`")
    :gsub("%[/?b%]", "**"):gsub("%[/?i%]", "*"):gsub("%[br%]", "\n")
    :gsub("%[url=(.-)%](.-)%[/url%]", "[%2](%1)")
    :gsub("%[%w+ ([%w_%.@]+)%]", "`%1`"):gsub("%[([%w_%.@]+)%]", "`%1`"))
end

function M.lookup(api, query, base)
  local owner, name = query:match("^([%w_@]+)%.([%w_]+)$")
  local class = api.classes[query]
  if class then
    local heading = "**" .. class.name .. "**" .. (class.inherits and (" extends `" .. class.inherits .. "`") or "")
    return heading .. "\n\n" .. markdown(class.brief_description) .. "\n\n" .. markdown(class.description)
  end
  local member, defined = M.member(api, owner or base, name or query)
  if not member and not owner then member = api.utility[query] end
  if member then
    local signature = (defined and defined .. "." or "") .. member.name
    if member.kind == "method" or member.kind == "event" or api.utility[query] == member then
      local args = {}
      for _, arg in ipairs(member.arguments or {}) do table.insert(args, arg.name .. ": " .. arg.type) end
      signature = signature .. "(" .. table.concat(args, ", ") .. ")"
    end
    local ty = member.return_type or (member.return_value and member.return_value.type) or member.type
    return "`" .. signature .. (ty and (" : " .. ty) or "") .. "`\n\n" .. markdown(member.description)
  end
end

function M.preview(text)
  vim.lsp.util.open_floating_preview(vim.split(vim.trim(text), "\n", { plain = true }), "markdown", {
    focus_id = "godot-doc", border = "rounded", max_width = 88, max_height = 25,
  })
end

function M.native(symbol)
  return "`" .. symbol.detail .. "`\n\n" .. markdown(symbol.documentation)
end

return M
