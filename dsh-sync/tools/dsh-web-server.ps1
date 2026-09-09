<#
  Start the standalone DSH web server for the `web` profile, and keep it alive.

  No DSH Desktop required: this boots the profile with the globally installed
  `dsh` CLI. Deployed by install-web-service.ps1 to %LOCALAPPDATA%\dsh-web\tools.

  - Idempotent: if the port already answers, exits 0 immediately WITHOUT
    touching the log, so a second instance (logon task, double-click) can never
    fail just because the first one holds the log open.
  - Supervises: restarts the server if it exits, but gives up after 5 immediate
    failures (broken profile / bad config) and leaves the cause in the log.
#>
param(
    [int]$Port = 43120,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$logDir = Join-Path $env:LOCALAPPDATA 'dsh-web'
$logFile = Join-Path $logDir 'server.log'

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

function Write-Log {
    param([string]$Message)
    # Best effort: a logging failure must never kill the supervisor.
    try {
        "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message" | Add-Content -Path $logFile -Encoding UTF8 -ErrorAction Stop
    } catch { }
}

# Fast path first, deliberately before any log write (see header).
if (-not $Force -and (Test-DshPort $Port)) { exit 0 }

New-Item -ItemType Directory -Force -Path $logDir | Out-Null

$dsh = Join-Path $env:APPDATA 'npm\dsh.cmd'
if (-not (Test-Path $dsh)) { $dsh = 'dsh' }

Write-Log "supervisor start (dsh: $dsh, port: $Port)"

$consecutiveFastFailures = 0
while ($true) {
    $startedAt = Get-Date
    Write-Log "starting: $dsh web --port $Port"
    $previousEap = $ErrorActionPreference
    # A native command's stderr must NOT become a terminating error: with
    # ErrorActionPreference Stop, PowerShell throws on the FIRST stderr line, so
    # the log keeps only "file:line" and the actual cause (printed on the lines
    # after it) is lost.
    $ErrorActionPreference = 'Continue'
    try {
        # Pipe through Write-Log so the child's output is re-encoded to UTF-8
        # instead of appended raw (cmd.exe emits UTF-16, which garbles the log).
        & $dsh web --port $Port 2>&1 | ForEach-Object { Write-Log $_ }
        $code = $LASTEXITCODE
    } catch {
        Write-Log "launch failed: $($_.Exception.Message)"
        $code = 1
    } finally {
        $ErrorActionPreference = $previousEap
    }

    $aliveSeconds = ((Get-Date) - $startedAt).TotalSeconds
    Write-Log ("server exited with code $code after {0:N1}s" -f $aliveSeconds)

    if ($aliveSeconds -lt 15) {
        $consecutiveFastFailures++
        if ($consecutiveFastFailures -ge 5) {
            Write-Log 'gave up after 5 immediate failures; see the log above for the cause'
            exit 1
        }
    } else {
        $consecutiveFastFailures = 0
    }

    Start-Sleep -Seconds 10
    Write-Log 'restarting'
}
