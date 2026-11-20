-- Run from the plugin root with nvim --headless -u NONE -l tests/shader_compat.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.cmd("filetype on")
require("godot").setup()

local path = vim.fn.tempname() .. ".gdshader"
local lines = {
  "shader_type canvas_item;",
  "uniform vec2 centers[128];",
  "void fragment() {",
  "  vec3 a = mix(vec3(0.1), vec3(0.2), UV.x * 0.8);",
  "  vec3 b = mix(a, vec3(0.4), greaterThanEqual(a, vec3(0.2)));",
  "  vec2 v = smoothstep(vec2(0.0), vec2(1.0), step(0.5, UV));",
  "  v = clamp(mod(v, 0.2), 0.0, 1.0) + reflect(v, UV);",
  "  ivec2 i = max(min(ivec2(1), 2), 0);",
  "  COLOR = textureGrad(TEXTURE, v, UV, UV) + vec4(b, 1.0);",
  "  COLOR = mix(COLOR, vec4(1.0), vec2(1.0));",
  "}",
}
vim.fn.writefile(lines, path)
vim.cmd.edit(vim.fn.fnameescape(path))
local buf = vim.api.nvim_get_current_buf()
local function errors() return vim.diagnostic.get(buf, { severity = vim.diagnostic.severity.ERROR }) end
local function wait_error(row, needle)
  assert(vim.wait(7000, function()
    for _, d in ipairs(errors()) do
      if d.lnum == row and d.message:find(needle, 1, true) then return true end
    end
  end), vim.inspect(errors()))
end
wait_error(9, "mix")
assert(#errors() == 1, vim.inspect(errors()))

-- An edited, unsaved document must get the same overloads as a newly opened one.
vim.api.nvim_buf_set_lines(buf, 9, 10, false, { "  COLOR = mix(COLOR, vec4(1.0), UV.x);" })
assert(vim.wait(7000, function() return #errors() == 0 end), vim.inspect(errors()))
vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "uniform vec2 centers[128]" })
wait_error(1, "Expected ';'")

vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "// an ordinary comment" })
assert(vim.wait(7000, function() return #errors() == 0 end), vim.inspect(errors()))
local client = assert(vim.lsp.get_clients({ bufnr = buf, name = "gdshader-lsp" })[1])
local r = assert(client:request_sync("textDocument/formatting", {
  textDocument = { uri = vim.uri_from_bufnr(buf) }, options = { tabSize = 4, insertSpaces = false },
}, 3000, buf))
local replacement = assert(r.result[1]).newText
assert(replacement:find("textureGrad", 1, true) and not replacement:find("#include", 1, true), replacement)

vim.api.nvim_buf_set_lines(buf, -2, -1, false, {})
wait_error(#lines - 1, "Expected '}'")
for _, d in ipairs(errors()) do assert(not d.message:find("include", 1, true), d.message) end
print("PASS shader overloads, uniform array semicolons, unsaved edits and formatting")
