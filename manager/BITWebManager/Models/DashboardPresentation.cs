namespace BITWebManager.Models;

public enum StatusTone
{
    Neutral,
    Success,
    Warning,
    Error,
}

public sealed record DashboardPresentation(
    string OverallTitle,
    string OverallDetail,
    StatusTone OverallTone,
    string TaskValue,
    StatusTone TaskTone,
    string AccountValue,
    StatusTone AccountTone,
    string VersionValue,
    string InstallDirectory)
{
    public static DashboardPresentation FromStatus(ManagementStatus status)
    {
        var version = IsKnownVersion(status.Version) ? status.Version.Trim() : "—";

        if (!status.Installed)
        {
            var detail = status.CredentialExists
                ? "已检测到安全保存的账号信息，可以继续安装自动登录。"
                : "自动登录尚未设置，校园网账号也未配置。";
            return new DashboardPresentation(
                "自动登录尚未安装",
                detail,
                StatusTone.Warning,
                "未安装",
                StatusTone.Warning,
                status.CredentialExists ? "已配置" : "未配置",
                status.CredentialExists ? StatusTone.Success : StatusTone.Warning,
                version,
                status.InstallDirectory);
        }

        var taskState = status.TaskState.Trim();
        var taskIsHealthy = taskState.Contains("Ready", StringComparison.OrdinalIgnoreCase)
            || taskState.Contains("Running", StringComparison.OrdinalIgnoreCase);
        var taskIsDisabled = taskState.Contains("Disabled", StringComparison.OrdinalIgnoreCase);

        if (!status.CredentialExists)
        {
            return new DashboardPresentation(
                "自动登录需要配置账号",
                "后台任务已安装，但没有找到当前 Windows 用户的安全凭据。",
                StatusTone.Warning,
                taskIsHealthy ? "已启用" : "需要关注",
                taskIsHealthy ? StatusTone.Success : StatusTone.Warning,
                "未配置",
                StatusTone.Warning,
                version,
                status.InstallDirectory);
        }

        if (taskIsHealthy)
        {
            return new DashboardPresentation(
                "自动登录运行正常",
                "账号已配置 · 凭据由 Windows DPAPI 加密保护",
                StatusTone.Success,
                "已启用",
                StatusTone.Success,
                "已配置",
                StatusTone.Success,
                version,
                status.InstallDirectory);
        }

        return new DashboardPresentation(
            taskIsDisabled ? "自动登录已停用" : "自动登录需要关注",
            taskIsDisabled ? "后台任务存在，但目前处于停用状态。" : "已读取后台任务，但当前状态需要进一步检查。",
            StatusTone.Warning,
            taskIsDisabled ? "已停用" : "需要关注",
            StatusTone.Warning,
            "已配置",
            StatusTone.Success,
            version,
            status.InstallDirectory);
    }

    private static bool IsKnownVersion(string value) =>
        !string.IsNullOrWhiteSpace(value)
        && value != "—"
        && !value.Equals("无法读取", StringComparison.OrdinalIgnoreCase);
}
