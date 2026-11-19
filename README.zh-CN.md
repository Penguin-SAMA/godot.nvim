# godot.nvim

[English](README.md)

在 Neovim 中编写 GDScript 和着色器，浏览场景树，运行或调试 Godot 游戏。

已在 Windows、Neovim 0.12.5 和 Godot 4.7.2 上验证。

## 在 LazyVim 中安装

将下面的配置放入 Neovim 配置目录的 `lua/plugins/godot.lua`。确保 `PATH` 中的 `godot` 指向 Godot 编辑器，或将 `opts.executable` 设为编辑器的完整路径。

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

## 首次使用

1. 打开含 `project.godot` 的项目中的 `.gd` 文件，插件会按需连接 Godot 语言服务。按 `gd` 跳到定义，用 `:checkhealth godot` 检查连接。
2. 安装 `godot_resource` 解析器后，打开 `.tscn` 或已挂载到场景的脚本，按 `<leader>Gso` 浏览节点。在节点上按回车可打开它挂载的脚本。
3. 要编辑节点或使用右上角的五个运行按钮，在项目中执行一次 `:GodotBridgeInstall`，再执行 `:GodotOpen`。若该项目的 Godot 编辑器已打开，请重启它。

## 快捷键

在普通模式按 `<leader>G`（LazyVim 默认为空格，再按 Shift+G），然后输入下表中的按键。

| 菜单分组 | 按键 |
| --- | --- |
| Project | `po` 打开 Godot 编辑器 · `ph` 检查环境与连接 |
| Editing | `ef` 格式化文件 · `eg` 打开光标处的资源 · `eh` 查看光标处的文档 |
| Scene Tree | `so` 打开场景树 |
| Run | `rm` 运行主场景 · `rc` 运行当前场景 · `rs` 停止 · `ro` 打开输出 |
| Debug | `db` 切换断点 · `dm` 调试主场景 · `dg` 继续执行 |

### 编辑场景树

在场景树缓冲区中，按 `R` 重命名选中的节点，按 `d` 确认删除该节点及其子树，或按 `m` 选择同一场景中的新父节点。移动后的节点会追加到新父节点的子节点列表末尾。按 `u` 可撤销 Godot 中的场景编辑。

这些操作需要安装 Bridge 插件并运行带图形渲染器的 Godot 编辑器。只支持本地可编辑的非根节点。涉及继承或实例边界、无法保留场景所有权或无法安全保留场景引用时，操作会被拒绝。节点名称必须合法，且不能与同级节点重名。若场景在 Neovim 中有未保存的修改，或与磁盘上的文件冲突，Bridge 也会拒绝编辑。它不会改写 GDScript 中的节点路径。移动会保留 `Node2D` 和 `Node3D` 的全局变换，但容器布局仍可能改变子节点在屏幕上的位置。

## 可选工具

- **语法高亮与场景浏览** — 用 `:TSInstall gdscript godot_resource gdshader` 安装 Tree-sitter 解析器。
- **运行与调试快捷键** — 安装 [nvim-dap](https://github.com/mfussenegger/nvim-dap)。
- **着色器补全与诊断** — 安装 [gdshader-lsp v0.3.2](https://github.com/Dead-Shrimp-Studio/gdshader-lsp-cpp/releases/tag/v0.3.2)。
- **格式化** — GDScript 使用 `gdscript-formatter`，着色器使用 `clang-format`。
- **Godot 场景与工具栏图标** — 运行 `scripts/install-windows-font.ps1`，将 `Godot Scene Icons` 加入 Windows Terminal 字体列表，在插件配置中设置 `opts.scene_icons = "godot"`，然后重开终端。
