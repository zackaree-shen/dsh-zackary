<#
.SYNOPSIS
  Export the current machine's shareable DSH config/plugins back into dsh-sync/dsh.
.DESCRIPTION
  Copies settings.yaml, agent presets, profile manifests, and every custom
  plugin found on this machine (scanning ~/.dsh/plugins, ~/dsh-plugins and any
  `file:`/`link:` dependency in the local profile package.json files) into this
  repository's dsh-sync/dsh tree, normalizing machine-specific absolute paths to
  the portable `link:../../plugins/<name>` form.

  Profiles / plugins that exist in the repo but not on this machine are kept
  untouched (they may come from another computer).

  This script intentionally does NOT export:
    - .credentials.yaml and account-switcher.json (secrets/API keys)
    - sessions, storages, attachments, caches, logs
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

# Trim trailing blank lines (single final newline) so exported files stay
# git-clean (git diff --check passes).
function Set-SingleTrailingNewline {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return }
  $raw = [System.IO.File]::ReadAllText($Path)
  $fixed = $raw.TrimEnd("`r", "`n") + "`n"
  if ($fixed -cne $raw) {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $fixed, $utf8NoBom)
  }
}

# --- settings.yaml ---
Copy-Item -LiteralPath (Join-Path $DshHome 'settings.yaml') -Destination (Join-Path $RepoDsh 'settings.yaml') -Force
Set-SingleTrailingNewline -Path (Join-Path $RepoDsh 'settings.yaml')

# --- skin-center active skin (small, shareable; absent on installs without the skin center) ---
$skinActiveSrc = Join-Path $DshHome 'skin-center-active.json'
$skinActiveDest = Join-Path $RepoDsh 'skin-center-active.json'
if (Test-Path -LiteralPath $skinActiveSrc) {
  Copy-Item -LiteralPath $skinActiveSrc -Destination $skinActiveDest -Force
  Set-SingleTrailingNewline -Path $skinActiveDest
}

# --- .agent-presets (small, shareable; no secrets expected here) ---
$presetSrc = Join-Path $DshHome '.agent-presets'
$presetDest = Join-Path $RepoDsh '.agent-presets'
if (Test-Path -LiteralPath $presetSrc) {
  if (Test-Path -LiteralPath $presetDest) { Remove-Item -LiteralPath $presetDest -Recurse -Force }
  Copy-Item -LiteralPath $presetSrc -Destination $RepoDsh -Recurse -Force
}

# --- dsh-sync skill: pick up local edits back into the repo ---
$skillSrc = Join-Path $HOME '.agents\skills\dsh-sync'
$skillDest = Join-Path $PSScriptRoot '..\.agents\skills\dsh-sync'
if (Test-Path -LiteralPath (Join-Path $skillSrc 'SKILL.md')) {
  New-Item -ItemType Directory -Force -Path $skillDest | Out-Null
  Copy-Item -LiteralPath (Join-Path $skillSrc 'SKILL.md') -Destination (Join-Path $skillDest 'SKILL.md') -Force
  Set-SingleTrailingNewline -Path (Join-Path $skillDest 'SKILL.md')
  Write-Host 'dsh-sync skill exported'
}

# --- Profiles: update the ones present locally; keep repo-only profiles ---
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
Get-ChildItem -Directory -LiteralPath $profilesSrc | Where-Object { $_.Name -ne 'node_modules' } | Sort-Object Name | ForEach-Object {
  $profileName = $_.Name
  $srcDir = $_.FullName
  $destDir = Join-Path $profilesDest $profileName
  New-Item -ItemType Directory -Force -Path $destDir | Out-Null
  foreach ($file in $profileFiles) {
    $srcFile = Join-Path $srcDir $file
    if (Test-Path -LiteralPath $srcFile) {
      $destFile = Join-Path $destDir $file
      Copy-Item -LiteralPath $srcFile -Destination $destFile -Force
      Set-SingleTrailingNewline -Path $destFile
    }
  }
  Write-Host "Profile updated: $profileName"
}

# --- Custom plugin discovery ---
# Candidate roots that may contain plugin source directories.
$pluginRoots = @(
  (Join-Path $DshHome 'plugins'),
  (Join-Path $HOME 'dsh-plugins')
)
# Plugins that must never be exported (uninstalled / deprecated / secrets-adjacent).
$excludedPlugins = @('dsh-account-switcher')
# Name -> absolute source dir of every plugin found on this machine.
$exportedPlugins = @{}

foreach ($root in $pluginRoots) {
  if (-not (Test-Path -LiteralPath $root)) { continue }
  Get-ChildItem -Directory -LiteralPath $root | ForEach-Object {
    if ($excludedPlugins -contains $_.Name) { return }
    if (-not $exportedPlugins.ContainsKey($_.Name)) { $exportedPlugins[$_.Name] = $_.FullName }
  }
}

# Also discover plugins referenced as file:/link: deps in any local profile
# package.json (e.g. "dsh-realtime-sync": "file:C:/Users/<user>/dsh-realtime-sync").
Get-ChildItem -Directory -LiteralPath $profilesSrc | Where-Object { $_.Name -ne 'node_modules' } | ForEach-Object {
  $pkg = Join-Path $_.FullName 'package.json'
  if (-not (Test-Path -LiteralPath $pkg)) { return }
  try {
    $pkgJson = Get-Content -LiteralPath $pkg -Raw | ConvertFrom-Json
  } catch { return }
  foreach ($dep in $pkgJson.dependencies.PSObject.Properties) {
    $spec = [string]$dep.Value
    if ($spec -match '^(file|link):') {
      $target = $spec.Substring(5)
      $resolved = $target
      if (-not ([System.IO.Path]::IsPathRooted($target))) {
        $resolved = Join-Path (Split-Path $pkg -Parent) $target
      }
      if (Test-Path -LiteralPath $resolved) {
        $name = Split-Path $resolved -Leaf
        if (-not $exportedPlugins.ContainsKey($name)) { $exportedPlugins[$name] = (Get-Item -LiteralPath $resolved).FullName }
      }
    }
  }
}

# Copy each plugin's source (never node_modules / .git / caches).
$pluginsDest = Join-Path $RepoDsh 'plugins'
New-Item -ItemType Directory -Force -Path $pluginsDest | Out-Null
foreach ($name in ($exportedPlugins.Keys | Sort-Object)) {
  $src = $exportedPlugins[$name]
  $dest = Join-Path $pluginsDest $name
  New-Item -ItemType Directory -Force -Path $dest | Out-Null
  Get-ChildItem -Force -LiteralPath $src | Where-Object {
    $_.Name -notin @('node_modules', '.git', '.pnpm-store', 'cache', 'logs')
  } | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $dest -Recurse -Force
  }
  Write-Host "Plugin exported: $name  <-  $src"
}

# --- Normalize machine-specific absolute paths to the portable relative layout ---
# Handles:
#   file:C:/Users/<user>/<...>/<plugin>  -> link:../../plugins/<plugin>
#   link:C:\Users\<user>\<...>\<plugin>  -> link:../../plugins/<plugin>
#   file:../../../<plugin>               -> link:../../plugins/<plugin>   (pnpm lockfile version form)
#   link:../../../dsh-plugins/<plugin>   -> link:../../plugins/<plugin>   (legacy form)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
foreach ($name in ($exportedPlugins.Keys | Sort-Object { $_.Length } -Descending)) {
  $esc = [regex]::Escape($name)
  Get-ChildItem -Directory -LiteralPath $profilesDest | ForEach-Object {
    foreach ($rel in @('package.json', 'pnpm-lock.yaml')) {
      $file = Join-Path $_.FullName $rel
      if (-not (Test-Path -LiteralPath $file)) { continue }
      $text = Get-Content -LiteralPath $file -Raw -Encoding UTF8
      $orig = $text
      $text = $text -replace "(?:file|link):C:[\\/]Users[\\/][^\r\n""]*?$esc(?=[\r\n""\s,}:])", "link:../../plugins/$name"
      $text = $text -replace "file:(?:\.\./)+$esc(?=[\r\n""\s,}:])", "link:../../plugins/$name"
      $text = $text -replace "link:(?:\.\./)*dsh-plugins/$esc(?=[\r\n""\s,}:])", "link:../../plugins/$name"
      $text = $text -replace "directory: (?:\.\./)+$esc(?=[\r\n,}])", "directory: ../../plugins/$name"
      if ($text -cne $orig) {
        [System.IO.File]::WriteAllText($file, $text, $utf8NoBom)
        Write-Host "Normalized $($_.Name)/$rel (plugin $name)"
      }
    }
  }
}

Write-Host 'Done. Review `git status` and commit the changes on the dev branch.'
