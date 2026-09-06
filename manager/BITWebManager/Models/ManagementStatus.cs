using System.Text.Json.Serialization;

namespace BITWebManager.Models;

public sealed record ManagementStatus
{
    [JsonPropertyName("schemaVersion")]
    public int SchemaVersion { get; init; }

    [JsonPropertyName("installed")]
    public bool Installed { get; init; }

    [JsonPropertyName("taskState")]
    public string TaskState { get; init; } = string.Empty;

    [JsonPropertyName("credentialExists")]
    public bool CredentialExists { get; init; }

    [JsonPropertyName("version")]
    public string Version { get; init; } = string.Empty;

    [JsonPropertyName("installDirectory")]
    public string InstallDirectory { get; init; } = string.Empty;
}
