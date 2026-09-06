namespace BITWebManager.Models;

public sealed record PreparedUpdate(
    UpdateInfo Info,
    string WorkspaceDirectory,
    string PayloadDirectory,
    string UpdaterPath,
    string ResultPath);
