# Read-only PowerShell syntax validator for prepared update packages.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackageDirectory
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

try {
    $root = [IO.Path]::GetFullPath($PackageDirectory)
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "Package directory not found: $root"
    }

    $files = @(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object {
        $_.Extension -in @('.ps1', '.psm1')
    })
    $failures = @()
    foreach ($file in $files) {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $file.FullName,
            [ref]$tokens,
            [ref]$errors
        ) | Out-Null
        foreach ($parseError in @($errors)) {
            $failures += [pscustomobject][ordered]@{
                file = $file.FullName.Substring($root.Length).TrimStart('\')
                message = [string]$parseError.Message
            }
        }
    }

    $payload = [ordered]@{
        schemaVersion = 1
        success = ($failures.Count -eq 0)
        filesChecked = $files.Count
        failures = $failures
    }
    [Console]::Out.WriteLine(($payload | ConvertTo-Json -Compress -Depth 4))
    if ($failures.Count -gt 0) { exit 2 }
    exit 0
}
catch {
    [Console]::Error.WriteLine($_.Exception.ToString())
    exit 1
}
