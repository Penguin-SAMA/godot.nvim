# Godot Scene Icons

`GodotSceneIcons.ttf` contains 254 original editor icons from Godot 4.7.2. The Lua map covers all 284 documented node classes and PackedScene. A class without its own SVG uses the nearest ancestor with an icon.

The outlines come from the editor and module SVGs in the Godot source release. The palette matches the Modern dark editor at icon saturation 2.0, including its success and error colors. ColorRect retains its four separate colors. The palette is embedded in the font, so changing a Godot theme or Neovim highlight does not recolor it.

The font uses TrueType outlines, COLR version 0 and CPAL version 0. Every icon has a square 1-em advance. The font maps only its own supplementary private-use characters, U+F4000 through U+F40FD. RootMotionView's radial opacity gradient uses 48 nested vector bands. At small sizes each terminal's text renderer determines pixel coverage and antialiasing.

The artwork is distributed under Godot's MIT license. [Godot 4.7.2 source release](https://github.com/godotengine/godot/releases/tag/4.7.2-stable) · [Upstream editor icons](https://github.com/godotengine/godot/tree/4.7.2-stable/editor/icons) · [License](GODOT-LICENSE.txt)

## Rebuild

From the plugin root, use Python 3.12 in a virtual environment and install the build dependencies.

```sh
python -m pip install -r fonts/requirements.txt
python fonts/generate.py
```

The script downloads the upstream source archive, verifies its SHA-256 digest, reads class ancestry from the release's XML documentation, then generates the font, Lua map and license. To use a previously downloaded release archive, pass `--archive /path/to/godot-4.7.2-stable.tar.xz`. Pass `--saturation 1.0` for the original SVG colors with the editor's success and error substitutions.
