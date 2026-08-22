# BIT-Web Auto Login v1.2 - offline-only tests
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
    Assert-Equal ([string]$settings.Version) '1.2' 'settings version'
    $mainSource = Get-Content -LiteralPath (Join-Path $projectRoot 'AutoLogin.ps1') -Raw -Encoding UTF8
    Assert-True ($mainSource -match '\$ScriptVersion = ''1\.2''') 'main script version'
    Assert-True (@($settings.ConnectivityChecks).Count -ge 2) 'redundant connectivity checks'
    Assert-True ([int]$settings.InternetFailureConfirmations -ge 2) 'consecutive failure confirmation'
    Assert-True ([int]$settings.AuthenticationCooldownSeconds -ge 300) 'authentication cooldown'
    Assert-True ([int]$settings.PostLoginVerifyAttempts -ge 2) 'post-login verification retries'
    Assert-Equal ([int]$settings.MaxRetrySeconds) 1800 'maximum retry delay'
}

Test-Case 'one-click installer uses a stable per-user deployment' {
    $source = Get-Content -LiteralPath (Join-Path $projectRoot 'Install.ps1') -Raw -Encoding UTF8
    Assert-True ($source -match '\$version = ''1\.2''') 'installer version'
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

Write-Host ("Offline test summary: {0} passed, {1} failed" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) {
    exit 1
}
exit 0
