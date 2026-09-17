<#
  Windows setup for the standalone DSH web profile:
    1. deploy the launcher/supervisor scripts to %LOCALAPPDATA%\dsh-web\tools
    2. register the logon task "DSH Web Server" (restart-on-failure)
    3. create the Desktop shortcut "DSH Web" (default browser)
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

foreach ($file in @('dsh-web-server.ps1', 'dsh-web-open.ps1', 'dsh-web-open.cmd', 'register-web-task.ps1')) {
  $src = Join-Path $PSScriptRoot $file
  if (-not (Test-Path -LiteralPath $src)) { throw "Missing tool: $src" }
  Copy-Item -LiteralPath $src -Destination (Join-Path $ToolsDir $file) -Force
}
Write-Host "dsh-web tools installed to $ToolsDir"

# 1. Logon task with restart-on-failure. -MultipleInstances IgnoreNew keeps a
#    double start (task + manual double-click) from racing.
#    Registering a task in the root folder requires the elevated token, so a
#    non-elevated run (even for an administrator; the UAC filtered token gets
#    0x80070005) is retried once through a UAC one-shot of the same helper. The
#    helper runs as a child process so its exit code survives either path.
$registerHelper = Join-Path $ToolsDir 'register-web-task.ps1'
$previousEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $registerHelper -TaskName $TaskName -Port $Port
$directExit = $LASTEXITCODE
$ErrorActionPreference = $previousEap
if ($directExit -eq 2) {
  Write-Host 'task registration was denied for this shell; asking once via a UAC elevation prompt ...'
  try {
    $elevated = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru -WindowStyle Hidden `
      -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $registerHelper, '-TaskName', $TaskName, '-Port', "$Port"
  } catch {
    throw "the UAC elevation prompt was declined or failed ($($_.Exception.Message)); register the task by running install-web-service.ps1 from an elevated PowerShell"
  }
  if ($elevated.ExitCode -ne 0) {
    throw "elevated task registration failed (exit $($elevated.ExitCode)); run install-web-service.ps1 from an elevated PowerShell to see the registration error"
  }
} elseif ($directExit -ne 0) {
  throw "register-web-task.ps1 failed (exit $directExit)"
}
Write-Host "scheduled task '$TaskName' registered (logon trigger, restart every 1 min on failure)"

# 2. Desktop shortcut. It points at the launcher so a cold click also starts the
#    server; the launcher then opens the default browser.
if (-not $NoShortcut) {
  $desktop = [Environment]::GetFolderPath('Desktop')
  $lnkPath = Join-Path $desktop 'DSH Web.lnk'
  $shell = New-Object -ComObject WScript.Shell
  $shortcut = $shell.CreateShortcut($lnkPath)
  $shortcut.TargetPath = Join-Path $ToolsDir 'dsh-web-open.cmd'
  $shortcut.WorkingDirectory = $ToolsDir
  $shortcut.Description = "Open the DSH web profile (http://127.0.0.1:$Port/) in the default browser"
  $shortcut.IconLocation = 'shell32.dll,14'
  $shortcut.Save()
  Write-Host "desktop shortcut created: $lnkPath"
}

# 2b. Preflight: boot the profile once so a broken tree (credentials layout
#     mismatch, missing plugin, stale link) is reported HERE instead of showing
#     up later as a blank browser page.
function Test-WebProfileBoot {
  $dsh = Join-Path $env:APPDATA 'npm\dsh.cmd'
  if (-not (Test-Path -LiteralPath $dsh)) { $dsh = 'dsh' }
  Write-Host 'Verifying the web profile boots ...'
  $previousEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = & $dsh web --help 2>&1
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousEap
  }
  if ($code -eq 0) {
    Write-Host 'web profile boot check: OK'
    return $true
  }
  Write-Warning "web profile boot check FAILED (exit $code); first lines:"
  $output | Select-Object -First 12 | ForEach-Object { Write-Host "  $_" }
  return $false
}
$null = Test-WebProfileBoot

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
    $log = Join-Path $env:LOCALAPPDATA 'dsh-web\server.log'
    if (Test-Path $log) {
      Write-Host "--- last 30 lines of $log ---" -ForegroundColor Yellow
      Get-Content $log -Tail 30 | ForEach-Object { Write-Host "  $_" }
    }
  }
} else {
  Write-Host "port $Port already served; left as is"
}
