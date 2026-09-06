namespace BITWebManager.Models;

public sealed record PowerShellResult(int ExitCode, string StandardOutput, string StandardError);
