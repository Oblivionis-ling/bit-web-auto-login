# BIT-Web Auto Login v1.2.5 - read-only diagnostics
[CmdletBinding()]
param(
    [switch]$IncludeInternetCheck,
    [ValidateRange(1, 500)][int]$LogTail = 30,
    [string]$RuntimeDirectory
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($RuntimeDirectory)) {
    $installedRuntime = Join-Path $env:LOCALAPPDATA 'BITWebAutoLogin'
    if (Test-Path -LiteralPath (Join-Path $installedRuntime 'AutoLogin.ps1') -PathType Leaf) {
        $RuntimeDirectory = $installedRuntime
    }
    else {
        $RuntimeDirectory = $projectRoot
    }
}

$settingsPath = Join-Path $RuntimeDirectory 'settings.json'
$modulePath = Join-Path $RuntimeDirectory 'BITWebAutoLogin.psm1'
$credentialPath = Join-Path $RuntimeDirectory 'credential.xml'
$taskName = 'BIT-Web AutoLogin'

Import-Module $modulePath -Force
$settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
$connection = Get-CampusConnectionContext `
    -Mode ([string]$settings.ConnectionMode) `
    -TargetSsid ([string]$settings.Ssid) `
    -EthernetIpv4Prefixes @($settings.EthernetIpv4Prefixes)

$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($null -eq $task) {
    foreach ($legacyName in @('BIT-Web AutoLogin v1.1', 'BIT-Web AutoLogin v1.0')) {
        $legacyTask = Get-ScheduledTask -TaskName $legacyName -ErrorAction SilentlyContinue
        if ($null -ne $legacyTask) {
            $taskName = $legacyName
            $task = $legacyTask
            break
        }
    }
}
$taskInfo = $null
if ($null -ne $task) {
    $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName
}

$monitorProcesses = @(
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match '^(?i)(powershell|pwsh)\.exe$' -and
            [string]$_.CommandLine -match '(?i)AutoLogin\.ps1.+-Live'
        }
)

Write-Output '=== BIT-Web Auto Login diagnostics ==='
Write-Output ("Time: {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Write-Output ("Runtime directory: {0}" -f $RuntimeDirectory)
Write-Output ("Settings version: {0}" -f $settings.Version)
Write-Output ("Connection mode: {0}" -f $settings.ConnectionMode)
Write-Output ("Eligible connection: {0}" -f $connection.Eligible)
Write-Output ("Connection kind: {0}" -f $connection.Kind)
Write-Output ("Connection name: {0}" -f $connection.DisplayName)
Write-Output ("Connection IPv4: {0}" -f $connection.IPv4Address)
Write-Output ("Connection reason: {0}" -f $connection.Reason)
Write-Output ("Credential file exists: {0}" -f (Test-Path -LiteralPath $credentialPath -PathType Leaf))
Write-Output ("Scheduled task installed: {0}" -f ($null -ne $task))
if ($null -ne $task) {
    Write-Output ("Scheduled task name: {0}" -f $taskName)
    Write-Output ("Scheduled task state: {0}" -f $task.State)
    Write-Output ("Scheduled task last run: {0}" -f $taskInfo.LastRunTime)
    Write-Output ("Scheduled task last result: {0}" -f $taskInfo.LastTaskResult)
}
Write-Output ("Live monitor process count: {0}" -f $monitorProcesses.Count)
foreach ($process in $monitorProcesses) {
    Write-Output ("Live monitor PID: {0}" -f $process.ProcessId)
}

if ($IncludeInternetCheck) {
    $internetHealthy = Test-InternetAccessSet `
        -Checks @($settings.ConnectivityChecks) `
        -TimeoutSeconds ([int]$settings.RequestTimeoutSeconds)
    Write-Output ("Internet check: {0}" -f $internetHealthy)
}
else {
    Write-Output 'Internet check: skipped (use -IncludeInternetCheck)'
}

$logDirectory = Join-Path $RuntimeDirectory 'logs'
$latestLog = $null
if (Test-Path -LiteralPath $logDirectory -PathType Container) {
    $latestLog = Get-ChildItem -LiteralPath $logDirectory `
        -File -Filter '*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

if ($null -eq $latestLog) {
    Write-Output 'Latest log: none'
}
else {
    Write-Output ("=== Latest log tail: {0} ===" -f $latestLog.Name)
    Get-Content -LiteralPath $latestLog.FullName -Encoding UTF8 -Tail $LogTail
}

Write-Output 'Diagnostics completed. No network adapter setting was changed.'
