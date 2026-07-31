# BIT-Web Auto Login v1.1 - advanced DPAPI credential setup
[CmdletBinding()]
param(
    [string]$CredentialPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($CredentialPath)) {
    $CredentialPath = Join-Path (Join-Path $env:LOCALAPPDATA 'BITWebAutoLogin') 'credential.xml'
}
$credentialDirectory = Split-Path -Parent $CredentialPath
if (-not (Test-Path -LiteralPath $credentialDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $credentialDirectory -Force | Out-Null
}

Write-Host 'This creates a credential file decryptable only by the current Windows user on this computer.'
Write-Host 'The username is visible in XML. Windows DPAPI encrypts the password.'
$credential = Get-Credential -Message 'Enter the BIT-Web username and password'
if ($null -eq $credential) {
    throw 'No credential entered. Operation cancelled.'
}
$credential | Export-Clixml -LiteralPath $CredentialPath -Force
Write-Host "Encrypted credential saved: $CredentialPath"
