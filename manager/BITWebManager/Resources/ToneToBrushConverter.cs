using System.Globalization;
using System.Windows.Data;
using System.Windows.Media;
using BITWebManager.Models;

namespace BITWebManager.Resources;

public sealed class ToneToBrushConverter : IValueConverter
{
    private static readonly Brush Neutral = Freeze("#647184");
    private static readonly Brush Success = Freeze("#168653");
    private static readonly Brush Warning = Freeze("#B15C00");
    private static readonly Brush Error = Freeze("#C42B1C");

    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is StatusTone tone
            ? tone switch
            {
                StatusTone.Success => Success,
                StatusTone.Warning => Warning,
                StatusTone.Error => Error,
                _ => Neutral,
            }
            : Neutral;

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        throw new NotSupportedException();

    private static Brush Freeze(string color)
    {
        var brush = new SolidColorBrush((Color)ColorConverter.ConvertFromString(color));
        brush.Freeze();
        return brush;
    }
}
