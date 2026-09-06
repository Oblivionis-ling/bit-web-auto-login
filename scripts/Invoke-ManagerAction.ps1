# Structured management-action bridge for BITWebManager.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('RefreshCredential', 'Install', 'Repair', 'Uninstall', 'ClearCredential')]
    [string]$Action,
    [string]$InstallDirectory,
    [string]$ProjectDirectory,
    [switch]$TestMode,
    [ValidateSet('Success', 'Failure')]
    [string]$TestOutcome = 'Success',
    [ValidateRange(0, 30000)]
    [int]$TestDelayMilliseconds = 0
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$utf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8
[Console]::InputEncoding = $utf8
$OutputEncoding = $utf8

function Write-ActionPayload {
    param(
        [bool]$Success,
        [string]$Message,
        [string]$ErrorCode,
        [bool]$RequiresRefresh
    )

    $payload = [ordered]@{
        schemaVersion = 1
        success = $Success
        action = $Action.Substring(0, 1).ToLowerInvariant() + $Action.Substring(1)
        message = $Message
        requiresRefresh = $RequiresRefresh
        errorCode = if ([string]::IsNullOrWhiteSpace($ErrorCode)) { $null } else { $ErrorCode }
    }
    [Console]::Out.WriteLine(($payload | ConvertTo-Json -Compress))
}

try {
    if ($TestDelayMilliseconds -gt 0) {
        Start-Sleep -Milliseconds $TestDelayMilliseconds
    }
    if ($TestMode) {
        if ($TestOutcome -eq 'Failure') {
            throw 'Simulated manager action failure.'
        }
        Write-ActionPayload -Success $true -Message 'Test action completed.' -ErrorCode '' -RequiresRefresh $true
        exit 0
    }

    if ([string]::IsNullOrWhiteSpace($ProjectDirectory)) {
        $parentDirectory = Split-Path -Parent $PSScriptRoot
        $ProjectDirectory = if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'BITWebAutoLogin.Management.psm1') -PathType Leaf) {
            $PSScriptRoot
        }
        elseif (Test-Path -LiteralPath (Join-Path $parentDirectory 'BITWebAutoLogin.Management.psm1') -PathType Leaf) {
            $parentDirectory
        }
        else {
            $PSScriptRoot
        }
    }
    $modulePath = Join-Path $ProjectDirectory 'BITWebAutoLogin.Management.psm1'
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        $modulePath = Join-Path $PSScriptRoot 'BITWebAutoLogin.Management.psm1'
    }
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        throw "Management module not found: $modulePath"
    }

    Import-Module $modulePath -Force -ErrorAction Stop
    $common = @{ ProjectDirectory = $ProjectDirectory }
    if (-not [string]::IsNullOrWhiteSpace($InstallDirectory)) {
        $common.InstallDirectory = $InstallDirectory
    }

    $null = @(& {
        switch ($Action) {
            'RefreshCredential' { Install-BITWebAutoLogin @common -RefreshCredential }
            'Install' { Install-BITWebAutoLogin @common }
            'Repair' { Install-BITWebAutoLogin @common -UpdateOnly }
            'Uninstall' { Uninstall-BITWebAutoLogin -ProjectDirectory $ProjectDirectory }
            'ClearCredential' { Clear-BITWebCredential @common -Confirm:$false }
        }
    } *>&1)

    Write-ActionPayload -Success $true -Message 'Action completed.' -ErrorCode '' -RequiresRefresh $true
    exit 0
}
catch {
    $detail = $_.Exception.ToString()
    $errorCode = if ($detail -match '(?i)credential entry was cancelled|操作已取消') {
        'CREDENTIAL_CANCELLED'
    }
    elseif ($detail -match '(?i)access.*denied|unauthorized|权限|拒绝访问') {
        'PERMISSION_DENIED'
    }
    else {
        'ACTION_FAILED'
    }
    Write-ActionPayload -Success $false -Message 'Action failed.' -ErrorCode $errorCode -RequiresRefresh $false
    [Console]::Error.WriteLine($detail)
    exit 1
}
