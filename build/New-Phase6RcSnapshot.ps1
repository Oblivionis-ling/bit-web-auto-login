[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'BITWebAutoLogin'),
    [switch]$AcknowledgeLocalMetadata
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if (-not $AcknowledgeLocalMetadata) {
    throw 'This script records local paths and task metadata. Re-run with -AcknowledgeLocalMetadata after reviewing the output location.'
}

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputDirectory = Join-Path $projectRoot "artifacts\phase6-rc-snapshot\$stamp"
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$allowedRoot = ([IO.Path]::GetFullPath((Join-Path $projectRoot 'artifacts\phase6-rc-snapshot'))).TrimEnd('\') + '\'
if (-not ($OutputDirectory.TrimEnd('\') + '\').StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "OutputDirectory must stay under $allowedRoot"
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$credentialPath = Join-Path $InstallDirectory 'credential.xml'
$settingsPath = Join-Path $InstallDirectory 'settings.json'
$shortcutPath = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\BIT-Web 自动登录管理器.lnk'
$taskNames = @('BIT-Web AutoLogin', 'BIT-Web AutoLogin v1.1', 'BIT-Web AutoLogin v1.0')

$credentialHash = if (Test-Path -LiteralPath $credentialPath -PathType Leaf) {
    (Get-FileHash -LiteralPath $credentialPath -Algorithm SHA256).Hash.ToLowerInvariant()
}
else { $null }

$fileManifest = @()
if (Test-Path -LiteralPath $InstallDirectory -PathType Container) {
    $fileManifest = @(Get-ChildItem -LiteralPath $InstallDirectory -Recurse -File | Sort-Object FullName | ForEach-Object {
        $relative = $_.FullName.Substring($InstallDirectory.TrimEnd('\').Length + 1).Replace('\', '/')
        [ordered]@{
            path = $relative
            size = $_.Length
            sha256 = if ($relative -ieq 'credential.xml') { $credentialHash } else { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
        }
    })
}

$taskMetadata = @()
foreach ($taskName in $taskNames) {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($null -eq $task) { continue }
    $taskMetadata += [ordered]@{
        name = $taskName
        state = [string]$task.State
        actions = @($task.Actions | ForEach-Object { [ordered]@{ execute = $_.Execute; arguments = $_.Arguments; workingDirectory = $_.WorkingDirectory } })
        triggers = @($task.Triggers | ForEach-Object { [ordered]@{ type = $_.CimClass.CimClassName; enabled = $_.Enabled } })
        principal = [ordered]@{ userId = $task.Principal.UserId; logonType = [string]$task.Principal.LogonType; runLevel = [string]$task.Principal.RunLevel }
    }
    Export-ScheduledTask -TaskName $taskName | Set-Content -LiteralPath (Join-Path $OutputDirectory (($taskName -replace '[^A-Za-z0-9.-]', '_') + '.xml')) -Encoding UTF8
}

$shortcutMetadata = $null
if (Test-Path -LiteralPath $shortcutPath -PathType Leaf) {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcutMetadata = [ordered]@{
        path = $shortcutPath
        targetPath = $shortcut.TargetPath
        arguments = $shortcut.Arguments
        workingDirectory = $shortcut.WorkingDirectory
        iconLocation = $shortcut.IconLocation
    }
}

if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
    Copy-Item -LiteralPath $settingsPath -Destination (Join-Path $OutputDirectory 'settings.before.json')
}

$snapshot = [ordered]@{
    schemaVersion = 1
    capturedAt = (Get-Date).ToUniversalTime().ToString('o')
    installDirectory = [IO.Path]::GetFullPath($InstallDirectory)
    credential = [ordered]@{ exists = Test-Path -LiteralPath $credentialPath -PathType Leaf; sha256 = $credentialHash; contentCaptured = $false }
    settingsBackup = Test-Path -LiteralPath $settingsPath -PathType Leaf
    tasks = $taskMetadata
    shortcut = $shortcutMetadata
    files = $fileManifest
}
$snapshot | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'snapshot.json') -Encoding UTF8
Write-Host "RC snapshot written to $OutputDirectory. credential.xml content was not copied."
