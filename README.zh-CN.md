# godot.nvim

[English](README.md)

在 Neovim 中编写 GDScript 和着色器，浏览场景树，运行或调试 Godot 游戏。

已在 Windows、Neovim 0.12.5 和 Godot 4.7.2 上验证。

## 在 LazyVim 中安装

将下面的配置放入 Neovim 配置目录的 `lua/plugins/godot.lua`。

```lua
return {
  {
    "Penguin-SAMA/godot.nvim",
    lazy = false,
    main = "godot",
    opts = {
      -- godot_path = "F:/Godots", -- 可选，也接受多个安装目录
      features = {
        -- scene_tree = true,  -- 浏览场景树，自动准备 godot_resource 解析器
        -- bridge = true,      -- 为项目配置 Neovim Bridge，启用节点编辑和运行工具栏
        -- dap = false,        -- 改为 true 以配置 nvim-dap，启用运行和断点调试命令
        -- shader_lsp = true,  -- 着色器补全、悬停和诊断
        -- formatting = true,  -- GDScript 和着色器格式化
      },
    },
  },
}
```

`opts = {}` 即可使用全部默认值。只想开启调试时写 `opts = { features = { dap = true } }`。关闭某项会停用 godot.nvim 的对应功能，并保留本机工具和项目文件。

Windows x64 上，插件加载配置后会在后台准备已开启的工具。插件优先使用已配置的路径和兼容的本机工具，缺少的组件按固定版本校验后安装在 Neovim 数据目录。其他平台请自行安装对应工具，或通过 `opts.shader_lsp`、`opts.gdscript_formatter`、`opts.clang_format` 指定可执行文件。`:checkhealth godot` 显示各项状态和路径，`:GodotToolsRetry` 重试失败的工具安装。

插件优先连接当前项目已运行的 Godot 编辑器。需要启动 Godot 时（包括 GDScript 语言服务用的后台编辑器），才搜索 `godot_path`。可以填一个目录字符串，也可以填目录列表。插件会查找各目录下最多四层的文件，读取候选引擎实际报告的版本。GodotHub 项目优先使用 `.godothub/.godotrc` 指定的版本和 .NET 类型，其他项目按 `project.godot` 中的主、次版本匹配。

只有一个匹配项时自动使用，有多个时在 Neovim 中选择。未配置路径或目录内没有匹配项时，Neovim 会提示输入可执行文件路径或安装目录，选定后在当前 Neovim 会话中按项目记住。取消会跳过启动，之后可用 `:GodotOpen` 或 `:GodotReconnect` 重试。已有的 `opts.executable` 和 `GODOT_NVIM_EXECUTABLE` 在 `godot_path` 为空时仍然生效。

## 首次使用

1. 打开含 `project.godot` 的项目中的 `.gd` 文件，插件会按需连接 Godot 语言服务。按 `gd` 跳到定义，用 `:checkhealth godot` 检查连接。
2. 打开 `.tscn` 或已挂载到场景的脚本，执行 `:GodotTree` 浏览节点。在节点上按回车可打开它挂载的脚本。
3. 默认首次打开项目时，插件会把 Bridge 安装到 `addons/nvim_bridge`，并在 `project.godot` 中启用它。用 `:GodotOpen` 打开编辑器即可编辑节点或使用运行工具栏。如果编辑器已打开，可在项目设置的插件页启用 **Neovim Bridge**，或重新打开项目。遇到自定义 Bridge 文件或未保存的项目设置时，用 `:checkhealth godot` 查看原因，处理后运行 `:GodotBridgeInstall` 重试。

## 快捷键

装有 which-key.nvim v3 时，在普通模式按 `<leader>G`（LazyVim 默认为空格，再按 Shift+G），即可查看当前缓冲区可用的快捷键。下表列出的是此前缀之后的按键。

无论是否安装 which-key，都可以直接执行 `:GodotTree`、`:GodotRun main` 等命令。未安装时，`:GodotMenu` 会打开内置菜单。如果 `<leader>G` 尚未绑定，也可以用它打开这个菜单。

| 菜单分组 | 按键 |
| --- | --- |
| Project | `po` 打开 Godot 编辑器 · `ph` 检查环境与连接 |
| Editing | `ef` 格式化文件 · `eg` 打开光标处的资源 · `eh` 查看光标处的文档 |
| Scene Tree | `so` 打开场景树 |
| Run（需启用 DAP） | `rm` 运行主场景 · `rc` 运行当前场景 · `rs` 停止 · `ro` 打开输出 |
| Debug（需启用 DAP） | `db` 切换断点 · `dm` 调试主场景 · `dg` 继续执行 |

### 编辑场景树

在场景树缓冲区中，按 `R` 重命名选中的节点，按 `d` 确认删除该节点及其子树，或按 `m` 选择同一场景中的新父节点。移动后的节点会追加到新父节点的子节点列表末尾。按 `u` 可撤销 Godot 中的场景编辑。

这些操作需要安装 Bridge 插件并运行带图形渲染器的 Godot 编辑器。只支持本地可编辑的非根节点。涉及继承或实例边界、无法保留场景所有权或无法安全保留场景引用时，操作会被拒绝。节点名称必须合法，且不能与同级节点重名。若场景在 Neovim 中有未保存的修改，或与磁盘上的文件冲突，Bridge 也会拒绝编辑。它不会改写 GDScript 中的节点路径。移动会保留 `Node2D` 和 `Node3D` 的全局变换，但容器布局仍可能改变子节点在屏幕上的位置。

## 可选工具

- **脚本与着色器语法高亮** — 可用 `:TSInstall gdscript gdshader` 添加对应的 Tree-sitter 解析器。
- **其他平台** — 场景树使用 `godot_resource` 解析器，运行和调试使用 `nvim-dap`，着色器语言服务使用 `gdshader-lsp`，格式化使用 `gdscript-formatter` 和 `clang-format`。
- **Godot 场景与工具栏图标** — 运行 `scripts/install-windows-font.ps1`，将 `Godot Scene Icons` 加入 Windows Terminal 字体列表，在插件配置中设置 `opts.scene_icons = "godot"`，然后重开终端。
