using System.Text.RegularExpressions;
using BITWebVersioning;

namespace BITWebManager.Services;

public static partial class UpdateSecurity
{
    public const string Owner = "Oblivionis-ling";
    public const string Repository = "bit-web-auto-login";
    public static readonly Uri LatestReleaseApi = new($"https://api.github.com/repos/{Owner}/{Repository}/releases/latest");

    public static ReleaseVersion ParseReleaseTag(string tag)
    {
        try
        {
            return ReleaseVersion.ParseTag(tag);
        }
        catch (FormatException exception)
        {
            throw new UpdateException(
                "GitHub Release 的版本格式不正确。",
                $"Invalid release tag: '{tag}'. Expected vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-rc.N.",
                "INVALID_RELEASE_TAG",
                exception);
        }
    }

    public static void ValidateApiUri(Uri uri)
    {
        if (uri.Scheme != Uri.UriSchemeHttps ||
            !uri.Host.Equals("api.github.com", StringComparison.OrdinalIgnoreCase) ||
            !uri.AbsolutePath.Equals($"/repos/{Owner}/{Repository}/releases/latest", StringComparison.Ordinal))
        {
            throw UnsafeUrl(uri);
        }
    }

    public static Uri QaReleaseApi(string requestedTag)
    {
        var version = ParseReleaseTag(requestedTag);
        if (!version.IsPrerelease) throw InvalidQaTag(requestedTag);
        return new Uri($"https://api.github.com/repos/{Owner}/{Repository}/releases/tags/{requestedTag}");
    }

    public static ReleaseVersion ValidateQaRequest(ReleaseVersion currentVersion, string requestedTag)
    {
        if (!currentVersion.IsPrerelease)
            throw new UpdateException("正式版本不能使用 RC QA 更新入口。", $"Stable manager {currentVersion} rejected --qa-release-tag.", "QA_MODE_REQUIRES_RC");
        var requestedVersion = ParseReleaseTag(requestedTag);
        if (!requestedVersion.IsPrerelease) throw InvalidQaTag(requestedTag);
        if (!string.Equals(requestedVersion.BaseVersion, currentVersion.BaseVersion, StringComparison.Ordinal))
            throw new UpdateException("RC QA 标签与当前版本不属于同一发布基线。", $"Current base {currentVersion.BaseVersion}; requested {requestedVersion.BaseVersion}.", "QA_BASE_VERSION_MISMATCH");
        return requestedVersion;
    }

    public static void ValidateQaApiUri(Uri uri, string requestedTag)
    {
        var expected = QaReleaseApi(requestedTag);
        if (uri.Scheme != Uri.UriSchemeHttps ||
            !uri.Host.Equals("api.github.com", StringComparison.OrdinalIgnoreCase) ||
            !uri.AbsolutePath.Equals(expected.AbsolutePath, StringComparison.Ordinal))
        {
            throw UnsafeUrl(uri);
        }
    }

    public static void ValidateReleasePageUri(Uri uri)
    {
        var prefix = $"/{Owner}/{Repository}/releases/";
        if (uri.Scheme != Uri.UriSchemeHttps ||
            !uri.Host.Equals("github.com", StringComparison.OrdinalIgnoreCase) ||
            !uri.AbsolutePath.StartsWith(prefix, StringComparison.Ordinal))
        {
            throw UnsafeUrl(uri);
        }
    }

    public static void ValidateInitialAssetUri(Uri uri, string releaseTag, string expectedFileName)
    {
        var expectedPrefix = $"/{Owner}/{Repository}/releases/download/{releaseTag}/";
        if (uri.Scheme != Uri.UriSchemeHttps ||
            !uri.Host.Equals("github.com", StringComparison.OrdinalIgnoreCase) ||
            !uri.AbsolutePath.StartsWith(expectedPrefix, StringComparison.Ordinal) ||
            !Uri.UnescapeDataString(uri.AbsolutePath).EndsWith('/' + expectedFileName, StringComparison.Ordinal))
        {
            throw UnsafeUrl(uri);
        }
    }

    public static void ValidateRedirectUri(Uri uri)
    {
        var allowedHosts = new[] { "github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com" };
        if (uri.Scheme != Uri.UriSchemeHttps || !allowedHosts.Contains(uri.Host, StringComparer.OrdinalIgnoreCase))
        {
            throw UnsafeUrl(uri);
        }
    }

    public static string AssetName(ReleaseVersion version) => $"BITWebAutoLogin-v{version}-win-x64.zip";

    private static UpdateException InvalidQaTag(string tag) => new(
        "RC QA 标签格式不正确。",
        $"QA release tag must be a restricted RC tag: '{tag}'.",
        "INVALID_QA_RELEASE_TAG");

    private static UpdateException UnsafeUrl(Uri uri) => new(
        "更新来源未通过安全校验。",
        $"Rejected update URL: {uri}",
        "UNSAFE_UPDATE_URL");
}
