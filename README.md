# godot.nvim

在 Neovim 编写 GDScript、查看场景、调试游戏。打开项目中的 `.gd` 时，插件按需连接 Godot 官方语言服务。单独打开 `.tscn` 或着色器可以直接工作。首版的验收环境为 Windows、Neovim 0.12.5 和 Godot 4.7.2。[下载 Godot 4.7.2](https://godotengine.org/download/archive/4.7.2-stable/)

## 安装与第一次使用

将本仓库放进 Neovim 的原生包目录 `stdpath("data")/site/pack/local/start/godot.nvim`，或用 lazy.nvim 加载本地仓库。下面是本地开发和 LazyVim 都能使用的插件配置，替换为自己的路径即可。

```lua
return {
  {
    dir = vim.fn.expand("~/src/godot.nvim"),
    name = "godot.nvim",
    main = "godot",
    lazy = false,
    dependencies = { "folke/which-key.nvim" }, -- LazyVim 已包含 which-key
    opts = {},
  },
}
```

原生包安装后，默认使用 PATH 中的 `godot`。需要选择引擎版本时，在 `init.lua` 调用 `require("godot").setup({ executable = [[引擎的完整路径]] })`。也可以在启动 Neovim 前设置环境变量 `GODOT_NVIM_EXECUTABLE`。

1. 打开含 `project.godot` 的项目里的一个 `.gd` 文件，执行 `:checkhealth godot`。首次导入项目时，Godot 需要一些时间建立脚本索引。
2. 在脚本中输入 `player.` 或节点路径进行补全。用 `gd` 跳到定义，`grr` 查引用，`grn` 重命名。在引擎类或成员上执行 `:GodotDoc` 可查官方文档。
3. 打开 `.tscn`，在 `ExtResource("…")` 上按 `gd` 跳到资源。执行 `:GodotTree` 查看节点树。需要操作节点时，运行 `:GodotBridgeInstall`，再运行 `:GodotOpen`。如果安装桥接时图形编辑器已经打开，请重开该项目的编辑器。
4. 安装 `nvim-dap` 后，在脚本中按 `<leader>Gdb` 切换当前行断点，按 `<leader>Gdm` 调试主场景。命中断点后，用 `:GodotDebugAction frames` 查看调用栈，按 `<leader>Gdg` 继续。按 `<leader>Gro` 查看输出，在带源码位置的错误行按回车。

### 按功能安装依赖

| 功能 | 所需组件 |
| --- | --- |
| GDScript 补全、重命名、查引用 | Godot 编辑器可执行文件 |
| GDScript 语义高亮、场景文件补全和节点树 | Tree-sitter 的 `gdscript`、`godot_resource` 解析器。使用 nvim-treesitter 时执行 `:TSInstall gdscript godot_resource gdshader`，同时安装着色器高亮支持。 |
| 着色器补全、悬停、诊断 | `gdshader-lsp`，插件以 stdio 启动服务。[gdshader-lsp](https://github.com/GodOfAvacyn/gdshader-lsp) |
| 脚本与着色器格式化 | `gdscript-formatter` 和 LLVM 的 `clang-format`。[GDScript formatter](https://github.com/GDQuest/GDScript-formatter) |
| 运行与调试 | 将 `mfussenegger/nvim-dap` 加入 Neovim 插件列表。[nvim-dap](https://github.com/mfussenegger/nvim-dap) |

`setup()` 接受 `shader_lsp`、`gdscript_formatter`、`clang_format` 的可执行文件路径，默认值与上表中的命令名相同。项目中的 GDScript 上下文由 Godot 提供。若已有另一款插件也为 GDScript 启动语言服务，迁移时请关闭它的 Godot LSP 配置，避免同一缓冲区出现重复候选项。

## 快捷键

在 LazyVim 的普通模式按 **空格**，等 which-key 的快捷键提示出现，选择 **大写 G · Godot.nvim**。打开 Godot 项目文件时会显示五个分组。按 `r` 查看运行操作，再按 `m` 运行主场景。也可以直接连按 **空格 → Shift+g → r → m**，或按 `Esc` 取消。用 `:verbose nmap <leader>Grm` 可以查看当前缓冲区的实际绑定。

使用自定义 leader 时，将空格换成自己的 leader。独立安装且未使用 which-key 时，`<leader>G` 打开插件自带菜单，可用方向键或 `j` / `k` 移动、回车选择、退格返回。

下表中的按键接在 `<leader>G` 后。例如，`so` 是 `<leader>Gso`。

| 分组 | 按键与功能 |
| --- | --- |
| `p` 项目与连接 | `ph` 检查环境与连接，`po` 打开 Godot 编辑器 |
| `e` 编辑与导航 | `ef` 格式化脚本或着色器，`eg` 打开光标处的资源，`eh` 查光标处的官方文档 |
| `s` 场景树 | `so` 打开当前场景树 |
| `r` 运行与输出 | `rm` 运行主场景，`rc` 运行当前场景，`rs` 停止游戏或调试，`ro` 打开输出面板 |
| `d` 调试 | `db` 在 GDScript 中切换断点，`dm` 调试主场景，`dg` 在暂停后继续 |

跳转定义、悬停、查引用、重命名和诊断沿用编辑器的按键。安装桥接用 `:GodotBridgeInstall`，重连用 `:GodotReconnect`，指定场景可直接输入 `:GodotRun res://scenes/example.tscn`。在命令行输入 `:Godot` 后按 Tab 可以补全插件命令。

独立打开脚本、场景或着色器也会显示五个分组。脚本和着色器可直接格式化，查官方文档也可在项目外使用。标有「需项目」的操作要求当前文件所在目录或上级目录中有 `project.godot`。在其他类型的非项目文件中，`<leader>Gph` 可以检查环境。

要从树插入节点路径，先在分屏中打开场景挂载的脚本并放好光标，再切到树上选中节点，按 `i` 插入路径，按 `I` 生成带类型的 `@onready` 声明。

插件使用加载时的 `vim.g.mapleader`，Neovim 默认值为反斜杠。如果你已经为 `<leader>G` 设置了映射，可用 `:GodotMenu` 打开菜单，或将这个命令绑定到自己的按键。

## 命令

| 命令 | 用途 |
| --- | --- |
| `:GodotMenu` | 打开当前窗口的 Godot.nvim 快捷菜单。 |
| `:checkhealth godot`、`:GodotReconnect` | 查看当前项目根目录、引擎版本、服务端口和工具状态；重新连接当前项目的 GDScript 缓冲区。 |
| `:GodotDoc [类名或类名.成员]` | 查看光标下符号或指定符号的引擎文档。API 数据从选定的引擎导出，缓存在本机。 |
| `:GodotFormat` | 格式化当前脚本或着色器，保留 shader 的 include 顺序。 |
| `:GodotResource [路径]` | 打开光标下或指定的 `res://`、`uid://`。Godot 需要先导入项目才能识别 UID。 |
| `:GodotBridgeInstall`、`:GodotOpen` | 将随插件提供的桥接安装到当前项目并启用；打开或复用该项目的图形编辑器。 |
| `:GodotTree [场景]` | 从 `.tscn` 查看当前场景，从 `.gd` 查看挂载该脚本的场景。多个场景挂载同一脚本时可选择其一。 |
| `:GodotExternalEditor` | 主动将 Godot 的外部脚本编辑器设置为 Neovim。这是 Godot 的全局设置，启动器会按文件所属项目选择 Neovim 窗口。 |
| `:GodotRun [场景]`、`:GodotDebug [场景]` | 默认运行主场景。也接受 `main`、`current` 和 `res://scenes/example.tscn`。当前缓冲区是场景文件时，`current` 使用该文件；在脚本里则使用图形编辑器的当前场景。 |
| `:GodotDebugAction 操作` | `frames` 查看调用栈，`step_over` 单步跳过，`step_into` 单步进入，`step_out` 单步跳出，`continue` 继续，`toggle_breakpoint` 切换断点。操作名支持 Tab 补全。 |
| `:GodotStop`、`:GodotOutput` | 停止当前项目的游戏，或打开该项目的输出面板。 |

在 LazyVim 中，场景树与 Snacks 文件树共用左侧栏，沿用文件树的宽度。按 `<leader>Gso` 切到场景树，再次打开场景会复用这一栏。按 `q` 关闭场景树，如果之前显示了文件树，会恢复文件树。找不到脚本挂载的场景时，提示会指出脚本名称。

点击节点前的箭头或按 `za` 展开、折叠分支。也可以用 `h` / `←` 折叠或移到父节点，用 `l` / `→` 展开或移到子节点。回车打开选中节点挂载的脚本。

### 使用 Godot 编辑器的节点图标

插件附带从 Godot 4.7.2 官方 SVG 生成的彩色字体，采用深色编辑器、图标饱和度 `2.0` 的配色。`Timer` 显示沙漏，`Area2D` 显示带四角的方框，`ColorRect` 保留边框和内部的三种颜色。场景树可以离线显示这些图标。[Godot 4.7.2 编辑器图标](https://github.com/godotengine/godot/tree/4.7.2-stable/editor/icons)

1. 在插件目录运行 `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-windows-font.ps1`，为当前用户安装字体。
2. 在 Windows Terminal 1.21 或更新版本的设置中，将 `Godot Scene Icons` 加到所用配置的字体列表末尾。例如，已有 Maple Mono 的用户可将 `font.face` 设为 `"Maple Mono NF CN, Godot Scene Icons"`。保留「全彩图形」选项（`font.colorGlyphs`）的默认开启状态。[Windows Terminal 字体回退](https://devblogs.microsoft.com/commandline/windows-terminal-preview-1-21-release/)
3. 在 LazyVim 的插件 `opts` 或 `require("godot").setup()` 中设置 `scene_icons = "godot"`。重新打开 Windows Terminal 和 Neovim，在场景里按 `<leader>Gso`。

未安装专用字体的终端可沿用默认的 `scene_icons = "nerd"`。使用浅色主题、自定义编辑器配色或脚本的 `@icon` 时，内置图标按上述深色配色和节点的原生类型显示。

在节点树中，`a` 添加子节点，`s` 挂载或创建脚本，`c` 连接信号，`u` 撤销，`r` 刷新。启用 Neovim 鼠标后，将节点拖到同一场景挂载的脚本中即可插入相对路径，按住 Ctrl 拖动则生成类成员 `@onready` 声明。节点增改与场景保存都交给图形编辑器。若 Neovim 中有相关未保存的修改，先处理提示的缓冲区。

后台编辑器按项目共享，最后一个使用它的 Neovim 正常退出时回收。Windows 上会核对监听端口的进程归属。手动启动的 Godot 可通过桥接登记，或通过带绝对项目路径的编辑器启动参数识别。`:GodotOpen` 打开的图形窗口由用户关闭。

如果场景在 Godot 打开期间已从 Neovim 保存，先在 Godot 处理外部改动，再继续节点操作。更换节点原有的脚本时，请在 Godot 中核对该节点的导出属性。侧栏的挂载命令适用于没有脚本的节点，重复选择同一脚本会保留现有属性。

如果场景操作之后又产生了全局或远程检查器操作，侧栏无法确认下一次撤销的归属时会提示打开 Godot 的 History 面板。选择 Scene only 即可针对当前场景撤销。

## 已有 blink.cmp 或 conform.nvim 的配置

blink.cmp 的 `lsp` 来源会收到插件提供的候选项。将 `native_completion = false` 加入 godot.nvim 的 `opts`，即可明确由 blink 显示菜单。使用 Neovim 自带菜单时保留默认值。

若使用 conform.nvim 管理保存时格式化，可将以下字段并入它的 `opts`。手动格式化仍可执行 `:GodotFormat`。

```lua
formatters_by_ft = {
  gdscript = { "gdscript-formatter" },
  gdshader = { "godot_shader_format" },
},
formatters = {
  ["gdscript-formatter"] = { args = { "--stdout" }, stdin = true },
  godot_shader_format = {
    command = "clang-format",
    args = {
      "--assume-filename=shader.cpp",
      "--style={BasedOnStyle: LLVM, UseTab: Always, IndentWidth: 4, TabWidth: 4, SortIncludes: Never}",
    },
    stdin = true,
  },
},
```

## 运行验收测试

从 Git 安装后，可以在有主场景的 Godot 项目里打开一个已挂载的脚本，用 `<leader>Gso` 查看对应场景树，用 `<leader>Grm` 运行主场景，再用 `<leader>Gro` 查看输出。

完整测试脚本和测试项目保存在维护者本地开发工作区的 `tests/` 中。有该目录时，可以在 Windows 桌面用 PowerShell 7 运行下列命令。先安装上表的可执行工具和解析器。若 `godot_resource` 解析器尚未放在 Neovim 的运行时目录，可额外传 `-ResourceParser` 指定其 DLL。测试会复制小型项目，场景和外部编辑器用例会短暂打开窗口。

```powershell
./tests/run.ps1 -Godot (Get-Command godot).Source -Dap "$env:LOCALAPPDATA/nvim-data/lazy/nvim-dap"
```

测试覆盖快捷菜单连按与取消、键盘插入节点路径和声明、干净 Neovim 的实际补全插入、跨文件重命名、双项目连接与回收、场景保存和撤销、真实鼠标拖动、UID 跳转、跨窗口回调、断点重启和运行错误定位。

