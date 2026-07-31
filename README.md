# BIT-Web 自动登录 v1.1

Windows 校园网后台认证工具，支持：

- `BIT-Web` Wi-Fi。
- 符合允许 IPv4 前缀的物理有线网卡，默认是校园网 `10.*`。
- 深澜（Srun）challenge、HMAC-MD5、SHA-1、SRBX1 登录流程。
- 普通 HTML 登录表单兼容路径。
- Windows 登录后自动启动、断网检测、自动认证和持续重试。

脚本不会创建、切换、启用、禁用或修改网卡配置。Windows 负责连接已有网络，脚本只处理网页认证。

## v1.1 运行策略

- 每 30 秒检查一次符合条件的校园网连接。
- 使用 Microsoft 和 Firefox 两个独立公网探测地址，任一成功即视为在线。
- 连续两轮探测都失败才提交认证，避免瞬时网络波动造成误登录。
- 认证接口接受后进入 5 分钟冷却，冷却期内不会重复提交。
- 登录后最多进行 4 次公网恢复验证。
- 认证请求发生错误时，从 30 秒开始指数退避，最长 30 分钟；达到上限后仍每 30 分钟持续尝试，不会自动放弃。
- 日志只记录状态和错误，不记录账号、密码、请求正文或完整响应正文。

## 系统要求

- Windows 10 或 Windows 11。
- Windows PowerShell 5.1。
- 已由 Windows 保存并能连接校园网有线网络或 `BIT-Web`。
- 当前 Windows 用户可以使用“任务计划程序”；通常不需要管理员权限。

## 一键部署

### 1. 获取项目

仓库目前是私有仓库。已安装 GitHub CLI 时可执行：

```powershell
gh repo clone Oblivionis-ling/bit-web-auto-login
cd bit-web-auto-login
```

也可以在 GitHub 网页中选择 **Code → Download ZIP**，解压后进入项目目录。

### 2. 运行一键安装

下载 ZIP 的用户可以直接双击：

```text
Install.cmd
```

也可以在 PowerShell 中运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

第一次安装会弹出 Windows 凭据输入框。请在本地输入校园网账号密码，不要把密码写入命令、配置文件或聊天。

安装器会自动完成：

1. 校验 v1.1 运行文件。
2. 复制运行文件到 `%LOCALAPPDATA%\BITWebAutoLogin`。
3. 创建或保留 `credential.xml`。密码由当前 Windows 用户的 DPAPI 加密。
4. 将旧版 `BIT-Web AutoLogin v1.0` 任务迁移到稳定任务名 `BIT-Web AutoLogin`。
5. 注册“当前用户登录 Windows 后启动”的后台任务。
6. 立即启动任务并验证其进入 `Running` 状态。

安装器不会复制仓库中的测试、文档、历史日志或临时文件到运行目录。

### 3. 验证部署

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Diagnostics.ps1 -IncludeInternetCheck -LogTail 50
```

正常结果应包括：

```text
Settings version: 1.1
Eligible connection: True
Scheduled task installed: True
Scheduled task name: BIT-Web AutoLogin
Scheduled task state: Running
Live monitor process count: 1
Internet check: True
```

任务计划结果 `267009`（十六进制 `0x41301`）表示任务正在运行，不是错误。

## 安装预览

只查看安装计划，不复制文件、不提示凭据、不修改任务：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -WhatIf
```

## 更新已有安装

拉取新版本后重新运行同一个安装脚本：

```powershell
git pull
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

默认会保留 `%LOCALAPPDATA%\BITWebAutoLogin\credential.xml`，无需重复输入密码。

需要更换账号密码时：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -RefreshCredential
```

## 卸载后台任务

预览：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall.ps1 -WhatIf
```

实际卸载：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall.ps1
```

卸载脚本只停止并删除任务计划，保留安装目录、设置、日志和加密凭据，方便以后恢复。需要彻底清理时，请先卸载任务，再由当前用户手动删除：

```text
%LOCALAPPDATA%\BITWebAutoLogin
```

删除该目录会同时删除本机加密凭据和运行日志，请确认不再需要后再操作。

## 配置

非敏感配置位于 `settings.json`，安装时复制到运行目录。

主要选项：

- `ConnectionMode`：`Auto`、`Wifi` 或 `Ethernet`。
- `Ssid`：允许认证的 Wi-Fi 名称，默认 `BIT-Web`。
- `EthernetIpv4Prefixes`：允许认证的物理有线 IPv4 前缀，默认 `["10."]`。
- `PortalUrl`：校园网入口，默认 `http://10.0.0.55/`。
- `PollSeconds`：正常监控间隔，默认 30 秒。
- `AuthenticationCooldownSeconds`：认证后的防重复冷却，默认 300 秒。
- `MaxRetrySeconds`：认证错误的最大退避间隔，默认 1800 秒。

不要把账号或密码写入 `settings.json`。

## 项目结构

```text
.
├── Install.ps1                 # 一键安装/升级
├── Install.cmd                 # Windows 双击安装入口
├── Uninstall.ps1               # 安全卸载任务
├── AutoLogin.ps1               # 后台监控入口
├── BITWebAutoLogin.psm1        # 网络判断与认证实现
├── settings.json               # 非敏感配置
├── scripts/
│   └── Setup-Credential.ps1    # 高级用户单独更新凭据
├── tests/
│   ├── Offline.Tests.ps1       # 完全离线的逻辑测试
│   └── Test-Diagnostics.ps1    # 只读运行诊断
└── docs/
    └── 全面测试流程-v1.1.md
```

测试脚本全部位于独立的 `tests/` 目录，不会被一键安装器复制到正式运行目录。

## 开发与测试

安全预览：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\AutoLogin.ps1
```

离线回归测试：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Offline.Tests.ps1
```

完整人工验收参考 [docs/全面测试流程-v1.1.md](docs/全面测试流程-v1.1.md)。

## 安全说明

- `credential.xml` 和 `logs/` 已加入 `.gitignore`，不得提交到 GitHub。
- DPAPI 凭据只能由创建它的 Windows 用户在同一台电脑上解密。
- 登录接口目前使用 HTTP。账号密码可能以校园网既有协议要求的形式在局域网中传输；客户端脚本无法替服务端增加 HTTPS。
- 默认拒绝把凭据发送到与入口不同源的服务器。
- 如果电脑可能连接其他使用 `10.*` 地址的物理有线网络，建议收窄 `EthernetIpv4Prefixes`，或将 `ConnectionMode` 设置为 `Wifi`。
