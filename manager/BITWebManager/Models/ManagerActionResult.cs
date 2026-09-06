using System.Text.Json.Serialization;

namespace BITWebManager.Models;

public sealed record ManagerActionResult
{
    [JsonPropertyName("schemaVersion")]
    public int SchemaVersion { get; init; }

    [JsonPropertyName("success")]
    public bool Success { get; init; }

    [JsonPropertyName("action")]
    public string Action { get; init; } = string.Empty;

    [JsonPropertyName("message")]
    public string Message { get; init; } = string.Empty;

    [JsonPropertyName("requiresRefresh")]
    public bool RequiresRefresh { get; init; }

    [JsonPropertyName("errorCode")]
    public string? ErrorCode { get; init; }
}
