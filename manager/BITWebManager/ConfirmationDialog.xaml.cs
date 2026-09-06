using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace BITWebManager;

public partial class ConfirmationDialog : Window
{
    private readonly string? _capturePath;
    private readonly double _captureDpi;

    internal ConfirmationDialog(
        string title,
        string message,
        string confirmText,
        Window? owner = null,
        string? capturePath = null,
        double captureDpi = 96)
    {
        InitializeComponent();
        Title = title;
        HeadingText.Text = title;
        MessageText.Text = message;
        ConfirmButton.Content = confirmText;
        Owner = owner;
        _capturePath = capturePath;
        _captureDpi = captureDpi;
        ContentRendered += OnContentRendered;
    }

    private async void OnContentRendered(object? sender, EventArgs e)
    {
        CancelButton.Focus();
        if (string.IsNullOrWhiteSpace(_capturePath)) return;

        await Dispatcher.Yield(DispatcherPriority.ApplicationIdle);
        Capture(_capturePath, _captureDpi);
        DialogResult = false;
    }

    private void OnConfirmClick(object sender, RoutedEventArgs e) => DialogResult = true;

    private void Capture(string path, double dpi)
    {
        var directory = Path.GetDirectoryName(path);
        if (string.IsNullOrWhiteSpace(directory) || !Directory.Exists(directory))
        {
            throw new DirectoryNotFoundException($"Capture directory does not exist: {directory}");
        }

        var scale = dpi / 96d;
        var bitmap = new RenderTargetBitmap(
            Math.Max(1, (int)Math.Ceiling(ActualWidth * scale)),
            Math.Max(1, (int)Math.Ceiling(ActualHeight * scale)),
            dpi,
            dpi,
            PixelFormats.Pbgra32);
        var drawing = new DrawingVisual();
        using (var context = drawing.RenderOpen())
        {
            context.DrawRectangle(new VisualBrush(this), null, new Rect(0, 0, ActualWidth, ActualHeight));
        }
        bitmap.Render(drawing);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var stream = File.Create(path);
        encoder.Save(stream);
    }
}
