[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackageZip
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$passed = 0
$failed = 0

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:passed++; Write-Host "PASS $Name" }
    catch { $script:failed++; Write-Host "FAIL $Name - $($_.Exception.Message)" }
}

function New-TestCredential([string]$Path) {
    $secure = New-Object Security.SecureString
    $credential = New-Object Management.Automation.PSCredential('phase4-test-user', $secure)
    $credential | Export-Clixml -LiteralPath $Path -Force
}

function Get-Shortcut([string]$Path) {
    $shell = New-Object -ComObject WScript.Shell
    return $shell.CreateShortcut($Path)
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('BITWebAutoLogin-installer-tests\' + [guid]::NewGuid().ToString('N'))
$extractRoot = Join-Path $testRoot 'package'
New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null

try {
    Expand-Archive -LiteralPath ([IO.Path]::GetFullPath($PackageZip)) -DestinationPath $extractRoot
    $source = Get-ChildItem -LiteralPath $extractRoot -Directory | Select-Object -First 1 -ExpandProperty FullName
    if ([string]::IsNullOrWhiteSpace($source)) { throw 'Release package root was not found.' }
    $packageVersion = [string](Get-Content -LiteralPath (Join-Path $source 'settings.json') -Raw -Encoding UTF8 | ConvertFrom-Json).Version
    Assert-True ($packageVersion -match '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(-rc\.([1-9]\d*))?$') 'package version uses restricted stable or RC grammar'

    Test-Case 'v1.2.5 upgrade preserves credential and settings while migrating task and shortcut' {
        $target = Join-Path $testRoot 'upgrade-target'
        $state = Join-Path $testRoot 'upgrade-state'
        New-Item -ItemType Directory -Path $target, (Join-Path $state 'Programs') -Force | Out-Null
        New-TestCredential (Join-Path $target 'credential.xml')
        Set-Content -LiteralPath (Join-Path $target 'settings.json') -Value '{"Version":"1.2.5","PollSeconds":77,"UserChoice":"keep"}' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $target 'AutoLogin.ps1') -Value '# old-v1.2.5' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $state 'task-state.json') -Value '{"schemaVersion":1,"count":1,"taskName":"BIT-Web AutoLogin","execute":"old"}' -Encoding UTF8
        $shortcutPath = Join-Path $state 'Programs\BIT-Web 自动登录管理器.lnk'
        $oldShortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcutPath)
        $oldShortcut.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
        $oldShortcut.Arguments = 'Open-GUI.vbs'
        $oldShortcut.Save()

        $beforeCredential = (Get-FileHash -LiteralPath (Join-Path $target 'credential.xml') -Algorithm SHA256).Hash
        & (Join-Path $source 'Install.ps1') -InstallDirectory $target -NoStart -TestMode -TestStateDirectory $state
        $afterCredential = (Get-FileHash -LiteralPath (Join-Path $target 'credential.xml') -Algorithm SHA256).Hash
        Assert-True ($beforeCredential -eq $afterCredential) 'credential SHA-256 unchanged'
        $merged = Get-Content -LiteralPath (Join-Path $target 'settings.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-True ($merged.Version -eq $packageVersion) 'settings version upgraded'
        Assert-True ($merged.PollSeconds -eq 77 -and $merged.UserChoice -eq 'keep') 'old user settings preserved'
        Assert-True ($merged.PostLoginVerifyAttempts -eq 4) 'new default setting present'
        Assert-True (Test-Path -LiteralPath (Join-Path $target 'BITWebManager.exe')) 'manager installed'
        Assert-True (Test-Path -LiteralPath (Join-Path $target 'BITWebUpdater.exe')) 'updater installed'
        $shortcut = Get-Shortcut $shortcutPath
        Assert-True ($shortcut.TargetPath -eq (Join-Path $target 'BITWebManager.exe')) 'shortcut migrated to native manager'
        Assert-True ([string]::IsNullOrWhiteSpace($shortcut.Arguments)) 'shortcut has no legacy arguments'
        Assert-True ($shortcut.IconLocation -like "$(Join-Path $target 'BITWebManager.exe'),0") 'shortcut uses the embedded native manager icon'
        $task = Get-Content -LiteralPath (Join-Path $state 'task-state.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-True ($task.count -eq 1 -and $task.taskName -eq 'BIT-Web AutoLogin') 'one stable task remains'
        Assert-True ($task.arguments -match 'RunHidden\.vbs' -and $task.workingDirectory -eq $target) 'task action targets new runtime'
        Assert-True ($task.trigger -eq 'AtLogOn' -and $task.logonType -eq 'Interactive' -and $task.runLevel -eq 'Limited') 'task trigger and principal preserved'

        & (Join-Path $source 'Install.ps1') -InstallDirectory $target -NoStart -TestMode -TestStateDirectory $state
        $secondCredential = (Get-FileHash -LiteralPath (Join-Path $target 'credential.xml') -Algorithm SHA256).Hash
        $secondTask = Get-Content -LiteralPath (Join-Path $state 'task-state.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-True ($secondCredential -eq $beforeCredential) 'credential unchanged after repair install'
        Assert-True ($secondTask.count -eq 1) 'repair does not duplicate task'
    }

    Test-Case 'fresh native install deploys the release runtime without Git or .NET input' {
        $freshSource = Join-Path $testRoot 'fresh-source'
        $target = Join-Path $testRoot 'fresh-target'
        $state = Join-Path $testRoot 'fresh-state'
        Copy-Item -LiteralPath $source -Destination $freshSource -Recurse
        New-TestCredential (Join-Path $freshSource 'credential.xml')
        & (Join-Path $freshSource 'Install.ps1') -InstallDirectory $target -NoStart -TestMode -TestStateDirectory $state
        Assert-True (Test-Path -LiteralPath (Join-Path $target 'BITWebManager.exe')) 'manager deployed'
        Assert-True (Test-Path -LiteralPath (Join-Path $target 'BITWebUpdater.exe')) 'updater deployed'
        Assert-True (Test-Path -LiteralPath (Join-Path $target 'PowerShell\Get-ManagerStatus.ps1')) 'status bridge deployed'
        Assert-True (Test-Path -LiteralPath (Join-Path $target 'legacy\Manage.ps1')) 'legacy fallback retained'
        Assert-True (Test-Path -LiteralPath (Join-Path $target 'Licenses\Sarasa-Gothic-OFL.txt')) 'font license deployed'
        $task = Get-Content -LiteralPath (Join-Path $state 'task-state.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-True ($task.count -eq 1) 'fresh install creates one task'
    }

    Test-Case 'simulated mid-copy failure restores the existing v1.2.5 installation' {
        $target = Join-Path $testRoot 'rollback-target'
        $state = Join-Path $testRoot 'rollback-state'
        New-Item -ItemType Directory -Path $target, (Join-Path $state 'Programs') -Force | Out-Null
        New-TestCredential (Join-Path $target 'credential.xml')
        Set-Content -LiteralPath (Join-Path $target 'settings.json') -Value '{"Version":"1.2.5","PollSeconds":91}' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $target 'AutoLogin.ps1') -Value '# rollback-old' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $state 'task-state.json') -Value '{"schemaVersion":1,"count":1,"taskName":"BIT-Web AutoLogin","execute":"old"}' -Encoding UTF8
        $credentialHash = (Get-FileHash -LiteralPath (Join-Path $target 'credential.xml') -Algorithm SHA256).Hash
        $settingsHash = (Get-FileHash -LiteralPath (Join-Path $target 'settings.json') -Algorithm SHA256).Hash
        $scriptHash = (Get-FileHash -LiteralPath (Join-Path $target 'AutoLogin.ps1') -Algorithm SHA256).Hash
        $failedAsExpected = $false
        try {
            & (Join-Path $source 'Install.ps1') -InstallDirectory $target -NoStart -TestMode -TestStateDirectory $state -TestFailAfterCopy 3
        }
        catch { $failedAsExpected = $true }
        Assert-True $failedAsExpected 'failure was injected'
        Assert-True ((Get-FileHash -LiteralPath (Join-Path $target 'credential.xml') -Algorithm SHA256).Hash -eq $credentialHash) 'credential restored'
        Assert-True ((Get-FileHash -LiteralPath (Join-Path $target 'settings.json') -Algorithm SHA256).Hash -eq $settingsHash) 'settings restored'
        Assert-True ((Get-FileHash -LiteralPath (Join-Path $target 'AutoLogin.ps1') -Algorithm SHA256).Hash -eq $scriptHash) 'old script restored'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $target 'BITWebManager.exe'))) 'partially copied manager removed'
        $task = Get-Content -LiteralPath (Join-Path $state 'task-state.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-True ($task.execute -eq 'old' -and $task.count -eq 1) 'task state unchanged'
    }
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

Write-Host ("Native installer test summary: {0} passed, {1} failed" -f $passed, $failed)
if ($failed -gt 0) { exit 1 }
exit 0
