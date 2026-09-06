namespace BITWebManager.Models;

public enum UpdateStage
{
    Checking,
    Downloading,
    Validating,
    Preparing,
    Deploying,
}

public sealed record UpdateProgress(UpdateStage Stage, string Message, long? BytesReceived = null, long? TotalBytes = null);
