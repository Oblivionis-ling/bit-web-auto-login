using BITWebVersioning;

namespace BITWebManager.Models;

public sealed record UpdateInfo(
    ReleaseVersion CurrentVersion,
    ReleaseVersion LatestVersion,
    string ReleaseTag,
    string ReleaseName,
    DateTimeOffset PublishedAt,
    Uri? DownloadUrl,
    Uri? ChecksumUrl,
    Uri ReleasePageUrl,
    bool IsUpdateAvailable);
