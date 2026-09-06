using System.Diagnostics;
using BITWebVersioning;

namespace BITWebUpdater;

public sealed class ProcessUpdaterRuntime : IUpdaterRuntime
{
    public void RunInstaller(string targetDirectory)
    {
        var script = Path.Combine(targetDirectory, "Install.ps1");
        var start = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (var argument in new[] { "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, "-InstallDirectory", targetDirectory })
            start.ArgumentList.Add(argument);
        using var process = Process.Start(start) ?? throw new InvalidOperationException("Failed to start Install.ps1.");
        var stdout = process.StandardOutput.ReadToEndAsync();
        var stderr = process.StandardError.ReadToEndAsync();
        if (!process.WaitForExit(120000))
        {
            process.Kill(entireProcessTree: true);
            throw new TimeoutException("Install.ps1 exceeded 120 seconds.");
        }
        Task.WaitAll(stdout, stderr);
        if (process.ExitCode != 0) throw new InvalidOperationException($"Install.ps1 exit code: {process.ExitCode}{Environment.NewLine}{stderr.Result}{Environment.NewLine}{stdout.Result}");
    }

    public bool RunHealthCheck(string managerPath, ReleaseVersion expectedVersion, string healthResultPath)
    {
        if (File.Exists(healthResultPath)) File.Delete(healthResultPath);
        var start = new ProcessStartInfo { FileName = managerPath, UseShellExecute = false, CreateNoWindow = true };
        start.ArgumentList.Add("--health-check");
        start.ArgumentList.Add(healthResultPath);
        start.ArgumentList.Add("--expected-version");
        start.ArgumentList.Add(expectedVersion.ToString());
        using var process = Process.Start(start);
        if (process is null || !process.WaitForExit(30000))
        {
            try { process?.Kill(entireProcessTree: true); } catch { }
            return false;
        }
        if (process.ExitCode != 0 || !File.Exists(healthResultPath)) return false;
        return File.ReadAllText(healthResultPath).Contains("\"success\":true", StringComparison.Ordinal);
    }

    public void LaunchManager(string managerPath) => Process.Start(new ProcessStartInfo { FileName = managerPath, UseShellExecute = true });
}
