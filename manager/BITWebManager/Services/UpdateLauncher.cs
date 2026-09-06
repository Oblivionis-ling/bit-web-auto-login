using System.Diagnostics;
using System.IO;
using BITWebManager.Models;

namespace BITWebManager.Services;

public sealed class UpdateLauncher : IUpdateLauncher
{
    public void Launch(PreparedUpdate update, string targetDirectory, int managerProcessId)
    {
        if (!File.Exists(update.UpdaterPath))
        {
            throw new FileNotFoundException("The prepared updater helper was not found.", update.UpdaterPath);
        }

        var start = new ProcessStartInfo
        {
            FileName = update.UpdaterPath,
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = update.PayloadDirectory,
        };
        foreach (var argument in new[]
        {
            "--manager-pid", managerProcessId.ToString(),
            "--prepared-directory", update.PayloadDirectory,
            "--target-directory", targetDirectory,
            "--expected-version", update.Info.LatestVersion.ToString(),
            "--result-path", update.ResultPath,
        })
        {
            start.ArgumentList.Add(argument);
        }

        Process.Start(start)?.Dispose();
    }
}
