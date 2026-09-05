# BIT-Web Auto Login - management operations used by the GUI
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:TaskNames = @(
    'BIT-Web AutoLogin',
    'BIT-Web AutoLogin v1.1',
    'BIT-Web AutoLogin v1.0'
)
$script:GitHubRepository = 'Oblivionis-ling/bit-web-auto-login'
$script:GitHubApiBase = 'https://api.github.com/repos/Oblivionis-ling/bit-web-auto-login'

function Get-BITWebInstallDirectory {
    [CmdletBinding()]
    param()

    return (Join-Path $env:LOCALAPPDATA 'BITWebAutoLogin')
}

function Get-BITWebManagementStatus {
    [CmdletBinding()]
    param(
        [string]$InstallDirectory = (Get-BITWebInstallDirectory),
        [string]$ProjectDirectory = $PSScriptRoot
    )

    $tasks = @()
    $taskError = $null
    try {
        foreach ($taskName in $script:TaskNames) {
            $candidate = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            if ($null -ne $candidate) {
                $tasks += $candidate
            }
        }
    }
    catch {
        $taskError = $_.Exception.Message
    }

    $installedCredential = Join-Path $InstallDirectory 'credential.xml'
    $sourceCredential = Join-Path $ProjectDirectory 'credential.xml'
    $credentialPaths = @($installedCredential)
    if (-not [string]::Equals(
        [IO.Path]::GetFullPath($sourceCredential),
        [IO.Path]::GetFullPath($installedCredential),
        [StringComparison]::OrdinalIgnoreCase
    )) {
        $credentialPaths += $sourceCredential
    }

    [pscustomobject]@{
        InstallDirectory = $InstallDirectory
        IsInstalled = ($tasks.Count -gt 0)
        TaskState = if ($tasks.Count -gt 0) {
            (@($tasks | ForEach-Object {
                if ($_.TaskName -eq 'BIT-Web AutoLogin') {
                    [string]$_.State
                }
                else {
                    "旧版 $($_.TaskName)：$($_.State)"
                }
            }) -join '；')
        }
        else {
            '未安装'
        }
        TaskError = $taskError
        CredentialExists = (@($credentialPaths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }).Count -gt 0)
        CredentialPaths = $credentialPaths
        InstalledVersion = if (Test-Path -LiteralPath (Join-Path $InstallDirectory 'settings.json') -PathType Leaf) {
            try {
                [string]((Get-Content -LiteralPath (Join-Path $InstallDirectory 'settings.json') -Raw -Encoding UTF8 | ConvertFrom-Json).Version)
            }
            catch {
                '无法读取'
            }
        }
        else {
            '—'
        }
    }
}

function Get-BITWebDashboardState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Status
    )

    if (-not [string]::IsNullOrWhiteSpace([string]$Status.TaskError)) {
        $autoLoginTitle = '状态读取失败'
        $autoLoginDetail = '请查看详细日志'
        $autoLoginTone = 'Error'
    }
    elseif (-not [bool]$Status.IsInstalled) {
        $autoLoginTitle = '尚未安装'
        $autoLoginDetail = '安装后自动保持认证'
        $autoLoginTone = 'Warning'
    }
    elseif ([string]$Status.TaskState -match '(?i)disabled') {
        $autoLoginTitle = '自动登录已停用'
        $autoLoginDetail = '任务存在，但当前已禁用'
        $autoLoginTone = 'Error'
    }
    elseif ([string]$Status.TaskState -match '(?i)ready|running') {
        $autoLoginTitle = '自动登录正常'
        $autoLoginDetail = '任务已安装并可用'
        $autoLoginTone = 'Success'
    }
    else {
        $autoLoginTitle = '自动登录需要关注'
        $autoLoginDetail = "任务状态：$($Status.TaskState)"
        $autoLoginTone = 'Warning'
    }

    if ([bool]$Status.CredentialExists) {
        $accountTitle = '账号已配置'
        $accountDetail = '密码由 Windows DPAPI 加密'
        $accountTone = 'Success'
    }
    else {
        $accountTitle = '账号未配置'
        $accountDetail = '安装或更换账号时填写'
        $accountTone = 'Warning'
    }

    $installedVersion = [string]$Status.InstalledVersion
    if ([string]::IsNullOrWhiteSpace($installedVersion) -or $installedVersion -eq '—' -or $installedVersion -eq '无法读取') {
        $versionValue = '—'
        $versionDetail = '当前版本未知'
        $versionTone = 'Warning'
    }
    else {
        $versionValue = $installedVersion
        $versionDetail = '当前安装版本'
        $versionTone = 'Neutral'
    }

    $isInstalled = [bool]$Status.IsInstalled
    [pscustomobject]@{
        AutoLoginTitle = $autoLoginTitle
        AutoLoginDetail = $autoLoginDetail
        AutoLoginTone = $autoLoginTone
        AccountTitle = $accountTitle
        AccountDetail = $accountDetail
        AccountTone = $accountTone
        VersionValue = $versionValue
        VersionDetail = $versionDetail
        VersionTone = $versionTone
        HeaderVersion = if ($versionValue -eq '—') { '版本未知' } else { "v$versionValue" }
        PrimaryAction = if ($isInstalled) { 'Update' } else { 'Install' }
        PrimaryTitle = if ($isInstalled) { '检查更新' } else { '安装自动登录' }
        PrimaryDescription = if ($isInstalled) {
            '从官方 GitHub 仓库获取并验证最新版本'
        }
        else {
            '配置账号并创建当前用户自动登录任务'
        }
        PrimaryButtonText = if ($isInstalled) { '检查并更新' } else { '安装自动登录' }
        RepairEnabled = $isInstalled
    }
}

function Invoke-BITWebProjectScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ScriptName,
        [hashtable]$Parameters = @{},
        [string]$ProjectDirectory = $PSScriptRoot
    )

    $scriptPath = Join-Path $ProjectDirectory $ScriptName
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw "找不到管理脚本：$scriptPath"
    }

    $lines = @(& $scriptPath @Parameters 2>&1 | ForEach-Object { [string]$_ })
    return ($lines -join [Environment]::NewLine)
}

function Install-BITWebAutoLogin {
    [CmdletBinding()]
    param(
        [switch]$RefreshCredential,
        [switch]$UpdateOnly,
        [string]$InstallDirectory = (Get-BITWebInstallDirectory),
        [string]$ProjectDirectory = $PSScriptRoot
    )

    if ($UpdateOnly) {
        $status = Get-BITWebManagementStatus -InstallDirectory $InstallDirectory -ProjectDirectory $ProjectDirectory
        if (-not $status.IsInstalled) {
            throw '尚未安装后台任务，请先使用“安装”。'
        }
    }

    $parameters = @{ InstallDirectory = $InstallDirectory }
    if ($RefreshCredential) {
        $parameters.RefreshCredential = $true
    }
    Invoke-BITWebProjectScript -ScriptName 'Install.ps1' -Parameters $parameters -ProjectDirectory $ProjectDirectory
}

function Get-BITWebRemoteUpdateInfo {
    [CmdletBinding()]
    param()

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $headers = @{
        'Accept' = 'application/vnd.github+json'
        'User-Agent' = 'BIT-Web-Auto-Login-Manager'
    }

    try {
        $release = Invoke-RestMethod `
            -Uri "$script:GitHubApiBase/releases/latest" `
            -Headers $headers `
            -UseBasicParsing `
            -ErrorAction Stop
        if (-not $release.draft -and -not $release.prerelease -and -not [string]::IsNullOrWhiteSpace([string]$release.tag_name)) {
            return [pscustomobject]@{
                Channel = 'Release'
                Identifier = [string]$release.tag_name
                DisplayVersion = [string]$release.tag_name
                ArchiveUrl = [string]$release.zipball_url
            }
        }
    }
    catch {
        # A repository without releases returns 404. Fall back to the verified main branch below.
    }

    $commit = Invoke-RestMethod `
        -Uri "$script:GitHubApiBase/commits/main" `
        -Headers $headers `
        -UseBasicParsing `
        -ErrorAction Stop
    $sha = [string]$commit.sha
    if ($sha -notmatch '^[0-9a-f]{40}$') {
        throw 'GitHub 返回了无效的 main 分支提交标识。'
    }

    return [pscustomobject]@{
        Channel = 'main'
        Identifier = $sha
        DisplayVersion = "main@$($sha.Substring(0, 7))"
        ArchiveUrl = "$script:GitHubApiBase/zipball/$sha"
    }
}

function Send-BITWebProgress {
    param(
        [scriptblock]$Callback,
        [string]$Stage,
        [string]$Message
    )

    if ($null -ne $Callback) {
        & $Callback $Stage $Message
    }
}

function Update-BITWebAutoLogin {
    [CmdletBinding()]
    param(
        [string]$InstallDirectory = (Get-BITWebInstallDirectory),
        [scriptblock]$ProgressCallback
    )

    $status = Get-BITWebManagementStatus -InstallDirectory $InstallDirectory -ProjectDirectory $PSScriptRoot
    if (-not $status.IsInstalled) {
        throw '尚未安装后台任务，请先使用“安装”。'
    }

    Send-BITWebProgress -Callback $ProgressCallback -Stage 'Checking' -Message '正在检查 GitHub 更新…'
    $remote = Get-BITWebRemoteUpdateInfo
    $statePath = Join-Path $InstallDirectory 'update-state.json'
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        try {
            $installedState = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]$installedState.Repository -eq $script:GitHubRepository -and
                [string]$installedState.Identifier -eq $remote.Identifier) {
                return "当前已经是 GitHub 最新版本：$($remote.DisplayVersion)"
            }
        }
        catch {
            # Ignore an unreadable state file and perform a full verified update.
        }
    }

    $temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ('BITWebAutoLogin-update-' + [guid]::NewGuid().ToString('N'))
    $archivePath = Join-Path $temporaryDirectory 'source.zip'
    $extractDirectory = Join-Path $temporaryDirectory 'source'
    New-Item -ItemType Directory -Path $extractDirectory -Force | Out-Null

    try {
        $headers = @{
            'Accept' = 'application/vnd.github+json'
            'User-Agent' = 'BIT-Web-Auto-Login-Manager'
        }
        $archiveUri = [uri]$remote.ArchiveUrl
        $expectedPathPrefix = "/repos/$script:GitHubRepository/zipball/"
        if ($archiveUri.Scheme -ne 'https' -or
            $archiveUri.Host -ne 'api.github.com' -or
            -not $archiveUri.AbsolutePath.StartsWith($expectedPathPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "拒绝非官方 GitHub 更新地址：$($remote.ArchiveUrl)"
        }
        Send-BITWebProgress -Callback $ProgressCallback -Stage 'Downloading' -Message "正在下载 $($remote.DisplayVersion)…"
        Invoke-WebRequest `
            -Uri $archiveUri `
            -Headers $headers `
            -UseBasicParsing `
            -OutFile $archivePath `
            -ErrorAction Stop
        Send-BITWebProgress -Callback $ProgressCallback -Stage 'Validating' -Message '正在解压并验证更新包…'
        Expand-Archive -LiteralPath $archivePath -DestinationPath $extractDirectory -Force

        $roots = @(Get-ChildItem -LiteralPath $extractDirectory -Directory)
        if ($roots.Count -ne 1) {
            throw 'GitHub 更新包目录结构无效。'
        }
        $sourceDirectory = $roots[0].FullName
        $requiredFiles = @(
            'AutoLogin.ps1',
            'BITWebAutoLogin.psm1',
            'RunHidden.vbs',
            'settings.json',
            'Install.ps1',
            'Uninstall.ps1'
        )
        foreach ($name in $requiredFiles) {
            if (-not (Test-Path -LiteralPath (Join-Path $sourceDirectory $name) -PathType Leaf)) {
                throw "GitHub 更新包缺少必要文件：$name"
            }
        }

        $parseFailures = New-Object System.Collections.Generic.List[string]
        Get-ChildItem -LiteralPath $sourceDirectory -Recurse -File -Include '*.ps1', '*.psm1' | ForEach-Object {
            $tokens = $null
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile(
                $_.FullName,
                [ref]$tokens,
                [ref]$errors
            ) | Out-Null
            if ($errors.Count -gt 0) {
                $parseFailures.Add($_.Name)
            }
        }
        if ($parseFailures.Count -gt 0) {
            throw "GitHub 更新包未通过 PowerShell 语法检查：$($parseFailures -join ', ')"
        }

        $remoteSettings = Get-Content -LiteralPath (Join-Path $sourceDirectory 'settings.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($remote.Channel -eq 'Release') {
            $expectedTag = 'v' + [string]$remoteSettings.Version
            if (-not [string]::Equals($expectedTag, $remote.Identifier, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Release 标签 '$($remote.Identifier)' 与包内版本 '$($remoteSettings.Version)' 不一致。"
            }
        }

        Send-BITWebProgress -Callback $ProgressCallback -Stage 'Installing' -Message '正在安装并重新启动自动登录…'
        & (Join-Path $sourceDirectory 'Install.ps1') -InstallDirectory $InstallDirectory

        $updateState = [ordered]@{
            Repository = $script:GitHubRepository
            Channel = $remote.Channel
            Identifier = $remote.Identifier
            DisplayVersion = $remote.DisplayVersion
            UpdatedAtUtc = [datetime]::UtcNow.ToString('o')
        }
        $temporaryStatePath = Join-Path $InstallDirectory 'update-state.json.tmp'
        $updateState | ConvertTo-Json | Set-Content -LiteralPath $temporaryStatePath -Encoding UTF8
        Move-Item -LiteralPath $temporaryStatePath -Destination $statePath -Force

        return "已从 GitHub 更新并重新启动：$($remote.DisplayVersion)"
    }
    finally {
        if (Test-Path -LiteralPath $temporaryDirectory -PathType Container) {
            Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
        }
    }
}

function Uninstall-BITWebAutoLogin {
    [CmdletBinding()]
    param(
        [string]$ProjectDirectory = $PSScriptRoot
    )

    Invoke-BITWebProjectScript -ScriptName 'Uninstall.ps1' -ProjectDirectory $ProjectDirectory
}

function Clear-BITWebCredential {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [string]$InstallDirectory = (Get-BITWebInstallDirectory),
        [string]$ProjectDirectory = $PSScriptRoot
    )

    $status = Get-BITWebManagementStatus -InstallDirectory $InstallDirectory -ProjectDirectory $ProjectDirectory
    $existingPaths = @($status.CredentialPaths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    $targetDescription = if ($existingPaths.Count -gt 0) { $existingPaths -join ', ' } else { '未找到凭据文件' }

    if (-not $PSCmdlet.ShouldProcess($targetDescription, '停用自动登录并删除 DPAPI 凭据')) {
        return '操作已取消；未停用任务，也未删除凭据。'
    }

    $output = New-Object System.Collections.Generic.List[string]
    $uninstallOutput = Uninstall-BITWebAutoLogin -ProjectDirectory $ProjectDirectory
    if (-not [string]::IsNullOrWhiteSpace($uninstallOutput)) {
        $output.Add($uninstallOutput)
    }

    if ($existingPaths.Count -eq 0) {
        $output.Add('未找到账号凭据；自动登录任务已停用。')
    }
    else {
        foreach ($path in $existingPaths) {
            Remove-Item -LiteralPath $path -Force
            $output.Add("已删除账号凭据：$path")
        }
    }
    return ($output -join [Environment]::NewLine)
}

Export-ModuleMember -Function @(
    'Get-BITWebInstallDirectory',
    'Get-BITWebManagementStatus',
    'Get-BITWebDashboardState',
    'Install-BITWebAutoLogin',
    'Update-BITWebAutoLogin',
    'Uninstall-BITWebAutoLogin',
    'Clear-BITWebCredential'
)
