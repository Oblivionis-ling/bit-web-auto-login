using BITWebManager.Models;

namespace BITWebManager.Services;

public interface IManagementStatusService
{
    Task<ManagementStatus> GetStatusAsync(CancellationToken cancellationToken = default);
}
