using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json;

namespace BITWebBootstrapper;

public static class EmbeddedPayload
{
    private const int MaximumEntries = 128;
    private const long MaximumUncompressedBytes = 350L * 1024 * 1024;
    private static readonly string[] RequiredFiles =
    {
        "BITWebManager.exe", "BITWebUpdater.exe", "Install.ps1", "Uninstall.ps1",
        "settings.json", "release-manifest.json", "PowerShell/Get-ManagerStatus.ps1",
        "PowerShell/Invoke-ManagerAction.ps1",
    };

    public static string ExtractAndValidate(Stream zipStream, string destination, string expectedVersion)
    {
        ArgumentNullException.ThrowIfNull(zipStream);
        if (string.IsNullOrWhiteSpace(destination)) throw new ArgumentException("Destination is required.", nameof(destination));
        if (string.IsNullOrWhiteSpace(expectedVersion)) throw new ArgumentException("Version is required.", nameof(expectedVersion));

        var destinationRoot = Path.GetFullPath(destination).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        Directory.CreateDirectory(destinationRoot);
        using var archive = new ZipArchive(zipStream, ZipArchiveMode.Read, leaveOpen: false);
        if (archive.Entries.Count == 0 || archive.Entries.Count > MaximumEntries)
            throw new InvalidDataException("The embedded package has an invalid file count.");

        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var roots = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        long totalSize = 0;
        foreach (var entry in archive.Entries)
        {
            var archivePath = entry.FullName.Replace('\\', '/');
            var relative = archivePath.Replace('/', Path.DirectorySeparatorChar);
            if (Path.IsPathRooted(relative)) throw new InvalidDataException("The embedded package contains an absolute path.");
            var target = Path.GetFullPath(Path.Combine(destinationRoot, relative));
            if (!target.StartsWith(destinationRoot, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("The embedded package contains a path outside its root.");
            if (!names.Add(archivePath)) throw new InvalidDataException("The embedded package contains duplicate paths.");

            var firstSlash = archivePath.IndexOf('/');
            if (firstSlash <= 0) throw new InvalidDataException("The embedded package must have one versioned root directory.");
            roots.Add(archivePath[..firstSlash]);
            totalSize = checked(totalSize + entry.Length);
            if (totalSize > MaximumUncompressedBytes)
                throw new InvalidDataException("The embedded package is unexpectedly large.");

            if (archivePath.EndsWith('/'))
            {
                Directory.CreateDirectory(target);
                continue;
            }

            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            using var source = entry.Open();
            using var output = new FileStream(target, FileMode.CreateNew, FileAccess.Write, FileShare.None);
            source.CopyTo(output);
        }

        if (roots.Count != 1) throw new InvalidDataException("The embedded package has multiple root directories.");
        var payloadRoot = Path.Combine(destinationRoot, roots.Single());
        ValidatePayload(payloadRoot, expectedVersion);
        return payloadRoot;
    }

    private static void ValidatePayload(string payloadRoot, string expectedVersion)
    {
        foreach (var relative in RequiredFiles)
        {
            if (!File.Exists(ToNativePath(payloadRoot, relative)))
                throw new InvalidDataException($"The embedded package is missing {relative}.");
        }

        using var settings = JsonDocument.Parse(File.ReadAllText(Path.Combine(payloadRoot, "settings.json")));
        var settingsVersion = settings.RootElement.GetProperty("Version").GetString();
        using var manifest = JsonDocument.Parse(File.ReadAllText(Path.Combine(payloadRoot, "release-manifest.json")));
        var manifestRoot = manifest.RootElement;
        if (manifestRoot.GetProperty("schemaVersion").GetInt32() != 1 ||
            !string.Equals(manifestRoot.GetProperty("version").GetString(), expectedVersion, StringComparison.Ordinal) ||
            !string.Equals(settingsVersion, expectedVersion, StringComparison.Ordinal))
            throw new InvalidDataException("The embedded package version does not match this setup EXE.");

        var declared = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var item in manifestRoot.GetProperty("files").EnumerateArray())
        {
            var relative = item.GetProperty("path").GetString()
                ?? throw new InvalidDataException("The embedded manifest contains an empty path.");
            if (!declared.Add(relative)) throw new InvalidDataException("The embedded manifest contains duplicate paths.");
            var path = ToNativePath(payloadRoot, relative);
            if (!File.Exists(path) || new FileInfo(path).Length != item.GetProperty("size").GetInt64())
                throw new InvalidDataException($"Embedded file size validation failed: {relative}");
            var actual = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path))).ToLowerInvariant();
            if (!string.Equals(actual, item.GetProperty("sha256").GetString(), StringComparison.Ordinal))
                throw new InvalidDataException($"Embedded file hash validation failed: {relative}");
        }

        var actualFiles = Directory.EnumerateFiles(payloadRoot, "*", SearchOption.AllDirectories)
            .Select(path => Path.GetRelativePath(payloadRoot, path).Replace('\\', '/'))
            .Where(path => !path.Equals("release-manifest.json", StringComparison.OrdinalIgnoreCase));
        if (actualFiles.Any(path => !declared.Contains(path)))
            throw new InvalidDataException("The embedded package contains a file not declared by its manifest.");
    }

    private static string ToNativePath(string root, string relative)
    {
        var normalized = relative.Replace('/', Path.DirectorySeparatorChar);
        var rootPrefix = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        var path = Path.GetFullPath(Path.Combine(rootPrefix, normalized));
        if (!path.StartsWith(rootPrefix, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("The embedded manifest contains a path outside its root.");
        return path;
    }
}
