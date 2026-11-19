local project = require("godot.project")
local M = {}
local snapshots = {}

local function value(node, buf)
  if not node then return end
  local raw = vim.treesitter.get_node_text(node, buf)
  if node:type() == "string" then
    local ok, decoded = pcall(vim.json.decode, raw)
    return ok and decoded or raw:sub(2, -2)
  end
  return raw
end

local function reference(node, buf)
  if not node or node:type() ~= "constructor" then return end
  local args = node:named_child(1)
  return value(node:named_child(0), buf), args and value(args:named_child(0), buf)
end

-- The resource grammar and extraction rules are shared by open buffers and
-- files read directly from disk. Neither indexing nor resolving an instance
-- needs to create a buffer or run a FileType autocmd.
local function collect(tree, buf, async)
  local data = { ext = {}, sub = {}, nodes = {}, scripts = {} }
  local deadline = async and vim.uv.hrtime() + 4e6
  for section in tree:root():iter_children() do
    if deadline and vim.uv.hrtime() >= deadline then
      coroutine.yield()
      deadline = vim.uv.hrtime() + 4e6
    end
    if section:type() == "section" and section:named_child(0) then
      local kind = value(section:named_child(0), buf)
      local attrs, script, instance, unique = {}, nil, nil, false
      for child in section:iter_children() do
        if child:type() == "attribute" then
          local key = value(child:named_child(0), buf)
          if key == "instance" then
            local ctor, id = reference(child:named_child(1), buf)
            if ctor == "ExtResource" and data.ext[id] then instance = data.ext[id].path end
          elseif key then
            attrs[key] = value(child:named_child(1), buf)
          end
        elseif child:type() == "property" and kind == "node" then
          local key = value(child:named_child(0), buf)
          if key == "script" then
            local ctor, id = reference(child:named_child(1), buf)
            local resource = ctor == "ExtResource" and data.ext[id]
            script = resource and resource.path or nil
          elseif key == "unique_name_in_owner" then
            unique = value(child:named_child(1), buf) == "true"
          end
        end
      end
      if kind == "ext_resource" and attrs.id and attrs.path then
        data.ext[attrs.id] = { type = attrs.type, path = attrs.path, row = section:range() }
      elseif kind == "sub_resource" and attrs.id then
        data.sub[attrs.id] = { type = attrs.type, row = section:range() }
      elseif kind == "node" and attrs.name then
        if script then data.scripts[script] = true end
        local path = "."
        if attrs.parent then
          path = attrs.parent == "." and attrs.name or (attrs.parent .. "/" .. attrs.name)
        end
        table.insert(data.nodes, {
          name = attrs.name, type = attrs.type, path = path, parent = attrs.parent,
          script = script, unique = unique, instance = instance,
        })
      end
    end
  end
  return data
end

function M.read(buf)
  if buf == 0 then buf = vim.api.nvim_get_current_buf() end
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  if snapshots[buf] and snapshots[buf].tick == tick then return snapshots[buf] end
  local parser, err = vim.treesitter.get_parser(buf, "godot_resource", { error = false })
  if not parser then return nil, err end
  local tree = parser:parse()[1]
  if not tree then return nil, "Scene parse pending" end
  local data = collect(tree, buf)
  data.tick = tick
  if not snapshots[buf] then
    vim.api.nvim_buf_attach(buf, false, { on_detach = function() snapshots[buf] = nil end })
  end
  snapshots[buf] = data
  return data
end

function M.parse_text(source, callback)
  local ok, parser = pcall(vim.treesitter.get_string_parser, source, "godot_resource")
  if not ok then
    if callback then return callback(parser) end
    return nil, parser
  end
  if callback then
    return parser:parse(nil, function(err, trees)
      if err then return callback(err) end
      local extract = coroutine.wrap(function() return collect(trees[1], source, true) end)
      local function step()
        local data = extract()
        if data then return callback(nil, data) end
        vim.defer_fn(step, 1)
      end
      step()
    end)
  end
  return collect(parser:parse()[1], source)
end

-- Paths in a text scene can be res:// URIs or relative to the scene itself.
function M.resource_file(root, scene, path)
  if vim.startswith(path, "res://") then return vim.fs.joinpath(root, path:sub(7)) end
  if not path:find("://", 1, true) and vim.fn.isabsolutepath(path) == 0 then
    return vim.fs.joinpath(vim.fs.dirname(scene), path)
  end
end

local function read_file(path)
  local buf = vim.fn.bufnr(path)
  local loaded = buf ~= -1 and vim.api.nvim_buf_is_loaded(buf)
  if loaded and vim.bo[buf].modified then return M.read(buf) end
  local ok, source = pcall(vim.fn.readblob, path)
  if not ok then
    if loaded then return M.read(buf) end
    return nil, source
  end
  return M.parse_text(source)
end

local function resolved_nodes(data, root, path)
  if not root then return data.nodes end
  local prefix = project.key(root):gsub("/$", "") .. "/"
  local types = {}
  local function node_type(node, scene)
    if node.type or not node.instance then return node.type end
    local file = M.resource_file(root, scene, node.instance)
    if not file or not file:lower():match("%.tscn$") then return end
    local key = project.key(file)
    if not vim.startswith(key, prefix) then return end
    if types[key] == nil then
      types[key] = false -- Guard against cyclic/incomplete scenes while editing.
      local child = read_file(file)
      if child and child.nodes[1] then types[key] = node_type(child.nodes[1], file) or false end
    end
    return types[key] or nil
  end
  local nodes = {}
  for i, node in ipairs(data.nodes) do
    local kind = node_type(node, path)
    local script = node.script
    local file = script and M.resource_file(root, path, script)
    if file and vim.startswith(project.key(file), prefix) then
      script = "res://" .. project.normalize(file):sub(#prefix + 1)
    end
    if kind ~= node.type or script ~= node.script then
      node = vim.tbl_extend("force", node, { type = kind, script = script })
    end
    nodes[i] = node
  end
  return nodes
end

function M.nodes(buf, root)
  local data, err = M.read(buf)
  return data and resolved_nodes(data, root, vim.api.nvim_buf_get_name(buf)), err
end

function M.file_nodes(path, root)
  local data, err = read_file(path)
  return data and resolved_nodes(data, root, path), err
end

function M.completion(buf, pos)
  local line = vim.api.nvim_buf_get_lines(buf, pos.line, pos.line + 1, false)[1] or ""
  local before = line:sub(1, pos.character)
  local ctor, start = before:match('([%a]+)%s*%(%s*"()[^"]*$')
  if ctor ~= "ExtResource" and ctor ~= "SubResource" then return {} end
  local data = M.read(buf)
  if not data then return {} end
  local items = {}
  for id, resource in pairs(ctor == "ExtResource" and data.ext or data.sub) do
    table.insert(items, {
      label = id, kind = 18, detail = table.concat({ resource.type or "", resource.path }, " "),
      textEdit = { newText = id, range = {
        start = { line = pos.line, character = start - 1 }, ["end"] = pos,
      } },
    })
  end
  table.sort(items, function(a, b) return a.label < b.label end)
  return items
end

function M.definition(buf, pos, root)
  local data = M.read(buf)
  if not data then return end
  local node = vim.treesitter.get_node({ bufnr = buf, pos = { pos.line, pos.character }, lang = "godot_resource" })
  while node and node:type() ~= "constructor" do node = node:parent() end
  local ctor, id = reference(node, buf)
  local uri, row = vim.uri_from_bufnr(buf), 0
  if ctor == "ExtResource" and data.ext[id] and vim.startswith(data.ext[id].path, "res://") then
    uri = vim.uri_from_fname(vim.fs.joinpath(root, data.ext[id].path:sub(7)))
  elseif ctor == "SubResource" and data.sub[id] then
    row = data.sub[id].row
  else
    return
  end
  local point = { line = row, character = 0 }
  return { uri = uri, range = { start = point, ["end"] = point } }
end

function M.type_at(buf, pos)
  if not M.read(buf) then return end
  local node = vim.treesitter.get_node({ bufnr = buf, pos = { pos.line, pos.character }, lang = "godot_resource" })
  while node and node:type() ~= "attribute" do node = node:parent() end
  if node and value(node:named_child(0), buf) == "type" then return value(node:named_child(1), buf) end
end

return M
