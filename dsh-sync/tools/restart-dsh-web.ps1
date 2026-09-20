# Restart the DSH web server so edits to dsh-web-server.ps1 take effect.
#
# Why this is needed: the running server was started with the flags its
# supervisor had loaded at the time, so changing the script alone changes
# nothing until the supervisor itself restarts. The supervisor is the scheduled
# task "DSH Web Server", which loops and restarts its child; both have to be
# replaced together, otherwise the surviving supervisor restarts the server
# with the OLD flags.
#
# There is no `Stop-ScheduledTask` for a task already inside its job: stop the
# runner FIRST, then the supervisor and server, so nothing respawns mid-way.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\restart-dsh-web.ps1
#
# NOTE: this closes the Web UI you are using. Open a new window afterwards with
# dsh-web-open.cmd (or the "DSH Web" desktop shortcut).

param(
    [int]$Port = 43120,
    [switch]$NoWindow
)

$ErrorActionPreference = 'Stop'

$toolsDir = $PSScriptRoot
$taskName = 'DSH Web Server'
$serverScript = Join-Path $toolsDir 'dsh-web-server.ps1'
$logFile = Join-Path $env:LOCALAPPDATA 'dsh-web\server.log'

function Test-DshPort {
    param([int]$Port)
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        return ($client.ConnectAsync('127.0.0.1', $Port).Wait(500) -and $client.Connected)
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

# Match the supervisor by its own script, not by process name: the machine runs
# many unrelated powershell processes.
function Get-DshProcesses {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe' OR Name='node.exe' OR Name='cmd.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match 'dsh-web-server\.ps1|dsh-web-open\.ps1|dsh[\\/]lib[\\/]bin\.js|npm\\dsh\.cmd' }
}

Write-Host 'Stopping the scheduled task runner ...'
try {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction Stop
    Write-Host "  stopped: $taskName"
} catch {
    Write-Host "  no scheduled task '$taskName' to stop ($($_.Exception.Message.Trim()))" -ForegroundColor Yellow
}

Write-Host 'Stopping the supervisor, server, and any open helper ...'
$targets = @(Get-DshProcesses)
if ($targets.Count -eq 0) {
    Write-Host '  nothing matched'
} else {
    foreach ($target in $targets) {
        $name = $target.Name
        try {
            Stop-Process -Id $target.ProcessId -Force -ErrorAction Stop
            Write-Host "  killed pid $($target.ProcessId) ($name)"
        } catch {
            Write-Host "  could not kill pid $($target.ProcessId) ($name): $($_.Exception.Message.Trim())" -ForegroundColor Yellow
        }
    }
}

# The port must actually be free before the new server binds it.
$deadline = (Get-Date).AddSeconds(20)
while ((Get-Date) -lt $deadline -and (Test-DshPort $Port)) { Start-Sleep -Milliseconds 400 }
if (Test-DshPort $Port) {
    Write-Host "Port $Port is still held by another process; leaving it alone." -ForegroundColor Red
    Write-Host 'Close it and run dsh-web-open.cmd instead.' -ForegroundColor Yellow
    if (-not $NoWindow) { Read-Host 'Press Enter to exit' }
    exit 1
}

Write-Host "Starting the background server again (profile: web, port $Port) ..."
& powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $serverScript -Port $Port

$deadline = (Get-Date).AddSeconds(90)
while ((Get-Date) -lt $deadline -and -not (Test-DshPort $Port)) { Start-Sleep -Milliseconds 500 }
if (-not (Test-DshPort $Port)) {
    Write-Host "Port $Port did not come up within 90s." -ForegroundColor Red
    if (Test-Path $logFile) {
        Write-Host "--- last 30 lines of $logFile ---" -ForegroundColor Yellow
        Get-Content $logFile -Tail 30 | ForEach-Object { Write-Host "  $_" }
    }
    if (-not $NoWindow) { Read-Host 'Press Enter to exit' }
    exit 1
}

Write-Host "Server is up on http://127.0.0.1:$Port/ (it no longer opens a browser by itself)." -ForegroundColor Green
Write-Host 'Open the UI with dsh-web-open.cmd, or the "DSH Web" desktop shortcut.'
Write-Host ''
Write-Host 'Log tail:' -ForegroundColor DarkGray
if (Test-Path $logFile) { Get-Content $logFile -Tail 5 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray } }
