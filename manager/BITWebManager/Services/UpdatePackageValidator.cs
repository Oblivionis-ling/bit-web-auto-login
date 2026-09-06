using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Text.Json;
using BITWebVersioning;

namespace BITWebManager.Services;

public sealed class UpdatePackageValidator
{
    private const int MaximumEntries = 5000;
    private const long MaximumExpandedBytes = 500L * 1024 * 1024;
    private readonly PowerShellService _powerShellService;
    private readonly string _syntaxBridgePath;
    private readonly bool _validateManagerVersion;

    public UpdatePackageValidator(PowerShellService powerShellService, string? syntaxBridgePath = null, bool validateManagerVersion = true)
    {
        _powerShellService = powerShellService;
        _syntaxBridgePath = syntaxBridgePath ?? Path.Combine(AppContext.BaseDirectory, "PowerShell", "Test-ManagerUpdatePackage.ps1");
        _validateManagerVersion = validateManagerVersion;
    }

    public async Task<string> ValidateAndExtractAsync(
        string archivePath,
        ReleaseVersion expectedVersion,
        string workspaceDirectory,
        CancellationToken cancellationToken = default)
    {
        if (!File.Exists(archivePath))
        {
            throw Invalid("Update archive does not exist.", "MISSING_ARCHIVE");
        }

        var payload = Path.Combine(workspaceDirectory, "payload");
        if (Directory.Exists(payload)) Directory.Delete(payload, recursive: true);
        Directory.CreateDirectory(payload);
        var rootName = $"BITWebAutoLogin-v{expectedVersion}-win-x64";
        try
        {
            using var archive = ZipFile.OpenRead(archivePath);
            if (archive.Entries.Count == 0 || archive.Entries.Count > MaximumEntries)
            {
                throw Invalid($"Invalid ZIP entry count: {archive.Entries.Count}.", "INVALID_ARCHIVE");
            }

            long expandedBytes = 0;
            foreach (var entry in archive.Entries)
            {
                cancellationToken.ThrowIfCancellationRequested();
                expandedBytes += entry.Length;
                if (expandedBytes > MaximumExpandedBytes)
                {
                    throw Invalid("Expanded archive exceeds 500 MiB.", "ARCHIVE_TOO_LARGE");
                }

                var name = entry.FullName.Replace('\\', '/');
                if (name.StartsWith('/') || name.Contains(':')) throw Invalid($"Unsafe ZIP entry: {entry.FullName}", "ZIP_SLIP");
                var segments = name.Split('/', StringSplitOptions.RemoveEmptyEntries);
                if (segments.Length == 0 || segments[0] != rootName || segments.Any(segment => segment is "." or ".."))
                {
                    throw Invalid($"Unexpected or unsafe ZIP entry: {entry.FullName}", "ZIP_SLIP");
                }
                if (((entry.ExternalAttributes >> 16) & 0xF000) == 0xA000)
                {
                    throw Invalid($"Symbolic links are not allowed: {entry.FullName}", "ZIP_SYMLINK");
                }
                if (segments.Length == 1) continue;

                var relative = Path.Combine(segments.Skip(1).ToArray());
                if (Path.GetFileName(relative).Equals("credential.xml", StringComparison.OrdinalIgnoreCase))
                {
                    throw Invalid("Update packages must not contain credential.xml.", "CREDENTIAL_IN_PACKAGE");
                }
                var destination = Path.GetFullPath(Path.Combine(payload, relative));
                var payloadPrefix = Path.GetFullPath(payload).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
                if (!destination.StartsWith(payloadPrefix, StringComparison.OrdinalIgnoreCase))
                {
                    throw Invalid($"ZIP entry escaped the payload directory: {entry.FullName}", "ZIP_SLIP");
                }
                if (entry.FullName.EndsWith('/'))
                {
                    Directory.CreateDirectory(destination);
                    continue;
                }

                Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
                await using var input = entry.Open();
                await using var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None, 81920, true);
                await input.CopyToAsync(output, cancellationToken);
            }

            ValidateRequiredFiles(payload);
            ValidateSettingsVersion(payload, expectedVersion);
            ValidateReleaseManifest(payload, expectedVersion);
            if (_validateManagerVersion) ValidateBinaryVersions(payload, expectedVersion);
            await ValidatePowerShellSyntaxAsync(payload, cancellationToken);
            return payload;
        }
        catch (UpdateException)
        {
            throw;
        }
        catch (InvalidDataException exception)
        {
            throw Invalid(exception.ToString(), "INVALID_ARCHIVE", exception);
        }
    }

    private static void ValidateRequiredFiles(string payload)
    {
        var required = new[]
        {
            "AutoLogin.ps1", "BITWebAutoLogin.psm1", "BITWebAutoLogin.Management.psm1",
            "Install.ps1", "Install.cmd", "Uninstall.ps1", "RunHidden.vbs", "settings.json",
            "BITWebManager.exe", "BITWebUpdater.exe", "release-manifest.json",
            "D3DCompiler_47_cor3.dll", "PenImc_cor3.dll", "PresentationNative_cor3.dll",
            "vcruntime140_cor3.dll", "wpfgfx_cor3.dll",
            Path.Combine("legacy", "Manage.ps1"),
            Path.Combine("legacy", "Open-GUI.cmd"),
            Path.Combine("legacy", "Open-GUI.vbs"),
            Path.Combine("PowerShell", "Get-ManagerStatus.ps1"),
            Path.Combine("PowerShell", "Invoke-ManagerAction.ps1"),
            Path.Combine("PowerShell", "Test-ManagerUpdatePackage.ps1"),
            Path.Combine("Licenses", "Sarasa-Gothic-OFL.txt"),
        };
        var missing = required.Where(relative => !File.Exists(Path.Combine(payload, relative))).ToArray();
        if (missing.Length > 0)
        {
            throw Invalid("Missing required files: " + string.Join(", ", missing), "MISSING_REQUIRED_FILE");
        }
    }

    private static void ValidateSettingsVersion(string payload, ReleaseVersion expectedVersion)
    {
        using var json = JsonDocument.Parse(File.ReadAllText(Path.Combine(payload, "settings.json")));
        var value = json.RootElement.GetProperty("Version").GetString();
        if (!string.Equals(value, expectedVersion.ToString(), StringComparison.Ordinal))
        {
            throw Invalid($"settings.json Version '{value}' did not match '{expectedVersion}'.", "VERSION_MISMATCH");
        }
    }

    private static void ValidateReleaseManifest(string payload, ReleaseVersion expectedVersion)
    {
        using var json = JsonDocument.Parse(File.ReadAllText(Path.Combine(payload, "release-manifest.json")));
        var root = json.RootElement;
        if (root.GetProperty("schemaVersion").GetInt32() != 1 ||
            root.GetProperty("version").GetString() != expectedVersion.ToString() ||
            root.GetProperty("rid").GetString() != "win-x64" ||
            root.GetProperty("manager").GetString() != "BITWebManager.exe" ||
            root.GetProperty("updater").GetString() != "BITWebUpdater.exe")
        {
            throw Invalid("release-manifest.json does not match the expected release.", "MANIFEST_MISMATCH");
        }
    }

    private static void ValidateBinaryVersions(string payload, ReleaseVersion expectedVersion)
    {
        foreach (var binary in new[] { "BITWebManager.exe", "BITWebUpdater.exe" })
        {
            var info = FileVersionInfo.GetVersionInfo(Path.Combine(payload, binary));
            var productValue = info.ProductVersion;
            if (!ReleaseVersion.TryParse(productValue, out var productVersion) || productVersion != expectedVersion)
            {
                throw Invalid($"{binary} ProductVersion '{productValue}' did not match '{expectedVersion}'.", "VERSION_MISMATCH");
            }
            var fileValue = info.FileVersion;
            if (!Version.TryParse(fileValue, out var fileVersion) ||
                fileVersion.Major != expectedVersion.Major ||
                fileVersion.Minor != expectedVersion.Minor ||
                fileVersion.Build != expectedVersion.Patch)
            {
                throw Invalid($"{binary} FileVersion '{fileValue}' did not match base version '{expectedVersion.BaseVersion}'.", "VERSION_MISMATCH");
            }
        }
    }

    private async Task ValidatePowerShellSyntaxAsync(string payload, CancellationToken cancellationToken)
    {
        var result = await _powerShellService.RunFileAsync(
            _syntaxBridgePath,
            new[] { "-PackageDirectory", payload },
            TimeSpan.FromSeconds(30),
            cancellationToken: cancellationToken);
        if (result.ExitCode != 0)
        {
            throw Invalid($"PowerShell syntax validation failed.{Environment.NewLine}{result.StandardError}{Environment.NewLine}{result.StandardOutput}", "POWERSHELL_SYNTAX_INVALID");
        }
    }

    private static UpdateException Invalid(string detail, string code, Exception? inner = null) => new(
        "更新包未通过安全校验。", detail, code, inner);
}
