# BIT-Web Auto Login v1.2.5 - offline-only tests
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $projectRoot 'BITWebAutoLogin.psm1'
Import-Module $modulePath -Force

$script:Passed = 0
$script:Failed = 0

function Test-Case {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )

    try {
        & $Body
        $script:Passed++
        Write-Host "PASS $Name"
    }
    catch {
        $script:Failed++
        Write-Host "FAIL $Name - $($_.Exception.Message)"
    }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Label)
    if ($Actual -ne $Expected) {
        throw "$Label expected '$Expected' but got '$Actual'"
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Label)
    if (-not $Condition) {
        throw "$Label expected true"
    }
}

Test-Case 'finds a standard relative-action login form' {
    $html = @'
<!doctype html>
<html><body>
<form action="/portal/login" method="post">
  <input type="hidden" name="csrf" value="a&amp;b">
  <input type="text" name="username">
  <input type="password" name="password">
  <input type="submit" name="action" value="login">
</form>
</body></html>
'@
    $form = Find-PortalLoginForm -Html $html -BaseUri ([uri]'http://10.0.0.55/')
    Assert-Equal $form.ActionUri.AbsoluteUri 'http://10.0.0.55/portal/login' 'action URI'
    Assert-Equal $form.Method 'POST' 'method'
    Assert-Equal $form.UsernameField 'username' 'username field'
    Assert-Equal $form.PasswordField 'password' 'password field'
    Assert-Equal $form.DefaultFields['csrf'] 'a&b' 'decoded hidden field'
    Assert-Equal $form.DefaultFields['action'] 'login' 'submit field'
}

Test-Case 'builds a payload from defaults, credential, and overrides' {
    $form = [pscustomobject]@{
        UsernameField = 'user'
        PasswordField = 'pass'
        DefaultFields = @{ token = 'offline-token'; action = 'login' }
    }
    $secure = ConvertTo-SecureString 'offline-test-password' -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential('offline-user', $secure)
    $payload = New-PortalLoginPayload -Form $form -Credential $credential -ExtraFields @{ action = 'connect'; domain = 'campus' }
    Assert-Equal $payload['user'] 'offline-user' 'username payload'
    Assert-Equal $payload['pass'] 'offline-test-password' 'password payload'
    Assert-Equal $payload['token'] 'offline-token' 'hidden payload'
    Assert-Equal $payload['action'] 'connect' 'override payload'
    Assert-Equal $payload['domain'] 'campus' 'extra payload'
}

Test-Case 'allows same-origin login URLs' {
    Assert-SafeLoginUri -PortalUri ([uri]'http://10.0.0.55/') -LoginUri ([uri]'http://10.0.0.55/login')
}

Test-Case 'rejects cross-origin login URLs by default' {
    $thrown = $false
    try {
        Assert-SafeLoginUri -PortalUri ([uri]'http://10.0.0.55/') -LoginUri ([uri]'http://example.invalid/login')
    }
    catch {
        $thrown = $true
    }
    Assert-True $thrown 'cross-origin rejection'
}

Test-Case 'doubles retry delay and respects the cap' {
    Assert-Equal (Get-NextRetryDelay -CurrentSeconds 30 -MaximumSeconds 1800) 60 'retry doubling'
    Assert-Equal (Get-NextRetryDelay -CurrentSeconds 960 -MaximumSeconds 1800) 1800 'retry cap'
    Assert-Equal (Get-NextRetryDelay -CurrentSeconds 1800 -MaximumSeconds 1800) 1800 'retry stays capped'
}

Test-Case 'healthy connectivity resets transient failure state' {
    $decision = Get-ConnectivityDecision `
        -InternetHealthy $true `
        -ConsecutiveFailures 1 `
        -RequiredFailures 2 `
        -Now ([datetime]'2026-07-29T12:00:00') `
        -CooldownUntil ([datetime]::MinValue) `
        -NextAttemptAt ([datetime]::MinValue)
    Assert-Equal $decision.Action 'Online' 'healthy action'
    Assert-Equal $decision.ConsecutiveFailures 0 'failure reset'
}

Test-Case 'first failed connectivity round requests confirmation' {
    $decision = Get-ConnectivityDecision `
        -InternetHealthy $false `
        -ConsecutiveFailures 0 `
        -RequiredFailures 2 `
        -Now ([datetime]'2026-07-29T12:00:00') `
        -CooldownUntil ([datetime]::MinValue) `
        -NextAttemptAt ([datetime]::MinValue)
    Assert-Equal $decision.Action 'Confirm' 'first-failure action'
    Assert-Equal $decision.ConsecutiveFailures 1 'first-failure count'
}

Test-Case 'second consecutive failed round permits authentication' {
    $decision = Get-ConnectivityDecision `
        -InternetHealthy $false `
        -ConsecutiveFailures 1 `
        -RequiredFailures 2 `
        -Now ([datetime]'2026-07-29T12:00:00') `
        -CooldownUntil ([datetime]::MinValue) `
        -NextAttemptAt ([datetime]::MinValue)
    Assert-Equal $decision.Action 'Authenticate' 'confirmed-failure action'
}

Test-Case 'authentication cooldown suppresses repeated login' {
    $decision = Get-ConnectivityDecision `
        -InternetHealthy $false `
        -ConsecutiveFailures 2 `
        -RequiredFailures 2 `
        -Now ([datetime]'2026-07-29T12:00:00') `
        -CooldownUntil ([datetime]'2026-07-29T12:05:00') `
        -NextAttemptAt ([datetime]::MinValue)
    Assert-Equal $decision.Action 'Cooldown' 'cooldown action'
}

Test-Case 'authentication error backoff suppresses retry' {
    $decision = Get-ConnectivityDecision `
        -InternetHealthy $false `
        -ConsecutiveFailures 2 `
        -RequiredFailures 2 `
        -Now ([datetime]'2026-07-29T12:00:00') `
        -CooldownUntil ([datetime]::MinValue) `
        -NextAttemptAt ([datetime]'2026-07-29T12:01:00')
    Assert-Equal $decision.Action 'Backoff' 'backoff action'
}

Test-Case 'matches the Srun SRBX1 JavaScript reference vector' {
    $info = ConvertTo-SrunInfo `
        -Username 'testuser' `
        -Password 'testpass' `
        -IpAddress '10.108.10.93' `
        -AcId '8' `
        -Token '0123456789abcdef0123456789abcdef'
    $expected = '{SRBX1}hV4+ngAtkcDZU1uYs4nHKHCazmn+dOMoQ8avsom2Wbr+t3L8mjlYjl4myb7nTGUq65Y4ZZgh5HD2u92DwMXV6WVl5Kj5FtIyNMjVEJUfM6+FtwS1nVyz0sCrcJ7ajCmsF68WfEIw0Q/='
    Assert-Equal $info $expected 'SRBX1 info'
}

Test-Case 'parses raw JSON and JSONP Srun responses' {
    $raw = ConvertFrom-Jsonp -Content '{"error":"ok","challenge":"abc"}'
    $jsonp = ConvertFrom-Jsonp -Content 'bitwebCallback({"error":"ok","challenge":"abc"});'
    Assert-Equal $raw.challenge 'abc' 'raw JSON challenge'
    Assert-Equal $jsonp.challenge 'abc' 'JSONP challenge'
}

Test-Case 'auto mode prefers the exact target Wi-Fi when both links exist' {
    $ethernet = [pscustomobject]@{
        Name = 'Ethernet'
        IPv4Addresses = @('10.108.10.93')
    }
    $context = Select-CampusConnectionContext `
        -Mode Auto `
        -TargetSsid 'BIT-Web' `
        -ConnectedWifiSsids @('BIT-Web') `
        -ActiveEthernetAdapters @($ethernet) `
        -EthernetIpv4Prefixes @('10.')
    Assert-True $context.Eligible 'auto mode eligibility'
    Assert-Equal $context.Kind 'Wifi' 'auto mode preference'
}

Test-Case 'auto mode accepts an allowed physical Ethernet address' {
    $ethernet = [pscustomobject]@{
        Name = 'Ethernet'
        IPv4Addresses = @('10.108.10.93')
    }
    $context = Select-CampusConnectionContext `
        -Mode Auto `
        -TargetSsid 'BIT-Web' `
        -ConnectedWifiSsids @() `
        -ActiveEthernetAdapters @($ethernet) `
        -EthernetIpv4Prefixes @('10.')
    Assert-True $context.Eligible 'Ethernet eligibility'
    Assert-Equal $context.Kind 'Ethernet' 'Ethernet kind'
    Assert-Equal $context.IPv4Address '10.108.10.93' 'Ethernet IPv4'
}

Test-Case 'Wi-Fi mode keeps Ethernet disabled' {
    $ethernet = [pscustomobject]@{
        Name = 'Ethernet'
        IPv4Addresses = @('10.108.10.93')
    }
    $context = Select-CampusConnectionContext `
        -Mode Wifi `
        -TargetSsid 'BIT-Web' `
        -ConnectedWifiSsids @() `
        -ActiveEthernetAdapters @($ethernet) `
        -EthernetIpv4Prefixes @('10.')
    Assert-True (-not $context.Eligible) 'Wi-Fi-only rejection'
}

Test-Case 'Ethernet mode rejects an address outside the allowlist' {
    $ethernet = [pscustomobject]@{
        Name = 'Ethernet'
        IPv4Addresses = @('192.168.1.20')
    }
    $context = Select-CampusConnectionContext `
        -Mode Ethernet `
        -TargetSsid 'BIT-Web' `
        -ConnectedWifiSsids @() `
        -ActiveEthernetAdapters @($ethernet) `
        -EthernetIpv4Prefixes @('10.')
    Assert-True (-not $context.Eligible) 'Ethernet prefix rejection'
}

Test-Case 'main monitor contains no Wi-Fi connect or profile mutation command' {
    $source = Get-Content -LiteralPath (Join-Path $projectRoot 'AutoLogin.ps1') -Raw
    Assert-True (-not ($source -match '(?i)netsh(?:\.exe)?\s+wlan\s+(?:connect|add|delete|set)')) 'no mutating netsh wlan command'
    Assert-True (-not ($source -match '(?i)\b(?:Set|Remove|New)-Net(?:Adapter|ConnectionProfile|IPAddress)')) 'no mutating Net cmdlet'
}

Test-Case 'safe preview path is explicitly gated before credential loading' {
    $source = Get-Content -LiteralPath (Join-Path $projectRoot 'AutoLogin.ps1') -Raw
    $previewIndex = $source.IndexOf('if (-not $Live)')
    $credentialIndex = $source.IndexOf('$credential = Get-LoginCredential -Path')
    Assert-True ($previewIndex -ge 0) 'preview gate exists'
    Assert-True ($credentialIndex -gt $previewIndex) 'credential function is called only after preview gate'
}

Test-Case 'settings enable redundant probes and anti-loop safeguards' {
    $settings = Get-Content -LiteralPath (Join-Path $projectRoot 'settings.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Equal ([string]$settings.Version) '1.3.0' 'settings version'
    $mainSource = Get-Content -LiteralPath (Join-Path $projectRoot 'AutoLogin.ps1') -Raw -Encoding UTF8
    Assert-True ($mainSource -match '\$ScriptVersion = ''1\.2\.5''') 'main script version'
    Assert-True (@($settings.ConnectivityChecks).Count -ge 2) 'redundant connectivity checks'
    Assert-True ([int]$settings.InternetFailureConfirmations -ge 2) 'consecutive failure confirmation'
    Assert-True ([int]$settings.AuthenticationCooldownSeconds -ge 300) 'authentication cooldown'
    Assert-True ([int]$settings.PostLoginVerifyAttempts -ge 2) 'post-login verification retries'
    Assert-Equal ([int]$settings.MaxRetrySeconds) 1800 'maximum retry delay'
}

Test-Case 'one-click installer uses a stable per-user deployment' {
    $source = Get-Content -LiteralPath (Join-Path $projectRoot 'Install.ps1') -Raw -Encoding UTF8
    Assert-True ($source -match '\$version = \[string\]\$settings\.Version') 'installer version comes from validated settings'
    Assert-True ($source.Contains("-rc\.([1-9]\d*)")) 'installer accepts only stable or rc.N release versions'
    Assert-True ($source -match '\$taskName = ''BIT-Web AutoLogin''') 'stable task name'
    Assert-True ($source -match "LOCALAPPDATA.*BITWebAutoLogin") 'per-user install directory'
    Assert-True ($source -match 'MultipleInstances IgnoreNew') 'duplicate process protection'
    Assert-True ($source -match 'RunHidden\.vbs') 'hidden launcher deployment'
    Assert-True ($source -match 'wscript\.exe') 'windowless task launcher'
    Assert-True (-not ($source -match '(?i)netsh(?:\.exe)?\s+wlan\s+(?:connect|add|delete|set)')) 'installer does not mutate Wi-Fi'
    Assert-True (Test-Path -LiteralPath (Join-Path $projectRoot 'Install.cmd') -PathType Leaf) 'double-click installer exists'
}

Test-Case 'one-click installer WhatIf makes no deployment changes' {
    $previewTarget = Join-Path $projectRoot ('_tmp\install-preview-' + [guid]::NewGuid().ToString('N'))
    $output = & powershell.exe `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File (Join-Path $projectRoot 'Install.ps1') `
        -InstallDirectory $previewTarget `
        -WhatIf 2>&1
    Assert-Equal $LASTEXITCODE 0 'installer WhatIf exit code'
    Assert-True (-not (Test-Path -LiteralPath $previewTarget)) 'installer WhatIf target absence'
    Assert-True (([string]($output -join "`n")) -match 'What if') 'installer WhatIf output'
}

Test-Case 'test scripts are isolated under tests' {
    $rootTestScripts = @(Get-ChildItem -LiteralPath $projectRoot -File -Filter '*.Tests.ps1')
    $testDirectoryScripts = @(Get-ChildItem -LiteralPath $PSScriptRoot -File -Filter '*.ps1')
    Assert-Equal $rootTestScripts.Count 0 'root test script count'
    Assert-True ($testDirectoryScripts.Count -ge 2) 'tests directory script count'
}

Test-Case 'management GUI is a thin wrapper around existing scripts' {
    $managementPath = Join-Path $projectRoot 'BITWebAutoLogin.Management.psm1'
    $guiPath = Join-Path $projectRoot 'Manage.ps1'
    $launcherPath = Join-Path $projectRoot 'Open-GUI.cmd'
    $hiddenLauncherPath = Join-Path $projectRoot 'Open-GUI.vbs'
    Assert-True (Test-Path -LiteralPath $managementPath -PathType Leaf) 'management module exists'
    Assert-True (Test-Path -LiteralPath $guiPath -PathType Leaf) 'GUI script exists'
    Assert-True (Test-Path -LiteralPath $launcherPath -PathType Leaf) 'GUI launcher exists'
    Assert-True (Test-Path -LiteralPath $hiddenLauncherPath -PathType Leaf) 'hidden GUI launcher exists'

    $managementSource = Get-Content -LiteralPath $managementPath -Raw -Encoding UTF8
    $guiSource = Get-Content -LiteralPath $guiPath -Raw -Encoding UTF8
    Assert-True ($managementSource -match "ScriptName 'Install\.ps1'") 'GUI install reuses installer'
    Assert-True ($managementSource -match "ScriptName 'Uninstall\.ps1'") 'GUI uninstall reuses uninstaller'
    Assert-True ($managementSource -match 'Remove-Item -LiteralPath \$path') 'credential deletion uses literal paths'
    Assert-True (-not ($guiSource -match '(?i)git\s+(?:pull|fetch|clone)')) 'GUI update does not require Git'
    Assert-True (-not ($guiSource -match '(?i)netsh(?:\.exe)?\s+wlan\s+(?:connect|add|delete|set)')) 'GUI does not mutate Wi-Fi'
    Assert-True ($managementSource -match 'https://api\.github\.com/repos/Oblivionis-ling/bit-web-auto-login') 'updater pins the official GitHub repository'
    Assert-True ($managementSource -match 'Expand-Archive') 'updater supports ZIP deployment without Git'
    Assert-True ($managementSource -match 'Language\.Parser.*ParseFile|ParseFile\(') 'updater validates PowerShell syntax'
    Assert-True ($managementSource -match "Host -ne 'api\.github\.com'") 'updater rejects non-GitHub archive hosts'
    $installerSource = Get-Content -LiteralPath (Join-Path $projectRoot 'Install.ps1') -Raw -Encoding UTF8
    Assert-True ($installerSource -match 'Start Menu\\Programs') 'installer creates an on-demand Start menu shortcut'
    Assert-True (-not ($installerSource -match '(?i)Startup')) 'dashboard is not configured for startup'
    Assert-True ($installerSource.IndexOf('$shortcut.Save()') -gt $installerSource.IndexOf('$PSCmdlet.ShouldProcess')) 'shortcut creation is gated by ShouldProcess'
}

Test-Case 'credential clear WhatIf preserves an exact temporary credential' {
    Import-Module (Join-Path $projectRoot 'BITWebAutoLogin.Management.psm1') -Force
    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('bitweb-management-' + [guid]::NewGuid().ToString('N'))
    $temporaryInstall = Join-Path $temporaryRoot 'runtime'
    New-Item -ItemType Directory -Path $temporaryInstall -Force | Out-Null
    $temporaryCredential = Join-Path $temporaryInstall 'credential.xml'
    Set-Content -LiteralPath $temporaryCredential -Value 'offline-placeholder' -Encoding UTF8
    try {
        Clear-BITWebCredential -InstallDirectory $temporaryInstall -ProjectDirectory $temporaryRoot -WhatIf | Out-Null
        Assert-True (Test-Path -LiteralPath $temporaryCredential -PathType Leaf) 'WhatIf credential preservation'
    }
    finally {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}

Test-Case 'dashboard status mapping covers installed and uninstalled states' {
    Import-Module (Join-Path $projectRoot 'BITWebAutoLogin.Management.psm1') -Force
    $installed = Get-BITWebDashboardState -Status ([pscustomobject]@{
        IsInstalled = $true
        TaskState = 'Ready'
        TaskError = $null
        CredentialExists = $true
        InstalledVersion = '1.2.5'
    })
    Assert-Equal $installed.AutoLoginTitle '自动登录正常' 'installed auto-login title'
    Assert-Equal $installed.AccountTitle '账号已配置' 'installed account title'
    Assert-Equal $installed.PrimaryAction 'Update' 'installed primary action'
    Assert-True $installed.RepairEnabled 'installed repair availability'

    $credentialOnly = Get-BITWebDashboardState -Status ([pscustomobject]@{
        IsInstalled = $false
        TaskState = '未安装'
        TaskError = $null
        CredentialExists = $true
        InstalledVersion = '1.2.5'
    })
    Assert-Equal $credentialOnly.AutoLoginTitle '尚未安装' 'credential-only auto-login title'
    Assert-Equal $credentialOnly.AccountTitle '账号已配置' 'credential-only account title'
    Assert-Equal $credentialOnly.PrimaryAction 'Install' 'credential-only primary action'

    $empty = Get-BITWebDashboardState -Status ([pscustomobject]@{
        IsInstalled = $false
        TaskState = '未安装'
        TaskError = $null
        CredentialExists = $false
        InstalledVersion = '—'
    })
    Assert-Equal $empty.AccountTitle '账号未配置' 'empty account title'
    Assert-Equal $empty.VersionValue '—' 'empty version value'
    Assert-True (-not $empty.RepairEnabled) 'empty repair availability'
}

Test-Case 'GUI V2 keeps dashboard and safety boundaries explicit' {
    $guiSource = Get-Content -LiteralPath (Join-Path $projectRoot 'Manage.ps1') -Raw -Encoding UTF8
    Assert-True (-not ($guiSource -match 'System\.Windows\.Forms\.GroupBox')) 'no traditional GroupBox layout'
    Assert-True ($guiSource -match 'LogExpanded = \$false') 'detailed log defaults collapsed'
    Assert-True ($guiSource -match 'Get-BITWebDashboardState') 'GUI uses management status mapping'
    Assert-True ($guiSource -match 'ProgressCallback') 'GUI receives update progress stages'
    Assert-True ($guiSource -match 'Set-ControlsBusy -Busy \$true') 'GUI disables actions while busy'
    Assert-True ($guiSource -match 'ExpandOnError') 'errors expand detailed logs'
    Assert-True ($guiSource -match 'Clear-BITWebCredential -Confirm:\$false') 'credential clear uses the management safety function'
    Assert-True ($guiSource -match "'YesNo'.*|'YesNo'") 'destructive action confirmation remains present'
    Assert-True (-not ($guiSource -match '(?i)Import-Clixml|GetNetworkCredential|\.Password')) 'GUI does not read credentials'
    Assert-True (-not ($guiSource -match '(?i)NotifyIcon|ApplicationContext|Startup')) 'GUI does not add tray or startup behavior'
    Assert-True ($guiSource -match '\[void\]\$form\.ShowDialog\(\)') 'GUI exits after its on-demand dialog closes'
}

Test-Case 'native manager Phase 3 keeps orchestration and update safety boundaries explicit' {
    $managerRoot = Join-Path $projectRoot 'manager\BITWebManager'
    $updaterRoot = Join-Path $projectRoot 'manager\BITWebUpdater'
    $statusBridgePath = Join-Path $projectRoot 'scripts\Get-ManagerStatus.ps1'
    $actionBridgePath = Join-Path $projectRoot 'scripts\Invoke-ManagerAction.ps1'
    Assert-True (Test-Path -LiteralPath (Join-Path $managerRoot 'BITWebManager.csproj') -PathType Leaf) 'WPF manager project exists'
    Assert-True (Test-Path -LiteralPath $statusBridgePath -PathType Leaf) 'status bridge exists'
    Assert-True (Test-Path -LiteralPath $actionBridgePath -PathType Leaf) 'action bridge exists'

    $managerSource = [string]::Join("`n", @(
        Get-ChildItem -LiteralPath $managerRoot -Recurse -File |
            Where-Object { $_.Extension -in @('.cs', '.xaml') } |
            ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 }
    ))
    $updaterSource = [string]::Join("`n", @(
        Get-ChildItem -LiteralPath $updaterRoot -Recurse -File |
            Where-Object { $_.Extension -eq '.cs' } |
            ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 }
    ))
    $statusBridgeSource = Get-Content -LiteralPath $statusBridgePath -Raw -Encoding UTF8
    $actionBridgeSource = Get-Content -LiteralPath $actionBridgePath -Raw -Encoding UTF8
    Assert-True ($managerSource -match 'PowerShellService') 'PowerShell calls are centralized'
    Assert-True ($managerSource -match 'CreateNoWindow = !options\.Interactive') 'noninteractive PowerShell console remains hidden'
    Assert-True (-not ($managerSource -match '(?i)Register-ScheduledTask|Unregister-ScheduledTask|Import-Clixml|Export-Clixml|GetNetworkCredential|\.Password')) 'C# does not implement task or credential internals'
    Assert-True ($managerSource -match 'HttpClient') 'native updater uses the standard .NET HTTP client'
    Assert-True ($managerSource -match 'Oblivionis-ling' -and $managerSource -match 'bit-web-auto-login') 'native updater locks the official repository'
    Assert-True ($managerSource -match 'AllowAutoRedirect = false') 'native updater validates redirects manually'
    Assert-True ($managerSource -match 'credential\.xml') 'package validation explicitly rejects credential files'
    Assert-True ($updaterSource -match 'Rollback' -and $updaterSource -match 'RunHealthCheck') 'updater implements health-checked rollback'
    Assert-True (-not ($updaterSource -match '(?i)HttpClient|api\.github\.com|GetNetworkCredential|\.Password')) 'helper contains no network or credential logic'
    Assert-True ($statusBridgeSource -match 'Get-BITWebManagementStatus') 'status bridge reuses management status'
    Assert-True ($actionBridgeSource -match "ValidateSet\('RefreshCredential', 'Install', 'Repair', 'Uninstall', 'ClearCredential'\)") 'action allowlist excludes update'
    Assert-True ($actionBridgeSource -match 'Install-BITWebAutoLogin @common -RefreshCredential') 'credential refresh reuses installer'
    Assert-True ($actionBridgeSource -match 'Install-BITWebAutoLogin @common -UpdateOnly') 'repair reuses installer semantics'
    Assert-True ($actionBridgeSource -match 'Uninstall-BITWebAutoLogin') 'uninstall reuses management module'
    Assert-True ($actionBridgeSource -match 'Clear-BITWebCredential @common -Confirm:\$false') 'credential clear reuses guarded management function'
    Assert-True (-not ($actionBridgeSource -match '(?i)Register-ScheduledTask|Unregister-ScheduledTask|Remove-Item|Import-Clixml|Export-Clixml|Invoke-WebRequest')) 'action bridge does not reimplement protected operations'
    Assert-True ($actionBridgeSource -match '\[Console\]::Out\.WriteLine') 'action bridge writes JSON to stdout'
    Assert-True ($actionBridgeSource -match '\[Console\]::Error\.WriteLine') 'action bridge separates errors to stderr'
    Assert-True ($managerSource -match '(?s)ConfirmClearCredential\(\).*ConfirmClearCredentialAgain\(\)') 'credential clear requires two confirmations'
    Assert-True ($managerSource -match 'UseShellExecute = true') 'install directory opens through the shell API'
    Assert-True (-not ($managerSource -match 'FileName\s*=\s*"explorer\.exe"')) 'manager does not build explorer command strings'
    Assert-True ($managerSource -match 'pack://application:,,,/Resources/Fonts/#Sarasa UI SC') 'manager uses the embedded Sarasa UI SC family'
    Assert-True (Test-Path -LiteralPath (Join-Path $managerRoot 'Resources\Fonts\SarasaUiSC-Regular.ttf') -PathType Leaf) 'Sarasa regular font is bundled'
    Assert-True (Test-Path -LiteralPath (Join-Path $managerRoot 'Resources\Fonts\SarasaUiSC-SemiBold.ttf') -PathType Leaf) 'Sarasa semibold font is bundled'
    Assert-True (Test-Path -LiteralPath (Join-Path $managerRoot 'Resources\Fonts\OFL.txt') -PathType Leaf) 'Sarasa OFL license is bundled'
}

Test-Case 'Phase 4 release build and native installer stay deterministic and migration-safe' {
    $buildPath = Join-Path $projectRoot 'build\Build-Release.ps1'
    $installerPath = Join-Path $projectRoot 'Install.ps1'
    Assert-True (Test-Path -LiteralPath $buildPath -PathType Leaf) 'release build script exists'
    $buildSource = Get-Content -LiteralPath $buildPath -Raw -Encoding UTF8
    $installerSource = Get-Content -LiteralPath $installerPath -Raw -Encoding UTF8
    Assert-True ($buildSource -match "PublishSingleFile=true") 'release uses single-file publish'
    Assert-True ($buildSource -match "EnableCompressionInSingleFile=true") 'release uses single-file compression'
    Assert-True ($buildSource -match "PublishTrimmed=false") 'release disables trimming'
    Assert-True ($buildSource -match "PublishReadyToRun=false") 'release disables ReadyToRun'
    Assert-True ($buildSource -match "--self-contained.*true") 'release is self-contained'
    Assert-True ($buildSource -match 'Directory\.Build\.props') 'canonical version comes from Directory.Build.props'
    Assert-True ($buildSource -match 'release-manifest\.json' -and $buildSource -match '\.sha256') 'release emits manifest and checksum'
    Assert-True (-not ($buildSource -match '(?i)gh\s+release|git\s+(?:push|tag)')) 'build script does not publish GitHub or Git'
    Assert-True ($installerSource -match 'Join-Path \$InstallDirectory ''BITWebManager\.exe''') 'shortcut targets native manager'
    Assert-True ($installerSource -match 'oldSettings' -and $installerSource -match 'mergedSettings') 'installer merges existing settings'
    Assert-True ($installerSource -match 'credentialBackup' -and $installerSource -match 'deployedFiles') 'installer protects credential and rolls back copied files'
    Assert-True ($installerSource -match '\$TestMode' -and $installerSource -match 'BITWebAutoLogin-installer-tests') 'installer test mode is isolated under temp'
}

Test-Case 'Phase 5 native manager keeps final visual and release experience assets' {
    $managerRoot = Join-Path $projectRoot 'manager\BITWebManager'
    $xaml = Get-Content -LiteralPath (Join-Path $managerRoot 'MainWindow.xaml') -Raw -Encoding UTF8
    $appXaml = Get-Content -LiteralPath (Join-Path $managerRoot 'App.xaml') -Raw -Encoding UTF8
    $project = Get-Content -LiteralPath (Join-Path $managerRoot 'BITWebManager.csproj') -Raw -Encoding UTF8
    $viewModel = Get-Content -LiteralPath (Join-Path $managerRoot 'ViewModels\MainWindowViewModel.cs') -Raw -Encoding UTF8
    $iconPath = Join-Path $managerRoot 'Resources\BITWebManager.ico'
    Assert-True (Test-Path -LiteralPath $iconPath -PathType Leaf) 'multi-size application icon exists'
    Assert-True ((Get-Item -LiteralPath $iconPath).Length -gt 4096) 'application icon contains rendered frames'
    Assert-True ($project -match '<ApplicationIcon>Resources\\BITWebManager\.ico</ApplicationIcon>') 'EXE embeds the application icon'
    Assert-True ($xaml -match 'Icon="Resources/BITWebManager\.ico"') 'window uses the application icon'
    Assert-True ($viewModel -match 'PrimaryActionText => IsInstalled \? "检查更新" : "安装自动登录"') 'primary action follows installation state'
    Assert-True ($xaml -notmatch 'Text="当前版本"') 'legacy core version is not repeated in the status card'
    Assert-True ($xaml -match 'BIT-Web 不读取或显示保存的密码') 'final security statement remains visible'
    Assert-True ($appXaml -match 'IsPressed' -and $appXaml -match 'IsKeyboardFocused') 'button pressed and keyboard focus states are styled'
}

Write-Host ("Offline test summary: {0} passed, {1} failed" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) {
    exit 1
}
exit 0
