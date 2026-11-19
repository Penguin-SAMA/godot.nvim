# Bridge structural integration fixture

Run against a scratch project: the fixture intentionally changes, saves, and undoes scene edits, and appends an external change to `base.tscn` to exercise the disk-conflict guard. Use the Godot console executable with a graphical session (not `--headless`). From the repository root in PowerShell:

```powershell
$Godot = 'C:/path/to/Godot_win64_console.exe'
& $Godot --version
$project = Join-Path $env:TEMP ('bridge-structure-' + [guid]::NewGuid())
Copy-Item tests/scene_tree $project -Recurse
Copy-Item addons/nvim_bridge "$project/addons/" -Recurse
& $Godot --editor --path $project --quit-after 500
```

Expect `Scene structure fixture failures: 0` and exit 0. If the marker is missing, the suite did not complete, even if the editor exits 0. The fixture invokes the production dispatcher and editor undo/save path directly; it does not exercise the TCP transport or Neovim UI. Fresh deserialization from disk checks the saved result and the saved undo.

To test the Neovim mutation hooks independently of Godot, run `nvim --headless -u NONE -l tests/scene_tree_bridge.lua` from the repository root. The test uses a temporary project and a loopback bridge peer to check outgoing dirty-buffer metadata and post-response buffer reloads.

For the installer check, copy the fixture to a separate scratch project without the bundled add-on, set `BRIDGE_TEST_PROJECT` to that project and `BRIDGE_TEST_MODE` to `fresh`, then run `nvim --headless -u NONE --cmd 'set rtp+=.' -l tests/scene_tree/install.lua`. To test upgrading, prepopulate the scratch project's add-on with the previous distribution instead and use mode `upgrade`.
