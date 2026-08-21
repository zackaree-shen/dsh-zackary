<#
.SYNOPSIS
  Export the current machine's shareable DSH config/plugins back into dsh-sync/dsh.
.DESCRIPTION
  Copies settings.yaml, agent presets, profile manifests, and the custom plugin
  source from the local DSH home into this repository's dsh-sync/dsh tree.

  This script intentionally does NOT export:
    - .credentials.yaml and account-switcher.json (secrets/API keys)
    - sessions, storages (except nothing in storages is exported), attachments, caches, logs
    - node_modules, AppData browser data, installers
.EXAMPLE
  ./export.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$DshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $HOME '.dsh' }
$RepoDsh = Join-Path $PSScriptRoot 'dsh'

if (-not (Test-Path -LiteralPath $DshHome)) {
  throw "Local DSH home not found: $DshHome"
}

Write-Host "Exporting from $DshHome to $RepoDsh"

# settings.yaml
Copy-Item -LiteralPath (Join-Path $DshHome 'settings.yaml') -Destination (Join-Path $RepoDsh 'settings.yaml') -Force

# .agent-presets (small, shareable; no secrets expected here)
$presetSrc = Join-Path $DshHome '.agent-presets'
$presetDest = Join-Path $RepoDsh '.agent-presets'
if (Test-Path -LiteralPath $presetSrc) {
  if (Test-Path -LiteralPath $presetDest) { Remove-Item -LiteralPath $presetDest -Recurse -Force }
  Copy-Item -LiteralPath $presetSrc -Destination $RepoDsh -Recurse -Force
}

# Profiles: only the manifest/config files, never node_modules or local-only files.
$profileFiles = @(
  'package.json',
  'pnpm-workspace.yaml',
  'cordis.yml',
  'cordis.patch.yml',
  'pnpm-lock.yaml'
)
$profilesSrc = Join-Path $DshHome 'profiles'
$profilesDest = Join-Path $RepoDsh 'profiles'
New-Item -ItemType Directory -Force -Path $profilesDest | Out-Null
Get-ChildItem -Directory -LiteralPath $profilesDest | ForEach-Object {
  Remove-Item -LiteralPath $_.FullName -Recurse -Force
}
Get-ChildItem -Directory -LiteralPath $profilesSrc | Where-Object { $_.Name -ne 'node_modules' } | Sort-Object Name | ForEach-Object {
  $profileName = $_.Name
  $srcDir = $_.FullName
  $destDir = Join-Path $profilesDest $profileName
  New-Item -ItemType Directory -Force -Path $destDir | Out-Null
  foreach ($file in $profileFiles) {
    $srcFile = Join-Path $srcDir $file
    if (Test-Path -LiteralPath $srcFile) {
      Copy-Item -LiteralPath $srcFile -Destination (Join-Path $destDir $file) -Force
    }
  }
}

# Custom plugin source (dsh-account-switcher), excluding node_modules.
$pluginName = 'dsh-account-switcher'
$pluginCandidates = @(
  (Join-Path (Join-Path $DshHome 'plugins') $pluginName),
  (Join-Path (Join-Path $HOME 'dsh-plugins') $pluginName)
)
$pluginSrc = $pluginCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
$pluginDest = Join-Path (Join-Path $RepoDsh 'plugins') $pluginName
$pluginFiles = @(
  'package.json',
  'index.js',
  'lib/client.js',
  'cordis.patch.yml',
  'README.md',
  'smoke.mjs',
  'pnpm-lock.yaml'
)
if ($pluginSrc -and (Test-Path -LiteralPath $pluginSrc)) {
  New-Item -ItemType Directory -Force -Path $pluginDest | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $pluginDest 'lib') | Out-Null
  foreach ($file in $pluginFiles) {
    $srcFile = Join-Path $pluginSrc $file
    if (Test-Path -LiteralPath $srcFile) {
      $relativeDest = Join-Path $pluginDest $file
      New-Item -ItemType Directory -Force -Path (Split-Path $relativeDest) | Out-Null
      Copy-Item -LiteralPath $srcFile -Destination $relativeDest -Force
    }
  }
} else {
  Write-Warning "Custom plugin not found locally: $pluginSrc"
}

# Normalize the local absolute link to the portable relative layout.
$desktopPackage = Join-Path (Join-Path $profilesDest 'desktop') 'package.json'
$desktopLock = Join-Path (Join-Path $profilesDest 'desktop') 'pnpm-lock.yaml'
foreach ($file in @($desktopPackage, $desktopLock)) {
  if (-not (Test-Path -LiteralPath $file)) { continue }
  $text = Get-Content -LiteralPath $file -Raw -Encoding UTF8
  $text = $text -replace 'link:C:\\Users\\Administrator\\dsh-plugins\\dsh-account-switcher', 'link:../../plugins/dsh-account-switcher'
  $text = $text -replace 'link:C:/Users/Administrator/dsh-plugins/dsh-account-switcher', 'link:../../plugins/dsh-account-switcher'
  $text = $text -replace 'link:\.\./\.\./\.\./dsh-plugins/dsh-account-switcher', 'link:../../plugins/dsh-account-switcher'
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($file, $text, $utf8NoBom)
}

Write-Host 'Done. Review `git status` and commit the changes on the dev branch.'
