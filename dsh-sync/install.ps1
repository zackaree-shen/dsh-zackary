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
.PARAMETER SkipWebService
  Do not deploy the standalone web server (logon task + Desktop shortcut).
.PARAMETER SkipCli
  Do not install the global @deepseek-ai/dsh CLI when it is missing.
.PARAMETER Port
  Port for the standalone web server. Default 43120.
.PARAMETER DshVersion
  Version of @deepseek-ai/dsh to install globally when missing.
.EXAMPLE
  ./install.ps1
.EXAMPLE
  ./install.ps1 -SkipInstall
.EXAMPLE
  ./install.ps1 -Port 3080
#>
[CmdletBinding()]
param(
  [switch]$SkipInstall,
  [switch]$SkipWebService,
  [switch]$SkipCli,
  [int]$Port = 43120,
  [string]$DshVersion = '0.1.0-rc.6'
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
$skinActive = Join-Path $RepoDsh 'skin-center-active.json'
if (Test-Path -LiteralPath $skinActive) {
  Copy-Item -LiteralPath $skinActive -Destination (Join-Path $DshHome 'skin-center-active.json') -Force
}
Copy-Into (Join-Path $RepoDsh '.agent-presets') (Join-Path $DshHome '.agent-presets')
Copy-Into (Join-Path $RepoDsh 'plugins') (Join-Path $DshHome 'plugins')
Copy-Into (Join-Path $RepoDsh 'profiles') (Join-Path $DshHome 'profiles')
# 1b0. Sync skin-center user skins ($DSH_HOME/skins/<id>/) so custom skins
#      (e.g. the qq2006 port) are selectable in the skin center on every machine.
Copy-Into (Join-Path $RepoDsh 'skins') (Join-Path $DshHome 'skins')

# 1a. Install the dsh-sync skill into the user-level skill catalog so every
#     machine (and every DSH endpoint on it) can load it.
$SkillRepo = Join-Path $PSScriptRoot '..\.agents\skills'
$SkillDest = Join-Path $HOME '.agents\skills'
if (Test-Path -LiteralPath (Join-Path $SkillRepo 'dsh-sync\SKILL.md')) {
  New-Item -ItemType Directory -Force -Path $SkillDest | Out-Null
  Copy-Into (Join-Path $SkillRepo 'dsh-sync') (Join-Path $SkillDest 'dsh-sync')
  Write-Host "dsh-sync skill installed to $SkillDest\dsh-sync"
} else {
  Write-Warning "dsh-sync skill source not found in repo: $SkillRepo\dsh-sync"
}

# 1a2. Install the pre-commit hook so skill edits auto-sync back into the repo
#      on every commit (no need to remember running export for the skill).
$HookSrc = Join-Path $PSScriptRoot 'hooks\pre-commit'
$RepoDotGit = Join-Path $PSScriptRoot '..\.git'
if (Test-Path -LiteralPath $HookSrc) {
  if (Test-Path -LiteralPath $RepoDotGit) {
    $HookDest = Join-Path $RepoDotGit 'hooks\pre-commit'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $HookDest) | Out-Null
    Copy-Item -LiteralPath $HookSrc -Destination $HookDest -Force
    Write-Host "dsh-sync pre-commit hook installed to $HookDest"
  } else {
    Write-Warning "No .git directory found; skipped installing pre-commit hook: $RepoDotGit"
  }
} else {
  Write-Warning "Hook source not found: $HookSrc"
}

# 1b. Clear the recovery-page "disable" state so previously disabled bundles
#     (written to the Electron userData plugin-management state, NOT ~/.dsh) can
#     never keep all plugins off after a sync. Only touches profiles that exist
#     in this DSH home; safe to run while DSH is closed (recommended anyway).
function Clear-DisabledBundles {
  $candidates = @(
    (Join-Path $env:APPDATA 'DSH Desktop\plugin-management\state.json')
  )
  foreach ($stateFile in $candidates) {
    if (-not (Test-Path -LiteralPath $stateFile)) { continue }
    try {
      $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
    } catch {
      Write-Warning "Could not read plugin-management state, skipped: $stateFile"
      continue
    }
    $localProfiles = @(Get-ChildItem -Directory -LiteralPath (Join-Path $DshHome 'profiles') |
      Where-Object { $_.Name -ne 'node_modules' } | ForEach-Object { $_.Name })
    $changed = $false
    foreach ($profile in @($state.profiles)) {
      if ($localProfiles -contains $profile.profileName) {
        $disabled = @($profile.disabledBundles)
        if ($disabled.Count -gt 0) {
          Write-Host "Re-enabling $($disabled.Count) disabled bundle(s) for profile '$($profile.profileName)': $($disabled -join ', ')"
          $profile.disabledBundles = @()
          $changed = $true
        }
      }
    }
    if ($changed) {
      $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
      $json = $state | ConvertTo-Json -Depth 10
      [System.IO.File]::WriteAllText($stateFile, $json, $utf8NoBom)
      Write-Host "Cleared disabled-bundle state in $stateFile"
    } else {
      Write-Host "No disabled bundles to re-enable in $stateFile"
    }
  }
}
Clear-DisabledBundles

# 1c. Standalone runtime wiring for `dsh web` (no DSH Desktop needed).
#     1c0. The global CLI must exist.
if (-not $SkipCli) {
  $dshCmd = Get-Command dsh -ErrorAction SilentlyContinue
  if (-not $dshCmd) {
    Write-Host "dsh CLI not found; installing @deepseek-ai/dsh@$DshVersion globally ..."
    & npm install -g "@deepseek-ai/dsh@$DshVersion"
    if ($LASTEXITCODE -ne 0) { Write-Warning "npm install -g failed (exit $LASTEXITCODE)" }
  } else {
    Write-Host "dsh CLI found: $($dshCmd.Source)"
  }
}

#     1c1. The @deepseek-ai SDK must resolve from $DSH_HOME/profiles. DSH Desktop
#     provided it as junctions into its app.asar, which a plain `dsh web` cannot
#     read; point the shared node_modules at the global CLI's own dependency tree
#     instead. This is machine-local wiring and is deliberately not synced.
function Connect-StandaloneSdk {
  $npmRoot = (& npm root -g 2>$null)
  if ($LASTEXITCODE -ne 0 -or -not $npmRoot) {
    Write-Warning "npm root -g failed; skipped SDK wiring"
    return
  }
  $npmRoot = @($npmRoot)[0].Trim()
  $sdkTarget = Join-Path $npmRoot '@deepseek-ai\dsh\node_modules'
  if (-not (Test-Path -LiteralPath (Join-Path $sdkTarget '@deepseek-ai\dsh-base\package.json'))) {
    Write-Warning "Global dsh dependency tree not found: $sdkTarget"
    return
  }
  $nm = Join-Path $DshHome 'profiles\node_modules'
  if (Test-Path -LiteralPath (Join-Path $nm '@deepseek-ai\dsh-base\package.json')) {
    Write-Host "profiles\node_modules already resolves @deepseek-ai/dsh-base"
    return
  }
  $existing = Get-Item -LiteralPath $nm -Force -ErrorAction SilentlyContinue
  if ($existing) {
    if ($existing.LinkType) {
      # Dangling junction/symlink: remove the link only, never the target.
      cmd /c rmdir "$nm" | Out-Null
      Write-Host "removed unusable link: $nm"
    } else {
      $backup = "$nm.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
      Move-Item -LiteralPath $nm -Destination $backup
      Write-Host "moved unusable profiles\node_modules to $backup"
    }
  }
  New-Item -ItemType Junction -Path $nm -Target $sdkTarget | Out-Null
  Write-Host "profiles\node_modules -> $sdkTarget"
}
Connect-StandaloneSdk

function Invoke-WebServiceInstall {
  if ($SkipWebService) {
    Write-Host "Skipped the standalone web server (-SkipWebService)."
    return
  }
  $webInstaller = Join-Path $PSScriptRoot 'tools\install-web-service.ps1'
  if (Test-Path -LiteralPath $webInstaller) {
    & $webInstaller -Port $Port
  } else {
    Write-Warning "Web service installer not found: $webInstaller"
  }
}

if ($SkipInstall) {
  Write-Host "Skipped pnpm install (-SkipInstall)."
  Write-Host "Done. Files copied to $DshHome"
  Invoke-WebServiceInstall
  return
}

# 2. Install each profile's dependencies from its own directory.
$pnpm = Get-Command pnpm -ErrorAction SilentlyContinue
if (-not $pnpm) {
  Write-Warning "pnpm not found on PATH; files were copied but dependencies were not installed."
  return
}

# 2a. Install each custom plugin's own dependencies (e.g. dsh-account-switcher
#     needs `yaml` / `@deepseek-ai/schemastery`). DSH loads plugin entry files by
#     their real path, so third-party deps must live under the plugin dir.
$pluginsDir = Join-Path $DshHome 'plugins'
if (Test-Path -LiteralPath $pluginsDir) {
  Get-ChildItem -Directory -LiteralPath $pluginsDir | Sort-Object Name | ForEach-Object {
    $pkg = Join-Path $_.FullName 'package.json'
    if (-not (Test-Path -LiteralPath $pkg)) { return }
    Write-Host "Installing plugin '$($_.Name)' dependencies ..."
    Push-Location $_.FullName
    try {
      & $pnpm.Source install --no-frozen-lockfile
      if ($LASTEXITCODE -ne 0) {
        Write-Warning "pnpm install failed in $($_.FullName) (exit code $LASTEXITCODE)"
      }
    }
    finally {
      Pop-Location
    }
  }
}

# 2b. Install each profile's dependencies.
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

# 3. Standalone web profile: logon task + Desktop app shortcut + start now.
Invoke-WebServiceInstall
