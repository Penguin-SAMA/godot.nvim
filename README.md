# godot.nvim

[简体中文](README.zh-CN.md)

Edit GDScript and shaders, browse scene trees, and run or debug your Godot game from Neovim.

Tested on Windows with Neovim 0.12.5 and Godot 4.7.2.

## Install with LazyVim

Add this to `lua/plugins/godot.lua` in your Neovim config. Put the Godot editor on your `PATH` as `godot`, or set `opts.executable` to its full path.

```lua
return {
  {
    "Penguin-SAMA/godot.nvim",
    lazy = false,
    main = "godot",
    dependencies = { "folke/which-key.nvim" },
    opts = {},
  },
}
```

## First use

1. Open a `.gd` file in a project with a `project.godot` file at its root. The plugin connects to Godot’s language server on demand. Use `gd` to jump to a definition or `:checkhealth godot` to check the connection.
2. With the `godot_resource` parser installed, open a `.tscn` or a script attached to a scene and press `<leader>Gso` to browse its nodes. Press `Enter` on a node to open its script.
3. To edit nodes or use the five run buttons, run `:GodotBridgeInstall` once per project, then `:GodotOpen`. Restart that project’s Godot editor if it was already open.

## Shortcuts

In Normal mode, press `<leader>G` (Space, then Shift+G in LazyVim). The keys below follow that prefix.

| Group | Keys |
| --- | --- |
| Project | `po` open Godot editor · `ph` check health |
| Editing | `ef` format file · `eg` open resource at cursor · `eh` show docs at cursor |
| Scene Tree | `so` open scene tree |
| Run | `rm` run main scene · `rc` run current scene · `rs` stop · `ro` open output |
| Debug | `db` toggle breakpoint · `dm` debug main scene · `dg` continue |

### Editing the scene tree

In the scene tree buffer, press `R` to rename the selected node, `d` to delete it and its subtree after confirmation, or `m` to choose a new parent in the same scene. The moved node is appended to the new parent's children. Press `u` to undo a scene edit in Godot.

These edits require the Bridge add-on and a running graphical Godot editor. Only local, editable non-root nodes are supported. Edits that cross inheritance or instance boundaries, cannot preserve scene ownership, or cannot safely preserve scene references are rejected. Node names must be valid and unique among siblings. The Bridge also rejects edits when the scene has unsaved changes in Neovim or conflicts with the file on disk. It does not rewrite node paths in GDScript. Moves preserve global transforms for `Node2D` and `Node3D`, but a container can still change a child’s on-screen position.

## Optional tools

- **Syntax and scene browsing** — install the Tree-sitter parsers with `:TSInstall gdscript godot_resource gdshader`.
- **Run and debug shortcuts** — install [nvim-dap](https://github.com/mfussenegger/nvim-dap).
- **Shader completion and diagnostics** — install [gdshader-lsp v0.3.2](https://github.com/Dead-Shrimp-Studio/gdshader-lsp-cpp/releases/tag/v0.3.2).
- **Formatting** — use `gdscript-formatter` for scripts and `clang-format` for shaders.
- **Godot scene and toolbar icons** — run `scripts/install-windows-font.ps1`, add `Godot Scene Icons` to your Windows Terminal font list, set `opts.scene_icons = "godot"`, and reopen the terminal.

