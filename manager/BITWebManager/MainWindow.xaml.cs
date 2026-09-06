using System.IO;
using System.Diagnostics;
using System.ComponentModel;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using BITWebManager.Models;
using BITWebManager.ViewModels;

namespace BITWebManager;

public partial class MainWindow : Window
{
    private readonly MainWindowViewModel _viewModel;
    private readonly LaunchOptions _launchOptions;
    private readonly CancellationTokenSource _lifetime = new();
    private bool _allowUpdateExit;

    internal MainWindow(MainWindowViewModel viewModel, LaunchOptions launchOptions)
    {
        _viewModel = viewModel;
        _launchOptions = launchOptions;
        DataContext = viewModel;
        InitializeComponent();
        if (_launchOptions.CaptureWidth is not null && _launchOptions.CaptureHeight is not null)
        {
            Width = _launchOptions.CaptureWidth.Value;
            Height = _launchOptions.CaptureHeight.Value;
        }
        _viewModel.UpdateReadyForExit += OnUpdateReadyForExit;
        Loaded += OnLoaded;
        Closing += OnClosing;
        Closed += OnClosed;
    }

    private void OnUpdateReadyForExit(object? sender, EventArgs e)
    {
        _allowUpdateExit = true;
        Close();
    }

    private void OnClosing(object? sender, CancelEventArgs e)
    {
        if (_allowUpdateExit)
        {
            return;
        }

        if (!_viewModel.IsBusy)
        {
            return;
        }

        if (_viewModel.IsCriticalOperation)
        {
            e.Cancel = true;
            MessageBox.Show(
                "当前正在完成关键管理操作。为避免安装或系统状态损坏，请等待操作结束后再关闭管理器。",
                "操作正在进行",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
            return;
        }

        var result = new ConfirmationDialog(
            "取消当前操作",
            "当前操作仍在进行。取消并退出不会继续等待当前可取消操作。",
            "取消并退出",
            this).ShowDialog();
        if (result != true)
        {
            e.Cancel = true;
            return;
        }

        _viewModel.CancelCurrentOperation();
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        Loaded -= OnLoaded;
        await _viewModel.LoadAsync(_lifetime.Token);
        if (!string.IsNullOrWhiteSpace(_launchOptions.PreviewOperation))
        {
            _viewModel.ApplyPreviewOperation(_launchOptions.PreviewOperation!);
        }
        if (_launchOptions.PreviewExpandDetails)
        {
            ErrorDetailsExpander.IsExpanded = true;
            UpdateLayout();
            ErrorDetailsExpander.BringIntoView();
        }
        if (!string.IsNullOrWhiteSpace(_launchOptions.PreviewDialog))
        {
            var dialog = CreatePreviewDialog(_launchOptions.PreviewDialog!);
            dialog.ShowDialog();
            _allowUpdateExit = true;
            Close();
            return;
        }
        if (!string.IsNullOrWhiteSpace(_launchOptions.CapturePath))
        {
            await Dispatcher.Yield(DispatcherPriority.ApplicationIdle);
            try
            {
                Capture(_launchOptions.CapturePath, _launchOptions.CaptureDpi);
                _allowUpdateExit = true;
                Close();
            }
            catch (Exception exception)
            {
                Debug.WriteLine(exception);
                Application.Current.Shutdown(1);
            }
        }
    }

    private ConfirmationDialog CreatePreviewDialog(string dialog) => dialog switch
    {
        "Uninstall" => new ConfirmationDialog(
            "卸载自动登录",
            "将停止并移除自动登录计划任务。\n\n已安装的 Manager、脚本、日志、设置和校园网账号将继续保留。",
            "卸载",
            this,
            _launchOptions.CapturePath,
            _launchOptions.CaptureDpi),
        "ClearCredential" => new ConfirmationDialog(
            "清除账号信息",
            "此操作会停止并移除自动登录任务，并删除当前用户保存的 DPAPI 校园网凭据。\n\n日志、设置和安装目录中的其他文件不会删除。",
            "继续",
            this,
            _launchOptions.CapturePath,
            _launchOptions.CaptureDpi),
        "CloseBusy" => new ConfirmationDialog(
            "取消当前操作",
            "当前操作仍在进行。取消并退出不会继续等待当前可取消操作。",
            "取消并退出",
            this,
            _launchOptions.CapturePath,
            _launchOptions.CaptureDpi),
        _ => throw new ArgumentException($"Unsupported preview dialog: {dialog}", nameof(dialog)),
    };

    private void OnClosed(object? sender, EventArgs e)
    {
        _lifetime.Cancel();
        _viewModel.UpdateReadyForExit -= OnUpdateReadyForExit;
        _lifetime.Dispose();
    }

    private void Capture(string path, double dpi)
    {
        var directory = Path.GetDirectoryName(path);
        if (string.IsNullOrWhiteSpace(directory) || !Directory.Exists(directory))
        {
            throw new DirectoryNotFoundException($"Capture directory does not exist: {directory}");
        }

        var scale = dpi / 96d;
        var pixelWidth = Math.Max(1, (int)Math.Ceiling(ActualWidth * scale));
        var pixelHeight = Math.Max(1, (int)Math.Ceiling(ActualHeight * scale));
        var bitmap = new RenderTargetBitmap(pixelWidth, pixelHeight, dpi, dpi, PixelFormats.Pbgra32);
        var drawing = new DrawingVisual();
        using (var context = drawing.RenderOpen())
        {
            context.DrawRectangle(
                new VisualBrush(this),
                null,
                new Rect(0, 0, ActualWidth, ActualHeight));
        }

        bitmap.Render(drawing);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var stream = File.Create(path);
        encoder.Save(stream);
    }
}
