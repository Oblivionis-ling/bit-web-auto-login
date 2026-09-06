using System.Windows;

namespace BITWebManager.Services;

public sealed class WpfUserDialogService : IUserDialogService
{
    public bool ConfirmUninstall() => Confirm(
        "卸载自动登录",
        "将停止并移除自动登录计划任务。\n\n已安装的 Manager、脚本、日志、设置和校园网账号将继续保留。",
        "卸载");

    public bool ConfirmClearCredential() => Confirm(
        "清除账号信息",
        "此操作会停止并移除自动登录任务，并删除当前用户保存的 DPAPI 校园网凭据。\n\n日志、设置和安装目录中的其他文件不会删除。",
        "继续");

    public bool ConfirmClearCredentialAgain() => Confirm(
        "再次确认清除账号",
        "请再次确认：清除后自动登录将停止，恢复使用前需要重新设置校园网账号。",
        "清除账号");

    public void ShowInformation(string title, string message) => MessageBox.Show(
        Application.Current.MainWindow,
        message,
        title,
        MessageBoxButton.OK,
        MessageBoxImage.Information);

    private static bool Confirm(string title, string message, string confirmText) =>
        new ConfirmationDialog(title, message, confirmText, Application.Current.MainWindow).ShowDialog() == true;
}
