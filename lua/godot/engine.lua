local M = {}
local project = require("godot.project")
local selected, pending = {}, {}

local function lines(path)
  local ok, result = pcall(vim.fn.readfile, path)
  return ok and result or {}
end

function M.requirement(root)
  for _, line in ipairs(lines(root .. "/.godothub/.godotrc")) do
    local version, flavor = vim.trim(line):match("^(%d[%w.%-]*)%s*(%S*)$")
    if version then return { pin = version, flavor = flavor } end
  end
  local application = false
  for _, line in ipairs(lines(root .. "/project.godot")) do
    local section = line:match("^%s*%[([^%]]+)%]")
    if section then application = section == "application" end
    if application and line:match("^%s*config/features%s*=") then
      return { series = line:match('"(%d+%.%d+)"'), flavor = line:find('"C#"', 1, true) and "dotnet" or nil }
    end
  end
  return {}
end

local function matches(version, want)
  local number, tag = version:match("^(%d+%.%d+[%.%d]*)%.([%a]+%d*)")
  if not number then return false end
  if want.pin then
    local pin, release = want.pin:match("^([%d.]+)%-?(.*)$")
    if number ~= pin or tag ~= (release ~= "" and release or "stable") then return false end
  elseif want.series and number:match("^%d+%.%d+") ~= want.series then
    return false
  end
  local mono = version:find(".mono.", 1, true) ~= nil
  return not ((want.flavor == "no-dotnet" and mono) or (want.flavor == "dotnet" and not mono))
end

local function candidates(paths)
  local found, seen = {}, {}
  local function add(path)
    path = project.normalize(path)
    local editor, count = path:gsub("_[Cc][Oo][Nn][Ss][Oo][Ll][Ee]%.[Ee][Xx][Ee]$", ".exe")
    if count > 0 and vim.uv.fs_stat(editor) then path = editor end
    local key = project.key(path)
    if not seen[key] and vim.fn.executable(path) == 1 then
      seen[key] = true
      found[#found + 1] = path
    end
  end
  local windows = vim.fn.has("win32") == 1
  for _, entry in ipairs(paths) do
    local path = vim.fs.normalize(entry)
    if vim.fn.isdirectory(path) == 1 then
      for rel, kind in vim.fs.dir(path, { depth = 4 }) do
        local name = vim.fs.basename(rel):lower()
        if kind ~= "directory" and (not windows or vim.endswith(name, ".exe")) then
          name = name:gsub("%.exe$", "")
          if name == "godot" or name:match("^godot[_%-]v?%d") or name:match("^godot%d") then
            add(vim.fs.joinpath(path, rel))
          end
        end
      end
    else
      local exe = vim.fn.exepath(path)
      if exe ~= "" then add(exe) end
    end
  end
  return found
end

local function inspect(paths, want, callback)
  local found = {}
  local function probe(i)
    local path = paths[i]
    if not path then return callback(found) end
    local ok = pcall(vim.system, { path, "--version" }, { text = true, timeout = 4000 }, vim.schedule_wrap(function(res)
      local version = vim.trim(res.stdout or "")
      if res.code == 0 and matches(version, want) then found[#found + 1] = { path = path, version = version } end
      probe(i + 1)
    end))
    if not ok then vim.schedule(function() probe(i + 1) end) end
  end
  probe(1)
end

-- Choices belong to one project, version requirement and configuration in this Neovim.
function M.resolve(root, callback, cached_only)
  local opts = require("godot.config").options
  local paths = opts.godot_path
  if type(paths) == "string" then paths = paths ~= "" and { paths } or {} end
  local legacy = (not paths or #paths == 0) and opts.executable
  if legacy then paths = { legacy } end
  paths = paths or {}
  local want = root and M.requirement(root) or {}
  local key = vim.json.encode({ root and project.key(root) or "", want.pin or "", want.series or "", want.flavor or "", paths })
  local chosen = selected[key]
  if chosen and vim.fn.executable(chosen) == 1 then return callback(nil, chosen) end
  if cached_only then
    -- Offline scene hover may read an existing API cache without probing Godot.
    local exe = legacy and vim.fn.exepath(legacy)
    return callback(nil, exe and exe ~= "" and exe or nil)
  end
  if pending[key] then
    table.insert(pending[key], callback)
    return
  end
  pending[key] = { callback }
  local function finish(err, path)
    selected[key] = path
    local waiters = pending[key]
    pending[key] = nil
    for _, cb in ipairs(waiters) do cb(err, path) end
  end
  local label = ("Godot %s for %s"):format(want.pin or want.series or "editor", root and vim.fs.basename(root) or "documentation")
  local function select_engine(items)
    if #items == 1 then return finish(nil, items[1].path) end
    vim.ui.select(items, {
      prompt = label,
      format_item = function(item) return item.version .. "  " .. item.path end,
    }, function(item)
      if item then finish(nil, item.path) else finish("Godot selection cancelled") end
    end)
  end
  local function input()
    vim.ui.input({ prompt = label .. " (executable or directory): ", completion = "file" }, function(value)
      if not value or vim.trim(value) == "" then return finish("Godot selection cancelled") end
      local path = vim.trim(value):gsub('^"(.*)"$', "%1")
      inspect(candidates({ path }), want, function(items)
        if #items == 0 then return finish("No matching " .. label .. " at " .. value .. ". Check godot_path and retry.") end
        select_engine(items)
      end)
    end)
  end
  inspect(candidates(paths), want, function(items)
    if #items > 0 then select_engine(items) else input() end
  end)
end

return M
