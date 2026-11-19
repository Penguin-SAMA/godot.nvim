local M = {}
local docs = require("godot.docs")
local types = { "variable", "property", "parameter", "function", "method", "type", "class", "enumMember", "event", "namespace", "keyword", "enum" }
local ids = {}
for i, name in ipairs(types) do ids[name] = i - 1 end
M.provider = { full = true, legend = { tokenTypes = types, tokenModifiers = { "declaration", "readonly", "defaultLibrary" } } }

local statements = {
  variable_statement = "property", const_statement = "constant", class_definition = "class",
  enum_definition = "enum", function_definition = "function", signal_statement = "event", class_name_statement = "class",
}
local globals = {
  preload = true, load = true, range = true, len = true, assert = true, print_debug = true, print_stack = true,
  get_stack = true, type_exists = true, is_instance_of = true, dict_to_inst = true, inst_to_dict = true,
}
local function text(node, buf) return vim.treesitter.get_node_text(node, buf) end
local function field(node, key) return node:field(key)[1] end
local function scope(parent) return setmetatable({}, { __index = parent }) end

local function class_scope(node, buf, outer)
  local symbols, base = scope(outer), "RefCounted"
  for child in node:iter_children() do
    local ty = child:type()
    if ty == "extends_statement" and child:named_child(0) then
      base = text(child:named_child(0), buf)
    elseif statements[ty] then
      local name = field(child, "name")
      if name then symbols[text(name, buf)] = statements[ty] end
    end
  end
  return symbols, base
end

function M.tokens(buf, api)
  local parser = vim.treesitter.get_parser(buf, "gdscript", { error = false })
  if not parser then return { data = {} } end
  local tree = parser:parse()[1]
  if not tree then return { data = {} } end
  local tokens = {}
  local prev_row, prev_col = 0, 0
  local function emit(node, kind, modifier)
    if not kind then return end
    if kind == "constant" then kind, modifier = "variable", modifier + 2 end
    local row, col, _, last = node:range()
    vim.list_extend(tokens, { row - prev_row, row == prev_row and col - prev_col or col, last - col, ids[kind], modifier })
    prev_row, prev_col = row, col
  end

  local function identifier(node, names, base)
    local name, parent = text(node, buf), node:parent()
    local ptype = parent:type()
    if ptype == "attribute_call" or (ptype == "attribute" and parent:named_child(0) ~= node) then
      local receiver = ptype == "attribute_call" and parent:prev_named_sibling() or node:prev_named_sibling()
      local owner = receiver and text(receiver, buf)
      if owner == "self" and names[name] then return names[name], 0 end
      local member = api and docs.member(api, owner == "self" and base or owner, name)
      if member then return member.kind, 4 end
      return ptype == "attribute_call" and "method" or "property", 0
    end
    if name == "self" or name == "super" then return "keyword", 0 end
    if names[name] then return names[name], 0 end
    local class = api and api.classes[name]
    if class then
      if api.singletons[name] then return "namespace", 4 end
      return class.builtin and "type" or "class", 4
    end
    local member = api and docs.member(api, base, name)
    if member then return member.kind, 4 end
    if globals[name] or (api and api.utility[name]) then return "function", 4 end
    if ptype == "type" then return "type", 0 end
    if ptype == "call" and parent:named_child(0) == node then return "function", 0 end
  end

  local function walk(node, names, base, in_class)
    local ty, parent = node:type(), node:parent()
    if ty == "source" or (ty == "body" and parent:type() == "class_definition") then
      names, base = class_scope(node, buf, names)
      in_class = true
    elseif ty == "function_definition" or ty == "lambda" or ty == "signal_statement" or ty == "for_statement" then
      names, in_class = scope(names), false
    elseif ty == "body" then
      names = scope(names)
    end
    if ty == "identifier" or ty == "name" then
      local ptype, name = parent:type(), text(node, buf)
      if ty == "name" and statements[ptype] then
        local kind = statements[ptype]
        if ptype == "variable_statement" and not in_class then kind = "variable" end
        names[name] = kind
        emit(node, kind, 1)
      elseif ptype == "parameters" or (ptype:match("_parameter$") and parent:named_child(0) == node) then
        names[name] = "parameter"
        emit(node, "parameter", 1)
      elseif ptype == "for_statement" and field(parent, "left") == node then
        names[name] = "variable"
        emit(node, "variable", 1)
      else
        emit(node, identifier(node, names, base))
      end
      return
    end
    for child in node:iter_children() do
      if child:named() then walk(child, names, base, in_class) end
    end
  end
  walk(tree:root(), {}, "RefCounted", true)
  return { data = tokens }
end
return M
