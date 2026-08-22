# BIT-Web Auto Login v1.2
[CmdletBinding()]
param(
    [switch]$Live,
    [switch]$Once,
    [ValidateSet('Auto', 'Wifi', 'Ethernet')]
    [string]$ConnectionMode,
    [string]$ConfigPath,
    [string]$CredentialPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ScriptVersion = '1.2'
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot 'settings.json'
}
if ([string]::IsNullOrWhiteSpace($CredentialPath)) {
    $CredentialPath = Join-Path $PSScriptRoot 'credential.xml'
}
$ModulePath = Join-Path $PSScriptRoot 'BITWebAutoLogin.psm1'
Import-Module $ModulePath -Force

function Read-Settings {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Settings file not found: $Path"
    }
    $value = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json

    foreach ($required in @(
        'ConnectionMode', 'Ssid', 'EthernetIpv4Prefixes',
        'PortalUrl', 'ConnectivityCheckUrl', 'ConnectivityChecks', 'PollSeconds',
        'InternetFailureConfirmations', 'FailureConfirmationIntervalSeconds',
        'InitialRetrySeconds', 'MaxRetrySeconds', 'AuthenticationCooldownSeconds',
        'PostLoginWaitSeconds', 'PostLoginVerifyAttempts',
        'PostLoginVerifyIntervalSeconds', 'RequestTimeoutSeconds', 'LogRetentionDays'
    )) {
        if ($null -eq $value.PSObject.Properties[$required]) {
            throw "Required settings.json property missing: $required"
        }
    }

    $portalUri = [uri]$value.PortalUrl
    $checkUri = [uri]$value.ConnectivityCheckUrl
    if ($portalUri.Scheme -notin @('http', 'https')) {
        throw 'PortalUrl must use http or https.'
    }
    if ($checkUri.Scheme -notin @('http', 'https')) {
        throw 'ConnectivityCheckUrl must use http or https.'
    }
    if (@($value.ConnectivityChecks).Count -lt 2) {
        throw 'ConnectivityChecks must contain at least two independent checks.'
    }
    foreach ($check in @($value.ConnectivityChecks)) {
        if ($null -eq $check.PSObject.Properties['Url'] -or
            [string]::IsNullOrWhiteSpace([string]$check.Url)) {
            throw 'Each ConnectivityChecks item must provide Url.'
        }
        $checkItemUri = [uri]$check.Url
        if ($checkItemUri.Scheme -notin @('http', 'https')) {
            throw 'Every ConnectivityChecks URL must use http or https.'
        }
    }
    foreach ($numberName in @(
        'PollSeconds', 'InternetFailureConfirmations',
        'FailureConfirmationIntervalSeconds', 'InitialRetrySeconds',
        'MaxRetrySeconds', 'AuthenticationCooldownSeconds',
        'PostLoginWaitSeconds', 'PostLoginVerifyAttempts',
        'PostLoginVerifyIntervalSeconds', 'RequestTimeoutSeconds',
        'LogRetentionDays'
    )) {
        if ([int]$value.$numberName -lt 1) {
            throw "$numberName must be greater than zero."
        }
    }
    if ([int]$value.InitialRetrySeconds -gt [int]$value.MaxRetrySeconds) {
        throw 'InitialRetrySeconds cannot exceed MaxRetrySeconds.'
    }
    if ([int]$value.InternetFailureConfirmations -lt 2) {
        throw 'InternetFailureConfirmations must be at least 2.'
    }
    if ([string]$value.ConnectionMode -notin @('Auto', 'Wifi', 'Ethernet')) {
        throw 'ConnectionMode must be Auto, Wifi, or Ethernet.'
    }
    if (@($value.EthernetIpv4Prefixes).Count -lt 1) {
        throw 'EthernetIpv4Prefixes must contain at least one allowed prefix.'
    }
    return $value
}

function Write-AppLog {
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $logDirectory = Join-Path $PSScriptRoot 'logs'
    if (-not (Test-Path -LiteralPath $logDirectory)) {
        New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    }
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath (Join-Path $logDirectory ((Get-Date -Format 'yyyy-MM-dd') + '.log')) -Value $line -Encoding UTF8
}

function Remove-ExpiredLogs {
    param([int]$RetentionDays)

    $logDirectory = Join-Path $PSScriptRoot 'logs'
    if (-not (Test-Path -LiteralPath $logDirectory)) {
        return
    }
    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    Get-ChildItem -LiteralPath $logDirectory -File -Filter '*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Set-StateLog {
    param(
        [Parameter(Mandatory = $true)][string]$State,
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )

    if ($script:LastState -ne $State) {
        Write-AppLog -Level $Level -Message $Message
        $script:LastState = $State
    }
}

function Get-LoginCredential {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ($null -ne $script:CredentialCache) {
        return $script:CredentialCache
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Encrypted credential file not found. Rerun Install.ps1 -RefreshCredential from the downloaded project: $Path"
    }
    $value = Import-Clixml -LiteralPath $Path
    if ($value -isnot [pscredential]) {
        throw "Invalid credential file: $Path"
    }
    $script:CredentialCache = $value
    return $script:CredentialCache
}

$settings = Read-Settings -Path $ConfigPath
if ([string]::IsNullOrWhiteSpace($ConnectionMode)) {
    $ConnectionMode = [string]$settings.ConnectionMode
}

if (-not $Live) {
    Write-Host "BIT-Web Auto Login v$ScriptVersion (safe preview mode)"
    Write-Host 'No network request was sent. Credentials were not read. Network settings were not changed.'
    Write-Host ("Connection mode: {0}" -f $ConnectionMode)
    Write-Host ("Target SSID: {0}" -f $settings.Ssid)
    Write-Host ("Allowed Ethernet IPv4 prefixes: {0}" -f (@($settings.EthernetIpv4Prefixes) -join ', '))
    Write-Host ("Portal URL: {0}" -f $settings.PortalUrl)
    Write-Host ("Connectivity probes: {0}; failures required before login: {1}" -f (@($settings.ConnectivityChecks).Count), $settings.InternetFailureConfirmations)
    Write-Host ("Authentication cooldown: {0}s; post-login verification attempts: {1}" -f $settings.AuthenticationCooldownSeconds, $settings.PostLoginVerifyAttempts)
    Write-Host ("Poll: {0}s; maximum retry delay: {1}s" -f $settings.PollSeconds, $settings.MaxRetrySeconds)
    Write-Host 'User-only live test command: .\AutoLogin.ps1 -Live -Once'
    return
}

$portal = [uri]$settings.PortalUrl
if ($portal.Scheme -eq 'http') {
    Write-Warning 'The portal uses HTTP. Login data may travel unencrypted on the campus network.'
}

Remove-ExpiredLogs -RetentionDays ([int]$settings.LogRetentionDays)
Write-AppLog -Level INFO -Message "BIT-Web Auto Login v$ScriptVersion started in $ConnectionMode mode. This script does not switch or configure network adapters."

$script:LastState = ''
$script:CredentialCache = $null
$retrySeconds = [int]$settings.InitialRetrySeconds
$nextAttemptAt = [datetime]::MinValue
$authenticationCooldownUntil = [datetime]::MinValue
$consecutiveInternetFailures = 0

while ($true) {
    $sleepSeconds = [int]$settings.PollSeconds
    $connection = Get-CampusConnectionContext `
        -Mode $ConnectionMode `
        -TargetSsid ([string]$settings.Ssid) `
        -EthernetIpv4Prefixes @($settings.EthernetIpv4Prefixes)

    if (-not $connection.Eligible) {
        Set-StateLog -State 'WaitingConnection' -Message ([string]$connection.Reason)
        $retrySeconds = [int]$settings.InitialRetrySeconds
        $nextAttemptAt = [datetime]::MinValue
        $authenticationCooldownUntil = [datetime]::MinValue
        $consecutiveInternetFailures = 0
        if ($Once) { exit 2 }
    }
    else {
        $internetHealthy = Test-InternetAccessSet `
            -Checks @($settings.ConnectivityChecks) `
            -TimeoutSeconds ([int]$settings.RequestTimeoutSeconds)
        $now = Get-Date
        $decision = Get-ConnectivityDecision `
            -InternetHealthy $internetHealthy `
            -ConsecutiveFailures $consecutiveInternetFailures `
            -RequiredFailures ([int]$settings.InternetFailureConfirmations) `
            -Now $now `
            -CooldownUntil $authenticationCooldownUntil `
            -NextAttemptAt $nextAttemptAt
        $consecutiveInternetFailures = [int]$decision.ConsecutiveFailures

        switch ($decision.Action) {
            'Online' {
                Set-StateLog -State 'Online' -Message 'Internet connectivity is healthy.'
                $retrySeconds = [int]$settings.InitialRetrySeconds
                $nextAttemptAt = [datetime]::MinValue
                if ($Once) { exit 0 }
            }
            'Confirm' {
                Set-StateLog `
                    -State 'ConfirmingOffline' `
                    -Message ("All connectivity probes failed ({0}/{1}); waiting {2}s before confirmation." -f $consecutiveInternetFailures, $settings.InternetFailureConfirmations, $settings.FailureConfirmationIntervalSeconds) `
                    -Level WARN
                $sleepSeconds = [int]$settings.FailureConfirmationIntervalSeconds
            }
            'Cooldown' {
                Set-StateLog `
                    -State 'Cooldown' `
                    -Message ("Connectivity probes failed during authentication cooldown; no login will be submitted before {0}." -f $authenticationCooldownUntil.ToString('HH:mm:ss')) `
                    -Level WARN
            }
            'Backoff' {
                Set-StateLog `
                    -State 'Backoff' `
                    -Message ("Waiting after an authentication error. Next attempt: {0}" -f $nextAttemptAt.ToString('HH:mm:ss')) `
                    -Level WARN
            }
            'Authenticate' {
                Set-StateLog `
                    -State 'Authenticating' `
                    -Message ("Eligible {0} connection '{1}' failed all connectivity probes {2} consecutive times; submitting portal authentication." -f $connection.Kind, $connection.DisplayName, $consecutiveInternetFailures) `
                    -Level WARN
                try {
                    $credential = Get-LoginCredential -Path $CredentialPath
                    $result = Invoke-PortalAuthentication -Settings $settings -Credential $credential
                    $authenticationCooldownUntil = (Get-Date).AddSeconds([int]$settings.AuthenticationCooldownSeconds)
                    Write-AppLog -Level INFO -Message ("Authentication request accepted: HTTP {0}, method {1}; cooldown until {2}." -f $result.StatusCode, $result.Method, $authenticationCooldownUntil.ToString('HH:mm:ss'))

                    $internetVerified = $false
                    for ($attempt = 1; $attempt -le [int]$settings.PostLoginVerifyAttempts; $attempt++) {
                        if ($attempt -eq 1) {
                            Start-Sleep -Seconds ([int]$settings.PostLoginWaitSeconds)
                        }
                        else {
                            Start-Sleep -Seconds ([int]$settings.PostLoginVerifyIntervalSeconds)
                        }

                        if (Test-InternetAccessSet `
                            -Checks @($settings.ConnectivityChecks) `
                            -TimeoutSeconds ([int]$settings.RequestTimeoutSeconds)) {
                            $internetVerified = $true
                            break
                        }
                    }

                    if ($internetVerified) {
                        Set-StateLog -State 'Online' -Message 'Portal authentication succeeded; Internet access is restored.'
                        $retrySeconds = [int]$settings.InitialRetrySeconds
                        $nextAttemptAt = [datetime]::MinValue
                        $consecutiveInternetFailures = 0
                        if ($Once) { exit 0 }
                    }
                    else {
                        Set-StateLog `
                            -State 'Cooldown' `
                            -Message ("Portal accepted authentication, but Internet verification failed after {0} attempts. Re-authentication is suppressed until {1}." -f $settings.PostLoginVerifyAttempts, $authenticationCooldownUntil.ToString('HH:mm:ss')) `
                            -Level WARN
                        $retrySeconds = [int]$settings.InitialRetrySeconds
                        $nextAttemptAt = [datetime]::MinValue
                        $consecutiveInternetFailures = [int]$settings.InternetFailureConfirmations
                        if ($Once) { exit 3 }
                    }
                }
                catch {
                    Write-AppLog -Level ERROR -Message ("Authentication attempt failed: {0}" -f $_.Exception.Message)
                    $nextAttemptAt = (Get-Date).AddSeconds($retrySeconds)
                    $retrySeconds = Get-NextRetryDelay -CurrentSeconds $retrySeconds -MaximumSeconds ([int]$settings.MaxRetrySeconds)
                    $script:LastState = 'AuthenticationFailed'
                    $consecutiveInternetFailures = [int]$settings.InternetFailureConfirmations
                    if ($Once) { exit 3 }
                }
            }
        }
    }

    Start-Sleep -Seconds $sleepSeconds
}
