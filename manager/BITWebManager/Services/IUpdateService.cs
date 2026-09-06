using BITWebManager.Models;
using BITWebVersioning;

namespace BITWebManager.Services;

public interface IUpdateService
{
    Task<UpdateInfo> CheckForUpdatesAsync(ReleaseVersion currentVersion, CancellationToken cancellationToken = default);
    Task<UpdateInfo> CheckForQaReleaseAsync(ReleaseVersion currentVersion, string requestedTag, CancellationToken cancellationToken = default);
    Task<string> DownloadUpdateAsync(UpdateInfo info, IProgress<UpdateProgress>? progress = null, CancellationToken cancellationToken = default);
    Task<string> ValidateUpdateAsync(UpdateInfo info, string workspaceDirectory, IProgress<UpdateProgress>? progress = null, CancellationToken cancellationToken = default);
    Task<PreparedUpdate> PrepareUpdateAsync(UpdateInfo info, string workspaceDirectory, string payloadDirectory, CancellationToken cancellationToken = default);
}
