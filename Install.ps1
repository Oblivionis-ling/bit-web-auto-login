# BIT-Web Auto Login v1.2.5 - one-click per-user installer and upgrader
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]$InstallDirectory,
    [switch]$RefreshCredential,
    [switch]$NoStart,
    [switch]$TestMode,
    [string]$TestStateDirectory,
    [ValidateRange(-1, 1000)]
    [int]$TestFailAfterCopy = -1
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$taskName = 'BIT-Web AutoLogin'
$legacyTaskNames = @('BIT-Web AutoLogin v1.0', 'BIT-Web AutoLogin v1.1')
$sourceDirectory = $PSScriptRoot

if ([string]::IsNullOrWhiteSpace($InstallDirectory)) {
    $InstallDirectory = Join-Path $env:LOCALAPPDATA 'BITWebAutoLogin'
}

if ($env:OS -ne 'Windows_NT') {
    throw 'This installer supports Windows only.'
}

if ($TestMode) {
    if ([string]::IsNullOrWhiteSpace($TestStateDirectory)) {
        throw 'TestStateDirectory is required in TestMode.'
    }
    $testRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) 'BITWebAutoLogin-installer-tests')).TrimEnd('\') + '\'
    $resolvedTestState = [IO.Path]::GetFullPath($TestStateDirectory)
    if (-not $resolvedTestState.StartsWith($testRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "TestStateDirectory must be under $testRoot"
    }
    New-Item -ItemType Directory -Path $resolvedTestState -Force | Out-Null
}

$legacySourceFiles = @(
    'AutoLogin.ps1',
    'BITWebAutoLogin.psm1',
    'RunHidden.vbs',
    'settings.json',
    'Install.ps1',
    'Uninstall.ps1',
    'BITWebAutoLogin.Management.psm1',
    'Manage.ps1',
    'Open-GUI.cmd',
    'Open-GUI.vbs'
)
$nativeSourceFiles = @(
    'BITWebManager.exe',
    'BITWebUpdater.exe',
    'D3DCompiler_47_cor3.dll',
    'PenImc_cor3.dll',
    'PresentationNative_cor3.dll',
    'vcruntime140_cor3.dll',
    'wpfgfx_cor3.dll',
    'AutoLogin.ps1',
    'BITWebAutoLogin.psm1',
    'BITWebAutoLogin.Management.psm1',
    'RunHidden.vbs',
    'settings.json',
    'Install.ps1',
    'Install.cmd',
    'Uninstall.ps1',
    'release-manifest.json',
    'PowerShell\Get-ManagerStatus.ps1',
    'PowerShell\Invoke-ManagerAction.ps1',
    'PowerShell\Test-ManagerUpdatePackage.ps1',
    'legacy\Manage.ps1',
    'legacy\Open-GUI.cmd',
    'legacy\Open-GUI.vbs',
    'Licenses\Sarasa-Gothic-OFL.txt'
)
$isNativePackage = Test-Path -LiteralPath (Join-Path $sourceDirectory 'BITWebManager.exe') -PathType Leaf
$requiredSourceFiles = if ($isNativePackage) { $nativeSourceFiles } else { $legacySourceFiles }
foreach ($name in $requiredSourceFiles) {
    $path = Join-Path $sourceDirectory $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required source file not found: $path"
    }
}

$settings = Get-Content -LiteralPath (Join-Path $sourceDirectory 'settings.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$version = [string]$settings.Version
if ($version -notmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(-rc\.([1-9]\d*))?$') {
    throw "settings.json version '$version' is not a supported release version."
}

$credentialSource = Join-Path $sourceDirectory 'credential.xml'
$credentialTarget = Join-Path $InstallDirectory 'credential.xml'
$mainScriptTarget = Join-Path $InstallDirectory 'AutoLogin.ps1'
$existingSettings = Join-Path $InstallDirectory 'settings.json'
$oldSettings = if (Test-Path -LiteralPath $existingSettings -PathType Leaf) {
    Get-Content -LiteralPath $existingSettings -Raw -Encoding UTF8 | ConvertFrom-Json
} else { $null }

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
$transactionRoot = Join-Path ([IO.Path]::GetTempPath()) ('BITWebAutoLogin-install-' + [guid]::NewGuid().ToString('N'))
$backupRoot = Join-Path $transactionRoot 'backup'
New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
$deployedFiles = New-Object System.Collections.Generic.List[object]
$credentialExisted = Test-Path -LiteralPath $credentialTarget -PathType Leaf
$credentialBackup = Join-Path $transactionRoot 'credential.xml'
if ($credentialExisted) { Copy-Item -LiteralPath $credentialTarget -Destination $credentialBackup }
$shortcutPath = $null
$shortcutExisted = $false
$shortcutBackup = Join-Path $transactionRoot 'shortcut.lnk'
$copiedCount = 0
$existingTaskXml = $null
$taskWasChanged = $false
$testTaskStateExisted = $false
$testTaskStateBackup = $null
if ($TestMode) {
    $taskStatePath = Join-Path $resolvedTestState 'task-state.json'
    $testTaskStateExisted = Test-Path -LiteralPath $taskStatePath -PathType Leaf
    if ($testTaskStateExisted) { $testTaskStateBackup = Get-Content -LiteralPath $taskStatePath -Raw -Encoding UTF8 }
}

try {
    foreach ($name in $requiredSourceFiles) {
        if ($name -eq 'settings.json') { continue }
        $source = Join-Path $sourceDirectory $name
        $target = Join-Path $InstallDirectory $name
        if (-not [string]::Equals($resolvedSource, $resolvedTarget, [StringComparison]::OrdinalIgnoreCase)) {
            $existed = Test-Path -LiteralPath $target -PathType Leaf
            if ($existed) {
                $backup = Join-Path $backupRoot $name
                $backupParent = Split-Path -Parent $backup
                if (-not (Test-Path -LiteralPath $backupParent -PathType Container)) { New-Item -ItemType Directory -Path $backupParent -Force | Out-Null }
                Copy-Item -LiteralPath $target -Destination $backup
            }
            $targetParent = Split-Path -Parent $target
            if (-not (Test-Path -LiteralPath $targetParent -PathType Container)) {
                New-Item -ItemType Directory -Path $targetParent -Force | Out-Null
            }
            Copy-Item -LiteralPath $source -Destination $target -Force
            $deployedFiles.Add([pscustomobject]@{ Relative = $name; Existed = $existed }) | Out-Null
            $copiedCount++
            if ($TestMode -and $TestFailAfterCopy -ge 0 -and $copiedCount -ge $TestFailAfterCopy) {
                throw "Simulated copy failure after $copiedCount files."
            }
        }
    }

    $settingsExisted = Test-Path -LiteralPath $existingSettings -PathType Leaf
    if ($settingsExisted) { Copy-Item -LiteralPath $existingSettings -Destination (Join-Path $backupRoot 'settings.json') }
    $deployedFiles.Add([pscustomobject]@{ Relative = 'settings.json'; Existed = $settingsExisted }) | Out-Null
    $mergedSettings = [ordered]@{}
    foreach ($property in $settings.PSObject.Properties) { $mergedSettings[$property.Name] = $property.Value }
    if ($null -ne $oldSettings) {
        foreach ($property in $oldSettings.PSObject.Properties) {
            if ($property.Name -ne 'Version') { $mergedSettings[$property.Name] = $property.Value }
        }
    }
    $mergedSettings['Version'] = $version
    $mergedSettings | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $existingSettings -Encoding UTF8

    $programsDirectory = if ($TestMode) { Join-Path $resolvedTestState 'Programs' } else { Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs' }
    if (-not (Test-Path -LiteralPath $programsDirectory -PathType Container)) { New-Item -ItemType Directory -Path $programsDirectory -Force | Out-Null }
    $shortcutPath = Join-Path $programsDirectory 'BIT-Web 自动登录管理器.lnk'
    $shortcutExisted = Test-Path -LiteralPath $shortcutPath -PathType Leaf
    if ($shortcutExisted) { Copy-Item -LiteralPath $shortcutPath -Destination $shortcutBackup }
    $shortcutTarget = if ($isNativePackage) { Join-Path $InstallDirectory 'BITWebManager.exe' } else { Join-Path $env:SystemRoot 'System32\wscript.exe' }
    $shortcutArguments = if ($isNativePackage) { '' } else { '"{0}"' -f (Join-Path $InstallDirectory 'Open-GUI.vbs') }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $shortcutTarget
    $shortcut.Arguments = $shortcutArguments
    $shortcut.WorkingDirectory = $InstallDirectory
    $shortcut.Description = if ($isNativePackage) { '打开 BIT-Web Native Manager' } else { '按需打开 BIT-Web 自动登录管理器' }
    if ($isNativePackage) { $shortcut.IconLocation = "$shortcutTarget,0" }
    $shortcut.Save()

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

if ($TestMode) {
    $taskStatePath = Join-Path $resolvedTestState 'task-state.json'
    $taskState = [ordered]@{
        schemaVersion = 1
        count = 1
        taskName = $taskName
        execute = (Join-Path $env:SystemRoot 'System32\wscript.exe')
        arguments = ('"{0}"' -f (Join-Path $InstallDirectory 'RunHidden.vbs'))
        workingDirectory = $InstallDirectory
        trigger = 'AtLogOn'
        principal = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        logonType = 'Interactive'
        runLevel = 'Limited'
    }
    $taskState | ConvertTo-Json | Set-Content -LiteralPath $taskStatePath -Encoding UTF8
}
else {
    $launcherTarget = Join-Path $InstallDirectory 'RunHidden.vbs'
    $wscriptExe = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $arguments = '"{0}"' -f $launcherTarget
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $action = New-ScheduledTaskAction -Execute $wscriptExe -Argument $arguments -WorkingDirectory $InstallDirectory
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
    $taskBeforeInstall = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($null -ne $taskBeforeInstall) { $existingTaskXml = Export-ScheduledTask -TaskName $taskName }
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
    $taskWasChanged = $true

    if (-not $NoStart) {
        Start-ScheduledTask -TaskName $taskName
        $installedTask = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
        if ($null -eq $installedTask) {
            throw "The installed task could not be found after registration."
        }

        $monitorProcess = $null
        for ($attempt = 1; $attempt -le 10; $attempt++) {
            Start-Sleep -Seconds 1
            $monitorProcess = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
                Where-Object { $_.CommandLine -match '(?i)(^|[\\\" ])AutoLogin\.ps1([\\\" ]|$)' -and $_.CommandLine -match '(?i)(^|[\\\" ])-Live([\\\" ]|$)' } |
                Select-Object -First 1
            if ($null -ne $monitorProcess) {
                break
            }
        }
        if ($null -eq $monitorProcess) {
            throw "The installed task was registered but no live AutoLogin.ps1 monitor process was detected. Task state: $($installedTask.State)"
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
}

Write-Host "BIT-Web Auto Login v$version installed successfully."
Write-Host "Runtime: $InstallDirectory"
Write-Host "Task: $taskName"
Write-Host "Dashboard shortcut: $shortcutPath"
if ($NoStart) {
    Write-Host 'The task is installed but was not started because -NoStart was specified.'
}
else {
    Write-Host 'The task is running and will start automatically at Windows logon.'
}
}
catch {
    for ($index = $deployedFiles.Count - 1; $index -ge 0; $index--) {
        $item = $deployedFiles[$index]
        $target = Join-Path $InstallDirectory $item.Relative
        $backup = Join-Path $backupRoot $item.Relative
        if ($item.Existed -and (Test-Path -LiteralPath $backup -PathType Leaf)) {
            Copy-Item -LiteralPath $backup -Destination $target -Force
        }
        elseif (-not $item.Existed -and (Test-Path -LiteralPath $target -PathType Leaf)) {
            Remove-Item -LiteralPath $target -Force
        }
    }
    if ($credentialExisted -and (Test-Path -LiteralPath $credentialBackup -PathType Leaf)) {
        Copy-Item -LiteralPath $credentialBackup -Destination $credentialTarget -Force
    }
    elseif (-not $credentialExisted -and (Test-Path -LiteralPath $credentialTarget -PathType Leaf)) {
        Remove-Item -LiteralPath $credentialTarget -Force
    }
    if (-not [string]::IsNullOrWhiteSpace($shortcutPath)) {
        if ($shortcutExisted -and (Test-Path -LiteralPath $shortcutBackup -PathType Leaf)) {
            Copy-Item -LiteralPath $shortcutBackup -Destination $shortcutPath -Force
        }
        elseif (-not $shortcutExisted -and (Test-Path -LiteralPath $shortcutPath -PathType Leaf)) {
            Remove-Item -LiteralPath $shortcutPath -Force
        }
    }
    if ($TestMode -and -not [string]::IsNullOrWhiteSpace($TestStateDirectory)) {
        $taskStatePath = Join-Path $resolvedTestState 'task-state.json'
        if ($testTaskStateExisted) {
            Set-Content -LiteralPath $taskStatePath -Value $testTaskStateBackup -Encoding UTF8
        }
        elseif (Test-Path -LiteralPath $taskStatePath -PathType Leaf) {
            Remove-Item -LiteralPath $taskStatePath -Force
        }
    }
    elseif ($taskWasChanged) {
        try {
            if (-not [string]::IsNullOrWhiteSpace($existingTaskXml)) {
                Register-ScheduledTask -TaskName $taskName -Xml $existingTaskXml -Force | Out-Null
            }
            else {
                Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
            }
        }
        catch {
        }
    }
    throw
}
finally {
    if (Test-Path -LiteralPath $transactionRoot) { Remove-Item -LiteralPath $transactionRoot -Recurse -Force }
}
