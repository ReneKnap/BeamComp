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
    if (Test-Path -LiteralPath $serverOut) { Remove-Item -LiteralPath $serverOut -Recurse -Force }
    New-Dir $serverOut
    Copy-Item -Path (Join-Path $serverDir '*') -Destination $serverOut -Recurse -Force
    Copy-Item -LiteralPath $envelope -Destination (Join-Path $serverOut 'envelope.lua') -Force

    Write-Host "BeamComp deployed to: $resourcesDir"
    Write-Host "  client zip -> $clientZip"
    Write-Host "  server     -> $serverOut"
}
finally {
    if ($ownStaging -and (Test-Path -LiteralPath $StagingDir)) {
        Remove-Item -LiteralPath $StagingDir -Recurse -Force
    }
}
