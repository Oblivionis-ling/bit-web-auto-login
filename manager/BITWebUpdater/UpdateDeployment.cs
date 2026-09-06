using System.Text.Json;
using System.Text.Json.Nodes;
using BITWebVersioning;

namespace BITWebUpdater;

public sealed class UpdateDeployment(IUpdaterRuntime runtime, bool failHealthCheckForRcQa = false)
{
    public void Execute(UpdaterOptions options)
    {
        UpdaterPathPolicy.Validate(options);
        WaitForManager(options);
        var target = options.TargetDirectory;
        var prepared = options.PreparedDirectory;
        Directory.CreateDirectory(target);
        var backup = Path.Combine(Path.GetDirectoryName(prepared)!, "backup-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(backup);
        var deployed = new List<(string Relative, bool Existed)>();
        var oldSettings = File.Exists(Path.Combine(target, "settings.json")) ? File.ReadAllText(Path.Combine(target, "settings.json")) : null;

        try
        {
            foreach (var source in Directory.EnumerateFiles(prepared, "*", SearchOption.AllDirectories))
            {
                var relative = Path.GetRelativePath(prepared, source);
                if (Path.GetFileName(relative).Equals("credential.xml", StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("Prepared update contains credential.xml.");
                var destination = SafeCombine(target, relative);
                var backupFile = SafeCombine(backup, relative);
                var existed = File.Exists(destination);
                if (existed)
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(backupFile)!);
                    File.Copy(destination, backupFile, overwrite: false);
                }
                Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
                var temporary = destination + ".update-new";
                File.Copy(source, temporary, overwrite: true);
                File.Move(temporary, destination, overwrite: true);
                deployed.Add((relative, existed));
            }

            MergeSettings(oldSettings, Path.Combine(target, "settings.json"), options.ExpectedVersion);
            runtime.RunInstaller(target);
            var healthPath = Path.Combine(Path.GetDirectoryName(prepared)!, "health-result.json");
            var managerPath = Path.Combine(target, "BITWebManager.exe");
            if (failHealthCheckForRcQa)
                throw new InvalidOperationException("RC QA injected manager health-check failure.");
            if (!runtime.RunHealthCheck(managerPath, options.ExpectedVersion, healthPath))
                throw new InvalidOperationException("Updated manager health check failed.");
            WriteResult(options.ResultPath, true, options.ExpectedVersion, null);
            TryDelete(backup);
            runtime.LaunchManager(managerPath);
        }
        catch (Exception exception)
        {
            Rollback(target, backup, deployed);
            try { runtime.RunInstaller(target); } catch { }
            WriteResult(options.ResultPath, false, options.ExpectedVersion, exception.ToString());
            var managerPath = Path.Combine(target, "BITWebManager.exe");
            if (File.Exists(managerPath)) runtime.LaunchManager(managerPath);
            throw;
        }
    }

    private static void WaitForManager(UpdaterOptions options)
    {
        if (options.ManagerProcessId == 0 && options.TestMode) return;
        var parentProcessId = WindowsProcessIdentity.GetParentProcessId(Environment.ProcessId);
        if (parentProcessId != options.ManagerProcessId)
            throw new InvalidOperationException("Updater was not launched by the supplied Manager PID.");

        System.Diagnostics.Process process;
        try
        {
            process = System.Diagnostics.Process.GetProcessById(options.ManagerProcessId);
        }
        catch (ArgumentException)
        {
            // The direct-parent identity above remains available after the Manager exits.
            return;
        }

        using (process)
        {
            if (process.HasExited) return;
            string actualPath;
            try
            {
                actualPath = process.MainModule?.FileName ?? string.Empty;
            }
            catch (InvalidOperationException) when (process.HasExited)
            {
                return;
            }
            var expectedPath = Path.Combine(options.TargetDirectory, "BITWebManager.exe");
            if (!Path.GetFullPath(actualPath).Equals(Path.GetFullPath(expectedPath), StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Manager PID does not belong to the target installation.");
            if (!process.WaitForExit(60000)) throw new TimeoutException("Manager did not exit within 60 seconds.");
        }
    }

    private static void MergeSettings(string? oldSettings, string newSettingsPath, ReleaseVersion expectedVersion)
    {
        if (oldSettings is null || !File.Exists(newSettingsPath)) return;
        var oldObject = JsonNode.Parse(oldSettings)?.AsObject() ?? throw new InvalidDataException("Existing settings.json is invalid.");
        var newObject = JsonNode.Parse(File.ReadAllText(newSettingsPath))?.AsObject() ?? throw new InvalidDataException("New settings.json is invalid.");
        foreach (var property in oldObject)
        {
            if (!property.Key.Equals("Version", StringComparison.OrdinalIgnoreCase)) newObject[property.Key] = property.Value?.DeepClone();
        }
        newObject["Version"] = expectedVersion.ToString();
        File.WriteAllText(newSettingsPath, newObject.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
    }

    private static void Rollback(string target, string backup, IEnumerable<(string Relative, bool Existed)> deployed)
    {
        foreach (var item in deployed.Reverse())
        {
            var destination = SafeCombine(target, item.Relative);
            var backupFile = SafeCombine(backup, item.Relative);
            if (item.Existed && File.Exists(backupFile)) File.Copy(backupFile, destination, overwrite: true);
            else if (!item.Existed && File.Exists(destination)) File.Delete(destination);
        }
    }

    private static string SafeCombine(string root, string relative)
    {
        var normalizedRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        var result = Path.GetFullPath(Path.Combine(root, relative));
        if (!result.StartsWith(normalizedRoot, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException($"Path escaped root: {relative}");
        return result;
    }

    private static void WriteResult(string path, bool success, ReleaseVersion version, string? detail)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temporary = path + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(new { schemaVersion = 1, success, version = version.ToString(), detail, completedAtUtc = DateTimeOffset.UtcNow }));
        File.Move(temporary, path, overwrite: true);
    }

    private static void TryDelete(string path) { try { if (Directory.Exists(path)) Directory.Delete(path, true); } catch { } }
}
