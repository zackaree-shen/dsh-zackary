<#
  Windows setup for the standalone DSH web profile:
    1. deploy the launcher/supervisor scripts to %LOCALAPPDATA%\dsh-web\tools
    2. register the logon task "DSH Web Server" (restart-on-failure)
    3. create the Desktop shortcut "DSH Web" (app-style window)
    4. start the server now (idempotent)

  Called by install.ps1; safe to re-run.
#>
[CmdletBinding()]
param(
  [int]$Port = 43120,
  [string]$TaskName = 'DSH Web Server',
  [switch]$NoShortcut,
  [switch]$NoStart
)

$ErrorActionPreference = 'Stop'

$ToolsDir = Join-Path $env:LOCALAPPDATA 'dsh-web\tools'
New-Item -ItemType Directory -Force -Path $ToolsDir | Out-Null

foreach ($file in @('dsh-web-server.ps1', 'dsh-web-open.ps1', 'dsh-web-open.cmd')) {
  $src = Join-Path $PSScriptRoot $file
  if (-not (Test-Path -LiteralPath $src)) { throw "Missing tool: $src" }
  Copy-Item -LiteralPath $src -Destination (Join-Path $ToolsDir $file) -Force
}
Write-Host "dsh-web tools installed to $ToolsDir"

# 1. Logon task with restart-on-failure. -MultipleInstances IgnoreNew keeps a
#    double start (task + manual double-click) from racing.
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ToolsDir\dsh-web-server.ps1`" -Port $Port"
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
  -MultipleInstances IgnoreNew -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Seconds 0)
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
  -Description "Serve the DSH web profile on http://127.0.0.1:$Port/" -Force | Out-Null
Write-Host "scheduled task '$TaskName' registered (logon trigger, restart every 1 min on failure)"

# 2. Desktop shortcut. It points at the launcher so a cold click also starts the
#    server; the launcher then prefers an app-style browser window.
if (-not $NoShortcut) {
  $desktop = [Environment]::GetFolderPath('Desktop')
  $lnkPath = Join-Path $desktop 'DSH Web.lnk'
  $shell = New-Object -ComObject WScript.Shell
  $shortcut = $shell.CreateShortcut($lnkPath)
  $shortcut.TargetPath = Join-Path $ToolsDir 'dsh-web-open.cmd'
  $shortcut.WorkingDirectory = $ToolsDir
  $shortcut.Description = "Open the DSH web profile (http://127.0.0.1:$Port/) in an app-style window"
  $shortcut.IconLocation = 'shell32.dll,14'
  $shortcut.Save()
  Write-Host "desktop shortcut created: $lnkPath"
}

# 3. Start now, but only if nothing is already serving the port.
$listening = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
if (-not $NoStart -and -not $listening) {
  Start-ScheduledTask -TaskName $TaskName
  $deadline = (Get-Date).AddSeconds(90)
  while ((Get-Date) -lt $deadline -and -not (Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)) {
    Start-Sleep -Milliseconds 500
  }
  if (Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue) {
    Write-Host "server is listening on http://127.0.0.1:$Port/"
  } else {
    Write-Warning "server did not come up within 90s; check $env:LOCALAPPDATA\dsh-web\server.log"
  }
} else {
  Write-Host "port $Port already served; left as is"
}
