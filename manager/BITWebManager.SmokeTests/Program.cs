using System.Text.Json;
using System.IO.Compression;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Windows;
using BITWebManager.Models;
using BITWebManager.Services;
using BITWebManager.ViewModels;
using BITWebUpdater;
using BITWebVersioning;

var passed = 0;
var failed = 0;
var repositoryRoot = args.Length > 0 ? Path.GetFullPath(args[0]) : Directory.GetCurrentDirectory();
var statusBridge = Path.Combine(repositoryRoot, "scripts", "Get-ManagerStatus.ps1");
var actionBridge = Path.Combine(repositoryRoot, "scripts", "Invoke-ManagerAction.ps1");

await TestAsync("parses the fixed status schema", () =>
{
    const string json = """
        {"schemaVersion":1,"installed":true,"taskState":"Ready","credentialExists":true,"version":"1.2.5","installDirectory":"C:\\BITWebAutoLogin"}
        """;
    var status = ManagementStatusService.ParseAndValidate(json);
    Assert(status.Installed && status.TaskState == "Ready" && status.CredentialExists, "status fields");
    Assert(status.Version == "1.2.5", "version");
    return Task.CompletedTask;
});

await TestAsync("rejects an unsupported status schema", () =>
{
    const string json = """
        {"schemaVersion":2,"installed":true,"taskState":"Ready","credentialExists":true,"version":"1.2.5","installDirectory":"C:\\BITWebAutoLogin"}
        """;
    AssertThrowsData(() => ManagementStatusService.ParseAndValidate(json));
    return Task.CompletedTask;
});

await TestAsync("parses the action JSON schema", () =>
{
    const string json = """
        {"schemaVersion":1,"success":true,"action":"repair","message":"Action completed.","requiresRefresh":true,"errorCode":null}
        """;
    var result = ManagementActionService.ParseAndValidate(json, ManagerAction.Repair);
    Assert(result.Success && result.RequiresRefresh, "action result");
    return Task.CompletedTask;
});

await TestAsync("rejects an unsupported action schema", () =>
{
    const string json = """
        {"schemaVersion":2,"success":true,"action":"repair","message":"Action completed.","requiresRefresh":true,"errorCode":null}
        """;
    AssertThrowsData(() => ManagementActionService.ParseAndValidate(json, ManagerAction.Repair));
    return Task.CompletedTask;
});

await TestAsync("maps installed healthy state", () =>
{
    var view = DashboardPresentation.FromStatus(Status(true, "Ready", true, "1.2.5"));
    Assert(view.OverallTitle == "自动登录运行正常", "overall title");
    Assert(view.TaskValue == "已启用" && view.AccountValue == "已配置", "healthy values");
    Assert(view.OverallTone == StatusTone.Success, "overall tone");
    return Task.CompletedTask;
});

await TestAsync("maps installed missing credential state", () =>
{
    var view = DashboardPresentation.FromStatus(Status(true, "Ready", false, "1.2.5"));
    Assert(view.OverallTitle == "自动登录需要配置账号", "overall title");
    Assert(view.AccountValue == "未配置" && view.OverallTone == StatusTone.Warning, "missing credential");
    return Task.CompletedTask;
});

await TestAsync("maps uninstalled states", () =>
{
    var credentialOnly = DashboardPresentation.FromStatus(Status(false, "NotInstalled", true, "1.2.5"));
    var empty = DashboardPresentation.FromStatus(Status(false, "NotInstalled", false, ""));
    Assert(credentialOnly.TaskValue == "未安装" && credentialOnly.AccountValue == "已配置", "credential-only");
    Assert(empty.AccountValue == "未配置" && empty.VersionValue == "—", "empty");
    return Task.CompletedTask;
});

await TestAsync("surfaces status failures without throwing", async () =>
{
    var viewModel = new MainWindowViewModel(new FailingStatusService());
    await viewModel.LoadAsync();
    Assert(viewModel.HasError && viewModel.OverallTitle == "无法读取系统状态", "failure state");
    Assert(viewModel.TechnicalDetails.Contains("offline failure", StringComparison.Ordinal), "technical details");
});

await TestAsync("captures nonzero exit code and stderr", async () =>
{
    var process = await new PowerShellService().RunFileAsync(
        actionBridge,
        new[] { "-Action", "Repair", "-TestMode", "-TestOutcome", "Failure" },
        TimeSpan.FromSeconds(5));
    Assert(process.ExitCode != 0, "nonzero exit code");
    Assert(process.StandardError.Contains("Simulated manager action failure", StringComparison.Ordinal), "stderr");
    Assert(process.StandardOutput.Contains("\"success\":false", StringComparison.Ordinal), "failure JSON");
});

await TestAsync("enforces PowerShell timeout", async () =>
{
    await AssertThrowsAsync<TimeoutException>(() => new PowerShellService().RunFileAsync(
        actionBridge,
        new[] { "-Action", "Repair", "-TestMode", "-TestDelayMilliseconds", "3000" },
        TimeSpan.FromMilliseconds(150)));
});

await TestAsync("supports PowerShell cancellation", async () =>
{
    using var source = new CancellationTokenSource(TimeSpan.FromMilliseconds(150));
    await AssertThrowsAsync<OperationCanceledException>(() => new PowerShellService().RunFileAsync(
        actionBridge,
        new[] { "-Action", "Repair", "-TestMode", "-TestDelayMilliseconds", "3000" },
        TimeSpan.FromSeconds(5),
        cancellationToken: source.Token));
});

await TestAsync("disables open directory while uninstalled", async () =>
{
    var directory = new RecordingDirectoryService();
    var viewModel = new MainWindowViewModel(
        new SequenceStatusService(Status(false, "NotInstalled", false, "")),
        new ImmediateActionService(), directory, new RecordingDialogService());
    await viewModel.LoadAsync();
    Assert(!viewModel.CanOpenInstallDirectory, "open directory state");
    Assert(!viewModel.OpenInstallDirectoryCommand.CanExecute(null), "open directory command");
    Assert(directory.OpenCount == 0, "directory not opened");
});

await TestAsync("uses one state-appropriate primary action", async () =>
{
    var installed = new MainWindowViewModel(
        new SequenceStatusService(Status(true, "Ready", true, "1.3.0")),
        new ImmediateActionService(), new RecordingDirectoryService(), new RecordingDialogService());
    await installed.LoadAsync();
    Assert(installed.PrimaryActionText == "检查更新", "installed primary action");
    Assert(installed.CanCheckUpdate && installed.InstalledVisibility == Visibility.Visible, "installed update and repair availability");

    var fresh = new MainWindowViewModel(
        new SequenceStatusService(Status(false, "NotInstalled", false, "")),
        new ImmediateActionService(), new RecordingDirectoryService(), new RecordingDialogService());
    await fresh.LoadAsync();
    Assert(fresh.PrimaryActionText == "安装自动登录", "fresh primary action");
    Assert(fresh.InstalledVisibility == Visibility.Collapsed, "repair hidden while uninstalled");
});

await TestAsync("does not create a missing install directory", () =>
{
    var missingPath = Path.Combine(Path.GetTempPath(), "bitweb-missing-" + Guid.NewGuid().ToString("N"));
    AssertThrows<DirectoryNotFoundException>(() => new InstallDirectoryService().Open(missingPath));
    Assert(!Directory.Exists(missingPath), "missing directory remains absent");
    return Task.CompletedTask;
});

await TestAsync("refreshes status after a write action", async () =>
{
    var status = new SequenceStatusService(Status(true, "Ready", true, "1.2.5"));
    var action = new ImmediateActionService();
    var viewModel = new MainWindowViewModel(status, action, new RecordingDirectoryService(), new RecordingDialogService());
    await viewModel.LoadAsync();
    await viewModel.ExecuteManagerActionAsync(ManagerAction.Repair);
    Assert(action.CallCount == 1, "action count");
    Assert(status.CallCount == 2, "post-action status refresh");
    Assert(!viewModel.IsBusy, "busy cleared");
});

await TestAsync("rejects concurrent write operations", async () =>
{
    var action = new BlockingActionService();
    var viewModel = new MainWindowViewModel(
        new SequenceStatusService(Status(true, "Ready", true, "1.2.5")),
        action, new RecordingDirectoryService(), new RecordingDialogService());
    await viewModel.LoadAsync();
    var first = viewModel.ExecuteManagerActionAsync(ManagerAction.Repair);
    await action.Started.Task.WaitAsync(TimeSpan.FromSeconds(2));
    Assert(viewModel.IsBusy && viewModel.IsCriticalOperation, "critical busy state");
    await viewModel.ExecuteManagerActionAsync(ManagerAction.Uninstall);
    Assert(action.CallCount == 1, "second action rejected");
    action.Release.TrySetResult();
    await first;
});

await TestAsync("requires two confirmations before clearing credentials", async () =>
{
    var declinedDialog = new RecordingDialogService { FirstClearAnswer = true, SecondClearAnswer = false };
    var declinedAction = new ImmediateActionService();
    var declined = new MainWindowViewModel(
        new SequenceStatusService(Status(true, "Ready", true, "1.2.5")),
        declinedAction, new RecordingDirectoryService(), declinedDialog);
    await declined.LoadAsync();
    await declined.RequestClearCredentialAsync();
    Assert(declinedDialog.FirstClearCount == 1 && declinedDialog.SecondClearCount == 1, "two dialogs shown");
    Assert(declinedAction.CallCount == 0, "declined clear not executed");

    var acceptedDialog = new RecordingDialogService { FirstClearAnswer = true, SecondClearAnswer = true };
    var acceptedAction = new ImmediateActionService();
    var accepted = new MainWindowViewModel(
        new SequenceStatusService(Status(true, "Ready", true, "1.2.5")),
        acceptedAction, new RecordingDirectoryService(), acceptedDialog);
    await accepted.LoadAsync();
    await accepted.RequestClearCredentialAsync();
    Assert(acceptedAction.CallCount == 1 && acceptedAction.LastAction == ManagerAction.ClearCredential, "accepted clear executed");
});

await TestAsync("reads real status through the PowerShell JSON bridge", async () =>
{
    var service = new ManagementStatusService(new PowerShellService(), statusBridge);
    var status = await service.GetStatusAsync();
    Assert(status.SchemaVersion == 1, "schema version");
    Assert(!string.IsNullOrWhiteSpace(status.TaskState), "taskState");
    Assert(!string.IsNullOrWhiteSpace(status.InstallDirectory), "installDirectory");
});

await TestAsync("refreshes the real status through the view model command path", async () =>
{
    var viewModel = new MainWindowViewModel(
        new ManagementStatusService(new PowerShellService(), statusBridge),
        new ImmediateActionService(), new RecordingDirectoryService(), new RecordingDialogService());
    await viewModel.LoadAsync();
    await viewModel.RefreshStatusAsync();
    Assert(!viewModel.IsBusy && !viewModel.HasError, "real refresh completed");
    Assert(viewModel.TaskValue != "读取中", "real task state mapped");
});

await TestAsync("parses strict release versions and compares numerically", () =>
{
    Assert(UpdateSecurity.ParseReleaseTag("v1.10.0") > UpdateSecurity.ParseReleaseTag("v1.9.0"), "numeric comparison");
    Assert(ReleaseVersion.Parse("1.3.0-rc.1") < ReleaseVersion.Parse("1.3.0-rc.2"), "RC ordinal comparison");
    Assert(ReleaseVersion.Parse("1.3.0-rc.2") < ReleaseVersion.Parse("1.3.0"), "RC precedes stable");
    Assert(ReleaseVersion.Parse("1.3.0") < ReleaseVersion.Parse("1.3.1-rc.1"), "next base RC follows stable");
    Assert(ReleaseVersion.Parse("1.3.1-rc.1") < ReleaseVersion.Parse("1.3.1"), "next RC precedes stable");
    Assert(ReleaseVersion.Parse("1.3.0-rc.10") > ReleaseVersion.Parse("1.3.0-rc.2"), "RC ordinals are numeric");
    AssertThrows<UpdateException>(() => UpdateSecurity.ValidateQaRequest(ReleaseVersion.Parse("1.3.0"), "v1.3.0-rc.2"));
    AssertThrows<UpdateException>(() => UpdateSecurity.ParseReleaseTag("1.3.0"));
    AssertThrows<UpdateException>(() => UpdateSecurity.ParseReleaseTag("v1.3"));
    foreach (var invalid in new[] { "1.3", "1.3.0-rc", "1.3.0-rc.0", "1.3.0-rc.01", "1.3.0-beta.1", "1.3.0-preview", "v1.3.0-rc.x" })
        Assert(!ReleaseVersion.TryParse(invalid, out _), $"rejected {invalid}");
    return Task.CompletedTask;
});

await TestAsync("keeps the stable channel prerelease-free", () =>
{
    using var prerelease = JsonDocument.Parse(ReleaseJson("v1.3.0-rc.1", includeAssets: true, prerelease: true));
    var exception = CaptureThrows<UpdateException>(() => UpdateService.ParseRelease(prerelease.RootElement, ReleaseVersion.Parse("1.2.5")));
    Assert(exception.ErrorCode == "UNSTABLE_RELEASE", "stable path rejected RC metadata");
    using var stable = JsonDocument.Parse(ReleaseJson("v1.3.0", includeAssets: true));
    Assert(UpdateService.ParseRelease(stable.RootElement, ReleaseVersion.Parse("1.2.5")).IsUpdateAvailable, "stable update discovered");
    return Task.CompletedTask;
});

await TestAsync("allows only a higher same-base RC through the QA path", async () =>
{
    using var client = new HttpClient(new StaticHttpHandler(request =>
    {
        Assert(request.RequestUri!.AbsolutePath.EndsWith("/releases/tags/v1.3.0-rc.2", StringComparison.Ordinal), "fixed QA endpoint");
        return new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent(ReleaseJson("v1.3.0-rc.2", includeAssets: true, prerelease: true)),
        };
    }));
    using var service = new UpdateService(client);
    var info = await service.CheckForQaReleaseAsync(ReleaseVersion.Parse("1.3.0-rc.1"), "v1.3.0-rc.2");
    Assert(info.IsUpdateAvailable && info.LatestVersion == ReleaseVersion.Parse("1.3.0-rc.2"), "RC2 discovered");
    using var lower = JsonDocument.Parse(ReleaseJson("v1.3.0-rc.1", includeAssets: false, prerelease: true));
    Assert(!UpdateService.ParseRelease(lower.RootElement, ReleaseVersion.Parse("1.3.0-rc.2"), "v1.3.0-rc.1").IsUpdateAvailable, "RC downgrade blocked");
    using var equal = JsonDocument.Parse(ReleaseJson("v1.3.0-rc.1", includeAssets: false, prerelease: true));
    Assert(!UpdateService.ParseRelease(equal.RootElement, ReleaseVersion.Parse("1.3.0-rc.1"), "v1.3.0-rc.1").IsUpdateAvailable, "same RC is current");
    await AssertThrowsAsync<UpdateException>(() => service.CheckForQaReleaseAsync(ReleaseVersion.Parse("1.3.0"), "v1.3.0-rc.2"));
    await AssertThrowsAsync<UpdateException>(() => service.CheckForQaReleaseAsync(ReleaseVersion.Parse("1.3.0-rc.2"), "v1.4.0-rc.1"));
});

await TestAsync("rejects mismatched or non-prerelease QA metadata", () =>
{
    using var wrongTag = JsonDocument.Parse(ReleaseJson("v1.3.0-rc.1", includeAssets: true, prerelease: true));
    AssertThrows<UpdateException>(() => UpdateService.ParseRelease(wrongTag.RootElement, ReleaseVersion.Parse("1.3.0-rc.1"), "v1.3.0-rc.2"));
    using var stableFlag = JsonDocument.Parse(ReleaseJson("v1.3.0-rc.2", includeAssets: true, prerelease: false));
    AssertThrows<UpdateException>(() => UpdateService.ParseRelease(stableFlag.RootElement, ReleaseVersion.Parse("1.3.0-rc.1"), "v1.3.0-rc.2"));
    using var draft = JsonDocument.Parse(ReleaseJson("v1.3.0-rc.2", includeAssets: true, prerelease: true, draft: true));
    AssertThrows<UpdateException>(() => UpdateService.ParseRelease(draft.RootElement, ReleaseVersion.Parse("1.3.0-rc.1"), "v1.3.0-rc.2"));
    return Task.CompletedTask;
});

await TestAsync("parses stable release metadata and requires assets only for upgrades", () =>
{
    using var upgrade = JsonDocument.Parse(ReleaseJson("v1.3.1", includeAssets: true));
    var info = UpdateService.ParseRelease(upgrade.RootElement, new Version(1, 3, 0));
    Assert(info.IsUpdateAvailable && info.LatestVersion == new Version(1, 3, 1), "upgrade metadata");
    Assert(info.DownloadUrl is not null && info.ChecksumUrl is not null, "release assets");

    using var equal = JsonDocument.Parse(ReleaseJson("v1.3.0", includeAssets: false));
    Assert(!UpdateService.ParseRelease(equal.RootElement, new Version(1, 3, 0)).IsUpdateAvailable, "equal version");
    using var older = JsonDocument.Parse(ReleaseJson("v1.2.5", includeAssets: false));
    Assert(!UpdateService.ParseRelease(older.RootElement, new Version(1, 3, 0)).IsUpdateAvailable, "downgrade blocked");
    return Task.CompletedTask;
});

await TestAsync("rejects missing release assets and unsafe URLs", () =>
{
    using var missing = JsonDocument.Parse(ReleaseJson("v1.3.1", includeAssets: false));
    AssertThrows<UpdateException>(() => UpdateService.ParseRelease(missing.RootElement, new Version(1, 3, 0)));
    AssertThrows<UpdateException>(() => UpdateSecurity.ValidateRedirectUri(new Uri("https://example.com/file.zip")));
    AssertThrows<UpdateException>(() => UpdateSecurity.ValidateReleasePageUri(new Uri("https://github.com/other/repo/releases/tag/v1.3.1")));
    return Task.CompletedTask;
});

await TestAsync("maps GitHub rate limit responses", async () =>
{
    using var client = new HttpClient(new StaticHttpHandler(_ =>
    {
        var response = new HttpResponseMessage(HttpStatusCode.Forbidden);
        response.Headers.Add("X-RateLimit-Remaining", "0");
        return response;
    }));
    using var service = new UpdateService(client);
    var exception = await CaptureThrowsAsync<UpdateException>(() => service.CheckForUpdatesAsync(new Version(1, 3, 0)));
    Assert(exception.ErrorCode == "GITHUB_RATE_LIMIT", "rate limit code");
});

await TestAsync("downloads assets and rejects checksum mismatch", async () =>
{
    var archive = new byte[] { 1, 2, 3, 4 };
    var checksum = Convert.ToHexString(SHA256.HashData(archive));
    using var client = new HttpClient(new StaticHttpHandler(request => new HttpResponseMessage(HttpStatusCode.OK)
    {
        Content = new ByteArrayContent(request.RequestUri!.AbsolutePath.EndsWith(".sha256", StringComparison.Ordinal) ?
            System.Text.Encoding.ASCII.GetBytes(checksum) : archive),
    }));
    using var service = new UpdateService(client);
    var info = UpdateInfoFor(new Version(1, 3, 1));
    var workspace = await service.DownloadUpdateAsync(info);
    try { Assert(File.Exists(Path.Combine(workspace, UpdateSecurity.AssetName(info.LatestVersion))), "archive downloaded"); }
    finally { UpdateService.TryDeleteDirectory(workspace); }

    using var badClient = new HttpClient(new StaticHttpHandler(request => new HttpResponseMessage(HttpStatusCode.OK)
    {
        Content = new ByteArrayContent(request.RequestUri!.AbsolutePath.EndsWith(".sha256", StringComparison.Ordinal) ?
            System.Text.Encoding.ASCII.GetBytes(new string('0', 64)) : archive),
    }));
    using var badService = new UpdateService(badClient);
    var exception = await CaptureThrowsAsync<UpdateException>(() => badService.DownloadUpdateAsync(info));
    Assert(exception.ErrorCode == "CHECKSUM_MISMATCH", "checksum rejection");
});

await TestAsync("rejects redirects outside the GitHub allowlist", async () =>
{
    using var client = new HttpClient(new StaticHttpHandler(_ =>
    {
        var response = new HttpResponseMessage(HttpStatusCode.Redirect);
        response.Headers.Location = new Uri("https://example.com/payload.zip");
        return response;
    }));
    using var service = new UpdateService(client);
    var exception = await CaptureThrowsAsync<UpdateException>(() => service.DownloadUpdateAsync(UpdateInfoFor(new Version(1, 3, 1))));
    Assert(exception.ErrorCode == "UNSAFE_UPDATE_URL", "unsafe redirect rejected");
});

await TestAsync("cancels a release request", async () =>
{
    using var client = new HttpClient(new DelayedHttpHandler());
    using var service = new UpdateService(client);
    using var source = new CancellationTokenSource(TimeSpan.FromMilliseconds(50));
    await AssertThrowsAsync<OperationCanceledException>(() => service.CheckForUpdatesAsync(new Version(1, 3, 0), source.Token));
});

await TestAsync("parses the updater command contract", () =>
{
    var root = NewTestDirectory("arguments");
    try
    {
        var parsed = UpdaterOptions.Parse(new[]
        {
            "--manager-pid", "42", "--prepared-directory", Path.Combine(root, "prepared"),
            "--target-directory", Path.Combine(root, "target"), "--expected-version", "1.3.1",
            "--result-path", Path.Combine(root, "target", "update-result.json"), "--test-mode",
        });
        Assert(parsed.ManagerProcessId == 42 && parsed.TestMode && parsed.ExpectedVersion == new Version(1, 3, 1), "updater arguments");
        var rcParsed = UpdaterOptions.Parse(new[]
        {
            "--manager-pid", "0", "--prepared-directory", Path.Combine(root, "prepared"),
            "--target-directory", Path.Combine(root, "target"), "--expected-version", "1.3.0-rc.2",
            "--result-path", Path.Combine(root, "target", "update-result.json"), "--test-mode",
        });
        Assert(rcParsed.ExpectedVersion == ReleaseVersion.Parse("1.3.0-rc.2"), "updater accepts restricted RC expected version");
    }
    finally { Directory.Delete(root, true); }
    return Task.CompletedTask;
});

await TestAsync("validates a package and rejects Zip Slip", async () =>
{
    var work = NewTestDirectory("package");
    try
    {
        var syntaxBridge = Path.Combine(repositoryRoot, "scripts", "Test-ManagerUpdatePackage.ps1");
        var validator = new UpdatePackageValidator(new PowerShellService(), syntaxBridge, validateManagerVersion: false);
        var validZip = Path.Combine(work, "valid.zip");
        CreatePackage(validZip, new Version(1, 3, 1));
        var payload = await validator.ValidateAndExtractAsync(validZip, new Version(1, 3, 1), work);
        Assert(File.Exists(Path.Combine(payload, "BITWebManager.exe")), "valid payload");

        var slipZip = Path.Combine(work, "slip.zip");
        using (var archive = ZipFile.Open(slipZip, ZipArchiveMode.Create)) archive.CreateEntry("BITWebAutoLogin-v1.3.1-win-x64/../escape.txt");
        var exception = await CaptureThrowsAsync<UpdateException>(() => validator.ValidateAndExtractAsync(slipZip, new Version(1, 3, 1), work));
        Assert(exception.ErrorCode == "ZIP_SLIP", "zip slip code");
    }
    finally { Directory.Delete(work, true); }
});

await TestAsync("rejects packages containing credentials", async () =>
{
    var work = NewTestDirectory("credential-package");
    try
    {
        var archivePath = Path.Combine(work, "credential.zip");
        using (var archive = ZipFile.Open(archivePath, ZipArchiveMode.Create))
        {
            archive.CreateEntry("BITWebAutoLogin-v1.3.1-win-x64/credential.xml");
        }
        var validator = new UpdatePackageValidator(new PowerShellService(), Path.Combine(repositoryRoot, "scripts", "Test-ManagerUpdatePackage.ps1"), false);
        var exception = await CaptureThrowsAsync<UpdateException>(() => validator.ValidateAndExtractAsync(archivePath, new Version(1, 3, 1), work));
        Assert(exception.ErrorCode == "CREDENTIAL_IN_PACKAGE", "credential rejected");
    }
    finally { Directory.Delete(work, true); }
});

await TestAsync("rejects invalid PowerShell syntax in update packages", async () =>
{
    var work = NewTestDirectory("syntax-package");
    try
    {
        var zip = Path.Combine(work, "invalid-syntax.zip");
        CreatePackage(zip, new Version(1, 3, 1), invalidPowerShell: true);
        var validator = new UpdatePackageValidator(new PowerShellService(), Path.Combine(repositoryRoot, "scripts", "Test-ManagerUpdatePackage.ps1"), false);
        var exception = await CaptureThrowsAsync<UpdateException>(() => validator.ValidateAndExtractAsync(zip, new Version(1, 3, 1), work));
        Assert(exception.ErrorCode == "POWERSHELL_SYNTAX_INVALID", "syntax rejected");
    }
    finally { Directory.Delete(work, true); }
});

await TestAsync("enforces updater test path policy", () =>
{
    var testRoot = Path.Combine(Path.GetTempPath(), "BITWebAutoLogin-updater-tests", Guid.NewGuid().ToString("N"));
    var target = Path.Combine(testRoot, "target");
    var prepared = Path.Combine(testRoot, "prepared");
    UpdaterPathPolicy.Validate(new UpdaterOptions(0, prepared, target, new Version(1, 3, 1), Path.Combine(target, "update-result.json"), true));
    AssertThrows<InvalidOperationException>(() => UpdaterPathPolicy.Validate(new UpdaterOptions(0, Path.GetTempPath(), @"C:\Windows", new Version(1, 3, 1), @"C:\Windows\update-result.json", true)));
    return Task.CompletedTask;
});

await TestAsync("deploys in a test directory while preserving settings and credentials", () =>
{
    WithDeploymentFixture(healthSucceeds: true, (target, prepared, options, runtime) =>
    {
        new UpdateDeployment(runtime).Execute(options);
        Assert(File.ReadAllText(Path.Combine(target, "marker.txt")) == "new", "new payload deployed");
        Assert(File.ReadAllText(Path.Combine(target, "credential.xml")) == "secret", "credential preserved");
        using var settings = JsonDocument.Parse(File.ReadAllText(Path.Combine(target, "settings.json")));
        Assert(settings.RootElement.GetProperty("Version").GetString() == "1.3.1", "new version retained");
        Assert(settings.RootElement.GetProperty("UserChoice").GetString() == "keep", "user setting retained");
        Assert(runtime.InstallerRuns == 1 && runtime.LaunchRuns == 1, "installer and restart");
    });
    return Task.CompletedTask;
});

await TestAsync("rolls back when the new manager health check fails", () =>
{
    WithDeploymentFixture(healthSucceeds: false, (target, prepared, options, runtime) =>
    {
        AssertThrows<InvalidOperationException>(() => new UpdateDeployment(runtime).Execute(options));
        Assert(File.ReadAllText(Path.Combine(target, "marker.txt")) == "old", "old file restored");
        Assert(File.ReadAllText(Path.Combine(target, "credential.xml")) == "secret", "credential preserved after rollback");
        Assert(runtime.InstallerRuns == 2 && runtime.LaunchRuns == 1, "rollback installer and restart");
    });
    return Task.CompletedTask;
});

await TestAsync("hands a validated update from the view model to the helper launcher", async () =>
{
    var update = new ImmediateUpdateService(updateAvailable: true);
    var launcher = new RecordingUpdateLauncher();
    var viewModel = new MainWindowViewModel(
        new SequenceStatusService(Status(true, "Ready", true, "1.2.5")),
        new ImmediateActionService(), new RecordingDirectoryService(), new RecordingDialogService(), update, launcher);
    await viewModel.LoadAsync();
    var exitRequested = false;
    viewModel.UpdateReadyForExit += (_, _) => exitRequested = true;
    await viewModel.CheckForUpdatesAsync();
    Assert(update.CheckRuns == 1 && update.PrepareRuns == 1, "update pipeline completed");
    Assert(launcher.LaunchRuns == 1 && exitRequested, "helper handoff requested");
    Assert(viewModel.IsCriticalOperation, "handoff remains critical until process exit");
});

await TestAsync("reports current release without starting the helper", async () =>
{
    var update = new ImmediateUpdateService(updateAvailable: false);
    var launcher = new RecordingUpdateLauncher();
    var viewModel = new MainWindowViewModel(
        new SequenceStatusService(Status(true, "Ready", true, "1.2.5")),
        new ImmediateActionService(), new RecordingDirectoryService(), new RecordingDialogService(), update, launcher);
    await viewModel.LoadAsync();
    await viewModel.CheckForUpdatesAsync();
    Assert(launcher.LaunchRuns == 0 && !viewModel.IsBusy, "no-update path completed");
    Assert(viewModel.ActivityTitle == "已是最新版本", "no-update feedback");
});

if (args.Any(value => value.Equals("--real-open-directory", StringComparison.OrdinalIgnoreCase)))
{
    await TestAsync("opens the real installed directory through the shell API", async () =>
    {
        var status = await new ManagementStatusService(new PowerShellService(), statusBridge).GetStatusAsync();
        Assert(status.Installed, "real installation is present");
        new InstallDirectoryService().Open(status.InstallDirectory);
    });
}

if (args.Any(value => value.Equals("--real-github", StringComparison.OrdinalIgnoreCase)))
{
    await TestAsync("reads the official GitHub latest Release through UpdateService", async () =>
    {
        using var service = new UpdateService();
        var info = await service.CheckForUpdatesAsync(new Version(1, 3, 0));
        Assert(info.ReleasePageUrl.Host.Equals("github.com", StringComparison.OrdinalIgnoreCase), "official release page");
        Assert(info.LatestVersion > new Version(0, 0, 0), "release version parsed");
    });
}

var packageArgument = Array.FindIndex(args, value => value.Equals("--release-package", StringComparison.OrdinalIgnoreCase));
if (packageArgument >= 0 && packageArgument + 1 < args.Length)
{
    await TestAsync("validates the generated self-contained Release ZIP", async () =>
    {
        var archivePath = Path.GetFullPath(args[packageArgument + 1]);
        var versionArgument = Array.FindIndex(args, value => value.Equals("--release-version", StringComparison.OrdinalIgnoreCase));
        var expectedReleaseVersion = versionArgument >= 0 && versionArgument + 1 < args.Length
            ? ReleaseVersion.Parse(args[versionArgument + 1])
            : ReleaseVersion.Parse("1.3.0");
        var workspace = NewTestDirectory("release-package");
        try
        {
            var validator = new UpdatePackageValidator(
                new PowerShellService(),
                Path.Combine(repositoryRoot, "scripts", "Test-ManagerUpdatePackage.ps1"),
                validateManagerVersion: true);
            var payload = await validator.ValidateAndExtractAsync(archivePath, expectedReleaseVersion, workspace);
            Assert(File.Exists(Path.Combine(payload, "BITWebManager.exe")), "published manager exists");
            Assert(File.Exists(Path.Combine(payload, "BITWebUpdater.exe")), "published updater exists");
        }
        finally { Directory.Delete(workspace, true); }
    });
}

Console.WriteLine($"Manager smoke test summary: {passed} passed, {failed} failed");
return failed == 0 ? 0 : 1;

async Task TestAsync(string name, Func<Task> body)
{
    try { await body(); passed++; Console.WriteLine($"PASS {name}"); }
    catch (Exception exception)
    {
        failed++;
        var detail = exception is UpdateException update ? update.TechnicalDetails : exception.Message;
        Console.WriteLine($"FAIL {name} - {detail}");
    }
}

static ManagementStatus Status(bool installed, string taskState, bool credentialExists, string version) => new()
{
    SchemaVersion = 1, Installed = installed, TaskState = taskState, CredentialExists = credentialExists,
    Version = version, InstallDirectory = @"C:\Users\User\AppData\Local\BITWebAutoLogin",
};

static void Assert(bool condition, string label)
{
    if (!condition) throw new InvalidOperationException($"Assertion failed: {label}");
}

static void AssertThrowsData(Action action)
{
    try { action(); }
    catch (Exception exception) when (exception is JsonException or InvalidDataException) { return; }
    throw new InvalidOperationException("Expected schema validation to throw.");
}

static void AssertThrows<TException>(Action action) where TException : Exception
{
    try { action(); }
    catch (TException) { return; }
    throw new InvalidOperationException($"Expected {typeof(TException).Name}.");
}

static TException CaptureThrows<TException>(Action action) where TException : Exception
{
    try { action(); }
    catch (TException exception) { return exception; }
    throw new InvalidOperationException($"Expected {typeof(TException).Name}.");
}

static async Task AssertThrowsAsync<TException>(Func<Task> action) where TException : Exception
{
    try { await action(); }
    catch (TException) { return; }
    throw new InvalidOperationException($"Expected {typeof(TException).Name}.");
}

static async Task<TException> CaptureThrowsAsync<TException>(Func<Task> action) where TException : Exception
{
    try { await action(); }
    catch (TException exception) { return exception; }
    throw new InvalidOperationException($"Expected {typeof(TException).Name}.");
}

static string ReleaseJson(string tag, bool includeAssets, bool prerelease = false, bool draft = false)
{
    var version = tag.TrimStart('v');
    var name = $"BITWebAutoLogin-v{version}-win-x64.zip";
    var assets = includeAssets
        ? $$"""[{"name":"{{name}}","browser_download_url":"https://github.com/Oblivionis-ling/bit-web-auto-login/releases/download/{{tag}}/{{name}}"},{"name":"{{name}}.sha256","browser_download_url":"https://github.com/Oblivionis-ling/bit-web-auto-login/releases/download/{{tag}}/{{name}}.sha256"}]"""
        : "[]";
    return $$"""{"draft":{{draft.ToString().ToLowerInvariant()}},"prerelease":{{prerelease.ToString().ToLowerInvariant()}},"tag_name":"{{tag}}","html_url":"https://github.com/Oblivionis-ling/bit-web-auto-login/releases/tag/{{tag}}","published_at":"2026-09-06T00:00:00Z","name":"{{tag}}","assets":{{assets}}}""";
}

static UpdateInfo UpdateInfoFor(Version version)
{
    var tag = "v" + version;
    var name = UpdateSecurity.AssetName(version);
    return new UpdateInfo(new Version(1, 3, 0), version, tag, tag, DateTimeOffset.UtcNow,
        new Uri($"https://github.com/Oblivionis-ling/bit-web-auto-login/releases/download/{tag}/{name}"),
        new Uri($"https://github.com/Oblivionis-ling/bit-web-auto-login/releases/download/{tag}/{name}.sha256"),
        new Uri($"https://github.com/Oblivionis-ling/bit-web-auto-login/releases/tag/{tag}"), true);
}

static string NewTestDirectory(string name)
{
    var path = Path.Combine(Path.GetTempPath(), "BITWebAutoLogin-updater-tests", name + "-" + Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(path);
    return path;
}

static void CreatePackage(string archivePath, ReleaseVersion version, bool invalidPowerShell = false)
{
    var root = $"BITWebAutoLogin-v{version}-win-x64/";
    var files = new[]
    {
        "AutoLogin.ps1", "BITWebAutoLogin.psm1", "BITWebAutoLogin.Management.psm1", "Install.ps1", "Uninstall.ps1",
        "RunHidden.vbs", "Install.cmd", "legacy/Manage.ps1", "legacy/Open-GUI.cmd", "legacy/Open-GUI.vbs",
        "BITWebManager.exe", "BITWebUpdater.exe", "D3DCompiler_47_cor3.dll", "PenImc_cor3.dll",
        "PresentationNative_cor3.dll", "vcruntime140_cor3.dll", "wpfgfx_cor3.dll",
        "PowerShell/Get-ManagerStatus.ps1", "PowerShell/Invoke-ManagerAction.ps1", "PowerShell/Test-ManagerUpdatePackage.ps1",
        "Licenses/Sarasa-Gothic-OFL.txt",
    };
    using var archive = ZipFile.Open(archivePath, ZipArchiveMode.Create);
    foreach (var relative in files)
    {
        var entry = archive.CreateEntry(root + relative);
        using var writer = new StreamWriter(entry.Open());
        writer.Write(invalidPowerShell && relative == "AutoLogin.ps1" ? "function Broken {" : string.Empty);
    }
    var settings = archive.CreateEntry(root + "settings.json");
    using (var settingsWriter = new StreamWriter(settings.Open()))
    {
        settingsWriter.Write(JsonSerializer.Serialize(new { Version = version.ToString() }));
    }
    var manifest = archive.CreateEntry(root + "release-manifest.json");
    using (var manifestWriter = new StreamWriter(manifest.Open()))
    {
        manifestWriter.Write(JsonSerializer.Serialize(new { schemaVersion = 1, version = version.ToString(), rid = "win-x64", manager = "BITWebManager.exe", updater = "BITWebUpdater.exe" }));
    }
}

static void WithDeploymentFixture(bool healthSucceeds, Action<string, string, UpdaterOptions, RecordingUpdaterRuntime> assertion)
{
    var root = NewTestDirectory("deployment");
    var target = Path.Combine(root, "target");
    var prepared = Path.Combine(root, "prepared");
    Directory.CreateDirectory(target);
    Directory.CreateDirectory(prepared);
    File.WriteAllText(Path.Combine(target, "marker.txt"), "old");
    File.WriteAllText(Path.Combine(target, "BITWebManager.exe"), "old-manager");
    File.WriteAllText(Path.Combine(target, "credential.xml"), "secret");
    File.WriteAllText(Path.Combine(target, "settings.json"), "{\"Version\":\"1.2.5\",\"UserChoice\":\"keep\"}");
    File.WriteAllText(Path.Combine(prepared, "marker.txt"), "new");
    File.WriteAllText(Path.Combine(prepared, "BITWebManager.exe"), "placeholder");
    File.WriteAllText(Path.Combine(prepared, "settings.json"), "{\"Version\":\"1.3.1\",\"NewDefault\":true}");
    var options = new UpdaterOptions(0, prepared, target, new Version(1, 3, 1), Path.Combine(target, "update-result.json"), true);
    var runtime = new RecordingUpdaterRuntime(healthSucceeds);
    try { assertion(target, prepared, options, runtime); }
    finally { Directory.Delete(root, true); }
}

sealed class FailingStatusService : IManagementStatusService
{
    public Task<ManagementStatus> GetStatusAsync(CancellationToken cancellationToken = default) =>
        throw new StatusReadException("读取失败", "offline failure");
}

sealed class SequenceStatusService(ManagementStatus status) : IManagementStatusService
{
    public int CallCount { get; private set; }
    public Task<ManagementStatus> GetStatusAsync(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested(); CallCount++; return Task.FromResult(status);
    }
}

sealed class ImmediateActionService : IManagementActionService
{
    public int CallCount { get; private set; }
    public ManagerAction? LastAction { get; private set; }
    public Task<ManagerActionResult> ExecuteAsync(ManagerAction action, bool interactive, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested(); CallCount++; LastAction = action;
        var value = action.ToString();
        return Task.FromResult(new ManagerActionResult
        {
            SchemaVersion = 1, Success = true, Action = char.ToLowerInvariant(value[0]) + value[1..],
            Message = "ok", RequiresRefresh = true,
        });
    }
}

sealed class BlockingActionService : IManagementActionService
{
    public TaskCompletionSource Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public TaskCompletionSource Release { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public int CallCount { get; private set; }
    public async Task<ManagerActionResult> ExecuteAsync(ManagerAction action, bool interactive, CancellationToken cancellationToken = default)
    {
        CallCount++; Started.TrySetResult(); await Release.Task.WaitAsync(cancellationToken);
        return new ManagerActionResult { SchemaVersion = 1, Success = true, Action = "repair", Message = "ok", RequiresRefresh = true };
    }
}

sealed class RecordingDirectoryService : IInstallDirectoryService
{
    public int OpenCount { get; private set; }
    public void Open(string path) => OpenCount++;
}

sealed class RecordingDialogService : IUserDialogService
{
    public bool FirstClearAnswer { get; init; }
    public bool SecondClearAnswer { get; init; }
    public int FirstClearCount { get; private set; }
    public int SecondClearCount { get; private set; }
    public bool ConfirmUninstall() => false;
    public bool ConfirmClearCredential() { FirstClearCount++; return FirstClearAnswer; }
    public bool ConfirmClearCredentialAgain() { SecondClearCount++; return SecondClearAnswer; }
    public void ShowInformation(string title, string message) { }
}

sealed class StaticHttpHandler(Func<HttpRequestMessage, HttpResponseMessage> responder) : HttpMessageHandler
{
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
        Task.FromResult(responder(request));
}

sealed class DelayedHttpHandler : HttpMessageHandler
{
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
        return new HttpResponseMessage(HttpStatusCode.OK);
    }
}

sealed class RecordingUpdaterRuntime(bool healthSucceeds) : IUpdaterRuntime
{
    public int InstallerRuns { get; private set; }
    public int LaunchRuns { get; private set; }
    public void RunInstaller(string targetDirectory) => InstallerRuns++;
    public bool RunHealthCheck(string managerPath, ReleaseVersion expectedVersion, string healthResultPath) => healthSucceeds;
    public void LaunchManager(string managerPath) => LaunchRuns++;
}

sealed class ImmediateUpdateService(bool updateAvailable) : IUpdateService
{
    public int CheckRuns { get; private set; }
    public int PrepareRuns { get; private set; }
    public Task<UpdateInfo> CheckForUpdatesAsync(ReleaseVersion currentVersion, CancellationToken cancellationToken = default)
    {
        CheckRuns++;
        ReleaseVersion latest = updateAvailable ? new Version(1, 3, 1) : currentVersion;
        var tag = "v" + latest;
        var asset = UpdateSecurity.AssetName(latest);
        return Task.FromResult(new UpdateInfo(
            currentVersion, latest, tag, tag, DateTimeOffset.UtcNow,
            new Uri($"https://github.com/Oblivionis-ling/bit-web-auto-login/releases/download/{tag}/{asset}"),
            new Uri($"https://github.com/Oblivionis-ling/bit-web-auto-login/releases/download/{tag}/{asset}.sha256"),
            new Uri($"https://github.com/Oblivionis-ling/bit-web-auto-login/releases/tag/{tag}"),
            updateAvailable));
    }
    public Task<UpdateInfo> CheckForQaReleaseAsync(ReleaseVersion currentVersion, string requestedTag, CancellationToken cancellationToken = default) =>
        CheckForUpdatesAsync(currentVersion, cancellationToken);
    public Task<string> DownloadUpdateAsync(UpdateInfo info, IProgress<UpdateProgress>? progress = null, CancellationToken cancellationToken = default) => Task.FromResult("workspace");
    public Task<string> ValidateUpdateAsync(UpdateInfo info, string workspaceDirectory, IProgress<UpdateProgress>? progress = null, CancellationToken cancellationToken = default) => Task.FromResult("payload");
    public Task<PreparedUpdate> PrepareUpdateAsync(UpdateInfo info, string workspaceDirectory, string payloadDirectory, CancellationToken cancellationToken = default)
    {
        PrepareRuns++;
        return Task.FromResult(new PreparedUpdate(info, workspaceDirectory, payloadDirectory, "updater.exe", "update-result.json"));
    }
}

sealed class RecordingUpdateLauncher : IUpdateLauncher
{
    public int LaunchRuns { get; private set; }
    public void Launch(PreparedUpdate update, string targetDirectory, int managerProcessId) => LaunchRuns++;
}
