<#
.SYNOPSIS
  Sync the shareable DSH configuration/plugins from this repo into the local DSH home.
.DESCRIPTION
  Copies dsh-sync/dsh (settings, agent presets, profiles, plugins) into $DSH_HOME
  (default ~/.dsh), then runs `pnpm install` in each profile directory.

  This script intentionally does NOT delete or overwrite machine-local data such as
  sessions, storages, .credentials.yaml, caches, logs, or node_modules.
.PARAMETER SkipInstall
  Copy files only; do not run pnpm install in the profiles.
.EXAMPLE
  ./install.ps1
.EXAMPLE
  ./install.ps1 -SkipInstall
#>
[CmdletBinding()]
param(
  [switch]$SkipInstall
)

$ErrorActionPreference = 'Stop'

$RepoDsh = Join-Path $PSScriptRoot 'dsh'
if (-not (Test-Path -LiteralPath $RepoDsh)) {
  throw "Cannot find dsh sync source: $RepoDsh"
}

$DshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $HOME '.dsh' }
Write-Host "DSH_HOME = $DshHome"

function Copy-Into {
  param(
    [string]$Source,
    [string]$Destination
  )
  if (-not (Test-Path -LiteralPath $Source)) {
    Write-Warning "Source does not exist, skipped: $Source"
    return
  }
  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  Get-ChildItem -Force -LiteralPath $Source | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force
  }
}

# 1. Copy shareable files. Existing local-only dirs are left in place.
New-Item -ItemType Directory -Force -Path $DshHome | Out-Null
Copy-Item -LiteralPath (Join-Path $RepoDsh 'settings.yaml') -Destination (Join-Path $DshHome 'settings.yaml') -Force
Copy-Into (Join-Path $RepoDsh '.agent-presets') (Join-Path $DshHome '.agent-presets')
Copy-Into (Join-Path $RepoDsh 'plugins') (Join-Path $DshHome 'plugins')
Copy-Into (Join-Path $RepoDsh 'profiles') (Join-Path $DshHome 'profiles')

if ($SkipInstall) {
  Write-Host "Skipped pnpm install (-SkipInstall)."
  Write-Host "Done. Files copied to $DshHome"
  return
}

# 2. Install each profile's dependencies from its own directory.
$pnpm = Get-Command pnpm -ErrorAction SilentlyContinue
if (-not $pnpm) {
  Write-Warning "pnpm not found on PATH; files were copied but dependencies were not installed."
  return
}

$profilesDir = Join-Path $DshHome 'profiles'
Get-ChildItem -Directory -LiteralPath $profilesDir | Sort-Object Name | ForEach-Object {
  $profileDir = $_.FullName
  $pkg = Join-Path $profileDir 'package.json'
  if (-not (Test-Path -LiteralPath $pkg)) { return }
  Write-Host "Installing profile '$($_.Name)' ..."
  Push-Location $profileDir
  try {
    & $pnpm.Source install --no-frozen-lockfile
    if ($LASTEXITCODE -ne 0) {
      Write-Warning "pnpm install failed in $profileDir (exit code $LASTEXITCODE)"
    }
  }
  finally {
    Pop-Location
  }
}

Write-Host "Done. Restart DSH Desktop if it was running."
