<#
  Ensure the DSH web server is running, then open the web profile in the
  default browser. Double-click entry point: dsh-web-open.cmd.

  Waiting here is condition-based, not a fixed race. A cold `dsh web` boot
  loads the whole plugin tree and has been measured at 42-250s on this machine,
  so the previous fixed 90s budget reported "did not come up within 90s" while
  the server was simply still starting (and it often bound the port seconds
  after the helper had already given up). The wait now ends when

    - the port answers                       -> success,
    - the supervisor logs that it gave up    -> fail fast (broken profile/config),
    - $TimeoutSeconds elapses                -> last resort;

  and it prints progress every 15s instead of going silent.

  Diagnostics only ever show what was written to the log *after* this attempt
  started. The old "last 30 lines" dump could surface a crash from days earlier
  (a stale EADDRINUSE, typically) and make it look like the cause of this run.
#>
param(
    [int]$Port = 43120,
    [int]$TimeoutSeconds = 300,
    [switch]$NoWindow
)

$ErrorActionPreference = 'Stop'

$toolsDir = $PSScriptRoot
$serverScript = Join-Path $toolsDir 'dsh-web-server.ps1'
$url = "http://127.0.0.1:$Port/"
$log = Join-Path $env:LOCALAPPDATA 'dsh-web\server.log'

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

function Get-LogOffset {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { return (Get-Item -LiteralPath $Path).Length }
    return 0L
}

# Read only what the log gained since $Offset. The file is opened with a share
# mode that tolerates the running supervisor appending to it.
function Read-LogSince {
    param([string]$Path, [long]$Offset)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $stream = $null
    $reader = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        if ($Offset -gt $stream.Length) { $Offset = 0 }
        $stream.Seek($Offset, [System.IO.SeekOrigin]::Begin) | Out-Null
        $reader = New-Object System.IO.StreamReader($stream)
        return @($reader.ReadToEnd() -split "`r?`n" | Where-Object { $_ -ne '' })
    } catch {
        return @()
    } finally {
        # StreamReader owns the stream once constructed; disposing both is safe.
        if ($reader) { $reader.Dispose() } elseif ($stream) { $stream.Dispose() }
    }
}

# A silent wait tells the user nothing; always surface the reason.
function Show-ServerLog {
    param([string]$Path, [long]$Offset, [int]$Lines = 30)
    Write-Host ''
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "no log yet at $Path" -ForegroundColor Yellow
        return
    }
    $new = @(Read-LogSince -Path $Path -Offset $Offset)
    if ($new.Count -gt 0) {
        Write-Host "--- log lines written since this attempt started ($Path) ---" -ForegroundColor Yellow
        $new | Select-Object -Last $Lines | ForEach-Object { Write-Host "  $_" }
        if ($new -match 'EADDRINUSE') {
            Write-Host ''
            Write-Host 'EADDRINUSE: the port is already held by another process, usually a' -ForegroundColor Yellow
            Write-Host 'leftover "dsh web" from an earlier start. Close it and retry.' -ForegroundColor Yellow
        }
        return
    }
    Write-Host "--- nothing new in the log; last $Lines lines (older events, NOT this attempt) ---" -ForegroundColor Yellow
    Get-Content -LiteralPath $Path -Tail $Lines | ForEach-Object { Write-Host "  $_" }
}

# The token URL the CLI prints on boot; only the newest line matters.
function Get-LastTokenUrl {
    param([string]$TokenLog)
    $printed = Select-String -LiteralPath $TokenLog -Pattern "dsh web: http://127\.0\.0\.1:$Port/\?token=" -ErrorAction SilentlyContinue |
        Select-Object -Last 1
    if ($printed) { return ($printed.Line -replace '^.*dsh web: ', '').Trim() }
    return $null
}

$logOffset = Get-LogOffset $log
$startedHere = $false

if (-not (Test-DshPort $Port)) {
    if (-not (Test-Path -LiteralPath $serverScript)) {
        Write-Host "Missing server script: $serverScript" -ForegroundColor Red
        if (-not $NoWindow) { Read-Host 'Press Enter to exit' }
        exit 1
    }
    Write-Host "Starting DSH web server (profile: web, port $Port) ..."
    Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', $serverScript, '-Port', $Port
    ) -WindowStyle Hidden
    $startedHere = $true

    $startedAt = Get-Date
    $deadline = $startedAt.AddSeconds($TimeoutSeconds)
    $nextProgress = $startedAt.AddSeconds(15)
    $gaveUp = $false

    while ((Get-Date) -lt $deadline -and -not (Test-DshPort $Port)) {
        # A supervisor that already gave up will never open the port: stop now
        # and show its reason instead of burning the whole timeout.
        if (@(Read-LogSince -Path $log -Offset $logOffset) -match 'gave up after 5 immediate failures') {
            $gaveUp = $true
            break
        }
        if ((Get-Date) -ge $nextProgress) {
            Write-Host ("  still starting ({0:N0}s elapsed; a cold boot can take several minutes) ..." -f ((Get-Date) - $startedAt).TotalSeconds)
            $nextProgress = (Get-Date).AddSeconds(15)
        }
        Start-Sleep -Milliseconds 500
    }

    if (-not (Test-DshPort $Port)) {
        if ($gaveUp) {
            Write-Host 'The server supervisor gave up after repeated immediate failures.' -ForegroundColor Red
        } else {
            Write-Host "Port $Port did not come up within ${TimeoutSeconds}s." -ForegroundColor Red
        }
        Show-ServerLog -Path $log -Offset $logOffset
        if (-not $NoWindow) { Read-Host 'Press Enter to exit' }
        exit 1
    }
}

if ($NoWindow) { exit 0 }

# 0.1.5+ serves the web UI behind a boot-time token: the server prints its
# authenticated URL once per boot, and that log line is the only place another
# process can read it from. The bare URL only yields the "authentication
# required" page, so prefer the newest printed URL.
#
# The URL is printed a moment AFTER the port starts answering, so a fresh boot
# gets a short bounded wait for its own line (a line from an earlier boot is
# not a substitute - its token may already be dead). When the server was
# already up, the newest logged URL is the current one.
$openUrl = $url
if ($startedHere) {
    $tokenDeadline = (Get-Date).AddSeconds(20)
    $fresh = $null
    while (-not $fresh -and (Get-Date) -lt $tokenDeadline) {
        $fresh = @(Read-LogSince -Path $log -Offset $logOffset) |
            Where-Object { $_ -match "dsh web: http://127\.0\.0\.1:$Port/\?token=" } |
            Select-Object -Last 1
        if (-not $fresh) { Start-Sleep -Milliseconds 500 }
    }
    if ($fresh) { $openUrl = ($fresh -replace '^.*dsh web: ', '').Trim() }
}

if ($openUrl -eq $url) {
    $printed = Get-LastTokenUrl -TokenLog $log
    if ($printed) {
        $openUrl = $printed
        Write-Host 'Using the authenticated URL printed by the server'
    } else {
        Write-Host 'No token URL in the server log; opening the bare URL'
    }
} else {
    Write-Host 'Using the authenticated URL printed by the server'
}

Write-Host "Opening $openUrl in the default browser"
Start-Process $openUrl
