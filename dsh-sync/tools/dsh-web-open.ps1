<#
  Ensure the DSH web server is running, then open the web profile in an
  app-style browser window (Edge/Chrome `--app`), falling back to the default
  browser. Double-click entry point: dsh-web-open.cmd.
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

function Find-AppBrowser {
    $candidates = @()
    # ${env:ProgramFiles(x86)} — the ${} form is required: $env:'ProgramFiles(x86)'
    # is not valid PowerShell and fails the whole script at parse time.
    $pf86 = ${env:ProgramFiles(x86)}
    $pf = $env:ProgramFiles
    if ($pf86) {
        $candidates += (Join-Path $pf86 'Microsoft\Edge\Application\msedge.exe')
        $candidates += (Join-Path $pf86 'Google\Chrome\Application\chrome.exe')
    }
    if ($pf) {
        $candidates += (Join-Path $pf 'Microsoft\Edge\Application\msedge.exe')
        $candidates += (Join-Path $pf 'Google\Chrome\Application\chrome.exe')
    }
    $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
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
        Write-Host "Port $Port did not come up within 90s. Log: $env:LOCALAPPDATA\dsh-web\server.log" -ForegroundColor Red
        if (-not $NoWindow) { Read-Host 'Press Enter to exit' }
        exit 1
    }
}

if ($NoWindow) { exit 0 }

$browser = Find-AppBrowser
if ($browser) {
    Write-Host "Opening $url in app mode ($([System.IO.Path]::GetFileName($browser)))"
    Start-Process -FilePath $browser -ArgumentList "--app=$url"
} else {
    Write-Host "Opening $url in the default browser"
    Start-Process $url
}
