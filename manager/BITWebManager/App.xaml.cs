using System.Windows;
using System.Windows.Threading;
using System.Reflection;
using System.Text.Json;
using System.IO;
using BITWebManager.Models;
using BITWebManager.Services;
using BITWebManager.ViewModels;
using BITWebVersioning;

namespace BITWebManager;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        DispatcherUnhandledException += OnDispatcherUnhandledException;

        var options = LaunchOptions.Parse(e.Args);
        var releaseVersion = ReleaseVersion.FromAssembly(Assembly.GetExecutingAssembly());
        if (options.QaReleaseTag is not null)
        {
            UpdateSecurity.ValidateQaRequest(releaseVersion, options.QaReleaseTag);
        }
        var powerShellService = new PowerShellService();
        if (options.HealthCheckPath is not null && options.ExpectedVersion is not null)
        {
            ShutdownMode = ShutdownMode.OnExplicitShutdown;
            RunHealthCheckAsync(options, powerShellService);
            return;
        }
        var isPreview = !string.IsNullOrWhiteSpace(options.PreviewState);
        IManagementStatusService statusService = isPreview
            ? new PreviewStatusService(options.PreviewState!)
            : new ManagementStatusService(powerShellService);
        IManagementActionService actionService = isPreview
            ? new PreviewActionService()
            : new ManagementActionService(powerShellService);
        var viewModel = new MainWindowViewModel(
            statusService,
            actionService,
            new InstallDirectoryService(),
            new WpfUserDialogService(),
            new UpdateService(),
            new UpdateLauncher(),
            options.QaReleaseTag);
        MainWindow = new MainWindow(viewModel, options);
        MainWindow.Show();
    }

    private async void RunHealthCheckAsync(LaunchOptions options, PowerShellService powerShellService)
    {
        var success = false;
        string? detail = null;
        var actual = ReleaseVersion.FromAssembly(Assembly.GetExecutingAssembly());
        try
        {
            if (actual != options.ExpectedVersion)
            {
                throw new InvalidOperationException($"Manager version {actual} did not match {options.ExpectedVersion}.");
            }

            await new ManagementStatusService(powerShellService).GetStatusAsync();
            success = true;
        }
        catch (Exception exception)
        {
            detail = exception.ToString();
        }

        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(options.HealthCheckPath!)!);
            File.WriteAllText(options.HealthCheckPath!, JsonSerializer.Serialize(new
            {
                schemaVersion = 1,
                success,
                version = actual.ToString(),
                detail,
            }));
        }
        catch
        {
            success = false;
        }

        Shutdown(success ? 0 : 1);
    }

    private void OnDispatcherUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        MessageBox.Show(
            "管理器遇到未预期的问题，已阻止异常继续扩散。请重新打开后再试。",
            "BIT-Web 自动登录",
            MessageBoxButton.OK,
            MessageBoxImage.Error);
        e.Handled = true;
    }
}
