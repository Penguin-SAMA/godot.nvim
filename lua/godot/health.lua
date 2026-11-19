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
    h.error("Godot missing: GDScript language service, scene editing, running and debugging unavailable.", {
      "Download the editor from https://godotengine.org/download/archive/4.7.2-stable/",
      "Set its path in require('godot').setup({ executable = 'path/to/Godot' }).",
    })
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
  for _, tool in ipairs({
    { option = "shader_lsp", feature = "shader completion, hover, definitions and diagnostics",
      install = "Download gdshader-lsp for your platform from https://github.com/Dead-Shrimp-Studio/gdshader-lsp-cpp/releases/tag/v0.3.2" },
    { option = "gdscript_formatter", feature = "GDScript formatting",
      install = "Download the formatter for your platform from https://github.com/GDQuest/GDScript-formatter/releases" },
    { option = "clang_format", feature = "shader formatting",
      install = "Install LLVM for your platform from https://github.com/llvm/llvm-project/releases" },
  }) do
    local exe_path = config[tool.option]
    if vim.fn.executable(exe_path) == 1 then
      h.ok(exe_path)
    else
      h.warn(exe_path .. " missing (" .. tool.feature .. " unavailable).", {
        tool.install, "Add the executable to PATH or set its path using setup({ " .. tool.option .. " = '...' }).",
      })
    end
  end
  local parser_features = {
    gdscript = "GDScript semantic highlighting",
    godot_resource = "offline scene tree, resource completion, definitions and node type hover",
    gdshader = "shader syntax highlighting",
  }
  for lang, features in vim.spairs(parser_features) do
    local ok, loaded = pcall(vim.treesitter.language.add, lang)
    if ok and loaded then h.ok("Parser: " .. lang)
    else h.warn("Missing parser: " .. lang .. " (" .. features .. " unavailable).",
      { ":TSInstall " .. lang .. " (nvim-treesitter)" }) end
  end
  if pcall(require, "dap") then h.ok("nvim-dap")
  else h.info("Install mfussenegger/nvim-dap for running and debugging.") end
end
return M

