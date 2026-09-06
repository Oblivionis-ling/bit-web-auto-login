using System.IO;
using BITWebVersioning;

namespace BITWebManager.Models;

internal sealed record LaunchOptions(
    string? CapturePath,
    double CaptureDpi,
    double? CaptureWidth,
    double? CaptureHeight,
    string? PreviewState,
    string? PreviewOperation,
    string? PreviewDialog,
    bool PreviewExpandDetails,
    string? QaReleaseTag,
    string? HealthCheckPath,
    ReleaseVersion? ExpectedVersion)
{
    public static LaunchOptions Parse(IReadOnlyList<string> arguments)
    {
        string? capturePath = null;
        string? previewState = null;
        string? previewOperation = null;
        string? previewDialog = null;
        var previewExpandDetails = false;
        string? qaReleaseTag = null;
        string? healthCheckPath = null;
        ReleaseVersion? expectedVersion = null;
        var captureDpi = 96d;
        double? captureWidth = null;
        double? captureHeight = null;

        for (var index = 0; index < arguments.Count; index++)
        {
            switch (arguments[index])
            {
                case "--capture" when index + 1 < arguments.Count:
                    capturePath = Path.GetFullPath(arguments[++index]);
                    break;
                case "--capture-dpi" when index + 1 < arguments.Count:
                    if (!double.TryParse(arguments[++index], out captureDpi) || captureDpi is < 96 or > 192)
                    {
                        throw new ArgumentException("Capture DPI must be between 96 and 192.");
                    }
                    break;
                case "--capture-size" when index + 1 < arguments.Count:
                    var parts = arguments[++index].Split('x', 'X');
                    if (parts.Length != 2 ||
                        !double.TryParse(parts[0], out var width) ||
                        !double.TryParse(parts[1], out var height) ||
                        width is < 760 or > 1920 || height is < 620 or > 1200)
                    {
                        throw new ArgumentException("Capture size must be WIDTHxHEIGHT within the supported window bounds.");
                    }
                    captureWidth = width;
                    captureHeight = height;
                    break;
                case "--preview-state" when index + 1 < arguments.Count:
                    previewState = arguments[++index];
                    break;
                case "--preview-operation" when index + 1 < arguments.Count:
                    previewOperation = arguments[++index];
                    break;
                case "--preview-dialog" when index + 1 < arguments.Count:
                    previewDialog = arguments[++index];
                    break;
                case "--preview-expand-details":
                    previewExpandDetails = true;
                    break;
                case "--qa-release-tag" when index + 1 < arguments.Count:
                    qaReleaseTag = arguments[++index];
                    break;
                case "--health-check" when index + 1 < arguments.Count:
                    healthCheckPath = Path.GetFullPath(arguments[++index]);
                    break;
                case "--expected-version" when index + 1 < arguments.Count:
                    if (!ReleaseVersion.TryParse(arguments[++index], out expectedVersion))
                    {
                        throw new ArgumentException("Expected version is invalid.");
                    }
                    break;
            }
        }

        if ((healthCheckPath is null) != (expectedVersion is null))
        {
            throw new ArgumentException("Health check path and expected version must be provided together.");
        }

        if ((previewOperation is not null || previewDialog is not null || previewExpandDetails) && previewState is null)
        {
            throw new ArgumentException("Preview operations require --preview-state.");
        }

        return new LaunchOptions(capturePath, captureDpi, captureWidth, captureHeight, previewState, previewOperation, previewDialog, previewExpandDetails, qaReleaseTag, healthCheckPath, expectedVersion);
    }
}
