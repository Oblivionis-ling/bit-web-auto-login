# BIT-Web Auto Login - on-demand Windows dashboard
[CmdletBinding()]
param(
    [switch]$HideConsole,
    [ValidateSet('Live', 'NotInstalledCredential', 'NotInstalledEmpty', 'Updating', 'UpdateSuccess', 'UpdateFailure', 'Busy')]
    [string]$PreviewState = 'Live',
    [switch]$StartExpanded,
    [string]$CapturePath,
    [switch]$CloseAfterCapture,
    [switch]$LayoutCheckOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($HideConsole) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class BITWebConsoleWindow {
    [DllImport("kernel32.dll")]
    private static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    public static void Hide() {
        IntPtr handle = GetConsoleWindow();
        if (handle != IntPtr.Zero) ShowWindow(handle, 0);
    }
}
'@
}

if ($env:OS -ne 'Windows_NT') {
    throw 'This GUI supports Windows only.'
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Import-Module (Join-Path $PSScriptRoot 'BITWebAutoLogin.Management.psm1') -Force

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:Colors = @{
    Window = [System.Drawing.Color]::FromArgb(246, 247, 249)
    Surface = [System.Drawing.Color]::White
    SurfaceSoft = [System.Drawing.Color]::FromArgb(249, 250, 251)
    Border = [System.Drawing.Color]::FromArgb(224, 228, 233)
    Text = [System.Drawing.Color]::FromArgb(31, 41, 55)
    Muted = [System.Drawing.Color]::FromArgb(96, 106, 120)
    Accent = [System.Drawing.Color]::FromArgb(0, 103, 192)
    AccentSoft = [System.Drawing.Color]::FromArgb(238, 246, 253)
    TrustSurface = [System.Drawing.Color]::FromArgb(248, 249, 251)
    Success = [System.Drawing.Color]::FromArgb(32, 132, 83)
    Warning = [System.Drawing.Color]::FromArgb(202, 112, 20)
    Error = [System.Drawing.Color]::FromArgb(183, 40, 46)
    Neutral = [System.Drawing.Color]::FromArgb(93, 105, 120)
}

$script:BaseClientHeight = 644
$script:ExpandedClientHeight = 762
$script:LogOffset = 118
$script:LogExpanded = $false
$script:IsBusy = $false
$script:CurrentStatus = $null
$script:CurrentDashboard = $null
$script:CaptureTimer = $null

function New-DashboardLabel {
    param(
        [string]$Text = '',
        [float]$Size = 9.5,
        [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular,
        [System.Drawing.Color]$Color = $script:Colors.Text
    )

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.AutoSize = $true
    $label.Font = New-Object System.Drawing.Font('Segoe UI', $Size, $Style)
    $label.ForeColor = $Color
    $label.BackColor = [System.Drawing.Color]::Transparent
    return $label
}

function New-SurfacePanel {
    param([int]$Height)

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Height = $Height
    $panel.BackColor = $script:Colors.Surface
    $panel.BorderStyle = 'None'
    return $panel
}

function Set-ButtonBaseStyle {
    param(
        [System.Windows.Forms.Button]$Button,
        [switch]$Primary,
        [switch]$Danger
    )

    $Button.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Regular)
    $Button.FlatStyle = 'Flat'
    $Button.FlatAppearance.BorderSize = 1
    $Button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $Button.UseVisualStyleBackColor = $false
    $Button.TextAlign = 'MiddleCenter'
    $Button.Padding = New-Object System.Windows.Forms.Padding(10, 0, 10, 0)
    if ($Primary) {
        $Button.Height = 40
        $Button.BackColor = $script:Colors.Accent
        $Button.ForeColor = [System.Drawing.Color]::White
        $Button.FlatAppearance.BorderColor = $script:Colors.Accent
        $Button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(0, 90, 168)
        $Button.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(0, 78, 146)
    }
    elseif ($Danger) {
        $Button.Height = 36
        $Button.BackColor = $script:Colors.Surface
        $Button.ForeColor = $script:Colors.Error
        $Button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(224, 166, 169)
        $Button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(253, 242, 242)
        $Button.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(249, 228, 229)
    }
    else {
        $Button.Height = 36
        $Button.BackColor = $script:Colors.Surface
        $Button.ForeColor = $script:Colors.Text
        $Button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(204, 210, 218)
        $Button.FlatAppearance.MouseOverBackColor = $script:Colors.AccentSoft
        $Button.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(224, 237, 249)
    }
}

function New-StatusDot {
    param([System.Drawing.Color]$Color = $script:Colors.Neutral)

    $dot = New-DashboardLabel -Text ([char]0x25CF) -Size 8 -Color $Color
    $dot.AutoSize = $false
    $dot.Size = New-Object System.Drawing.Size(12, 14)
    $dot.TextAlign = 'MiddleCenter'
    return $dot
}

function Get-ToneColor {
    param([string]$Tone)
    switch ($Tone) {
        'Success' { return $script:Colors.Success }
        'Warning' { return $script:Colors.Warning }
        'Error' { return $script:Colors.Error }
        default { return $script:Colors.Neutral }
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'BIT-Web 自动登录'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(800, $script:BaseClientHeight)
$form.MinimumSize = New-Object System.Drawing.Size(736, 683)
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
$form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
$form.BackColor = $script:Colors.Window
$form.MaximizeBox = $false
$form.KeyPreview = $true

$headerTitle = New-DashboardLabel -Text 'BIT-Web 自动登录' -Size 18 -Style Bold
$headerTitle.Location = New-Object System.Drawing.Point(28, 20)
$form.Controls.Add($headerTitle)

$headerSubtitle = New-DashboardLabel -Text '北京理工大学校园网自动登录管理器' -Size 9.5 -Color $script:Colors.Muted
$headerSubtitle.Location = New-Object System.Drawing.Point(30, 56)
$form.Controls.Add($headerSubtitle)

function New-StatusCard {
    param([string]$AccessibleName)

    $panel = New-SurfacePanel -Height 86
    $panel.AccessibleName = $AccessibleName
    $dot = New-StatusDot
    $dot.Location = New-Object System.Drawing.Point(14, 13)
    $panel.Controls.Add($dot)
    $title = New-DashboardLabel -Size 10.5 -Style Bold
    $title.Location = New-Object System.Drawing.Point(32, 11)
    $panel.Controls.Add($title)
    $detail = New-DashboardLabel -Size 8.75 -Color $script:Colors.Muted
    $detail.AutoSize = $false
    $detail.Location = New-Object System.Drawing.Point(32, 40)
    $detail.Size = New-Object System.Drawing.Size(180, 30)
    $panel.Controls.Add($detail)
    return [pscustomobject]@{ Panel = $panel; Dot = $dot; Title = $title; Detail = $detail }
}

$autoCard = New-StatusCard -AccessibleName '自动登录状态'
$accountCard = New-StatusCard -AccessibleName '账号配置状态'
$versionCard = New-StatusCard -AccessibleName '当前版本'
$versionCard.Dot.Visible = $false
$versionCard.Title.Location = New-Object System.Drawing.Point(18, 8)
$versionCard.Title.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
$versionCard.Detail.Location = New-Object System.Drawing.Point(18, 42)
$form.Controls.Add($autoCard.Panel)
$form.Controls.Add($accountCard.Panel)
$form.Controls.Add($versionCard.Panel)

$managementTitle = New-DashboardLabel -Text '管理' -Size 11.5 -Style Bold
$managementTitle.Location = New-Object System.Drawing.Point(28, 188)
$form.Controls.Add($managementTitle)

$primaryPanel = New-SurfacePanel -Height 80
$form.Controls.Add($primaryPanel)
$primaryAccent = New-Object System.Windows.Forms.Panel
$primaryAccent.BackColor = $script:Colors.Accent
$primaryAccent.Location = New-Object System.Drawing.Point(0, 0)
$primaryAccent.Size = New-Object System.Drawing.Size(4, 80)
$primaryPanel.Controls.Add($primaryAccent)
$primaryTitle = New-DashboardLabel -Size 11 -Style Bold
$primaryTitle.Location = New-Object System.Drawing.Point(20, 13)
$primaryPanel.Controls.Add($primaryTitle)
$primaryDescription = New-DashboardLabel -Size 8.75 -Color $script:Colors.Muted
$primaryDescription.Location = New-Object System.Drawing.Point(20, 43)
$primaryPanel.Controls.Add($primaryDescription)
$primaryButton = New-Object System.Windows.Forms.Button
$primaryButton.Size = New-Object System.Drawing.Size(146, 40)
$primaryButton.AccessibleName = '主要操作'
Set-ButtonBaseStyle -Button $primaryButton -Primary
$primaryPanel.Controls.Add($primaryButton)

function New-ActionCard {
    param(
        [string]$Title,
        [string]$Description,
        [string]$ButtonText
    )

    $panel = New-SurfacePanel -Height 76
    $titleLabel = New-DashboardLabel -Text $Title -Size 10.25 -Style Bold
    $titleLabel.Location = New-Object System.Drawing.Point(16, 12)
    $panel.Controls.Add($titleLabel)
    $descriptionLabel = New-DashboardLabel -Text $Description -Size 8.5 -Color $script:Colors.Muted
    $descriptionLabel.Location = New-Object System.Drawing.Point(16, 41)
    $panel.Controls.Add($descriptionLabel)
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $ButtonText
    $button.Size = New-Object System.Drawing.Size(104, 36)
    $button.AccessibleName = $Title
    Set-ButtonBaseStyle -Button $button
    $panel.Controls.Add($button)
    return [pscustomobject]@{ Panel = $panel; Button = $button; Description = $descriptionLabel }
}

$accountAction = New-ActionCard -Title '更换账号' -Description '修改校园网账号或密码' -ButtonText '更换账号'
$repairAction = New-ActionCard -Title '修复安装' -Description '重新部署当前本地版本' -ButtonText '修复安装'
$form.Controls.Add($accountAction.Panel)
$form.Controls.Add($repairAction.Panel)

$activitySectionTitle = New-DashboardLabel -Text '最近操作' -Size 11.5 -Style Bold
$form.Controls.Add($activitySectionTitle)

$activityPanel = New-SurfacePanel -Height 60
$form.Controls.Add($activityPanel)
$activityDot = New-StatusDot -Color $script:Colors.Success
$activityDot.Location = New-Object System.Drawing.Point(14, 10)
$activityPanel.Controls.Add($activityDot)
$activityTitle = New-DashboardLabel -Text '管理器已就绪' -Size 9.5 -Style Bold
$activityTitle.Location = New-Object System.Drawing.Point(32, 9)
$activityPanel.Controls.Add($activityTitle)
$activityDetail = New-DashboardLabel -Text '仅在点击检查更新时连接官方 GitHub 仓库' -Size 8.5 -Color $script:Colors.Muted
$activityDetail.AutoSize = $false
$activityDetail.Location = New-Object System.Drawing.Point(32, 34)
$activityDetail.Size = New-Object System.Drawing.Size(500, 20)
$activityPanel.Controls.Add($activityDetail)
$detailsButton = New-Object System.Windows.Forms.Button
$detailsButton.Text = '查看详细日志  ›'
$detailsButton.Size = New-Object System.Drawing.Size(126, 30)
$detailsButton.FlatStyle = 'Flat'
$detailsButton.FlatAppearance.BorderSize = 0
$detailsButton.BackColor = $script:Colors.Surface
$detailsButton.ForeColor = $script:Colors.Accent
$detailsButton.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$detailsButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$activityPanel.Controls.Add($detailsButton)
$operationProgress = New-Object System.Windows.Forms.Panel
$operationProgress.BackColor = $script:Colors.Accent
$operationProgress.Size = New-Object System.Drawing.Size(118, 8)
$operationProgress.Visible = $false
$activityPanel.Controls.Add($operationProgress)

$logPanel = New-SurfacePanel -Height 106
$logPanel.Visible = $false
$form.Controls.Add($logPanel)
$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = 'Vertical'
$logBox.BorderStyle = 'None'
$logBox.BackColor = $script:Colors.Surface
$logBox.ForeColor = $script:Colors.Text
$logBox.Font = New-Object System.Drawing.Font('Consolas', 8.75)
$logBox.Location = New-Object System.Drawing.Point(12, 10)
$logBox.Anchor = 'Top,Bottom,Left,Right'
$logPanel.Controls.Add($logBox)

$utilityPanel = New-Object System.Windows.Forms.Panel
$utilityPanel.Height = 36
$utilityPanel.BackColor = [System.Drawing.Color]::Transparent
$form.Controls.Add($utilityPanel)
$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Text = '刷新状态'
$refreshButton.Size = New-Object System.Drawing.Size(104, 36)
Set-ButtonBaseStyle -Button $refreshButton
$utilityPanel.Controls.Add($refreshButton)
$openButton = New-Object System.Windows.Forms.Button
$openButton.Text = '打开运行目录'
$openButton.Size = New-Object System.Drawing.Size(128, 36)
Set-ButtonBaseStyle -Button $openButton
$openButton.Location = New-Object System.Drawing.Point(114, 0)
$utilityPanel.Controls.Add($openButton)

$separator = New-Object System.Windows.Forms.Panel
$separator.Height = 1
$separator.BackColor = $script:Colors.Border
$form.Controls.Add($separator)

$advancedPanel = New-Object System.Windows.Forms.Panel
$advancedPanel.Height = 44
$advancedPanel.BackColor = [System.Drawing.Color]::Transparent
$form.Controls.Add($advancedPanel)
$advancedTitle = New-DashboardLabel -Text '高级操作' -Size 9.5 -Style Bold -Color $script:Colors.Muted
$advancedTitle.Location = New-Object System.Drawing.Point(0, 12)
$advancedPanel.Controls.Add($advancedTitle)
$uninstallButton = New-Object System.Windows.Forms.Button
$uninstallButton.Text = '卸载自动登录'
$uninstallButton.Size = New-Object System.Drawing.Size(122, 36)
$uninstallButton.Location = New-Object System.Drawing.Point(106, 5)
Set-ButtonBaseStyle -Button $uninstallButton
$advancedPanel.Controls.Add($uninstallButton)
$clearButton = New-Object System.Windows.Forms.Button
$clearButton.Text = '清除账号信息'
$clearButton.Size = New-Object System.Drawing.Size(122, 36)
$clearButton.Location = New-Object System.Drawing.Point(238, 5)
Set-ButtonBaseStyle -Button $clearButton -Danger
$advancedPanel.Controls.Add($clearButton)

$trustPanel = New-Object System.Windows.Forms.Panel
$trustPanel.Height = 40
$trustPanel.BackColor = $script:Colors.TrustSurface
$form.Controls.Add($trustPanel)
$trustTitle = New-DashboardLabel -Text '凭据安全' -Size 8.75 -Style Bold -Color $script:Colors.Muted
$trustTitle.Location = New-Object System.Drawing.Point(14, 4)
$trustPanel.Controls.Add($trustTitle)
$trustDetail = New-DashboardLabel -Text '密码由 Windows DPAPI 加密保存 · 不读取或显示密码 · 不修改网络适配器' -Size 8.25 -Color $script:Colors.Muted
$trustDetail.Location = New-Object System.Drawing.Point(14, 21)
$trustPanel.Controls.Add($trustDetail)

$toolTip = New-Object System.Windows.Forms.ToolTip
$toolTip.AutoPopDelay = 8000
$toolTip.InitialDelay = 350
$toolTip.ReshowDelay = 100

function Update-DashboardLayout {
    [int]$margin = 28
    [int]$clientWidth = $form.ClientSize.Width
    [int]$contentWidth = [Math]::Max(660, $clientWidth - ($margin * 2))
    [int]$statusGap = 12
    [int]$statusWidth = [Math]::Floor(($contentWidth - ($statusGap * 2)) / 3)
    [int]$secondWidth = [Math]::Floor(($contentWidth - 12) / 2)
    [int]$offset = if ($script:LogExpanded) { $script:LogOffset } else { 0 }

    $autoCard.Panel.SetBounds($margin, 88, $statusWidth, 86)
    $accountCard.Panel.SetBounds($margin + $statusWidth + $statusGap, 88, $statusWidth, 86)
    $versionCard.Panel.SetBounds($margin + (($statusWidth + $statusGap) * 2), 88, $contentWidth - (($statusWidth + $statusGap) * 2), 86)
    foreach ($card in @($autoCard, $accountCard)) {
        $card.Detail.Width = $card.Panel.Width - 50
    }
    $versionCard.Detail.Width = $versionCard.Panel.Width - 36

    $managementTitle.Location = New-Object System.Drawing.Point($margin, 188)
    $primaryPanel.SetBounds($margin, 212, $contentWidth, 80)
    [int]$primaryButtonLeft = $primaryPanel.Width - 166
    $primaryButton.Location = New-Object System.Drawing.Point($primaryButtonLeft, 19)
    $accountAction.Panel.SetBounds($margin, 302, $secondWidth, 76)
    $repairAction.Panel.SetBounds($margin + $secondWidth + 12, 302, $contentWidth - $secondWidth - 12, 76)
    [int]$accountButtonLeft = $accountAction.Panel.Width - 120
    [int]$repairButtonLeft = $repairAction.Panel.Width - 120
    $accountAction.Button.Location = New-Object System.Drawing.Point($accountButtonLeft, 19)
    $repairAction.Button.Location = New-Object System.Drawing.Point($repairButtonLeft, 19)

    $activitySectionTitle.Location = New-Object System.Drawing.Point($margin, 390)
    $activityPanel.SetBounds($margin, 414, $contentWidth, 60)
    [int]$detailsButtonLeft = $activityPanel.Width - 140
    [int]$progressLeft = $activityPanel.Width - 134
    $detailsButton.Location = New-Object System.Drawing.Point($detailsButtonLeft, 15)
    $operationProgress.Location = New-Object System.Drawing.Point($progressLeft, 47)
    $activityDetail.Width = [Math]::Max(240, $activityPanel.Width - 190)
    $logPanel.SetBounds($margin, 482, $contentWidth, 106)
    [int]$logWidth = $logPanel.Width - 24
    [int]$logHeight = $logPanel.Height - 20
    $logBox.Size = New-Object System.Drawing.Size($logWidth, $logHeight)

    $utilityPanel.SetBounds($margin, 490 + $offset, $contentWidth, 36)
    $separator.SetBounds($margin, 534 + $offset, $contentWidth, 1)
    $advancedPanel.SetBounds($margin, 542 + $offset, $contentWidth, 44)
    $trustPanel.SetBounds($margin, 592 + $offset, $contentWidth, 40)
}

function Set-LogExpanded {
    param([bool]$Expanded)

    if ($script:LogExpanded -eq $Expanded) {
        return
    }
    $script:LogExpanded = $Expanded
    $logPanel.Visible = $Expanded
    $detailsButton.Text = if ($Expanded) { '收起详细日志  ⌃' } else { '查看详细日志  ›' }
    $height = if ($Expanded) { $script:ExpandedClientHeight } else { $script:BaseClientHeight }
    $form.ClientSize = New-Object System.Drawing.Size($form.ClientSize.Width, $height)
    Update-DashboardLayout
}

function Write-ManagementLog {
    param([string]$Message)

    $timestamp = Get-Date -Format 'HH:mm:ss'
    $logBox.AppendText("[$timestamp] $Message" + [Environment]::NewLine)
    $logBox.SelectionStart = $logBox.TextLength
    $logBox.ScrollToCaret()
}

function Set-Activity {
    param(
        [string]$Title,
        [string]$Detail,
        [ValidateSet('Success', 'Warning', 'Error', 'Neutral', 'Busy')]
        [string]$Tone = 'Neutral',
        [switch]$ExpandOnError
    )

    $activityTitle.Text = $Title
    $activityDetail.Text = $Detail
    $activityDot.ForeColor = if ($Tone -eq 'Busy') { $script:Colors.Accent } else { Get-ToneColor $Tone }
    $operationProgress.Visible = ($Tone -eq 'Busy')
    if ($Tone -eq 'Error' -and $ExpandOnError) {
        Set-LogExpanded -Expanded $true
    }
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-ControlsBusy {
    param([bool]$Busy)

    $script:IsBusy = $Busy
    foreach ($button in @($primaryButton, $accountAction.Button, $repairAction.Button, $refreshButton, $openButton, $uninstallButton, $clearButton)) {
        $button.Enabled = -not $Busy
    }
    if (-not $Busy -and $null -ne $script:CurrentDashboard) {
        $repairAction.Button.Enabled = [bool]$script:CurrentDashboard.RepairEnabled
        $uninstallButton.Enabled = [bool]$script:CurrentStatus.IsInstalled
        $clearButton.Enabled = ([bool]$script:CurrentStatus.IsInstalled -or [bool]$script:CurrentStatus.CredentialExists)
    }
    $form.UseWaitCursor = $Busy
}

function Set-OperationStage {
    param([string]$Stage, [string]$Message)

    Write-ManagementLog $Message
    Set-Activity -Title $Message.TrimEnd([char]0x2026) -Detail '请稍候，不要关闭管理器' -Tone Busy
}

function Get-PreviewStatus {
    param([string]$State)

    switch ($State) {
        'NotInstalledCredential' {
            return [pscustomobject]@{ InstallDirectory = 'C:\Users\User\AppData\Local\BITWebAutoLogin'; IsInstalled = $false; TaskState = '未安装'; TaskError = $null; CredentialExists = $true; CredentialPaths = @(); InstalledVersion = '1.2.5' }
        }
        'NotInstalledEmpty' {
            return [pscustomobject]@{ InstallDirectory = 'C:\Users\User\AppData\Local\BITWebAutoLogin'; IsInstalled = $false; TaskState = '未安装'; TaskError = $null; CredentialExists = $false; CredentialPaths = @(); InstalledVersion = '—' }
        }
        default { return $null }
    }
}

function Update-ManagementStatus {
    try {
        $preview = Get-PreviewStatus -State $PreviewState
        $script:CurrentStatus = if ($null -ne $preview) { $preview } else { Get-BITWebManagementStatus -ProjectDirectory $PSScriptRoot }
        $script:CurrentDashboard = Get-BITWebDashboardState -Status $script:CurrentStatus

        $autoCard.Title.Text = $script:CurrentDashboard.AutoLoginTitle
        $autoCard.Detail.Text = $script:CurrentDashboard.AutoLoginDetail
        $autoCard.Dot.ForeColor = Get-ToneColor $script:CurrentDashboard.AutoLoginTone
        $accountCard.Title.Text = $script:CurrentDashboard.AccountTitle
        $accountCard.Detail.Text = $script:CurrentDashboard.AccountDetail
        $accountCard.Dot.ForeColor = Get-ToneColor $script:CurrentDashboard.AccountTone
        $versionCard.Title.Text = $script:CurrentDashboard.VersionValue
        $versionCard.Detail.Text = $script:CurrentDashboard.VersionDetail

        $primaryTitle.Text = $script:CurrentDashboard.PrimaryTitle
        $primaryDescription.Text = $script:CurrentDashboard.PrimaryDescription
        $primaryButton.Text = $script:CurrentDashboard.PrimaryButtonText
        $repairAction.Button.Enabled = [bool]$script:CurrentDashboard.RepairEnabled
        $repairAction.Description.Text = if ($script:CurrentDashboard.RepairEnabled) { '重新部署当前本地版本' } else { '安装完成后可用' }
        $uninstallButton.Enabled = [bool]$script:CurrentStatus.IsInstalled
        $clearButton.Enabled = ([bool]$script:CurrentStatus.IsInstalled -or [bool]$script:CurrentStatus.CredentialExists)

        $toolTip.SetToolTip($autoCard.Panel, "原始任务状态：$($script:CurrentStatus.TaskState)")
        $toolTip.SetToolTip($versionCard.Panel, "运行目录：$($script:CurrentStatus.InstallDirectory)")
        if (-not [string]::IsNullOrWhiteSpace([string]$script:CurrentStatus.TaskError)) {
            Write-ManagementLog "状态读取提示：$($script:CurrentStatus.TaskError)"
        }
    }
    catch {
        Write-ManagementLog "状态读取失败：$($_.Exception.Message)"
        Set-Activity -Title '状态读取失败' -Detail $_.Exception.Message -Tone Error -ExpandOnError
    }
}

function Invoke-ManagementOperation {
    param(
        [string]$Name,
        [string]$InitialMessage,
        [scriptblock]$Operation
    )

    Set-ControlsBusy -Busy $true
    try {
        Write-ManagementLog "开始：$Name"
        Set-Activity -Title $InitialMessage -Detail '请稍候，不要关闭管理器' -Tone Busy
        $result = & $Operation
        $resultText = [string]$result
        if (-not [string]::IsNullOrWhiteSpace($resultText)) {
            Write-ManagementLog $resultText
        }
        Write-ManagementLog "完成：$Name"
        $summary = if ([string]::IsNullOrWhiteSpace($resultText)) { "$Name 已完成" } else { ($resultText -split "`r?`n")[0] }
        Set-Activity -Title "$Name 已完成" -Detail $summary -Tone Success
    }
    catch {
        $message = $_.Exception.Message
        Write-ManagementLog "失败：$Name`r`n$message"
        Set-Activity -Title "$Name 失败" -Detail $message -Tone Error -ExpandOnError
        [System.Windows.Forms.MessageBox]::Show(
            "操作失败：$message`r`n`r`n详细信息已在日志中展开。",
            'BIT-Web 自动登录',
            'OK',
            'Error'
        ) | Out-Null
    }
    finally {
        Update-ManagementStatus
        Set-ControlsBusy -Busy $false
    }
}

$primaryButton.Add_Click({
    if ($script:IsBusy) { return }
    if ($script:CurrentDashboard.PrimaryAction -eq 'Install') {
        Invoke-ManagementOperation -Name '安装自动登录' -InitialMessage '正在安装自动登录…' -Operation {
            Install-BITWebAutoLogin -ProjectDirectory $PSScriptRoot
        }
    }
    else {
        Invoke-ManagementOperation -Name '检查更新' -InitialMessage '正在检查 GitHub 更新…' -Operation {
            Update-BITWebAutoLogin -ProgressCallback {
                param($Stage, $Message)
                Set-OperationStage -Stage $Stage -Message $Message
            }
        }
    }
})

$accountAction.Button.Add_Click({
    Invoke-ManagementOperation -Name '更换账号' -InitialMessage '正在打开账号凭据窗口…' -Operation {
        Install-BITWebAutoLogin -RefreshCredential -ProjectDirectory $PSScriptRoot
    }
})

$repairAction.Button.Add_Click({
    Invoke-ManagementOperation -Name '修复安装' -InitialMessage '正在重新部署当前版本…' -Operation {
        Install-BITWebAutoLogin -UpdateOnly -ProjectDirectory $PSScriptRoot
    }
})

$uninstallButton.Add_Click({
    $choice = [System.Windows.Forms.MessageBox]::Show(
        '将停止并移除自动登录任务。运行文件、日志和账号凭据会保留。是否继续？',
        '确认卸载自动登录',
        'YesNo',
        'Question'
    )
    if ($choice -eq 'Yes') {
        Invoke-ManagementOperation -Name '卸载自动登录' -InitialMessage '正在停用自动登录…' -Operation {
            Uninstall-BITWebAutoLogin -ProjectDirectory $PSScriptRoot
        }
    }
})

$clearButton.Add_Click({
    $status = Get-BITWebManagementStatus -ProjectDirectory $PSScriptRoot
    $existingPaths = @($status.CredentialPaths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    $pathText = if ($existingPaths.Count -gt 0) { $existingPaths -join "`r`n" } else { '未找到凭据文件' }
    $choice = [System.Windows.Forms.MessageBox]::Show(
        "清除账号会同时停用自动登录，并删除以下 DPAPI 凭据：`r`n`r`n$pathText`r`n`r`n日志、设置和其他文件不会删除。是否继续？",
        '确认清除账号信息',
        'YesNo',
        'Warning'
    )
    if ($choice -eq 'Yes') {
        Invoke-ManagementOperation -Name '清除账号信息' -InitialMessage '正在停用任务并清除账号…' -Operation {
            Clear-BITWebCredential -Confirm:$false -ProjectDirectory $PSScriptRoot
        }
    }
})

$detailsButton.Add_Click({ Set-LogExpanded -Expanded (-not $script:LogExpanded) })
$refreshButton.Add_Click({
    Update-ManagementStatus
    Set-Activity -Title '状态已刷新' -Detail '已重新读取任务、账号和版本信息' -Tone Success
    Write-ManagementLog '状态已刷新。'
})
$openButton.Add_Click({
    $directory = Get-BITWebInstallDirectory
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        [System.Windows.Forms.MessageBox]::Show('运行目录尚不存在，请先安装。', 'BIT-Web 自动登录', 'OK', 'Information') | Out-Null
        return
    }
    Start-Process explorer.exe -ArgumentList ('"{0}"' -f $directory)
})
$form.Add_Resize({ Update-DashboardLayout })
$form.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::Escape -and $script:LogExpanded) {
        Set-LogExpanded -Expanded $false
        $eventArgs.Handled = $true
    }
})

Update-DashboardLayout
if ($LayoutCheckOnly) {
    return
}

$form.Add_Shown({
    if ($HideConsole) {
        [BITWebConsoleWindow]::Hide()
    }
    Update-DashboardLayout
    Update-ManagementStatus
    Write-ManagementLog '管理器已就绪。只有点击“检查更新”时才会连接官方 GitHub 仓库。'
    if ($StartExpanded) {
        Set-LogExpanded -Expanded $true
    }
    switch ($PreviewState) {
        'Updating' { Set-ControlsBusy -Busy $true; Set-Activity -Title '正在验证更新包' -Detail '请稍候，不要关闭管理器' -Tone Busy }
        'UpdateSuccess' { Set-Activity -Title '检查更新已完成' -Detail '当前已经是最新版本' -Tone Success }
        'UpdateFailure' { Write-ManagementLog '模拟：无法连接 GitHub。'; Set-Activity -Title '检查更新失败' -Detail '无法连接 GitHub，请稍后重试' -Tone Error -ExpandOnError }
        'Busy' { Set-ControlsBusy -Busy $true; Set-Activity -Title '正在重新部署当前版本' -Detail '请稍候，不要关闭管理器' -Tone Busy }
    }
    if (-not [string]::IsNullOrWhiteSpace($CapturePath)) {
        $captureDirectory = Split-Path -Parent $CapturePath
        if (-not (Test-Path -LiteralPath $captureDirectory -PathType Container)) {
            throw "截图目录不存在：$captureDirectory"
        }
        $script:CaptureTimer = New-Object System.Windows.Forms.Timer
        $script:CaptureTimer.Interval = 700
        $script:CaptureTimer.Add_Tick({
            $script:CaptureTimer.Stop()
            $form.Activate()
            $form.BringToFront()
            [System.Windows.Forms.Application]::DoEvents()
            $bitmap = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
            try {
                $targetRectangle = New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)
                $form.DrawToBitmap($bitmap, $targetRectangle)
                $bitmap.Save($CapturePath, [System.Drawing.Imaging.ImageFormat]::Png)
            }
            catch {
                Write-Error "GUI screenshot failed: $($_.Exception.Message)"
            }
            finally {
                $bitmap.Dispose()
                if ($CloseAfterCapture) {
                    $form.Close()
                }
            }
        })
        $script:CaptureTimer.Start()
    }
})

[void]$form.ShowDialog()
