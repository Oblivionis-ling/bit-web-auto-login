# BIT-Web Auto Login v1.0 - scheduled task uninstaller (preview by default)
[CmdletBinding()]
param([switch]$Apply)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$taskName = 'BIT-Web AutoLogin v1.0'

Write-Host "Scheduled task to remove: $taskName"
Write-Host 'Scripts, logs, and credential.xml will be kept.'
if (-not $Apply) {
    Write-Host 'Preview only; the system was not changed. Rerun with -Apply to uninstall.'
    return
}

$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($null -eq $task) {
    Write-Host 'The scheduled task does not exist.'
    return
}
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
Write-Host "Scheduled task removed: $taskName"
