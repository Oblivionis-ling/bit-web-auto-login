# BIT-Web Auto Login v1.1 - safe task uninstaller
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$taskNames = @(
    'BIT-Web AutoLogin',
    'BIT-Web AutoLogin v1.1',
    'BIT-Web AutoLogin v1.0'
)

Write-Host 'This removes BIT-Web Auto Login scheduled tasks.'
Write-Host 'Installed scripts, logs, settings, and credential.xml are preserved.'

if (-not $PSCmdlet.ShouldProcess(($taskNames -join ', '), 'Stop and unregister scheduled tasks')) {
    return
}

$removed = 0
foreach ($taskName in $taskNames) {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($null -eq $task) {
        continue
    }
    if ($task.State -eq 'Running') {
        Stop-ScheduledTask -TaskName $taskName
    }
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    $removed++
    Write-Host "Removed scheduled task: $taskName"
}

if ($removed -eq 0) {
    Write-Host 'No BIT-Web Auto Login scheduled task was installed.'
}
Write-Host 'Runtime data was preserved under the install directory.'
