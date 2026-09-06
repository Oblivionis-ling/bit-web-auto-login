using System.IO;
using System.Text.Json;
using BITWebManager.Models;

namespace BITWebManager.Services;

public sealed class ManagementActionService : IManagementActionService
{
    private const int SupportedSchemaVersion = 1;
    private readonly PowerShellService _powerShellService;
    private readonly string _bridgePath;

    public ManagementActionService(PowerShellService powerShellService, string? bridgePath = null)
    {
        _powerShellService = powerShellService;
        _bridgePath = bridgePath ?? Path.Combine(AppContext.BaseDirectory, "PowerShell", "Invoke-ManagerAction.ps1");
    }

    public async Task<ManagerActionResult> ExecuteAsync(
        ManagerAction action,
        bool interactive,
        CancellationToken cancellationToken = default)
    {
        var arguments = new[] { "-Action", action.ToString() };
        PowerShellResult processResult;
        try
        {
            processResult = await _powerShellService.RunFileAsync(
                _bridgePath,
                arguments,
                GetTimeout(action),
                new PowerShellInvocationOptions(interactive),
                cancellationToken);
        }
        catch (Exception exception) when (exception is not OperationCanceledException)
        {
            throw new ManagementActionException(
                GetFailureMessage(action),
                exception.ToString(),
                innerException: exception);
        }

        ManagerActionResult? actionResult = null;
        if (!string.IsNullOrWhiteSpace(processResult.StandardOutput))
        {
            try
            {
                actionResult = ParseAndValidate(processResult.StandardOutput, action);
            }
            catch (Exception exception) when (exception is JsonException or InvalidDataException)
            {
                throw new ManagementActionException(
                    GetFailureMessage(action),
                    $"{exception}{Environment.NewLine}stdout:{Environment.NewLine}{processResult.StandardOutput}{Environment.NewLine}stderr:{Environment.NewLine}{processResult.StandardError}",
                    innerException: exception);
            }
        }

        if (processResult.ExitCode != 0 || actionResult is null || !actionResult.Success)
        {
            var details = $"PowerShell exit code: {processResult.ExitCode}{Environment.NewLine}" +
                $"stderr:{Environment.NewLine}{processResult.StandardError}{Environment.NewLine}" +
                $"stdout:{Environment.NewLine}{processResult.StandardOutput}";
            throw new ManagementActionException(
                GetFailureMessage(action, actionResult?.ErrorCode),
                details,
                actionResult?.ErrorCode);
        }

        return actionResult;
    }

    public static ManagerActionResult ParseAndValidate(string json, ManagerAction expectedAction)
    {
        var result = JsonSerializer.Deserialize<ManagerActionResult>(json)
            ?? throw new JsonException("The action JSON payload was null.");
        if (result.SchemaVersion != SupportedSchemaVersion)
        {
            throw new InvalidDataException(
                $"Unsupported action schema version {result.SchemaVersion}; expected {SupportedSchemaVersion}.");
        }

        var expectedName = ToProtocolName(expectedAction);
        if (!string.Equals(result.Action, expectedName, StringComparison.Ordinal))
        {
            throw new InvalidDataException($"Action response '{result.Action}' did not match '{expectedName}'.");
        }

        if (string.IsNullOrWhiteSpace(result.Message))
        {
            throw new InvalidDataException("message is required.");
        }

        return result;
    }

    private static TimeSpan GetTimeout(ManagerAction action) => action switch
    {
        ManagerAction.Install or ManagerAction.Repair or ManagerAction.RefreshCredential => TimeSpan.FromSeconds(120),
        ManagerAction.Uninstall or ManagerAction.ClearCredential => TimeSpan.FromSeconds(60),
        _ => TimeSpan.FromSeconds(60),
    };

    private static string ToProtocolName(ManagerAction action)
    {
        var value = action.ToString();
        return char.ToLowerInvariant(value[0]) + value[1..];
    }

    private static string GetFailureMessage(ManagerAction action, string? errorCode = null)
    {
        if (errorCode == "CREDENTIAL_CANCELLED")
        {
            return "账号输入已取消，未保存新的凭据。";
        }

        return action switch
        {
            ManagerAction.RefreshCredential => "更新校园网账号失败。",
            ManagerAction.Install => "安装自动登录失败。",
            ManagerAction.Repair => "修复安装失败。",
            ManagerAction.Uninstall => "卸载自动登录失败。",
            ManagerAction.ClearCredential => "清除账号信息失败。",
            _ => "管理操作失败。",
        };
    }
}
