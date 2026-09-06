# Read-only JSON bridge for BITWebManager.
[CmdletBinding()]
param(
    [string]$InstallDirectory,
    [string]$ProjectDirectory
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$utf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8
[Console]::InputEncoding = $utf8
$OutputEncoding = $utf8

try {
    if ([string]::IsNullOrWhiteSpace($ProjectDirectory)) {
        $ProjectDirectory = Split-Path -Parent $PSScriptRoot
    }

    $modulePath = Join-Path $PSScriptRoot 'BITWebAutoLogin.Management.psm1'
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        $modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'BITWebAutoLogin.Management.psm1'
    }
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        throw "Management module not found: $modulePath"
    }

    Import-Module $modulePath -Force -ErrorAction Stop
    $parameters = @{ ProjectDirectory = $ProjectDirectory }
    if (-not [string]::IsNullOrWhiteSpace($InstallDirectory)) {
        $parameters.InstallDirectory = $InstallDirectory
    }

    $status = Get-BITWebManagementStatus @parameters
    $payload = [ordered]@{
        schemaVersion = 1
        installed = [bool]$status.IsInstalled
        taskState = [string]$status.TaskState
        credentialExists = [bool]$status.CredentialExists
        version = [string]$status.InstalledVersion
        installDirectory = [string]$status.InstallDirectory
    }

    [Console]::Out.WriteLine(($payload | ConvertTo-Json -Compress))
    exit 0
}
catch {
    [Console]::Error.WriteLine($_.Exception.ToString())
    exit 1
}
