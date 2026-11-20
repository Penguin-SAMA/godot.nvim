# godot.nvim

[简体中文](README.zh-CN.md)

Edit GDScript and shaders, browse scene trees, and run or debug your Godot game from Neovim.

Tested on Windows with Neovim 0.12.5 and Godot 4.7.2.

## Install with LazyVim

Add this to `lua/plugins/godot.lua` in your Neovim config.

```lua
return {
  {
    "Penguin-SAMA/godot.nvim",
    lazy = false,
    main = "godot",
    opts = {
      -- godot_path = "F:/Godots", -- optional, also accepts a list of install directories
      features = {
        -- scene_tree = true,  -- browse scenes and prepare the godot_resource parser
        -- bridge = true,      -- configure each project's Bridge for node edits and the run toolbar
        -- dap = false,        -- set true to configure nvim-dap for run and breakpoint commands
        -- shader_lsp = true,  -- shader completion, hover and diagnostics
        -- formatting = true,  -- GDScript and shader formatting
      },
    },
  },
}
```

Use `opts = {}` for all defaults, or set just one option, e.g. `opts = { features = { dap = true } }`. Disabling a feature turns off its integration and keeps installed tools and project files on disk.

On Windows x64, enabled tools are prepared in the background when the plugin loads. Configured paths and compatible local tools take priority. Missing components are installed at pinned versions under Neovim’s data directory after checksum verification. On other platforms install the tools separately. Use `opts.shader_lsp`, `opts.gdscript_formatter` and `opts.clang_format` for executable overrides. Run `:checkhealth godot` for status and paths, or `:GodotToolsRetry` to retry failed tool installations.

The plugin first connects to the editor running this project. When it needs to start Godot (including the background editor for GDScript), it searches `godot_path`. Use a single directory or a list of directories. The search includes files up to four levels below each directory and checks the binaries’ reported versions. A GodotHub pin in `.godothub/.godotrc` selects the release and .NET flavor. Other projects use the major and minor version in `project.godot`.

A single match is automatic. Multiple matches open a picker. With no search path or no match, Neovim asks for an editor executable or installation directory. The choice is reused for this project in the current Neovim session. Cancel to skip launching and retry later with `:GodotOpen` or `:GodotReconnect`. Existing `opts.executable` and `GODOT_NVIM_EXECUTABLE` settings still supply an explicit executable when `godot_path` is empty.

## First use

1. Open a `.gd` file in a project with a `project.godot` file at its root. The plugin connects to Godot’s language server on demand. Use `gd` to jump to a definition or `:checkhealth godot` to check the connection.
2. Open a `.tscn` or a script attached to a scene and run `:GodotTree` to browse its nodes. Press `Enter` on a node to open its script.
3. On first opening a project, the plugin installs the Bridge into `addons/nvim_bridge` and enables it in `project.godot` by default. Use `:GodotOpen` for scene editing and the run toolbar. If the editor was already running, enable **Neovim Bridge** in the project's Plugins settings or reopen the project. For a custom add-on conflict or unsaved project settings, inspect `:checkhealth godot`, resolve the conflict and retry with `:GodotBridgeInstall`.

## Shortcuts

With which-key.nvim v3, press `<leader>G` in Normal mode (Space, then Shift+G in LazyVim) to see the shortcuts available in the current buffer. The keys below follow that prefix.

Commands such as `:GodotTree` and `:GodotRun main` work with or without which-key. Without which-key, `:GodotMenu` opens the built-in menu. If `<leader>G` is free, it opens that menu too.

| Group | Keys |
| --- | --- |
| Project | `po` open Godot editor · `ph` check health |
| Editing | `ef` format file · `eg` open resource at cursor · `eh` show docs at cursor |
| Scene Tree | `so` open scene tree |
| Run (DAP enabled) | `rm` run main scene · `rc` run current scene · `rs` stop · `ro` open output |
| Debug (DAP enabled) | `db` toggle breakpoint · `dm` debug main scene · `dg` continue |

### Editing the scene tree

In the scene tree buffer, press `R` to rename the selected node, `d` to delete it and its subtree after confirmation, or `m` to choose a new parent in the same scene. The moved node is appended to the new parent's children. Press `u` to undo a scene edit in Godot.

These edits require the Bridge add-on and a running graphical Godot editor. Only local, editable non-root nodes are supported. Edits that cross inheritance or instance boundaries, cannot preserve scene ownership, or cannot safely preserve scene references are rejected. Node names must be valid and unique among siblings. The Bridge also rejects edits when the scene has unsaved changes in Neovim or conflicts with the file on disk. It does not rewrite node paths in GDScript. Moves preserve global transforms for `Node2D` and `Node3D`, but a container can still change a child’s on-screen position.

## Optional tools

- **Script and shader highlighting** — add the Tree-sitter parsers with `:TSInstall gdscript gdshader`.
- **Other platforms** — install the `godot_resource` parser for scene trees, `nvim-dap` for run/debug commands, `gdshader-lsp` for shaders, and `gdscript-formatter` and `clang-format` for formatting.
- **Godot scene and toolbar icons** — run `scripts/install-windows-font.ps1`, add `Godot Scene Icons` to your Windows Terminal font list, set `opts.scene_icons = "godot"`, and reopen the terminal.

