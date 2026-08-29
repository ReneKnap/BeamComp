<#
.SYNOPSIS
  Assemble and deploy BeamComp into a BeamMP server's Resources/ layout.

.DESCRIPTION
  Stages the client mod (client/ + the shared envelope), zips it to
  Resources/Client/BeamComp.zip, and copies the server plugin (server/ + the
  shared envelope) to Resources/Server/BeamComp/. Idempotent: existing outputs
  are replaced on each run. The committed client/ and server/ trees are never
  modified -- all duplication happens in a staging directory and the target.

  Runtime data the plugin writes into the server folder (named grids, saved
  presets, the per-run records log) is copied out before the folder is wiped and
  put back afterwards, so a redeploy never resets it to the empty repo seed.

  A leftover beamcomp.records.json from the retired aggregate format (ADR-0050)
  is archived to <Target>\BeamComp-Archive\ -- deliberately a sibling of
  Resources\, which the wipe never touches -- and not restored.

.PARAMETER Target
  Path to the BeamMP server root (the folder that contains, or will contain, a
  Resources/ directory). Required -- no default. Example:
    .\scripts\deploy.ps1 -Target 'C:\BeamMP-Server'

.PARAMETER StagingDir
  Optional staging directory. Defaults to a unique temp folder, removed on exit.

.PARAMETER Clean
  Remove Resources/Client/BeamComp.zip before deploying. The server folder is
  wiped on every run anyway -- but only after the runtime data has been copied
  out, which is why -Clean must not delete it up front.

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
    # -Clean must NOT delete $serverOut here. The server folder is wiped further down anyway, but there
    # the wipe happens *after* the runtime data has been copied out; deleting it up front destroyed the
    # data the preserve step was about to save -- and the per-run records log (ADR-0050) is now the only
    # copy of every best time there is.
    if ($Clean) {
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

    # beamcomp.runs.jsonl is the same class of runtime data: the append-only per-run records log the
    # plugin writes at each race end (ADR-0050), and the ONLY copy of every best time and track record
    # there is -- the aggregate is derived from it in RAM and never written back. Preserve it identically,
    # or a redeploy wipes the whole history.
    $runsTarget = Join-Path $serverOut 'beamcomp.runs.jsonl'
    $runsBackup = $null
    if (Test-Path -LiteralPath $runsTarget) {
        $runsBackup = Join-Path ([System.IO.Path]::GetTempPath()) ("beamcomp_runs_" + [Guid]::NewGuid().ToString('N') + ".jsonl")
        Copy-Item -LiteralPath $runsTarget -Destination $runsBackup -Force
    }

    # beamcomp.records.json is the retired aggregate format (ADR-0050 supersedes ADR-0027 section 1/2).
    # Nothing reads or writes it any more, so it must not be restored -- but it holds months of best
    # times, so archive it instead of letting the wipe take it. The archive goes OUTSIDE the deploy
    # target: everything under Resources\Server\BeamComp\ is wiped on every deploy. Timestamped, so a
    # second archive never overwrites the first.
    $legacyRecords = Join-Path $serverOut 'beamcomp.records.json'
    if (Test-Path -LiteralPath $legacyRecords) {
        $archiveDir = Join-Path $Target 'BeamComp-Archive'
        New-Dir $archiveDir
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $archived = Join-Path $archiveDir "beamcomp.records.$stamp.json"
        Copy-Item -LiteralPath $legacyRecords -Destination $archived -Force
        Write-Host "  archived legacy beamcomp.records.json -> $archived"
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

    if ($null -ne $runsBackup) {
        Copy-Item -LiteralPath $runsBackup -Destination $runsTarget -Force
        Remove-Item -LiteralPath $runsBackup -Force
        Write-Host "  preserved existing beamcomp.runs.jsonl (per-run records history kept)"
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
