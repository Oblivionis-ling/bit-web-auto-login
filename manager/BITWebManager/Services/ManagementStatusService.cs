using System.IO;
using System.Text.Json;
using BITWebManager.Models;

namespace BITWebManager.Services;

public sealed class ManagementStatusService : IManagementStatusService
{
    private const int SupportedSchemaVersion = 1;
    private readonly PowerShellService _powerShellService;
    private readonly string _bridgePath;

    public ManagementStatusService(PowerShellService powerShellService, string? bridgePath = null)
    {
        _powerShellService = powerShellService;
        _bridgePath = bridgePath ?? Path.Combine(AppContext.BaseDirectory, "PowerShell", "Get-ManagerStatus.ps1");
    }

    public async Task<ManagementStatus> GetStatusAsync(CancellationToken cancellationToken = default)
    {
        PowerShellResult result;
        try
        {
            result = await _powerShellService.RunFileAsync(
                _bridgePath,
                timeout: TimeSpan.FromSeconds(15),
                cancellationToken: cancellationToken);
        }
        catch (Exception exception) when (exception is not OperationCanceledException)
        {
            throw new StatusReadException(
                "无法启动状态读取服务，请确认 Windows PowerShell 可用。",
                exception.ToString(),
                exception);
        }

        if (result.ExitCode != 0)
        {
            var details = string.IsNullOrWhiteSpace(result.StandardError)
                ? $"PowerShell exited with code {result.ExitCode}."
                : $"PowerShell exit code: {result.ExitCode}{Environment.NewLine}{result.StandardError}";
            throw new StatusReadException("暂时无法读取自动登录状态。", details);
        }

        if (string.IsNullOrWhiteSpace(result.StandardOutput))
        {
            throw new StatusReadException("状态服务没有返回数据。", "PowerShell stdout was empty.");
        }

        try
        {
            var status = JsonSerializer.Deserialize<ManagementStatus>(result.StandardOutput)
                ?? throw new JsonException("The JSON payload was null.");
            Validate(status);
            return status;
        }
        catch (Exception exception) when (exception is JsonException or InvalidDataException)
        {
            throw new StatusReadException(
                "状态数据格式不正确，请查看详细信息。",
                $"{exception}{Environment.NewLine}stdout:{Environment.NewLine}{result.StandardOutput}",
                exception);
        }
    }

    public static ManagementStatus ParseAndValidate(string json)
    {
        var status = JsonSerializer.Deserialize<ManagementStatus>(json)
            ?? throw new JsonException("The JSON payload was null.");
        Validate(status);
        return status;
    }

    private static void Validate(ManagementStatus status)
    {
        if (status.SchemaVersion != SupportedSchemaVersion)
        {
            throw new InvalidDataException(
                $"Unsupported status schema version {status.SchemaVersion}; expected {SupportedSchemaVersion}.");
        }

        if (string.IsNullOrWhiteSpace(status.TaskState))
        {
            throw new InvalidDataException("taskState is required.");
        }

        if (string.IsNullOrWhiteSpace(status.InstallDirectory))
        {
            throw new InvalidDataException("installDirectory is required.");
        }
    }
}
