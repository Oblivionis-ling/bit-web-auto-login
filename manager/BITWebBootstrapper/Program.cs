using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;

namespace BITWebBootstrapper;

internal static class Program
{
    private const string PayloadResourceName = "BITWebBootstrapper.Payload.zip";

    [STAThread]
    private static int Main()
    {
        var workspace = Path.Combine(
            Path.GetTempPath(),
            "BITWebAutoLogin-bootstrap",
            Guid.NewGuid().ToString("N"));

        try
        {
            Directory.CreateDirectory(workspace);
            using var payload = Assembly.GetExecutingAssembly().GetManifestResourceStream(PayloadResourceName)
                ?? throw new InvalidDataException("The embedded BIT-Web package is missing.");
            var expectedVersion = Assembly.GetExecutingAssembly()
                .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
                ?? throw new InvalidDataException("The setup version is missing.");
            var payloadDirectory = EmbeddedPayload.ExtractAndValidate(payload, workspace, expectedVersion);
            var managerPath = Path.Combine(payloadDirectory, "BITWebManager.exe");
            using var manager = Process.Start(new ProcessStartInfo
            {
                FileName = managerPath,
                WorkingDirectory = payloadDirectory,
                UseShellExecute = true,
            }) ?? throw new InvalidOperationException("Could not start BIT-Web Manager.");
            manager.WaitForExit();
            return 0;
        }
        catch (Exception exception)
        {
            MessageBox(IntPtr.Zero,
                "无法打开 BIT-Web 自动登录管理器。\n\n" + exception.Message +
                "\n\n请重新从官方 GitHub Releases 下载完整安装 EXE。",
                "BIT-Web 自动登录", 0x10);
            return 1;
        }
        finally
        {
            TryDeleteWorkspace(workspace);
        }
    }

    private static void TryDeleteWorkspace(string path)
    {
        for (var attempt = 0; attempt < 5; attempt++)
        {
            try
            {
                if (Directory.Exists(path)) Directory.Delete(path, true);
                return;
            }
            catch when (attempt < 4)
            {
                Thread.Sleep(200 * (attempt + 1));
            }
            catch
            {
                return;
            }
        }
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int MessageBox(IntPtr hWnd, string text, string caption, uint type);
}
