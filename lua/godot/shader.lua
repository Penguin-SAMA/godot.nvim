local M = {}
local lpeg = vim.lpeg
local P, S, R, C, Ct = lpeg.P, lpeg.S, lpeg.R, lpeg.C, lpeg.Ct
local word = R("az", "AZ", "09") + P("_")
local identifier = word ^ 1
local line = (1 - S("\r\n")) ^ 0
local comment = P("//") * line + P("/*") * (1 - P("*/")) ^ 0 * P("*/") ^ -1
local space = S(" \t\r\n") + comment
local quoted = P('"') * (P("\\") * 1 + (1 - S('"\r\n'))) ^ 0 * P('"') ^ -1
local directive = P("#") * line
local shader_type = P("shader_type") * space ^ 1
local declaration = shader_type * Ct(lpeg.Cg(C(identifier), "family")) * space ^ 0 * P(";")
local entry = P("void") * space ^ 1 * Ct(lpeg.Cg(C(identifier), "stage"))
  * space ^ 0 * P("(") * space ^ 0 * P(")") * space ^ 0 * P("{")
-- Only collect the shader type, entry points and braces. This also works in
-- incomplete shaders and without the optional Tree-sitter parser.
local structure = Ct((space + directive + quoted + declaration + entry + C(S("{}")) + identifier + 1) ^ 0)

local families = {}
for family, stages in pairs(require("godot.shader_builtins")) do
  families[family] = {}
  for stage, types in pairs(stages) do
    local names = {}
    for value_type, words in pairs(types) do
      for name in words:gmatch("%S+") do names[name] = value_type end
    end
    families[family][stage] = names
  end
end

local function scope(params, encoding)
  local buf = vim.uri_to_bufnr(params.textDocument.uri)
  if not vim.api.nvim_buf_is_loaded(buf) then return end
  local pos = params.position
  local lines = vim.api.nvim_buf_get_lines(buf, 0, pos.line + 1, false)
  if not lines[pos.line + 1] then return end
  local col = vim.str_byteindex(lines[#lines], encoding, pos.character, false)
  lines[#lines] = lines[#lines]:sub(1, col)
  local family, stage, depth = nil, nil, 0
  for _, token in ipairs(structure:match(table.concat(lines, "\n"))) do
    if token == "{" then
      depth = depth + 1
    elseif token == "}" then
      depth = math.max(depth - 1, 0)
      if depth == 0 then stage = nil end
    elseif token.family then
      family = families[token.family]
    else
      if depth == 0 then stage = token.stage end
      depth = depth + 1
    end
  end
  return family, stage
end

function M.completion(params, result, encoding)
  if type(result) ~= "table" then return result end
  local family, stage = scope(params, encoding)
  if not family then return result end
  local kinds = vim.lsp.protocol.CompletionItemKind
  for _, item in ipairs(result.items or result) do
    local name = item.label
    local value_type = family.constants[name] or family.global[name] or (family[stage] or {})[name]
    local insertion = item.textEdit and item.textEdit.newText or item.textEditText or item.insertText
    if value_type and item.kind == kinds.Function and item.detail == "void" and insertion == name .. "()" then
      item.kind = family.constants[name] and kinds.Constant or kinds.Variable
      item.detail, item.insertTextFormat = value_type, vim.lsp.protocol.InsertTextFormat.PlainText
      if item.textEdit then item.textEdit.newText = name end
      if item.textEditText then item.textEditText = name end
      if item.insertText then item.insertText = name end
    end
  end
  return result
end

-- The 0.3.1 server calls Godot 4.7's texture_blit shader type "blist".
-- Preserve every byte offset in its private copy of the document.
local blit_declaration = (space + directive) ^ 0 * shader_type * lpeg.Cp() * P("texture_blit")
  * space ^ 0 * P(";")
-- Import missing built-in signatures into the server's symbol table. Appending
-- the include keeps every user token at its original line and column.
local overloads = vim.fs.normalize(vim.api.nvim_get_runtime_file("lua/godot/shader_overloads.gdshaderinc", false)[1])
local overload_include = '#include "' .. overloads .. '"'
local formatted_include = "\n" .. vim.pesc(overload_include) .. "\r?\n"
local project_key = require("godot.project").key
local overload_key = project_key(overloads)
local signatures = vim.fn.readfile(overloads)

function M.is_overload_file(uri)
  return uri and uri:find("shader_overloads.gdshaderinc", 1, true)
    and project_key(vim.uri_to_fname(uri)) == overload_key
end

function M.is_overload_location(name, hit)
  if not hit or not hit.range then return false end
  local signature = signatures[hit.range.start.line + 1]
  return signature and signature:match("^%w+ (%w+)%(") == name
end

-- The Windows server opens includes through a narrow filesystem API. Supply
-- the header through its in-memory document store for non-ASCII installs.
function M.open_overloads(client)
  if vim.fn.has("win32") == 1 and overloads:find("[\128-\255]") then
    client:notify("textDocument/didOpen", { textDocument = {
      uri = vim.uri_from_fname(overloads), version = 0, languageId = "gdshader",
      text = table.concat(signatures, "\n"),
    } })
  end
end

-- The legacy parser stops at '[' in a postfix uniform array declaration.
-- Its GDS1001 range points to that bracket, even when the semicolon follows.
local fixed_array = P("[") * space ^ 0 * C(R("09") ^ 1) * space ^ 0 * P("]") * space ^ 0 * P(";")
function M.legacy_diagnostics(params, encoding)
  local lines
  params.diagnostics = vim.tbl_filter(function(d)
    if d.code ~= "GDS1001" or d.message ~= "Expected ';' after uniform declaration" then return true end
    local buf = vim.uri_to_bufnr(params.uri)
    if not vim.api.nvim_buf_is_loaded(buf) then return true end
    lines = lines or vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local pos = d.range.start
    local row = lines[pos.line + 1]
    if not row then return true end
    local col = vim.str_byteindex(row, encoding, pos.character, false)
    if row:sub(col + 1, col + 1) ~= "[" then return true end
    local size = fixed_array:match(table.concat(lines, "\n", pos.line + 1), col + 1)
    return not size or tonumber(size) == 0
  end, params.diagnostics)
end

-- Appending a directive inside a half-written function would make the server
-- report an unknown identifier named "include" on a line outside the buffer.
local trailing = (space + directive) ^ 0 * -P(1)
local last_token = C(S("};")) * #trailing * lpeg.Cc("end")
local delimiters = Ct((space + directive + quoted + last_token + C(S("(){}[]")) + identifier + 1) ^ 0)
local closer = { ["("] = ")", ["{"] = "}", ["["] = "]" }
local function can_append_include(source)
  local tokens = delimiters:match(source)
  if tokens[#tokens] ~= "end" then return false end
  local stack = {}
  for i = 1, #tokens - 1 do
    local token = tokens[i]
    if closer[token] then
      stack[#stack + 1] = closer[token]
    elseif token ~= ";" then
      if stack[#stack] ~= token then return false end
      stack[#stack] = nil
    end
  end
  return #stack == 0
end

local function legacy_source(source, uri)
  if source:find("texture_blit", 1, true) then
    local at = blit_declaration:match(source)
    if at then source = source:sub(1, at - 1) .. "blist       " .. source:sub(at + #"texture_blit") end
  end
  if M.is_overload_file(uri) or not can_append_include(source) then return source end
  return source .. "\n" .. overload_include .. "\n"
end

-- This server formats its entire private copy in one replacement edit.
function M.legacy_format(params, edits)
  if not edits or not edits[1] then return edits end
  local edit = edits[1]
  local buf = vim.uri_to_bufnr(params.textDocument.uri)
  if not vim.api.nvim_buf_is_loaded(buf) then return {} end
  if project_key(vim.api.nvim_buf_get_name(buf)) == overload_key then return edits end
  local source, count = ("\n" .. edit.newText):gsub(formatted_include, "\n")
  if count ~= 1 or source:find(overload_include, 1, true) then return {} end
  source = source:sub(2)
  local original = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  -- The legacy AST formatter drops postfix uniform array sizes entirely.
  -- Leave this edit to :GodotFormat, which works on the original buffer.
  if original:find("%f[%w_]uniform%s+[%w_%s]+%[") then return {} end
  if source:find("blist", 1, true) and blit_declaration:match(original) then
    source = source:gsub("(shader_type%s+)blist(%s*;)", "%1texture_blit%2", 1)
  end
  edit.newText = source
  edit.range["end"] = { line = vim.api.nvim_buf_line_count(buf), character = 0 }
  return edits
end

-- Synthetic declarations describe engine built-ins. They cannot be renamed.
function M.legacy_rename(_, result)
  if type(result) ~= "table" then return result end
  for uri in pairs(result.changes or {}) do
    if M.is_overload_file(uri) then return nil end
  end
  return result
end

function M.legacy_symbols(_, result)
  if type(result) ~= "table" then return result end
  return vim.tbl_filter(function(symbol) return not M.is_overload_file(symbol.location.uri) end, result)
end

-- v0.3.2 reports serverInfo.version 0.3.1. Its Windows compiler uses native
-- separators as document keys. Match them on the wire or requests never see
-- the AST published by the compiler, even for the same file.
function M.legacy_params(params)
  if type(params) ~= "table" or not params.textDocument then return params end
  local doc = params.textDocument
  local uri = doc.uri
  if vim.fn.has("win32") == 1 and uri then
    uri = uri:gsub("^(file:///)(%a:.*)$", function(scheme, drive_path)
      return scheme .. drive_path:gsub("/", "%%5C")
    end)
  end
  local text = doc.text and legacy_source(doc.text, doc.uri)
  if uri ~= doc.uri or text ~= doc.text then
    params = vim.tbl_extend("force", params, { textDocument = vim.tbl_extend("force", doc, { uri = uri, text = text }) })
  end
  local change = params.contentChanges and params.contentChanges[1]
  if change and not change.range then
    text = legacy_source(change.text, doc.uri)
    if text ~= change.text then
      params = vim.tbl_extend("force", params, { contentChanges = { { text = text } } })
    end
  end
  return params
end

return M
