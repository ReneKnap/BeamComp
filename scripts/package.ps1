<#
.SYNOPSIS
  Build the BeamComp download that goes out to users.

.DESCRIPTION
  Produces releases/BeamComp-<version>/ and zips it to
  releases/BeamComp-<version>.zip. The zip holds what a server operator needs
  and nothing else:

    README.md          what it is, how to install it, every setting explained
    COMMANDS.md        every chat command, linked from the README
    CHANGELOG.md       what is in this version
    LICENSE            the terms it comes under
    Resources/         drop this into the BeamMP server folder

  The Resources tree is built by deploy.ps1 -- the same code path that puts
  BeamComp on a live server -- so the download cannot drift from what has been
  tested.

  The version is READ from PLUGIN_VERSION in server/main.lua, never passed in,
  so the number on the zip is the number the server reports back with
  /beamcomp. The three ui/modules/apps/*/app.json carry their own copy (BeamNG
  reads them directly) and are checked against it here; a mismatch stops the
  build rather than shipping a package that disagrees with itself.

.PARAMETER SkipZip
  Build the folder but do not create the .zip.

.EXAMPLE
  .\scripts\package.ps1
#>
[CmdletBinding()]
param(
    [switch]$SkipZip
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Zip with forward-slash entry separators. Same reason as New-ModZip in deploy.ps1, and deliberately
# a second copy rather than a shared import: deploy.ps1 has a mandatory parameter, so dot-sourcing it
# would run it. .NET Framework's ZipFile.CreateFromDirectory writes the platform separator, which on
# Windows means backslashes -- a zip that unpacks flat for anyone on macOS, Linux or older 7-Zip.
function New-DownloadZip([string]$SourceDir, [string]$ZipPath) {
    Add-Type -AssemblyName System.IO.Compression | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
    if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }

    $base = (Resolve-Path -LiteralPath $SourceDir).Path.TrimEnd('\', '/')
    $zip = [System.IO.Compression.ZipFile]::Open($ZipPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in Get-ChildItem -LiteralPath $SourceDir -Recurse -File) {
            $entryName = $file.FullName.Substring($base.Length + 1) -replace '\\', '/'
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $file.FullName, $entryName) | Out-Null
        }
    }
    finally {
        $zip.Dispose()
    }
}

$repoRoot   = Split-Path -Parent $PSScriptRoot
$mainLua    = Join-Path $repoRoot 'server\main.lua'
$deploy     = Join-Path $PSScriptRoot 'deploy.ps1'
$releaseDir = Join-Path $repoRoot 'releases'

$docs = @(
    (Join-Path $repoRoot 'README.md'),
    (Join-Path $repoRoot 'COMMANDS.md'),
    (Join-Path $repoRoot 'CHANGELOG.md'),
    (Join-Path $repoRoot 'LICENSE')
)

foreach ($p in @($mainLua, $deploy) + $docs) {
    if (-not (Test-Path -LiteralPath $p)) { throw "Missing repo path: $p" }
}

# --- Version, from the one place it lives ---
$match = Select-String -LiteralPath $mainLua -Pattern '^local PLUGIN_VERSION = "([^"]+)"' | Select-Object -First 1
if ($null -eq $match) {
    throw "Could not read PLUGIN_VERSION from $mainLua -- has the line changed shape?"
}
$version = $match.Matches[0].Groups[1].Value
Write-Host "BeamComp $version"

# The app.json copies are hand-mirrored and drift silently: BeamNG shows their version in the app
# menu, nothing compares them to the plugin, and nobody notices until a user reports two numbers.
foreach ($appJson in (Get-ChildItem -LiteralPath (Join-Path $repoRoot 'client\ui\modules\apps') -Directory |
                      ForEach-Object { Join-Path $_.FullName 'app.json' })) {
    if (-not (Test-Path -LiteralPath $appJson)) { continue }
    $appVersion = (Get-Content -LiteralPath $appJson -Raw | ConvertFrom-Json).version
    if ($appVersion -ne $version) {
        throw "$appJson says version $appVersion, server/main.lua says $version. Set them to the same value."
    }
}

# --- A release built from uncommitted work is a release nobody can rebuild ---
try {
    $dirty = & git -C $repoRoot status --porcelain 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($dirty -join ''))) {
        Write-Host "  note: the working tree has uncommitted changes -- this package cannot be rebuilt from a commit" -ForegroundColor Yellow
    }
} catch {
    # No git, or not a repository. Not a reason to refuse to build.
}

# --- Assemble ---
$packageName = "BeamComp-$version"
$packageDir  = Join-Path $releaseDir $packageName
$zipPath     = Join-Path $releaseDir "$packageName.zip"

if (Test-Path -LiteralPath $packageDir) { Remove-Item -LiteralPath $packageDir -Recurse -Force }
New-Item -ItemType Directory -Path $packageDir -Force | Out-Null

# deploy.ps1 writes <Target>\Resources\{Client,Server}. Into a fresh folder it has nothing to
# preserve, so this is always a clean build.
& $deploy -Target $packageDir | ForEach-Object { Write-Host "  $_" }

foreach ($doc in $docs) {
    Copy-Item -LiteralPath $doc -Destination $packageDir -Force
}

if (-not $SkipZip) {
    New-DownloadZip -SourceDir $packageDir -ZipPath $zipPath
    $sizeMb = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1MB, 2)
    Write-Host ""
    Write-Host "Upload this: $zipPath  ($sizeMb MB)"
} else {
    Write-Host ""
    Write-Host "Package folder: $packageDir"
}
