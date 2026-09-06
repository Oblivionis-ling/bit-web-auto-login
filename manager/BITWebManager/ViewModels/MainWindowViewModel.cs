using System.ComponentModel;
using System.Collections.ObjectModel;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Diagnostics;
using System.Reflection;
using BITWebManager.Models;
using BITWebManager.Services;
using BITWebVersioning;

namespace BITWebManager.ViewModels;

public sealed class MainWindowViewModel : INotifyPropertyChanged
{
    private readonly IManagementStatusService _statusService;
    private readonly IManagementActionService _actionService;
    private readonly IInstallDirectoryService _directoryService;
    private readonly IUserDialogService _dialogService;
    private readonly IUpdateService _updateService;
    private readonly IUpdateLauncher _updateLauncher;
    private readonly string? _qaReleaseTag;
    private readonly object _operationSync = new();
    private ManagementStatus? _status;
    private CancellationTokenSource? _currentOperationSource;
    private bool _operationActive;
    private bool _isLoading = true;
    private bool _isBusy;
    private bool _isCriticalOperation;
    private bool _hasError;
    private string _overallTitle = "正在读取系统状态…";
    private string _overallDetail = "正在安全地查询计划任务、凭据和安装版本";
    private StatusTone _overallTone = StatusTone.Neutral;
    private string _taskValue = "读取中";
    private StatusTone _taskTone = StatusTone.Neutral;
    private string _accountValue = "读取中";
    private StatusTone _accountTone = StatusTone.Neutral;
    private string _versionValue = "—";
    private string _installDirectory = "正在定位安装目录…";
    private string _activityTitle = "管理器正在初始化";
    private string _activityDetail = "所有状态读取均为只读操作";
    private string _technicalDetails = string.Empty;
    private string _operationMessage = string.Empty;
    private string _feedbackMessage = string.Empty;
    private StatusTone _feedbackTone = StatusTone.Neutral;

    public MainWindowViewModel(
        IManagementStatusService statusService,
        IManagementActionService? actionService = null,
        IInstallDirectoryService? directoryService = null,
        IUserDialogService? dialogService = null,
        IUpdateService? updateService = null,
        IUpdateLauncher? updateLauncher = null,
        string? qaReleaseTag = null)
    {
        _statusService = statusService;
        _actionService = actionService ?? new PreviewActionService();
        _directoryService = directoryService ?? new InstallDirectoryService();
        _dialogService = dialogService ?? new WpfUserDialogService();
        _updateService = updateService ?? new DisabledUpdateService();
        _updateLauncher = updateLauncher ?? new DisabledUpdateLauncher();
        _qaReleaseTag = qaReleaseTag;
        Activities.Add(new ActivityEntry("管理器正在初始化", "所有状态读取均为只读操作", StatusTone.Neutral));

        RefreshStatusCommand = new AsyncRelayCommand(() => RefreshStatusAsync(), () => !IsBusy);
        PrimaryActionCommand = new AsyncRelayCommand(ExecutePrimaryActionAsync, () => CanRunPrimaryAction);
        RefreshCredentialCommand = new AsyncRelayCommand(
            () => ExecuteManagerActionAsync(ManagerAction.RefreshCredential),
            () => CanRefreshCredential);
        RepairCommand = new AsyncRelayCommand(
            () => ExecuteManagerActionAsync(ManagerAction.Repair),
            () => CanRepair);
        UninstallCommand = new AsyncRelayCommand(RequestUninstallAsync, () => CanUninstall);
        ClearCredentialCommand = new AsyncRelayCommand(RequestClearCredentialAsync, () => CanClearCredential);
        OpenInstallDirectoryCommand = new RelayCommand(OpenInstallDirectory, () => CanOpenInstallDirectory);
        CheckUpdateCommand = new AsyncRelayCommand(CheckForUpdatesAsync, () => CanCheckUpdate);
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    public event EventHandler? UpdateReadyForExit;

    public bool IsLoading
    {
        get => _isLoading;
        private set
        {
            if (SetField(ref _isLoading, value))
            {
                OnPropertyChanged(nameof(LoadingVisibility));
            }
        }
    }

    public bool HasError
    {
        get => _hasError;
        private set
        {
            if (SetField(ref _hasError, value))
            {
                OnPropertyChanged(nameof(ErrorVisibility));
            }
        }
    }

    public Visibility LoadingVisibility => IsLoading ? Visibility.Visible : Visibility.Collapsed;
    public Visibility BusyVisibility => IsBusy ? Visibility.Visible : Visibility.Collapsed;
    public Visibility ErrorVisibility => HasError ? Visibility.Visible : Visibility.Collapsed;
    public Visibility InstalledVisibility => IsInstalled ? Visibility.Visible : Visibility.Collapsed;
    public Visibility FeedbackVisibility => string.IsNullOrWhiteSpace(FeedbackMessage) ? Visibility.Collapsed : Visibility.Visible;

    public ObservableCollection<ActivityEntry> Activities { get; } = new();
    public AsyncRelayCommand RefreshStatusCommand { get; }
    public AsyncRelayCommand PrimaryActionCommand { get; }
    public AsyncRelayCommand RefreshCredentialCommand { get; }
    public AsyncRelayCommand RepairCommand { get; }
    public AsyncRelayCommand UninstallCommand { get; }
    public AsyncRelayCommand ClearCredentialCommand { get; }
    public RelayCommand OpenInstallDirectoryCommand { get; }
    public AsyncRelayCommand CheckUpdateCommand { get; }

    public bool IsBusy
    {
        get => _isBusy;
        private set
        {
            if (SetField(ref _isBusy, value))
            {
                OnPropertyChanged(nameof(BusyVisibility));
                NotifyCommandStates();
            }
        }
    }

    public bool IsCriticalOperation
    {
        get => _isCriticalOperation;
        private set => SetField(ref _isCriticalOperation, value);
    }

    public string OverallTitle { get => _overallTitle; private set => SetField(ref _overallTitle, value); }
    public string OverallDetail { get => _overallDetail; private set => SetField(ref _overallDetail, value); }
    public StatusTone OverallTone { get => _overallTone; private set => SetField(ref _overallTone, value); }
    public string TaskValue { get => _taskValue; private set => SetField(ref _taskValue, value); }
    public StatusTone TaskTone { get => _taskTone; private set => SetField(ref _taskTone, value); }
    public string AccountValue { get => _accountValue; private set => SetField(ref _accountValue, value); }
    public StatusTone AccountTone { get => _accountTone; private set => SetField(ref _accountTone, value); }
    public string VersionValue { get => _versionValue; private set => SetField(ref _versionValue, value); }
    public string InstallDirectory { get => _installDirectory; private set => SetField(ref _installDirectory, value); }
    public string ActivityTitle { get => _activityTitle; private set => SetField(ref _activityTitle, value); }
    public string ActivityDetail { get => _activityDetail; private set => SetField(ref _activityDetail, value); }
    public string TechnicalDetails { get => _technicalDetails; private set => SetField(ref _technicalDetails, value); }
    public string OperationMessage { get => _operationMessage; private set => SetField(ref _operationMessage, value); }
    public string FeedbackMessage
    {
        get => _feedbackMessage;
        private set
        {
            if (SetField(ref _feedbackMessage, value)) OnPropertyChanged(nameof(FeedbackVisibility));
        }
    }
    public StatusTone FeedbackTone { get => _feedbackTone; private set => SetField(ref _feedbackTone, value); }
    public bool IsInstalled => _status?.Installed == true;
    public bool CredentialExists => _status?.CredentialExists == true;
    public bool CanOpenInstallDirectory => !IsBusy && IsInstalled;
    public bool CanRefreshCredential => !IsBusy && _status is not null;
    public bool CanRepair => !IsBusy && IsInstalled;
    public bool CanUninstall => !IsBusy && IsInstalled;
    public bool CanClearCredential => !IsBusy && CredentialExists;
    public bool CanRunPrimaryAction => !IsBusy && _status is not null && (!IsInstalled || CanCheckUpdate);
    public bool CanCheckUpdate => !IsBusy && IsInstalled;
    public string ManagerVersionDisplay
    {
        get
        {
            return $"v{ReleaseVersion.FromAssembly(Assembly.GetExecutingAssembly())}";
        }
    }
    public string PrimaryActionText => IsInstalled ? "检查更新" : "安装自动登录";
    public string AccountActionText => CredentialExists ? "更换账号" : "设置账号";

    public async Task LoadAsync(CancellationToken cancellationToken = default)
    {
        await RefreshStatusAsync(cancellationToken, initialLoad: true);
    }

    internal void ApplyPreviewOperation(string operation)
    {
        HasError = false;
        TechnicalDetails = string.Empty;
        switch (operation)
        {
            case "UpToDate":
                SetFeedback("当前已是最新版本", StatusTone.Success);
                AddActivity("已是最新版本", "当前 BIT-Web 版本 v1.3.0", StatusTone.Success);
                break;
            case "CheckingUpdate":
                BeginPreviewBusy("正在检查更新…", "正在检查更新", "正在连接官方 GitHub Release");
                break;
            case "UpdateAvailable":
                BeginPreviewBusy("发现新版本 v1.3.1", "发现新版本 v1.3.1", "准备从官方 GitHub Release 下载");
                break;
            case "Downloading":
                BeginPreviewBusy("已下载 42.6 MB / 114.9 MB", "正在下载 v1.3.1", "更新检查期间可以安全取消");
                break;
            case "Validating":
                BeginPreviewBusy("正在验证更新包…", "正在验证更新包", "正在检查 SHA-256、版本和文件结构");
                break;
            case "Preparing":
                BeginPreviewBusy("正在准备安装…", "正在准备安装", "验证完成后将交给安全部署程序");
                break;
            case "UpdateFailure":
                ShowOperationFailure(
                    "检查更新失败",
                    "Error code: GITHUB_CONNECTION_FAILED\r\nHTTP status: unavailable\r\nSystem.Net.Http.HttpRequestException: Preview connection failure.");
                break;
            case "ManagementBusy":
                BeginPreviewBusy("正在修复安装…", "正在修复安装", "请勿同时启动其他管理操作", critical: true);
                break;
            default:
                throw new ArgumentException($"Unsupported preview operation: {operation}", nameof(operation));
        }
    }

    private void BeginPreviewBusy(string message, string activityTitle, string activityDetail, bool critical = false)
    {
        IsCriticalOperation = critical;
        OperationMessage = message;
        IsBusy = true;
        AddActivity(activityTitle, activityDetail, StatusTone.Neutral);
    }

    public async Task RefreshStatusAsync(CancellationToken cancellationToken = default, bool initialLoad = false)
    {
        if (!TryBeginOperation("正在刷新状态…", critical: false, cancellationToken, out var operationToken))
        {
            AddActivity("操作未开始", "已有管理操作正在执行", StatusTone.Warning);
            return;
        }

        IsLoading = true;
        try
        {
            await RefreshCoreAsync(operationToken);
            AddActivity(initialLoad ? "状态读取完成" : "状态刷新完成", "已读取任务、账号和版本信息", StatusTone.Success);
            if (!initialLoad) SetFeedback("状态已刷新", StatusTone.Success);
        }
        catch (OperationCanceledException)
        {
            AddActivity("状态刷新已取消", "没有修改系统配置", StatusTone.Warning);
            SetFeedback("状态刷新已取消", StatusTone.Warning);
        }
        catch (StatusReadException exception)
        {
            ShowStatusFailure(exception.Message, exception.TechnicalDetails);
        }
        catch (Exception exception)
        {
            ShowStatusFailure("发生了未预期的状态读取错误。", exception.ToString());
        }
        finally
        {
            IsLoading = false;
            EndOperation();
        }
    }

    public async Task ExecuteManagerActionAsync(ManagerAction action, CancellationToken cancellationToken = default)
    {
        if (!TryBeginOperation(GetBusyMessage(action), critical: true, cancellationToken, out var operationToken))
        {
            AddActivity("操作未开始", "已有管理操作正在执行", StatusTone.Warning);
            return;
        }

        HasError = false;
        TechnicalDetails = string.Empty;
        AddActivity(GetBusyMessage(action), "请勿同时启动其他管理操作", StatusTone.Neutral);
        try
        {
            var interactive = action == ManagerAction.RefreshCredential ||
                (action is ManagerAction.Install or ManagerAction.Repair && !CredentialExists);
            var result = await _actionService.ExecuteAsync(action, interactive, operationToken);
            if (result.RequiresRefresh)
            {
                try
                {
                    await RefreshCoreAsync(operationToken);
                }
                catch (Exception exception) when (exception is not OperationCanceledException)
                {
                    ShowOperationFailure(
                        $"{GetSuccessTitle(action)}，但状态刷新失败。",
                        exception.ToString());
                    return;
                }
            }

            AddActivity(GetSuccessTitle(action), "系统状态已自动刷新", StatusTone.Success);
            SetFeedback(GetSuccessTitle(action), StatusTone.Success);
        }
        catch (OperationCanceledException)
        {
            AddActivity("操作已取消", "未继续等待当前可取消操作", StatusTone.Warning);
            SetFeedback("操作已取消，系统配置未改变", StatusTone.Warning);
        }
        catch (ManagementActionException exception)
        {
            if (string.Equals(exception.ErrorCode, "CREDENTIAL_CANCELLED", StringComparison.Ordinal))
            {
                HasError = false;
                TechnicalDetails = string.Empty;
                AddActivity("账号输入已取消", "未保存新的凭据", StatusTone.Warning);
                SetFeedback("账号输入已取消，未保存新的凭据。", StatusTone.Warning);
            }
            else
            {
                ShowOperationFailure(exception.Message, exception.TechnicalDetails);
            }
        }
        catch (Exception exception)
        {
            ShowOperationFailure("管理操作失败。", exception.ToString());
        }
        finally
        {
            EndOperation();
        }
    }

    public void CancelCurrentOperation()
    {
        if (!IsCriticalOperation)
        {
            _currentOperationSource?.Cancel();
        }
    }

    public async Task CheckForUpdatesAsync()
    {
        if (!TryBeginOperation("正在检查更新…", critical: false, CancellationToken.None, out var operationToken))
        {
            AddActivity("操作未开始", "已有管理操作正在执行", StatusTone.Warning);
            return;
        }

        string? workspace = null;
        var handedOff = false;
        HasError = false;
        TechnicalDetails = string.Empty;
        try
        {
            var currentVersion = ReleaseVersion.FromAssembly(Assembly.GetExecutingAssembly());
            var info = _qaReleaseTag is null
                ? await _updateService.CheckForUpdatesAsync(currentVersion, operationToken)
                : await _updateService.CheckForQaReleaseAsync(currentVersion, _qaReleaseTag, operationToken);
            if (!info.IsUpdateAvailable)
            {
                AddActivity("已是最新版本", $"当前 BIT-Web 版本 v{currentVersion}", StatusTone.Success);
                SetFeedback("当前已是最新版本", StatusTone.Success);
                return;
            }

            AddActivity($"发现新版本 v{info.LatestVersion}", "正在从官方 GitHub Release 下载", StatusTone.Neutral);
            var progress = new Progress<UpdateProgress>(value => OperationMessage = value.Message);
            workspace = await _updateService.DownloadUpdateAsync(info, progress, operationToken);
            var payload = await _updateService.ValidateUpdateAsync(info, workspace, progress, operationToken);
            OperationMessage = "正在准备安装…";
            var prepared = await _updateService.PrepareUpdateAsync(info, workspace, payload, operationToken);

            IsCriticalOperation = true;
            OperationMessage = "正在完成更新…";
            _updateLauncher.Launch(prepared, InstallDirectory, Process.GetCurrentProcess().Id);
            handedOff = true;
            AddActivity("更新包已验证", "管理器将退出并由安全部署程序完成替换", StatusTone.Success);
            UpdateReadyForExit?.Invoke(this, EventArgs.Empty);
        }
        catch (OperationCanceledException)
        {
            if (workspace is not null) UpdateService.TryDeleteDirectory(workspace);
            AddActivity("更新已取消", "当前版本保持不变", StatusTone.Warning);
            SetFeedback("更新已取消，当前版本保持不变", StatusTone.Warning);
        }
        catch (UpdateException exception)
        {
            if (workspace is not null) UpdateService.TryDeleteDirectory(workspace);
            ShowOperationFailure(exception.Message, $"Error code: {exception.ErrorCode}{Environment.NewLine}{exception.TechnicalDetails}");
        }
        catch (Exception exception)
        {
            if (workspace is not null) UpdateService.TryDeleteDirectory(workspace);
            ShowOperationFailure("更新失败", exception.ToString());
        }
        finally
        {
            if (!handedOff) EndOperation();
        }
    }

    private Task ExecutePrimaryActionAsync() => IsInstalled
        ? CheckForUpdatesAsync()
        : ExecuteManagerActionAsync(ManagerAction.Install);

    public async Task RequestUninstallAsync()
    {
        if (_dialogService.ConfirmUninstall())
        {
            await ExecuteManagerActionAsync(ManagerAction.Uninstall);
        }
        else
        {
            AddActivity("卸载已取消", "没有修改计划任务或文件", StatusTone.Neutral);
        }
    }

    public async Task RequestClearCredentialAsync()
    {
        if (!_dialogService.ConfirmClearCredential() || !_dialogService.ConfirmClearCredentialAgain())
        {
            AddActivity("清除账号已取消", "凭据和自动登录任务均未修改", StatusTone.Neutral);
            return;
        }

        await ExecuteManagerActionAsync(ManagerAction.ClearCredential);
    }

    private void OpenInstallDirectory()
    {
        try
        {
            _directoryService.Open(InstallDirectory);
            AddActivity("已打开安装目录", InstallDirectory, StatusTone.Success);
        }
        catch (Exception exception)
        {
            ShowOperationFailure("无法打开安装目录。", exception.ToString());
            _dialogService.ShowInformation("安装目录不可用", "找不到当前安装目录，管理器不会自动创建该目录。请刷新状态后再试。");
        }
    }

    private async Task RefreshCoreAsync(CancellationToken cancellationToken)
    {
        var status = await _statusService.GetStatusAsync(cancellationToken);
        _status = status;
        Apply(DashboardPresentation.FromStatus(status));
        HasError = false;
        TechnicalDetails = string.Empty;
        FeedbackMessage = string.Empty;
        NotifyStateProperties();
    }

    private void Apply(DashboardPresentation presentation)
    {
        OverallTitle = presentation.OverallTitle;
        OverallDetail = presentation.OverallDetail;
        OverallTone = presentation.OverallTone;
        TaskValue = presentation.TaskValue;
        TaskTone = presentation.TaskTone;
        AccountValue = presentation.AccountValue;
        AccountTone = presentation.AccountTone;
        VersionValue = presentation.VersionValue;
        InstallDirectory = presentation.InstallDirectory;
    }

    private void ApplyFailure(string userMessage, string technicalDetails)
    {
        HasError = true;
        OverallTitle = "无法读取系统状态";
        OverallDetail = userMessage;
        OverallTone = StatusTone.Error;
        TaskValue = "读取失败";
        TaskTone = StatusTone.Error;
        AccountValue = "—";
        AccountTone = StatusTone.Neutral;
        VersionValue = "—";
        InstallDirectory = "—";
        ActivityTitle = "状态读取失败";
        ActivityDetail = "展开详细信息可查看技术原因";
        TechnicalDetails = technicalDetails;
    }

    private void ShowStatusFailure(string userMessage, string technicalDetails)
    {
        if (_status is null)
        {
            ApplyFailure(userMessage, technicalDetails);
        }
        else
        {
            ShowOperationFailure("状态刷新失败", technicalDetails);
        }
    }

    private void ShowOperationFailure(string userMessage, string technicalDetails)
    {
        HasError = true;
        TechnicalDetails = technicalDetails;
        SetFeedback(userMessage, StatusTone.Error);
        AddActivity(userMessage, "展开技术详情可查看原因", StatusTone.Error);
    }

    private void SetFeedback(string message, StatusTone tone)
    {
        FeedbackTone = tone;
        FeedbackMessage = message;
    }

    private bool TryBeginOperation(
        string message,
        bool critical,
        CancellationToken cancellationToken,
        out CancellationToken operationToken)
    {
        lock (_operationSync)
        {
            if (_operationActive)
            {
                operationToken = CancellationToken.None;
                return false;
            }

            _operationActive = true;
            _currentOperationSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            operationToken = _currentOperationSource.Token;
        }

        IsCriticalOperation = critical;
        OperationMessage = message;
        FeedbackMessage = string.Empty;
        IsBusy = true;
        return true;
    }

    private void EndOperation()
    {
        lock (_operationSync)
        {
            _currentOperationSource?.Dispose();
            _currentOperationSource = null;
            _operationActive = false;
        }

        IsCriticalOperation = false;
        OperationMessage = string.Empty;
        IsBusy = false;
    }

    private void AddActivity(string title, string detail, StatusTone tone)
    {
        ActivityTitle = title;
        ActivityDetail = $"{DateTime.Now:HH:mm} · {detail}";
        Activities.Insert(0, new ActivityEntry(title, ActivityDetail, tone));
        while (Activities.Count > 3)
        {
            Activities.RemoveAt(Activities.Count - 1);
        }
    }

    private static string GetBusyMessage(ManagerAction action) => action switch
    {
        ManagerAction.RefreshCredential => "正在更新校园网账号…",
        ManagerAction.Install => "正在安装自动登录…",
        ManagerAction.Repair => "正在修复安装…",
        ManagerAction.Uninstall => "正在卸载自动登录…",
        ManagerAction.ClearCredential => "正在停用任务并清除账号…",
        _ => "正在执行管理操作…",
    };

    private static string GetSuccessTitle(ManagerAction action) => action switch
    {
        ManagerAction.RefreshCredential => "校园网账号已更新",
        ManagerAction.Install => "自动登录安装完成",
        ManagerAction.Repair => "修复安装完成",
        ManagerAction.Uninstall => "自动登录已卸载",
        ManagerAction.ClearCredential => "账号信息已清除",
        _ => "管理操作完成",
    };

    private void NotifyStateProperties()
    {
        OnPropertyChanged(nameof(IsInstalled));
        OnPropertyChanged(nameof(CredentialExists));
        OnPropertyChanged(nameof(CanOpenInstallDirectory));
        OnPropertyChanged(nameof(CanRefreshCredential));
        OnPropertyChanged(nameof(CanRepair));
        OnPropertyChanged(nameof(CanUninstall));
        OnPropertyChanged(nameof(CanClearCredential));
        OnPropertyChanged(nameof(CanRunPrimaryAction));
        OnPropertyChanged(nameof(PrimaryActionText));
        OnPropertyChanged(nameof(AccountActionText));
        OnPropertyChanged(nameof(CanCheckUpdate));
        OnPropertyChanged(nameof(InstalledVisibility));
        NotifyCommandStates();
    }

    private void NotifyCommandStates()
    {
        RefreshStatusCommand.NotifyCanExecuteChanged();
        PrimaryActionCommand.NotifyCanExecuteChanged();
        RefreshCredentialCommand.NotifyCanExecuteChanged();
        RepairCommand.NotifyCanExecuteChanged();
        UninstallCommand.NotifyCanExecuteChanged();
        ClearCredentialCommand.NotifyCanExecuteChanged();
        OpenInstallDirectoryCommand.NotifyCanExecuteChanged();
        CheckUpdateCommand.NotifyCanExecuteChanged();
    }

    private bool SetField<T>(ref T field, T value, [CallerMemberName] string? propertyName = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value))
        {
            return false;
        }

        field = value;
        OnPropertyChanged(propertyName);
        return true;
    }

    private void OnPropertyChanged([CallerMemberName] string? propertyName = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
}

file sealed class DisabledUpdateService : IUpdateService
{
    private static Exception Disabled() => new InvalidOperationException("Update service was not configured.");
    public Task<UpdateInfo> CheckForUpdatesAsync(ReleaseVersion currentVersion, CancellationToken cancellationToken = default) => Task.FromException<UpdateInfo>(Disabled());
    public Task<UpdateInfo> CheckForQaReleaseAsync(ReleaseVersion currentVersion, string requestedTag, CancellationToken cancellationToken = default) => Task.FromException<UpdateInfo>(Disabled());
    public Task<string> DownloadUpdateAsync(UpdateInfo info, IProgress<UpdateProgress>? progress = null, CancellationToken cancellationToken = default) => Task.FromException<string>(Disabled());
    public Task<string> ValidateUpdateAsync(UpdateInfo info, string workspaceDirectory, IProgress<UpdateProgress>? progress = null, CancellationToken cancellationToken = default) => Task.FromException<string>(Disabled());
    public Task<PreparedUpdate> PrepareUpdateAsync(UpdateInfo info, string workspaceDirectory, string payloadDirectory, CancellationToken cancellationToken = default) => Task.FromException<PreparedUpdate>(Disabled());
}

file sealed class DisabledUpdateLauncher : IUpdateLauncher
{
    public void Launch(PreparedUpdate update, string targetDirectory, int managerProcessId) => throw new InvalidOperationException("Update launcher was not configured.");
}
