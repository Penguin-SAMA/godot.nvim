# Windows scene parser

`godot_resource.dll` contains the x86-64 Tree-sitter parser for Godot scenes and resources. It exports `tree_sitter_godot_resource` and uses Tree-sitter ABI 14. The installer verifies its SHA-256 before copying it into Neovim’s data directory.

The parser and external scanner come from [tree-sitter-godot-resource v0.7.0](https://github.com/PrestonKnopp/tree-sitter-godot-resource/tree/a1a7295b376fbd2531601f4ffff191b031ffc795). The upstream [MIT license](godot_resource-LICENSE.txt) accompanies the binary.

To reproduce it, check out commit `a1a7295b376fbd2531601f4ffff191b031ffc795` and run this command from the grammar root with MSYS2 UCRT64 GCC 16.2.0 (Rev4).

```powershell
gcc -std=c11 -Os -shared -s -Isrc "-Wl,--no-insert-timestamp" src/parser.c src/scanner.c -o ../godot_resource.dll
```

The resulting 19,456-byte DLL has SHA-256 `c4a2ce7c24914594dd545fdf963ebbb95582df79c59f1bd307fc5b0775833fd7`.
