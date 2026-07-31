# BIT-Web Auto Login v1.1 - one-click per-user installer and upgrader
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]$InstallDirectory,
    [switch]$RefreshCredential,
    [switch]$NoStart
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$version = '1.1'
$taskName = 'BIT-Web AutoLogin'
$legacyTaskNames = @('BIT-Web AutoLogin v1.0', 'BIT-Web AutoLogin v1.1')
$sourceDirectory = $PSScriptRoot

if ([string]::IsNullOrWhiteSpace($InstallDirectory)) {
    $InstallDirectory = Join-Path $env:LOCALAPPDATA 'BITWebAutoLogin'
}

if ($env:OS -ne 'Windows_NT') {
    throw 'This installer supports Windows only.'
}

$requiredSourceFiles = @(
    'AutoLogin.ps1',
    'BITWebAutoLogin.psm1',
    'settings.json'
)
foreach ($name in $requiredSourceFiles) {
    $path = Join-Path $sourceDirectory $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required source file not found: $path"
    }
}

$settings = Get-Content -LiteralPath (Join-Path $sourceDirectory 'settings.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$settings.Version -ne $version) {
    throw "settings.json version '$($settings.Version)' does not match installer version '$version'."
}

$credentialSource = Join-Path $sourceDirectory 'credential.xml'
$credentialTarget = Join-Path $InstallDirectory 'credential.xml'
$mainScriptTarget = Join-Path $InstallDirectory 'AutoLogin.ps1'

Write-Host "BIT-Web Auto Login v$version one-click installer"
Write-Host "Install directory: $InstallDirectory"
Write-Host "Scheduled task: $taskName"
Write-Host 'The installer does not create, switch, enable, disable, or modify network adapters.'
Write-Host 'Existing encrypted credentials are preserved unless -RefreshCredential is used.'

if (-not $PSCmdlet.ShouldProcess($InstallDirectory, "Install BIT-Web Auto Login v$version and register the current-user task")) {
    return
}

if (-not (Test-Path -LiteralPath $InstallDirectory)) {
    New-Item -ItemType Directory -Path $InstallDirectory -Force | Out-Null
}

$resolvedSource = [IO.Path]::GetFullPath($sourceDirectory).TrimEnd('\')
$resolvedTarget = [IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\')
foreach ($name in $requiredSourceFiles) {
    $source = Join-Path $sourceDirectory $name
    $target = Join-Path $InstallDirectory $name
    if (-not [string]::Equals($resolvedSource, $resolvedTarget, [StringComparison]::OrdinalIgnoreCase)) {
        Copy-Item -LiteralPath $source -Destination $target -Force
    }
}

if ($RefreshCredential -or -not (Test-Path -LiteralPath $credentialTarget -PathType Leaf)) {
    if (-not $RefreshCredential -and
        (Test-Path -LiteralPath $credentialSource -PathType Leaf) -and
        -not [string]::Equals(
            [IO.Path]::GetFullPath($credentialSource),
            [IO.Path]::GetFullPath($credentialTarget),
            [StringComparison]::OrdinalIgnoreCase
        )) {
        Copy-Item -LiteralPath $credentialSource -Destination $credentialTarget -Force
        Write-Host 'Reused the existing local DPAPI credential file.'
    }
    else {
        Write-Host 'Enter the BIT-Web account. The password is encrypted with Windows DPAPI.'
        $credential = Get-Credential -Message 'BIT-Web campus network account'
        if ($null -eq $credential) {
            throw 'Credential entry was cancelled.'
        }
        $credential | Export-Clixml -LiteralPath $credentialTarget -Force
        Write-Host 'Created a DPAPI-encrypted credential file for the current Windows user.'
    }
}
else {
    Write-Host 'Preserved the installed DPAPI credential file.'
}

$credentialCheck = Import-Clixml -LiteralPath $credentialTarget
if ($credentialCheck -isnot [pscredential]) {
    throw "Invalid credential file: $credentialTarget"
}
$credentialCheck = $null

$powerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Live' -f $mainScriptTarget
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$action = New-ScheduledTaskAction -Execute $powerShellExe -Argument $arguments -WorkingDirectory $InstallDirectory
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

$stoppedLegacyTasks = @()
try {
    foreach ($legacyTaskName in $legacyTaskNames) {
        $legacyTask = Get-ScheduledTask -TaskName $legacyTaskName -ErrorAction SilentlyContinue
        if ($null -ne $legacyTask) {
            if ($legacyTask.State -eq 'Running') {
                Stop-ScheduledTask -TaskName $legacyTaskName
                $stoppedLegacyTasks += $legacyTaskName
            }
        }
    }

    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($null -ne $existingTask -and $existingTask.State -eq 'Running') {
        Stop-ScheduledTask -TaskName $taskName
        Start-Sleep -Seconds 1
    }

    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $taskSettings `
        -Description "BIT-Web portal auto authentication v$version (per-user; does not modify network adapters)" `
        -Force | Out-Null

    if (-not $NoStart) {
        Start-ScheduledTask -TaskName $taskName
        Start-Sleep -Seconds 3
        $installedTask = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
        if ($installedTask.State -ne 'Running') {
            throw "The installed task did not enter Running state: $($installedTask.State)"
        }
    }

    foreach ($legacyTaskName in $legacyTaskNames) {
        if ($null -ne (Get-ScheduledTask -TaskName $legacyTaskName -ErrorAction SilentlyContinue)) {
            Unregister-ScheduledTask -TaskName $legacyTaskName -Confirm:$false
        }
    }
}
catch {
    foreach ($legacyTaskName in $stoppedLegacyTasks) {
        try {
            Start-ScheduledTask -TaskName $legacyTaskName -ErrorAction SilentlyContinue
        }
        catch {
        }
    }
    throw
}

Write-Host "BIT-Web Auto Login v$version installed successfully."
Write-Host "Runtime: $InstallDirectory"
Write-Host "Task: $taskName"
if ($NoStart) {
    Write-Host 'The task is installed but was not started because -NoStart was specified.'
}
else {
    Write-Host 'The task is running and will start automatically at Windows logon.'
}
