# BIT-Web Auto Login v1.0 - scheduled task installer (preview by default)
[CmdletBinding()]
param([switch]$Apply)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$taskName = 'BIT-Web AutoLogin v1.0'
$mainScript = Join-Path $PSScriptRoot 'AutoLogin.ps1'
$credentialPath = Join-Path $PSScriptRoot 'credential.xml'

Write-Host "Scheduled task to create at current-user logon: $taskName"
Write-Host "Command: $mainScript -Live"
Write-Host 'This task does not create or modify network profiles. It authenticates only on a connection allowed by settings.json.'

if (-not $Apply) {
    Write-Host 'Preview only; the system was not changed. After a successful one-shot live test, rerun with -Apply.'
    return
}

if (-not (Test-Path -LiteralPath $mainScript -PathType Leaf)) {
    throw "Main script not found: $mainScript"
}
if (-not (Test-Path -LiteralPath $credentialPath -PathType Leaf)) {
    throw 'credential.xml does not exist. Run Setup-Credential.ps1 first.'
}

$powerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Live' -f $mainScript
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$action = New-ScheduledTaskAction -Execute $powerShellExe -Argument $arguments -WorkingDirectory $PSScriptRoot
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity
$principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
$taskSettings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -StartWhenAvailable

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $taskSettings `
    -Description 'BIT-Web portal auto authentication v1.0 (does not switch or configure Wi-Fi)' `
    -Force | Out-Null

Write-Host "Scheduled task installed: $taskName"
