<#
  Ensure the DSH web server is running, then open the web profile in the
  default browser. Double-click entry point: dsh-web-open.cmd.
#>
param(
    [int]$Port = 43120,
    [switch]$NoWindow
)

$ErrorActionPreference = 'Stop'

$toolsDir = $PSScriptRoot
$serverScript = Join-Path $toolsDir 'dsh-web-server.ps1'
$url = "http://127.0.0.1:$Port/"

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

# A silent 90s wait tells the user nothing; always surface the reason.
function Show-ServerLog {
    param([int]$Lines = 30)
    $log = Join-Path $env:LOCALAPPDATA 'dsh-web\server.log'
    Write-Host ''
    if (Test-Path $log) {
        Write-Host "--- last $Lines lines of $log ---" -ForegroundColor Yellow
        Get-Content $log -Tail $Lines | ForEach-Object { Write-Host "  $_" }
    } else {
        Write-Host "no log yet at $log" -ForegroundColor Yellow
    }
}

if (-not (Test-DshPort $Port)) {
    if (-not (Test-Path $serverScript)) {
        Write-Host "Missing server script: $serverScript" -ForegroundColor Red
        if (-not $NoWindow) { Read-Host 'Press Enter to exit' }
        exit 1
    }
    Write-Host "Starting DSH web server (profile: web, port $Port) ..."
    Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', $serverScript, '-Port', $Port
    ) -WindowStyle Hidden

    $deadline = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $deadline -and -not (Test-DshPort $Port)) { Start-Sleep -Milliseconds 500 }
    if (-not (Test-DshPort $Port)) {
        Write-Host "Port $Port did not come up within 90s." -ForegroundColor Red
        Show-ServerLog
        if (-not $NoWindow) { Read-Host 'Press Enter to exit' }
        exit 1
    }
}

if ($NoWindow) { exit 0 }

# 0.1.5+ serves the web UI behind a boot-time token: the server prints its
# authenticated URL once per boot, and that log line is the only place another
# process can read it from. Prefer the newest printed URL; the bare URL only
# yields the "authentication required" page.
$log = Join-Path $env:LOCALAPPDATA 'dsh-web\server.log'
$openUrl = $url
$printed = Select-String -LiteralPath $log -Pattern "dsh web: http://127\.0\.0\.1:$Port/\?token=" -ErrorAction SilentlyContinue |
    Select-Object -Last 1
if ($printed) {
    $openUrl = ($printed.Line -replace '^.*dsh web: ', '').Trim()
    Write-Host 'Using the authenticated URL printed by the server'
} else {
    Write-Host 'No token URL in the server log; opening the bare URL'
}
Write-Host "Opening $openUrl in the default browser"
Start-Process $openUrl
