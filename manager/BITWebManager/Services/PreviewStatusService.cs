using BITWebManager.Models;

namespace BITWebManager.Services;

internal sealed class PreviewStatusService(string state) : IManagementStatusService
{
    public Task<ManagementStatus> GetStatusAsync(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (state.Equals("Failure", StringComparison.OrdinalIgnoreCase))
        {
            throw new StatusReadException(
                "暂时无法读取自动登录状态。",
                "Preview failure: Windows PowerShell exited with code 1.");
        }

        var status = state switch
        {
            "InstalledMissingCredential" => Create(installed: true, taskState: "Ready", credential: false, version: "1.3.0"),
            "NotInstalledCredential" => Create(installed: false, taskState: "未安装", credential: true, version: "1.3.0"),
            "NotInstalledEmpty" => Create(installed: false, taskState: "未安装", credential: false, version: "—"),
            "Disabled" => Create(installed: true, taskState: "Disabled", credential: true, version: "1.3.0"),
            "Unknown" => Create(installed: true, taskState: "Unknown", credential: true, version: "1.3.0"),
            "LongPath" => Create(installed: true, taskState: "Ready", credential: true, version: "1.3.0", installDirectory: @"C:\Users\User\AppData\Local\BITWebAutoLogin\An-Unusually-Long-Install-Directory-Used-For-Layout-Verification"),
            _ => Create(installed: true, taskState: "Ready", credential: true, version: "1.3.0"),
        };
        return Task.FromResult(status);
    }

    private static ManagementStatus Create(bool installed, string taskState, bool credential, string version, string installDirectory = @"C:\Users\User\AppData\Local\BITWebAutoLogin") =>
        new()
        {
            SchemaVersion = 1,
            Installed = installed,
            TaskState = taskState,
            CredentialExists = credential,
            Version = version,
            InstallDirectory = installDirectory,
        };
}
