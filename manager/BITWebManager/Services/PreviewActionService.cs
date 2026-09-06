using BITWebManager.Models;

namespace BITWebManager.Services;

internal sealed class PreviewActionService : IManagementActionService
{
    public async Task<ManagerActionResult> ExecuteAsync(
        ManagerAction action,
        bool interactive,
        CancellationToken cancellationToken = default)
    {
        await Task.Delay(250, cancellationToken);
        var value = action.ToString();
        return new ManagerActionResult
        {
            SchemaVersion = 1,
            Success = true,
            Action = char.ToLowerInvariant(value[0]) + value[1..],
            Message = "Preview action completed.",
            RequiresRefresh = true,
        };
    }
}
