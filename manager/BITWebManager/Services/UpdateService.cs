using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text.Json;
using BITWebManager.Models;
using BITWebVersioning;

namespace BITWebManager.Services;

public sealed class UpdateService : IUpdateService, IDisposable
{
    private static readonly TimeSpan CheckTimeout = TimeSpan.FromSeconds(15);
    private static readonly TimeSpan DownloadTimeout = TimeSpan.FromMinutes(5);
    private readonly HttpClient _httpClient;
    private readonly UpdatePackageValidator _packageValidator;
    private readonly bool _ownsClient;

    public UpdateService(HttpClient? httpClient = null, UpdatePackageValidator? packageValidator = null)
    {
        if (httpClient is null)
        {
            var handler = new HttpClientHandler { AllowAutoRedirect = false };
            _httpClient = new HttpClient(handler) { Timeout = Timeout.InfiniteTimeSpan };
            _ownsClient = true;
        }
        else
        {
            _httpClient = httpClient;
        }

        _packageValidator = packageValidator ?? new UpdatePackageValidator(new PowerShellService());
    }

    public Task<UpdateInfo> CheckForUpdatesAsync(ReleaseVersion currentVersion, CancellationToken cancellationToken = default) =>
        CheckReleaseAsync(currentVersion, UpdateSecurity.LatestReleaseApi, requestedQaTag: null, cancellationToken);

    public Task<UpdateInfo> CheckForQaReleaseAsync(ReleaseVersion currentVersion, string requestedTag, CancellationToken cancellationToken = default)
    {
        UpdateSecurity.ValidateQaRequest(currentVersion, requestedTag);

        var uri = UpdateSecurity.QaReleaseApi(requestedTag);
        UpdateSecurity.ValidateQaApiUri(uri, requestedTag);
        return CheckReleaseAsync(currentVersion, uri, requestedTag, cancellationToken);
    }

    private async Task<UpdateInfo> CheckReleaseAsync(ReleaseVersion currentVersion, Uri apiUri, string? requestedQaTag, CancellationToken cancellationToken)
    {
        if (requestedQaTag is null) UpdateSecurity.ValidateApiUri(apiUri);
        else UpdateSecurity.ValidateQaApiUri(apiUri, requestedQaTag);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(CheckTimeout);
        using var request = CreateRequest(HttpMethod.Get, apiUri, "application/vnd.github+json");
        HttpResponseMessage response;
        try
        {
            response = await _httpClient.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new UpdateException("连接 GitHub 超时，请稍后重试。", "GitHub release request timed out.", "GITHUB_TIMEOUT");
        }
        catch (HttpRequestException exception)
        {
            throw new UpdateException("无法连接 GitHub，请检查网络连接。", exception.ToString(), "GITHUB_CONNECTION_FAILED", exception);
        }

        using (response)
        {
            if (response.StatusCode == HttpStatusCode.Forbidden &&
                response.Headers.TryGetValues("X-RateLimit-Remaining", out var remaining) && remaining.Contains("0"))
            {
                throw new UpdateException("GitHub 暂时限制了更新检查，请稍后再试。", "GitHub API rate limit was exhausted (HTTP 403).", "GITHUB_RATE_LIMIT");
            }
            if (response.StatusCode == HttpStatusCode.NotFound)
            {
                throw new UpdateException(
                    requestedQaTag is null ? "官方仓库暂未提供稳定版更新。" : "找不到指定的 RC Release。",
                    $"GitHub release endpoint returned HTTP 404: {apiUri.AbsolutePath}",
                    "RELEASE_NOT_FOUND");
            }
            if (!response.IsSuccessStatusCode)
            {
                throw new UpdateException("GitHub 更新检查失败。", $"GitHub API returned HTTP {(int)response.StatusCode} {response.ReasonPhrase}.", "GITHUB_API_ERROR");
            }

            try
            {
                await using var stream = await response.Content.ReadAsStreamAsync(timeout.Token);
                using var json = await JsonDocument.ParseAsync(stream, cancellationToken: timeout.Token);
                return ParseRelease(json.RootElement, currentVersion, requestedQaTag);
            }
            catch (UpdateException)
            {
                throw;
            }
            catch (Exception exception) when (exception is JsonException or InvalidOperationException or FormatException)
            {
                throw new UpdateException("GitHub 返回的更新信息无效。", exception.ToString(), "INVALID_RELEASE_RESPONSE", exception);
            }
        }
    }

    public async Task<string> DownloadUpdateAsync(
        UpdateInfo info,
        IProgress<UpdateProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        if (!info.IsUpdateAvailable || info.DownloadUrl is null || info.ChecksumUrl is null)
        {
            throw new InvalidOperationException("No installable update is available.");
        }

        var workspace = Path.Combine(Path.GetTempPath(), "BITWebAutoLogin-update-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(workspace);
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(DownloadTimeout);
            var assetName = UpdateSecurity.AssetName(info.LatestVersion);
            var archivePath = Path.Combine(workspace, assetName);
            var checksumPath = archivePath + ".sha256";
            progress?.Report(new UpdateProgress(UpdateStage.Downloading, $"正在下载 v{info.LatestVersion}…"));
            await DownloadFileAsync(info.DownloadUrl, info.ReleaseTag, assetName, archivePath, progress, timeout.Token);
            await DownloadFileAsync(info.ChecksumUrl, info.ReleaseTag, assetName + ".sha256", checksumPath, null, timeout.Token);
            ValidateChecksum(archivePath, checksumPath);
            return workspace;
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            TryDeleteDirectory(workspace);
            throw new UpdateException("下载更新超时，请稍后重试。", "Release asset download timed out.", "DOWNLOAD_TIMEOUT");
        }
        catch
        {
            TryDeleteDirectory(workspace);
            throw;
        }
    }

    public async Task<string> ValidateUpdateAsync(
        UpdateInfo info,
        string workspaceDirectory,
        IProgress<UpdateProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        progress?.Report(new UpdateProgress(UpdateStage.Validating, "正在验证更新包…"));
        try
        {
            var archivePath = Path.Combine(workspaceDirectory, UpdateSecurity.AssetName(info.LatestVersion));
            return await _packageValidator.ValidateAndExtractAsync(archivePath, info.LatestVersion, workspaceDirectory, cancellationToken);
        }
        catch
        {
            TryDeleteDirectory(workspaceDirectory);
            throw;
        }
    }

    public Task<PreparedUpdate> PrepareUpdateAsync(
        UpdateInfo info,
        string workspaceDirectory,
        string payloadDirectory,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var updaterPath = Path.Combine(payloadDirectory, "BITWebUpdater.exe");
        if (!File.Exists(updaterPath))
        {
            throw new UpdateException("更新包缺少部署组件。", $"Missing updater: {updaterPath}", "MISSING_UPDATER");
        }

        var resultPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "BITWebAutoLogin", "update-result.json");
        return Task.FromResult(new PreparedUpdate(info, workspaceDirectory, payloadDirectory, updaterPath, resultPath));
    }

    public static UpdateInfo ParseRelease(JsonElement root, ReleaseVersion currentVersion, string? requestedQaTag = null)
    {
        var draft = root.GetProperty("draft").GetBoolean();
        var prerelease = root.GetProperty("prerelease").GetBoolean();
        if (requestedQaTag is null && (draft || prerelease))
        {
            throw new UpdateException("GitHub 最新版本不是稳定 Release。", "Latest release is draft or prerelease.", "UNSTABLE_RELEASE");
        }
        if (requestedQaTag is not null && (draft || !prerelease))
        {
            throw new UpdateException("指定的 Release 不是可用的 RC。", $"QA release draft={draft}, prerelease={prerelease}.", "INVALID_QA_RELEASE");
        }

        var tag = root.GetProperty("tag_name").GetString() ?? string.Empty;
        var latestVersion = UpdateSecurity.ParseReleaseTag(tag);
        if (requestedQaTag is null && latestVersion.IsPrerelease)
        {
            throw new UpdateException("GitHub 最新版本不是稳定 Release。", $"Stable endpoint returned prerelease tag {tag}.", "UNSTABLE_RELEASE");
        }
        if (requestedQaTag is not null)
        {
            if (!string.Equals(tag, requestedQaTag, StringComparison.Ordinal) || !latestVersion.IsPrerelease)
                throw new UpdateException("GitHub 返回的 RC 标签与请求不一致。", $"Requested {requestedQaTag}; returned {tag}.", "QA_TAG_MISMATCH");
            if (!string.Equals(latestVersion.BaseVersion, currentVersion.BaseVersion, StringComparison.Ordinal))
                throw new UpdateException("RC Release 与当前版本不属于同一发布基线。", $"Current {currentVersion}; returned {latestVersion}.", "QA_BASE_VERSION_MISMATCH");
        }
        var releasePage = new Uri(root.GetProperty("html_url").GetString() ?? string.Empty, UriKind.Absolute);
        UpdateSecurity.ValidateReleasePageUri(releasePage);
        var publishedAt = root.GetProperty("published_at").GetDateTimeOffset();
        var releaseName = root.TryGetProperty("name", out var nameElement) ? nameElement.GetString() ?? tag : tag;
        var updateAvailable = latestVersion.CompareTo(currentVersion) > 0;
        Uri? archive = null;
        Uri? checksum = null;

        if (updateAvailable)
        {
            var assetName = UpdateSecurity.AssetName(latestVersion);
            foreach (var asset in root.GetProperty("assets").EnumerateArray())
            {
                var name = asset.GetProperty("name").GetString();
                var urlText = asset.GetProperty("browser_download_url").GetString();
                if (string.IsNullOrWhiteSpace(urlText)) continue;
                if (name == assetName) archive = new Uri(urlText, UriKind.Absolute);
                if (name == assetName + ".sha256") checksum = new Uri(urlText, UriKind.Absolute);
            }

            if (archive is null || checksum is null)
            {
                throw new UpdateException("新版本缺少经过校验的 Windows 更新包。", $"Release {tag} must contain {assetName} and {assetName}.sha256.", "MISSING_RELEASE_ASSET");
            }
            UpdateSecurity.ValidateInitialAssetUri(archive, tag, assetName);
            UpdateSecurity.ValidateInitialAssetUri(checksum, tag, assetName + ".sha256");
        }

        return new UpdateInfo(currentVersion, latestVersion, tag, releaseName, publishedAt, archive, checksum, releasePage, updateAvailable);
    }

    private async Task DownloadFileAsync(
        Uri initialUri,
        string releaseTag,
        string expectedFileName,
        string destination,
        IProgress<UpdateProgress>? progress,
        CancellationToken cancellationToken)
    {
        UpdateSecurity.ValidateInitialAssetUri(initialUri, releaseTag, expectedFileName);
        var current = initialUri;
        for (var redirect = 0; redirect <= 5; redirect++)
        {
            UpdateSecurity.ValidateRedirectUri(current);
            using var request = CreateRequest(HttpMethod.Get, current, "application/octet-stream");
            using var response = await _httpClient.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
            if (IsRedirect(response.StatusCode))
            {
                if (redirect == 5 || response.Headers.Location is null)
                {
                    throw new UpdateException("GitHub 下载重定向无效。", "Release asset exceeded the redirect limit or omitted Location.", "INVALID_REDIRECT");
                }
                current = response.Headers.Location.IsAbsoluteUri ? response.Headers.Location : new Uri(current, response.Headers.Location);
                UpdateSecurity.ValidateRedirectUri(current);
                continue;
            }
            if (!response.IsSuccessStatusCode)
            {
                throw new UpdateException("下载更新失败。", $"Asset request returned HTTP {(int)response.StatusCode} {response.ReasonPhrase}.", "DOWNLOAD_FAILED");
            }

            var total = response.Content.Headers.ContentLength;
            await using var input = await response.Content.ReadAsStreamAsync(cancellationToken);
            await using var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None, 81920, true);
            var buffer = new byte[81920];
            long received = 0;
            int count;
            while ((count = await input.ReadAsync(buffer, cancellationToken)) > 0)
            {
                await output.WriteAsync(buffer.AsMemory(0, count), cancellationToken);
                received += count;
                progress?.Report(new UpdateProgress(UpdateStage.Downloading, $"已下载 {FormatBytes(received)}" + (total is null ? string.Empty : $" / {FormatBytes(total.Value)}"), received, total));
            }
            return;
        }
    }

    private static HttpRequestMessage CreateRequest(HttpMethod method, Uri uri, string accept)
    {
        var request = new HttpRequestMessage(method, uri);
        request.Headers.UserAgent.ParseAdd("BITWebAutoLogin/1.3");
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue(accept));
        request.Headers.TryAddWithoutValidation("X-GitHub-Api-Version", "2022-11-28");
        return request;
    }

    private static bool IsRedirect(HttpStatusCode status) => status is HttpStatusCode.MovedPermanently or HttpStatusCode.Found or HttpStatusCode.SeeOther or HttpStatusCode.TemporaryRedirect or HttpStatusCode.PermanentRedirect;

    private static void ValidateChecksum(string archivePath, string checksumPath)
    {
        var text = File.ReadAllText(checksumPath).Trim();
        var token = text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? string.Empty;
        if (token.Length != 64 || !token.All(Uri.IsHexDigit))
        {
            throw new UpdateException("更新包校验文件格式无效。", $"Invalid SHA-256 file: {checksumPath}", "INVALID_CHECKSUM_FILE");
        }
        using var stream = File.OpenRead(archivePath);
        var actual = Convert.ToHexString(SHA256.HashData(stream));
        if (!actual.Equals(token, StringComparison.OrdinalIgnoreCase))
        {
            throw new UpdateException("更新包完整性校验失败。", $"SHA-256 mismatch. Expected {token}; actual {actual}.", "CHECKSUM_MISMATCH");
        }
    }

    private static string FormatBytes(long bytes) => bytes >= 1024 * 1024
        ? $"{bytes / 1024d / 1024d:0.0} MB"
        : $"{bytes / 1024d:0.0} KB";

    public static void TryDeleteDirectory(string path)
    {
        try { if (Directory.Exists(path)) Directory.Delete(path, recursive: true); }
        catch { }
    }

    public void Dispose()
    {
        if (_ownsClient) _httpClient.Dispose();
    }
}
