# Exercise the actual Windows installer using a local archive and an isolated store.
$ErrorActionPreference = 'Stop'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('godot tools test ' + [Guid]::NewGuid())
$tmp = [IO.Path]::GetFullPath($tmp)
$repo = Split-Path -Parent $PSScriptRoot
$scripts = Join-Path $tmp 'scripts'
$store = Join-Path $tmp 'data'
$installer = Join-Path $scripts 'install-windows-tool.ps1'
$manifest = Join-Path $scripts 'dependencies-windows.json'
$zip = Join-Path $tmp 'package.zip'
$jobs = @()
try {
    [void][IO.Directory]::CreateDirectory($scripts)
    Copy-Item -LiteralPath (Join-Path $repo 'scripts/install-windows-tool.ps1') -Destination $installer
    $src = Join-Path $tmp 'package'
    [void][IO.Directory]::CreateDirectory((Join-Path $src 'package-v1/lua'))
    [IO.File]::WriteAllText((Join-Path $src 'package-v1/lua/dap.lua'), 'return {}')
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($src, $zip)
    $pkg = @{ id='dap'; version='1'; bundled='package.zip'; sha256=('0' * 64); format='zip'
              kind='directory'; source='package-v1'; destination='dap'; path='dap' }
    function WriteManifest {
        [IO.File]::WriteAllText($manifest, (@{packages=@($pkg)} | ConvertTo-Json -Depth 5))
    }
    WriteManifest
    $shell = (Get-Command powershell.exe).Source
    $failure = Start-Job -ArgumentList $shell,$installer,$store -ScriptBlock {
        param($shell, $installer, $store)
        $text = & $shell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $installer -Store $store -Id dap -Version 1 2>&1
        [pscustomobject]@{ Code=$LASTEXITCODE; Message=($text | Out-String) }
    }
    $jobs += $failure
    $res = $failure | Wait-Job | Receive-Job
    if ($res.Code -ne 1 -or $res.Message -notmatch 'SHA-256 mismatch') { throw "Wrong hash passed: $($res.Message)" }
    if (@(Get-ChildItem -LiteralPath (Join-Path $store 'dap') -Force).Count -ne 0) { throw 'Failed package was published' }
    $pkg.sha256 = (Get-FileHash -LiteralPath $zip).Hash.ToLowerInvariant()
    WriteManifest
    # Recreate the disk state of an installer terminated during a download.
    $stage = Join-Path $store ('dap/.stage-1-' + $pkg.sha256.Substring(0, 12))
    [void][IO.Directory]::CreateDirectory($stage)
    [IO.File]::WriteAllText((Join-Path $stage 'archive'), 'partial download')
    # Windows can leave the file name behind after an abnormal process exit.
    # An unlocked stale file must still allow the next installer to proceed.
    $lockFile = Join-Path $store ('dap/.lock-1-' + $pkg.sha256.Substring(0, 12))
    [IO.File]::WriteAllText($lockFile, '')
    $workers = @(foreach ($i in 1..2) {
        Start-Job -ArgumentList $installer,$store -ScriptBlock {
            param($installer, $store)
            & $installer -Store $store -Id dap -Version 1
            if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) { throw 'Installer failed' }
        }
    })
    $jobs += $workers
    $workers | Wait-Job | Receive-Job
    $published = @(Get-ChildItem -LiteralPath (Join-Path $store 'dap') -Force)
    if ($published.Count -ne 1) { throw 'Concurrent installers left extra files' }
    $file = Join-Path $published[0].FullName 'dap/lua/dap.lua'
    if ([IO.File]::ReadAllText($file) -ne 'return {}') { throw 'Archive member missing' }
    $mtime = [IO.File]::GetLastWriteTimeUtc($file)
    # The published copy must work without its original package.
    Move-Item -LiteralPath $zip -Destination "$zip.saved"
    & $installer -Store $store -Id dap -Version 1
    if ($mtime -ne [IO.File]::GetLastWriteTimeUtc($file)) { throw 'Changed an already installed release' }
    Move-Item -LiteralPath "$zip.saved" -Destination $zip
    [IO.File]::Delete($file)
    & $installer -Store $store -Id dap -Version 1
    if (![IO.File]::Exists($file)) { throw 'Failed to repair incomplete package' }
    Write-Host 'PASS checksum rejection, interrupted staging recovery, concurrent installation, offline reuse and repair'
} finally {
    $jobs | Remove-Job -Force
    if ([IO.Path]::GetDirectoryName($tmp).TrimEnd('\') -eq [IO.Path]::GetTempPath().TrimEnd('\') -and
        [IO.Path]::GetFileName($tmp) -like 'godot tools test *' -and (Test-Path -LiteralPath $tmp)) {
        Remove-Item -LiteralPath $tmp -Recurse -Force
    }
}
