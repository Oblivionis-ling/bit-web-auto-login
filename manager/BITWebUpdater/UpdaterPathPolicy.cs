namespace BITWebUpdater;

public static class UpdaterPathPolicy
{
    public static void Validate(UpdaterOptions options)
    {
        var target = Normalize(options.TargetDirectory);
        var prepared = Normalize(options.PreparedDirectory);
        var result = Normalize(options.ResultPath);
        var expectedTarget = Normalize(Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "BITWebAutoLogin"));
        var temp = Normalize(Path.GetTempPath());

        if (options.TestMode)
        {
            var testRoot = Normalize(Path.Combine(Path.GetTempPath(), "BITWebAutoLogin-updater-tests"));
            RequireChild(target, testRoot, "test target");
            RequireChild(prepared, testRoot, "test prepared directory");
        }
        else
        {
            if (!target.Equals(expectedTarget, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException($"Target directory is not the expected per-user install directory: {target}");
            RequireChild(prepared, temp, "prepared directory");
            var workspace = Directory.GetParent(prepared)?.FullName is { } parent ? Normalize(parent) : string.Empty;
            if (!Path.GetFileName(prepared).Equals("payload", StringComparison.OrdinalIgnoreCase) ||
                !Path.GetFileName(workspace).StartsWith("BITWebAutoLogin-update-", StringComparison.OrdinalIgnoreCase) ||
                Path.GetFileName(workspace).Length <= "BITWebAutoLogin-update-".Length)
                throw new InvalidOperationException("Prepared directory is not an update workspace.");
        }

        if (!result.Equals(Normalize(Path.Combine(target, "update-result.json")), StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Result path must be update-result.json inside the target directory.");
        if (prepared.Equals(target, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Prepared and target directories must be different.");
    }

    public static string Normalize(string path) => Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);

    private static void RequireChild(string candidate, string parent, string label)
    {
        var prefix = parent + Path.DirectorySeparatorChar;
        if (!candidate.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException($"Invalid {label}: {candidate}");
    }
}
