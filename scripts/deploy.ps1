<#
.SYNOPSIS
  Assemble and deploy BeamComp into a BeamMP server's Resources/ layout.

.DESCRIPTION
  Stages the client mod (client/ + the shared envelope), zips it to
  Resources/Client/BeamComp.zip, and copies the server plugin (server/ + the
  shared envelope) to Resources/Server/BeamComp/. Idempotent: existing outputs
  are replaced on each run. The committed client/ and server/ trees are never
  modified -- all duplication happens in a staging directory and the target.

.PARAMETER Target
  Path to the BeamMP server root (the folder that contains, or will contain, a
  Resources/ directory). Required -- no default. Example:
    .\scripts\deploy.ps1 -Target 'C:\BeamMP-Server'

.PARAMETER StagingDir
  Optional staging directory. Defaults to a unique temp folder, removed on exit.

.PARAMETER Clean
  Remove the existing Resources/Server/BeamComp folder and
  Resources/Client/BeamComp.zip before deploying.

.EXAMPLE
  .\scripts\deploy.ps1 -Target 'C:\BeamMP-Server'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Target,

    [string]$StagingDir,

    [switch]$Clean
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function New-Dir([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

# Zip a directory's contents with forward-slash entry separators.
# (PowerShell 5.1's Compress-Archive writes backslashes, which a strict mod
# loader may fail to split into directories -- BeamNG mods require '/'.)
function New-ModZip([string]$SourceDir, [string]$ZipPath) {
    Add-Type -AssemblyName System.IO.Compression | Out-Null            # ZipArchive, ZipArchiveMode
    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null # ZipFile, ZipFileExtensions
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

# Repo root is the parent of this script's folder.
$repoRoot  = Split-Path -Parent $PSScriptRoot
$clientDir = Join-Path $repoRoot 'client'
$serverDir = Join-Path $repoRoot 'server'
$envelope  = Join-Path $repoRoot 'shared\envelope.lua'

foreach ($p in @($clientDir, $serverDir, $envelope)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "Missing repo path: $p" }
}

# Target Resources/ paths.
$resourcesDir = Join-Path $Target 'Resources'
$serverOut    = Join-Path $resourcesDir 'Server\BeamComp'
$clientOutDir = Join-Path $resourcesDir 'Client'
$clientZip    = Join-Path $clientOutDir 'BeamComp.zip'

# Staging (own a temp dir unless the caller supplied one).
$ownStaging = $false
if ([string]::IsNullOrWhiteSpace($StagingDir)) {
    $StagingDir = Join-Path ([System.IO.Path]::GetTempPath()) ("beamcomp_deploy_" + [Guid]::NewGuid().ToString('N'))
    $ownStaging = $true
}
$stageClient = Join-Path $StagingDir 'client'

try {
    if ($Clean) {
        if (Test-Path -LiteralPath $serverOut) { Remove-Item -LiteralPath $serverOut -Recurse -Force }
        if (Test-Path -LiteralPath $clientZip) { Remove-Item -LiteralPath $clientZip -Force }
    }

    # --- Stage and zip the client mod ---
    if (Test-Path -LiteralPath $stageClient) { Remove-Item -LiteralPath $stageClient -Recurse -Force }
    New-Dir $stageClient
    Copy-Item -Path (Join-Path $clientDir '*') -Destination $stageClient -Recurse -Force

    $geBeamcomp = Join-Path $stageClient 'lua\ge\extensions\beamcomp'
    New-Dir $geBeamcomp
    Copy-Item -LiteralPath $envelope -Destination (Join-Path $geBeamcomp 'envelope.lua') -Force

    New-Dir $clientOutDir
    # Zip the staged contents so the archive root is the mod tree (lua/, ui/).
    New-ModZip -SourceDir $stageClient -ZipPath $clientZip

    # --- Deploy the server plugin ---
    # beamcomp.grids.json is runtime data the in-game editor writes (named grids + per-race defaults),
    # not source. Preserve an existing one across the deploy (which otherwise wipes the folder and
    # restores the empty repo seed), so authored grids survive a redeploy. Copy the file out byte-for-byte
    # before the wipe and back after, rather than letting the repo seed overwrite it.
    $gridsTarget = Join-Path $serverOut 'beamcomp.grids.json'
    $gridsBackup = $null
    if (Test-Path -LiteralPath $gridsTarget) {
        $gridsBackup = Join-Path ([System.IO.Path]::GetTempPath()) ("beamcomp_grids_" + [Guid]::NewGuid().ToString('N') + ".json")
        Copy-Item -LiteralPath $gridsTarget -Destination $gridsBackup -Force
    }

    # beamcomp.records.json is the same class of runtime data (accumulated best times the plugin writes
    # at each race finish, ADR-0027). Preserve it identically, or a redeploy resets every record to the
    # empty repo seed.
    $recordsTarget = Join-Path $serverOut 'beamcomp.records.json'
    $recordsBackup = $null
    if (Test-Path -LiteralPath $recordsTarget) {
        $recordsBackup = Join-Path ([System.IO.Path]::GetTempPath()) ("beamcomp_records_" + [Guid]::NewGuid().ToString('N') + ".json")
        Copy-Item -LiteralPath $recordsTarget -Destination $recordsBackup -Force
    }

    # beamcomp.presets.json is the same class of runtime data (named race-setup presets the panel writes,
    # ADR-0037 amendment). Preserve it identically, or a redeploy resets every saved preset to the empty
    # repo seed.
    $presetsTarget = Join-Path $serverOut 'beamcomp.presets.json'
    $presetsBackup = $null
    if (Test-Path -LiteralPath $presetsTarget) {
        $presetsBackup = Join-Path ([System.IO.Path]::GetTempPath()) ("beamcomp_presets_" + [Guid]::NewGuid().ToString('N') + ".json")
        Copy-Item -LiteralPath $presetsTarget -Destination $presetsBackup -Force
    }

    if (Test-Path -LiteralPath $serverOut) { Remove-Item -LiteralPath $serverOut -Recurse -Force }
    New-Dir $serverOut
    Copy-Item -Path (Join-Path $serverDir '*') -Destination $serverOut -Recurse -Force
    Copy-Item -LiteralPath $envelope -Destination (Join-Path $serverOut 'envelope.lua') -Force

    if ($null -ne $gridsBackup) {
        Copy-Item -LiteralPath $gridsBackup -Destination $gridsTarget -Force
        Remove-Item -LiteralPath $gridsBackup -Force
        Write-Host "  preserved existing beamcomp.grids.json (editor-authored grids kept)"
    }

    if ($null -ne $recordsBackup) {
        Copy-Item -LiteralPath $recordsBackup -Destination $recordsTarget -Force
        Remove-Item -LiteralPath $recordsBackup -Force
        Write-Host "  preserved existing beamcomp.records.json (accumulated best times kept)"
    }

    if ($null -ne $presetsBackup) {
        Copy-Item -LiteralPath $presetsBackup -Destination $presetsTarget -Force
        Remove-Item -LiteralPath $presetsBackup -Force
        Write-Host "  preserved existing beamcomp.presets.json (saved race-setup presets kept)"
    }

    Write-Host "BeamComp deployed to: $resourcesDir"
    Write-Host "  client zip -> $clientZip"
    Write-Host "  server     -> $serverOut"
}
finally {
    if ($ownStaging -and (Test-Path -LiteralPath $StagingDir)) {
        Remove-Item -LiteralPath $StagingDir -Recurse -Force
    }
}
