[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [string]$Configuration = 'Release',
    [string]$ReleaseVersion
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $projectRoot 'artifacts\release'
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)

$propsPath = Join-Path $projectRoot 'manager\Directory.Build.props'
[xml]$props = Get-Content -LiteralPath $propsPath -Raw -Encoding UTF8
$canonicalVersion = [string]$props.Project.PropertyGroup.Version
$stablePattern = '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$'
$rcPattern = '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)-rc\.([1-9]\d*)$'
if ($canonicalVersion -notmatch $stablePattern) { throw "Invalid canonical version in ${propsPath}: $canonicalVersion" }
if ([string]::IsNullOrWhiteSpace($ReleaseVersion)) { $ReleaseVersion = $canonicalVersion }
if ($ReleaseVersion -notmatch $stablePattern -and $ReleaseVersion -notmatch $rcPattern) {
    throw "ReleaseVersion '$ReleaseVersion' is not a supported stable or RC version."
}
$baseVersion = if ($ReleaseVersion -match $rcPattern) { "$($Matches[1]).$($Matches[2]).$($Matches[3])" } else { $ReleaseVersion }
if ($baseVersion -ne $canonicalVersion) {
    throw "ReleaseVersion base '$baseVersion' does not match canonical version '$canonicalVersion'."
}
$version = $ReleaseVersion

$settingsPath = Join-Path $projectRoot 'settings.json'
$settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$settings.Version -ne $canonicalVersion) {
    throw "settings.json version '$($settings.Version)' does not match canonical version '$canonicalVersion'."
}

& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'New-AppIcon.ps1')
if ($LASTEXITCODE -ne 0) { throw "Application icon generation failed with exit code $LASTEXITCODE." }

$dotnet = Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\dotnet.exe'
if (-not (Test-Path -LiteralPath $dotnet -PathType Leaf)) {
    $command = Get-Command dotnet.exe -ErrorAction SilentlyContinue
    if ($null -eq $command) { throw '.NET 8 SDK was not found.' }
    $dotnet = $command.Source
}

$allowedOutputRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot 'artifacts')).TrimEnd('\') + '\'
if (-not $OutputDirectory.StartsWith($allowedOutputRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "OutputDirectory must be under $allowedOutputRoot"
}
if (Test-Path -LiteralPath $OutputDirectory) { Remove-Item -LiteralPath $OutputDirectory -Recurse -Force }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$work = Join-Path $OutputDirectory ('.staging-' + [guid]::NewGuid().ToString('N'))
$managerPublish = Join-Path $work 'manager-publish'
$updaterPublish = Join-Path $work 'updater-publish'
$packageRootName = "BITWebAutoLogin-v$version-win-x64"
$packageRoot = Join-Path $work $packageRootName
New-Item -ItemType Directory -Path $managerPublish, $updaterPublish, $packageRoot -Force | Out-Null

$publishProperties = @(
    '--self-contained', 'true',
    '-p:PublishSingleFile=true',
    '-p:EnableCompressionInSingleFile=true',
    '-p:PublishTrimmed=false',
    '-p:PublishReadyToRun=false',
    '-p:DebugType=None',
    '-p:DebugSymbols=false',
    "-p:Version=$version",
    "-p:InformationalVersion=$version",
    "-p:AssemblyVersion=$canonicalVersion.0",
    "-p:FileVersion=$canonicalVersion.0",
    '-p:IncludeSourceRevisionInInformationalVersion=false'
)

try {
    & $dotnet clean (Join-Path $projectRoot 'manager\BITWebManager\BITWebManager.csproj') `
        '--configuration' $Configuration '--verbosity' 'quiet'
    if ($LASTEXITCODE -ne 0) { throw "Manager clean failed with exit code $LASTEXITCODE." }
    & $dotnet clean (Join-Path $projectRoot 'manager\BITWebUpdater\BITWebUpdater.csproj') `
        '--configuration' $Configuration '--verbosity' 'quiet'
    if ($LASTEXITCODE -ne 0) { throw "Updater clean failed with exit code $LASTEXITCODE." }

    & $dotnet publish (Join-Path $projectRoot 'manager\BITWebManager\BITWebManager.csproj') `
        '--configuration' $Configuration '--runtime' 'win-x64' '--output' $managerPublish @publishProperties
    if ($LASTEXITCODE -ne 0) { throw "Manager publish failed with exit code $LASTEXITCODE." }
    & $dotnet publish (Join-Path $projectRoot 'manager\BITWebUpdater\BITWebUpdater.csproj') `
        '--configuration' $Configuration '--runtime' 'win-x64' '--output' $updaterPublish @publishProperties
    if ($LASTEXITCODE -ne 0) { throw "Updater publish failed with exit code $LASTEXITCODE." }

    $managerFiles = @(
        'BITWebManager.exe', 'D3DCompiler_47_cor3.dll', 'PenImc_cor3.dll',
        'PresentationNative_cor3.dll', 'vcruntime140_cor3.dll', 'wpfgfx_cor3.dll'
    )
    foreach ($name in $managerFiles) {
        $source = Join-Path $managerPublish $name
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Manager publish is missing $name." }
        Copy-Item -LiteralPath $source -Destination (Join-Path $packageRoot $name)
    }
    Copy-Item -LiteralPath (Join-Path $updaterPublish 'BITWebUpdater.exe') -Destination (Join-Path $packageRoot 'BITWebUpdater.exe')

    $rootFiles = @(
        'AutoLogin.ps1', 'BITWebAutoLogin.psm1', 'BITWebAutoLogin.Management.psm1',
        'Install.ps1', 'Install.cmd', 'Uninstall.ps1', 'RunHidden.vbs'
    )
    foreach ($name in $rootFiles) {
        Copy-Item -LiteralPath (Join-Path $projectRoot $name) -Destination (Join-Path $packageRoot $name)
    }
    $stagingSettings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $stagingSettings.Version = $version
    $stagingSettings | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $packageRoot 'settings.json') -Encoding UTF8

    $powerShellDirectory = Join-Path $packageRoot 'PowerShell'
    $legacyDirectory = Join-Path $packageRoot 'legacy'
    $licenseDirectory = Join-Path $packageRoot 'Licenses'
    New-Item -ItemType Directory -Path $powerShellDirectory, $legacyDirectory, $licenseDirectory -Force | Out-Null
    foreach ($name in @('Get-ManagerStatus.ps1', 'Invoke-ManagerAction.ps1', 'Test-ManagerUpdatePackage.ps1')) {
        Copy-Item -LiteralPath (Join-Path $projectRoot "scripts\$name") -Destination (Join-Path $powerShellDirectory $name)
    }
    foreach ($name in @('Manage.ps1', 'Open-GUI.cmd', 'Open-GUI.vbs')) {
        Copy-Item -LiteralPath (Join-Path $projectRoot $name) -Destination (Join-Path $legacyDirectory $name)
    }
    Copy-Item -LiteralPath (Join-Path $projectRoot 'manager\BITWebManager\Resources\Fonts\OFL.txt') `
        -Destination (Join-Path $licenseDirectory 'Sarasa-Gothic-OFL.txt')

    foreach ($binary in @('BITWebManager.exe', 'BITWebUpdater.exe')) {
        $versionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $packageRoot $binary))
        $productVersion = $versionInfo.ProductVersion
        if ($productVersion -ne $version) {
            throw "$binary ProductVersion '$productVersion' does not match '$version'."
        }
        $fileVersion = $versionInfo.FileVersion
        $actualVersion = [Version]$fileVersion
        $expectedVersion = [Version]$canonicalVersion
        if ($actualVersion.Major -ne $expectedVersion.Major -or
            $actualVersion.Minor -ne $expectedVersion.Minor -or
            $actualVersion.Build -ne $expectedVersion.Build) {
            throw "$binary FileVersion '$fileVersion' does not match '$version'."
        }
    }

    $manifestFiles = @(Get-ChildItem -LiteralPath $packageRoot -Recurse -File | Sort-Object FullName | ForEach-Object {
        [ordered]@{
            path = $_.FullName.Substring($packageRoot.Length + 1).Replace('\', '/')
            size = $_.Length
            sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    })
    $manifest = [ordered]@{
        schemaVersion = 1
        version = $version
        rid = 'win-x64'
        selfContained = $true
        singleFile = $true
        compressed = $true
        trimmed = $false
        readyToRun = $false
        manager = 'BITWebManager.exe'
        updater = 'BITWebUpdater.exe'
        files = $manifestFiles
    }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $packageRoot 'release-manifest.json') -Encoding UTF8

    $syntaxResult = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `
        (Join-Path $projectRoot 'scripts\Test-ManagerUpdatePackage.ps1') -PackageDirectory $packageRoot
    if ($LASTEXITCODE -ne 0) { throw "PowerShell package syntax validation failed: $syntaxResult" }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zipName = "$packageRootName.zip"
    $zipPath = Join-Path $OutputDirectory $zipName
    [IO.Compression.ZipFile]::CreateFromDirectory(
        $packageRoot,
        $zipPath,
        [IO.Compression.CompressionLevel]::Optimal,
        $true
    )
    $zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $checksumPath = $zipPath + '.sha256'
    [IO.File]::WriteAllText($checksumPath, "$zipHash  $zipName`r`n", [Text.UTF8Encoding]::new($false))

    $result = [ordered]@{
        schemaVersion = 1
        version = $version
        zip = $zipPath
        checksum = $checksumPath
        sha256 = $zipHash
        zipBytes = (Get-Item -LiteralPath $zipPath).Length
        unpackedBytes = (Get-ChildItem -LiteralPath $packageRoot -Recurse -File | Measure-Object Length -Sum).Sum
        fileCount = @(Get-ChildItem -LiteralPath $packageRoot -Recurse -File).Count
    }
    $resultPath = Join-Path $OutputDirectory 'build-result.json'
    $result | ConvertTo-Json | Set-Content -LiteralPath $resultPath -Encoding UTF8
    Write-Host ($result | ConvertTo-Json -Compress)
}
finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
