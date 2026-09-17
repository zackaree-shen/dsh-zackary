<#
  Registers the "DSH Web Server" logon task for the standalone DSH web profile.

  install-web-service.ps1 calls this as a child process: directly first, and once
  more through a UAC-elevated one-shot when the direct attempt is denied. Run as
  a child process only — the exit code is the only failure signal.
  Exit codes: 0 registered; 2 registration denied (needs elevation); 1 other failure.
#>
[CmdletBinding()]
param(
  [int]$Port = 43120,
  [string]$TaskName = 'DSH Web Server'
)

$ErrorActionPreference = 'Stop'

$ToolsDir = Join-Path $env:LOCALAPPDATA 'dsh-web\tools'

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ToolsDir\dsh-web-server.ps1`" -Port $Port"
$trigger = New-ScheduledTaskTrigger -AtLogOn
# The task runs with this user's interactive token, so an any-user logon trigger
# would only fail on other accounts; scope it where this build allows.
try {
  $trigger.UserId = $env:USERNAME
} catch {
  Write-Host 'note: this build cannot scope the logon trigger to one user; leaving it for any user'
}
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
  -MultipleInstances IgnoreNew -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Seconds 0)

try {
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
    -Description "Serve the DSH web profile on http://127.0.0.1:$Port/" -Force | Out-Null
  exit 0
} catch {
  # 0x80070005 as HRESULT is -2147024891; Task Scheduler surfaces it as
  # PermissionDenied when the shell's token may not write the task folder.
  if ($_.FullyQualifiedErrorId -like '*PermissionDenied*' -or $_.Exception.HResult -eq -2147024891) {
    exit 2
  }
  Write-Error $_
  exit 1
}
