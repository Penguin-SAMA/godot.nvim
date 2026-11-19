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
local function legacy_source(source)
  if not source:find("texture_blit", 1, true) then return source end
  local at = blit_declaration:match(source)
  if not at then return source end
  return source:sub(1, at - 1) .. "blist       " .. source:sub(at + #"texture_blit")
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
  local text = doc.text and legacy_source(doc.text)
  if uri ~= doc.uri or text ~= doc.text then
    params = vim.tbl_extend("force", params, { textDocument = vim.tbl_extend("force", doc, { uri = uri, text = text }) })
  end
  local change = params.contentChanges and params.contentChanges[1]
  if change and not change.range then
    text = legacy_source(change.text)
    if text ~= change.text then
      params = vim.tbl_extend("force", params, { contentChanges = { { text = text } } })
    end
  end
  return params
end

return M
