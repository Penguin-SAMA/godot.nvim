# Installs the bundled icon font for the current Windows user.
[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = 'Stop'
$family = 'Godot Scene Icons'
$source = Get-Item -LiteralPath (Join-Path $PSScriptRoot '..\fonts\GodotSceneIcons.ttf')
$directory = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
# DirectWrite can retain the old character map when a registered TTF is replaced in place.
$hash = (Get-FileHash -LiteralPath $source.FullName).Hash
$destination = Join-Path $directory ("GodotSceneIcons-" + $hash.Substring(0, 16) + ".ttf")
$registry = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
$name = "$family (TrueType)"

if ($PSCmdlet.ShouldProcess($destination, "Install $family for the current user")) {
    [void][IO.Directory]::CreateDirectory($directory)
    $hadFile = Test-Path -LiteralPath $destination
    $sameFile = $hadFile -and
        ($hash -eq (Get-FileHash -LiteralPath $destination).Hash)
    if (-not (Test-Path -LiteralPath $registry)) {
        [void](New-Item -Path $registry)
    }
    $key = Get-Item -LiteralPath $registry
    $registered = $key.GetValue($name, $null, 'DoNotExpandEnvironmentNames')
    if (-not $sameFile -or $registered -ne $destination) {
        if (-not ('GodotSceneFont.Native' -as [type])) {
            Add-Type -Namespace GodotSceneFont -Name Native -MemberDefinition @'
            [System.Runtime.InteropServices.DllImport("gdi32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode, ExactSpelling=true)]
            public static extern int AddFontResourceW(string path);
            [System.Runtime.InteropServices.DllImport("gdi32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode, ExactSpelling=true)]
            public static extern bool RemoveFontResourceW(string path);
            [System.Runtime.InteropServices.DllImport("user32.dll")]
            public static extern bool SendNotifyMessageW(System.IntPtr window, uint message, System.UIntPtr wParam, System.IntPtr lParam);
'@
        }
        $stage = Join-Path $directory ([IO.Path]::GetRandomFileName())
        $backup = "$stage.bak"
        $placed = $false
        $updatedRegistration = $false
        $removed = 0
        $oldManaged = $registered -and $registered -ne $destination -and
            ([IO.Path]::GetDirectoryName($registered) -eq $directory) -and
            ([IO.Path]::GetFileName($registered) -match '^GodotSceneIcons(?:-[A-Fa-f0-9]{16})?\.ttf$')
        try {
            if (-not $sameFile) {
                [IO.File]::Copy($source.FullName, $stage)
                if ($hadFile) { [IO.File]::Replace($stage, $destination, $backup) }
                else { [IO.File]::Move($stage, $destination) }
                $placed = $true
            }
            if ($registered -ne $destination) {
                if ($null -ne $registered) { $oldKind = $key.GetValueKind($name) }
                [void](New-ItemProperty -LiteralPath $registry -Name $name -Value $destination -PropertyType String -Force)
                $updatedRegistration = $true
            }
            if ($oldManaged) {
                while ([GodotSceneFont.Native]::RemoveFontResourceW($registered)) { $removed++ }
            }
            if ([GodotSceneFont.Native]::AddFontResourceW($destination) -eq 0) {
                throw "Windows could not load the font at $destination."
            }
        } catch {
            if ($placed) {
                if ($hadFile) { [IO.File]::Replace($backup, $destination, $stage) }
                else { [IO.File]::Delete($destination) }
            }
            if ($updatedRegistration) {
                if ($null -eq $registered) { Remove-ItemProperty -LiteralPath $registry -Name $name }
                else { [void](New-ItemProperty -LiteralPath $registry -Name $name -Value $registered -PropertyType $oldKind -Force) }
            }
            for ($i = 0; $i -lt $removed; $i++) { [void][GodotSceneFont.Native]::AddFontResourceW($registered) }
            throw
        } finally {
            [IO.File]::Delete($stage)
        }
        [IO.File]::Delete($backup)
        if ($oldManaged) {
            try { [IO.File]::Delete($registered) }
            catch [IO.IOException] { Write-Verbose "The previous font file is still in use: $registered" }
            catch [UnauthorizedAccessException] { Write-Verbose "The previous font file is still in use: $registered" }
        }
        # HWND_BROADCAST, WM_FONTCHANGE
        [void][GodotSceneFont.Native]::SendNotifyMessageW([IntPtr]0xffff, 0x001d, [UIntPtr]::Zero, [IntPtr]::Zero)
    }
    Write-Output "$family is installed for the current user."
}

Write-Output @'
In Windows Terminal 1.21 or later, open Settings > Open JSON file.
Append ", Godot Scene Icons" to the existing font.face of your Neovim profile
or its inherited profiles.defaults.font.face. For example:
    "face": "Maple Mono NF CN, Godot Scene Icons"
Reopen Windows Terminal after installing the font.
'@
