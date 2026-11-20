local M = {}

local function feature_status(h, label, status, retry)
  local text = label .. " · " .. status.state
  if status.message then text = text .. " · " .. status.message end
  if status.path and not text:find(status.path, 1, true) then text = text .. " · " .. status.path end
  if status.state == "failed" then
    h.warn(text, { retry })
  elseif status.state == "ready" then
    h.ok(text)
  else
    h.info(text)
  end
end
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
  if config.godot_path and #config.godot_path > 0 then
    h.info("Godot search paths: " .. vim.inspect(config.godot_path))
  elseif config.executable then
    local exe = vim.fn.exepath(config.executable)
    if exe == "" then
      h.warn("Configured Godot executable is missing: " .. config.executable, {
        "Set godot_path to your Godot installation directory or download an editor from https://godotengine.org/download/",
      })
    else
      h.info("Configured Godot executable: " .. exe)
    end
  else
    h.info("Godot path will be requested when this project needs an engine.")
  end
  local root = require("godot").health_root()
  if root then
    h.info("Project: " .. root)
    local instances = require("godot.session").instances(root)
    if #instances == 0 then
      h.info("GDScript language service disconnected. Open a .gd file or use :GodotReconnect.")
      if config.features.dap then h.info("Debug service disconnected. Use :GodotRun or :GodotDebug to start it.") end
    end
    local owners = require("godot.ports").owners()
    for _, s in ipairs(instances) do
      h.info(("Instance: %s · PID %d · %s"):format(s.mode, s.pid, s.version or s.executable or "unknown engine version"))
      local services = { { "Language", s.lsp_port } }
      if config.features.dap then services[#services + 1] = { "Debug", s.dap_port } end
      if config.features.bridge then services[#services + 1] = { "Scene bridge", s.bridge_port } end
      for _, pair in ipairs(services) do
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
  h.start("Features and tools")
  feature_status(h, "Project Bridge", require("godot.bridge").status(root), "Run :GodotBridgeInstall in this project.")
  local tools = require("godot.tools")
  for _, id in ipairs({ "scene_tree", "dap", "shader_lsp", "gdscript_formatter", "clang_format" }) do
    feature_status(h, id, tools.status(id, root), "Correct the reported problem, then run :GodotToolsRetry.")
  end
  local parser_features = {
    gdscript = "GDScript semantic highlighting",
    gdshader = "shader syntax highlighting",
  }
  for lang, features in vim.spairs(parser_features) do
    local ok, loaded = pcall(vim.treesitter.language.add, lang)
    if ok and loaded then h.ok("Parser: " .. lang)
    else h.warn("Missing parser: " .. lang .. " (" .. features .. " unavailable).",
      { ":TSInstall " .. lang .. " (nvim-treesitter)" }) end
  end
end
return M
