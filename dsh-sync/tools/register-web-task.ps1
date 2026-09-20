<#
  Registers the "DSH Web Server" logon task for the standalone DSH web profile.

  install-web-service.ps1 calls this as a child process: directly first, and once
  more through a UAC-elevated one-shot when the direct attempt is denied. Run as
  a child process only — the exit code is the only failure signal.
  Exit codes: 0 registered; 2 registration denied (needs elevation); 1 other failure.
  Keep `2` accurate: the caller's elevation retry fires on that code alone.
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

# Registration in the task root needs the elevated token. Identify the denial on
# every shape it actually arrives in, because the caller's UAC fallback hangs off
# the exit code:
#   - Task Scheduler's own PermissionDenied error id;
#   - 0x80070005 as HResult, directly or on an InnerException;
#   - otherwise, a message that is/contains "Access is denied".
# The last rule is what actually fires on Windows 10 22H2 with PS 5.1: the
# ErrorRecord's *category* is PermissionDenied but its *id* is the message text
# "Access is denied.", the HResult is the generic 0x80131500, and the exception
# surfaces as a plain WriteErrorException. Matching on the id (as the first two
# rules do) therefore missed it and registration fell through to a plain exit 1,
# silently skipping the elevation retry in install-web-service.ps1.
function Test-TaskRegistrationDenied {
    param($ErrorRecord)
    if ($ErrorRecord.FullyQualifiedErrorId -like '*PermissionDenied*') { return $true }
    if ($ErrorRecord.Exception.HResult -eq -2147024891) { return $true }
    $inner = $ErrorRecord.Exception.InnerException
    if ($inner -and $inner.HResult -eq -2147024891) { return $true }
    return ($ErrorRecord.Exception.Message -match 'Access is denied')
}

try {
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
    -Description "Serve the DSH web profile on http://127.0.0.1:$Port/" -Force | Out-Null
  exit 0
} catch {
  if (Test-TaskRegistrationDenied $_) {
    exit 2
  }
  Write-Error $_
  exit 1
}
