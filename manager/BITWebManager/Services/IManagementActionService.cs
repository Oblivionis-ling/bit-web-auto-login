using BITWebManager.Models;

namespace BITWebManager.Services;

public interface IManagementActionService
{
    Task<ManagerActionResult> ExecuteAsync(
        ManagerAction action,
        bool interactive,
        CancellationToken cancellationToken = default);
}
