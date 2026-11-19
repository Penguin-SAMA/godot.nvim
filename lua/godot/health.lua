local M = {}
function M.check()
  local h = vim.health
  local config = require("godot.config").options
  h.start("godot.nvim")
  h.info("Neovim " .. tostring(vim.version()))
  if config.scene_icons == "godot" then
    local function glyph(class) return require("godot.node_icons").get({ type = class })[1] end
    h.info(("Godot Scene Icons (4.7.2): %s Timer, %s ColorRect. For empty boxes, add Godot Scene Icons to the terminal font list.")
      :format(glyph("Timer"), glyph("ColorRect")))
  end
  local exe = vim.fn.exepath(config.executable)
  if exe == "" then
    h.error("Godot missing", { "Set setup({ executable = 'path/to/Godot' })." })
  else
    local res = vim.system({ exe, "--version" }, { text = true }):wait(5000)
    h.info("Configured engine: " .. exe .. " " .. vim.trim(res.stdout or ""))
  end
  local root = require("godot").health_root()
  if root then
    h.info("Project: " .. root)
    local instances = require("godot.session").instances(root)
    if #instances == 0 then
      h.info("GDScript language service disconnected. Open a .gd file or use :GodotReconnect.")
      h.info("Debug service disconnected. Use :GodotRun or :GodotDebug to start it.")
      h.info("Scene bridge disconnected. Use :GodotBridgeInstall and :GodotOpen for scene actions.")
    end
    local owners = require("godot.ports").owners()
    for _, s in ipairs(instances) do
      local version = s.version
      if not version and s.executable then
        local res = vim.system({ s.executable, "--version" }, { text = true }):wait(5000)
        if res.code == 0 then version = vim.trim(res.stdout or "") end
      end
      h.info(("Instance: %s · PID %d · %s"):format(s.mode, s.pid, version or "unknown engine version"))
      for _, pair in ipairs({ { "Language", s.lsp_port }, { "Debug", s.dap_port }, { "Scene bridge", s.bridge_port } }) do
        if pair[2] and owners[pair[2]] == s.pid then
          h.ok(("%s connected to project · port %d"):format(pair[1], pair[2]))
        elseif pair[1] == "Scene bridge" then
          h.info("Scene bridge offline. Use :GodotBridgeInstall and open the graphical editor.")
        else
          h.warn(pair[1] .. " disconnected. Use :GodotReconnect or reopen the project editor.")
        end
      end
    end
  else
    h.info("Open a file under project.godot to check its services.")
  end
  h.start("Editing and debugging tools")
  for _, item in ipairs({
    { config.shader_lsp, "shader completion and diagnostics" },
    { config.gdscript_formatter, "GDScript formatting" },
    { config.clang_format, "shader formatting" },
  }) do
    if vim.fn.executable(item[1]) == 1 then h.ok(item[1])
    else h.warn(item[1] .. " missing (" .. item[2] .. "). Install it on PATH or set its path in setup().") end
  end
  for _, lang in ipairs({ "gdscript", "godot_resource", "gdshader" }) do
    local ok, loaded = pcall(vim.treesitter.language.add, lang)
    if ok and loaded then h.ok("Parser: " .. lang)
    else h.warn("Missing parser: " .. lang, { ":TSInstall " .. lang .. " (nvim-treesitter)" }) end
  end
  if pcall(require, "dap") then h.ok("nvim-dap")
  else h.info("Install mfussenegger/nvim-dap for running and debugging.") end
end
return M

