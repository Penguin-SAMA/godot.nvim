# Publish one pinned package under Neovim's data directory.
param(
    [Parameter(Mandatory)][string]$Store,
    [Parameter(Mandatory)][string]$Id,
    [Parameter(Mandatory)][string]$Version
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# Neovim may inherit module paths from a different PowerShell edition.
$env:PSModulePath = Join-Path $PSHOME 'Modules'

function ChildPath([string]$ParentDir, [string]$RelativePath) {
    $parent = [IO.Path]::GetFullPath($ParentDir).TrimEnd('\', '/')
    $child = [IO.Path]::GetFullPath([IO.Path]::Combine($parent, $RelativePath))
    if (!$child.StartsWith($parent + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path outside package directory: $RelativePath"
    }
    return $child
}

function IsPublished([string]$Directory) {
    $marker = Join-Path $Directory 'installed.json'
    if (!(Test-Path -LiteralPath $marker -PathType Leaf)) { return $false }
    try { $receipt = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json }
    catch { return $false }
    return ($receipt.sha256 -eq $pkg.sha256 -and [IO.File]::Exists((ChildPath $Directory $required)))
}

try {
    $manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'dependencies-windows.json') -Raw | ConvertFrom-Json
    $matches = @($manifest.packages | Where-Object { $_.id -ceq $Id -and $_.version -ceq $Version })
    if ($matches.Count -ne 1) { throw "Unknown package: $Id $Version" }
    $pkg = $matches[0]
    if ($pkg.sha256 -notmatch '^[0-9a-fA-F]{64}$') { throw "Missing SHA-256 pin for $Id $Version" }
    $required = $pkg.path
    if ($Id -eq 'dap') { $required = Join-Path $required 'lua/dap.lua' }
    $base = ChildPath $Store $Id
    $release = $Version + '-' + $pkg.sha256.Substring(0, 12)
    $final = ChildPath $base $release
    $stage = ChildPath $base ('.stage-' + $release)
    [void][IO.Directory]::CreateDirectory($base)

    # Lock the actual store, including when two instances address it through
    # different Windows path aliases. The OS closes the handle after a crash.
    $lockFile = ChildPath $base ('.lock-' + $release)
    $deadline = [DateTime]::UtcNow.AddMinutes(3)
    $lock = $null
    do {
        try {
            $lock = [IO.FileStream]::new($lockFile, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite,
                [IO.FileShare]::None, 1, [IO.FileOptions]::DeleteOnClose)
        } catch [IO.IOException] {
            if (($_.Exception.HResult -band 0xFFFF) -notin 32,33) { throw }
            if ([DateTime]::UtcNow -ge $deadline) { throw "Timed out waiting for another $Id installer" }
            Start-Sleep -Milliseconds 200
        }
    } until ($lock)
    try {
        if (IsPublished $final) { return }
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
        [void][IO.Directory]::CreateDirectory($stage)
        $archive = Join-Path $stage 'archive'
        if ($pkg.bundled) {
            $repo = Split-Path -Parent $PSScriptRoot
            [IO.File]::Copy((ChildPath $repo $pkg.bundled), $archive)
        } else {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -UseBasicParsing -Uri $pkg.url -OutFile $archive -TimeoutSec 120
        }
        if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $pkg.sha256) {
            throw "SHA-256 mismatch for $Id $Version"
        }
        $publish = Join-Path $stage 'publish'
        $destination = ChildPath $publish $pkg.destination
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
        if ($pkg.format -eq 'zip') {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            # Strip upstream archive prefixes before writing to disk (Windows MAX_PATH).
            $zip = [IO.Compression.ZipFile]::OpenRead($archive)
            try {
                $prefix = $pkg.source.TrimEnd('/') + '/'
                foreach ($entry in $zip.Entries) {
                    $name = $entry.FullName.Replace('\', '/')
                    if ($pkg.kind -eq 'directory') {
                        if (!$name.StartsWith($prefix, [StringComparison]::Ordinal) -or $name.EndsWith('/')) { continue }
                        $path = ChildPath $destination $name.Substring($prefix.Length)
                        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
                    } else {
                        if ($name -cne $pkg.source) { continue }
                        $path = $destination
                    }
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $path)
                }
            } finally { $zip.Dispose() }
        } elseif ($pkg.format -eq 'file') { [IO.File]::Move($archive, $destination) }
        else { throw "Unsupported package format: $($pkg.format)" }
        if (![IO.File]::Exists((ChildPath $publish $required))) { throw "Package is missing $required" }
        [IO.File]::WriteAllText((Join-Path $publish 'installed.json'), (@{sha256=$pkg.sha256} | ConvertTo-Json -Compress))
        if ([IO.Directory]::Exists($final)) { [IO.Directory]::Move($final, (Join-Path $stage 'incomplete')) }
        [IO.Directory]::Move($publish, $final)
    } finally {
        try {
            if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
        } finally { $lock.Dispose() }
    }
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
