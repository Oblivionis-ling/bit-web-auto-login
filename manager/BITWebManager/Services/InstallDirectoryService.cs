using System.Diagnostics;
using System.IO;

namespace BITWebManager.Services;

public sealed class InstallDirectoryService : IInstallDirectoryService
{
    public void Open(string path)
    {
        if (!Directory.Exists(path))
        {
            throw new DirectoryNotFoundException($"Install directory does not exist: {path}");
        }

        Process.Start(new ProcessStartInfo
        {
            FileName = path,
            UseShellExecute = true,
        });
    }
}
