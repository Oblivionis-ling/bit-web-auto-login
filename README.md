<div align="center">

# BIT-Web Auto Login

<code>bit-web-auto-login</code>

<br><br>

<em>让 Windows 在校园网认证失效后，安静地把公网连回来。</em>

<br><br>

[![Version](https://img.shields.io/badge/version-v1.2-2563eb?style=flat-square)](CHANGELOG.md)
[![Windows](https://img.shields.io/badge/Windows-10%20%7C%2011-0078d4?style=flat-square&logo=windows11&logoColor=white)](#系统要求)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1-5391fe?style=flat-square&logo=powershell&logoColor=white)](#系统要求)
[![PowerShell tests](https://github.com/Oblivionis-ling/bit-web-auto-login/actions/workflows/powershell-tests.yml/badge.svg)](https://github.com/Oblivionis-ling/bit-web-auto-login/actions/workflows/powershell-tests.yml)

**BIT-Web Wi-Fi · 校园网有线 · Srun 认证 · 登录后自启动 · 断线持续重试**

[快速开始](#快速开始) · [工作方式](#工作方式) · [运行与诊断](#运行与诊断) · [配置](#配置) · [安全边界](#安全边界)

</div>

---

BIT-Web Auto Login 是一个面向 Windows 的校园网后台认证脚本。Windows 负责连接已经保存的 Wi-Fi 或有线网络；本项目只判断当前连接是否符合条件，并在公网认证失效时提交网页登录。

它支持精确匹配 `BIT-Web` Wi-Fi，也支持 IPv4 地址命中允许前缀的活动物理有线网卡。默认 `Auto` 模式会优先识别 Wi-Fi，再检查校园网有线连接。

> 脚本不会创建、切换、启用、禁用或修改网卡，也不会替 Windows 连接 Wi-Fi。

## 它解决什么

- Windows 用户登录后，由任务计划程序启动一个隐藏的常驻监控进程。
- 同时使用 Microsoft 和 Firefox 两个 HTTP 地址探测公网；任意一个成功即视为在线。
- 只有连续两轮探测全部失败，才会读取凭据并提交认证，减少瞬时抖动造成的误登录。
- 自动处理深澜（Srun）challenge、HMAC-MD5、SHA-1 和 SRBX1 流程。
- 对非 Srun 页面，可自动解析普通 HTML 登录表单，也可在 `settings.json` 中显式配置接口和字段。
- 认证成功后复核公网；请求出错时按 `30s → 60s → 120s …` 指数退避，最长间隔 30 分钟，并持续尝试。

## 快速开始

### 系统要求

- Windows 10 或 Windows 11。
- Windows PowerShell 5.1。
- Windows 已经保存并能够连接 `BIT-Web`，或已经接入符合配置的校园网有线网络。
- 当前用户可以使用任务计划程序；安装任务以当前用户、有限权限运行。

### 1. 获取项目

```powershell
git clone https://github.com/Oblivionis-ling/bit-web-auto-login.git
cd bit-web-auto-login
```

也可以在 GitHub 页面选择 **Code → Download ZIP**，解压后进入项目目录。

### 2. 一键安装

直接双击 `Install.cmd`，或在 PowerShell 中执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

首次安装会弹出 Windows 凭据输入框。安装器会：

1. 校验 v1.2 的运行文件和配置版本。
2. 将 `AutoLogin.ps1`、`BITWebAutoLogin.psm1`、`settings.json` 复制到 `%LOCALAPPDATA%\BITWebAutoLogin`。
3. 创建或复用 `credential.xml`；密码由当前 Windows 用户的 DPAPI 加密。
4. 注册当前用户登录时启动的 `BIT-Web AutoLogin` 任务，并防止重复实例。
5. 通过无窗口启动器启动监控，避免 Windows 11 登录时弹出 PowerShell 控制台；默认立即启动任务、确认其进入 `Running` 状态，并移除旧版任务。

安装过程不会复制测试、文档、仓库日志或临时文件到正式运行目录。

### 3. 验证安装

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Diagnostics.ps1 -IncludeInternetCheck -LogTail 50
```

正常安装且当前位于符合条件的校园网时，关键结果应类似：

```text
Settings version: 1.2
Eligible connection: True
Scheduled task installed: True
Scheduled task name: BIT-Web AutoLogin
Scheduled task state: Running
Live monitor process count: 1
Internet check: True
```

任务结果 `267009`（`0x41301`）表示任务正在运行，不是失败代码。

## 工作方式

| 阶段 | v1.2 的实际行为 |
|---|---|
| 连接筛选 | `Wifi` 仅接受精确 SSID；`Ethernet` 仅接受活动物理有线网卡及允许的 IPv4 前缀；`Auto` 依次尝试两者 |
| 公网探测 | 默认每 30 秒检查两个地址，任意一个返回预期文本即视为在线 |
| 断网确认 | 首轮全失败后等待 10 秒；连续 2 轮全失败才允许认证 |
| 提交认证 | 优先识别并执行 Srun 流程，否则使用显式接口配置或解析 HTML 表单 |
| 登录复核 | 首次等待 5 秒，最多验证 4 次；后续验证间隔 5 秒 |
| 防重复 | 认证接口接受请求后进入 300 秒冷却，期间不重复提交 |
| 错误重试 | 从 30 秒开始指数退避，最高 1800 秒；达到上限后仍持续尝试 |
| 日志 | 按天写入，默认保留 14 天；相同状态不会每轮重复记录 |

只有当连接符合条件、公网探测确认失败且不处于冷却或退避期时，程序才加载本机凭据。

## 运行与诊断

### 安全预览

不发送网络请求、不读取凭据、不修改网络设置：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\AutoLogin.ps1
```

### 单次实际检查

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\AutoLogin.ps1 -Live -Once
$LASTEXITCODE
```

`-Once` 的退出码：

| 退出码 | 含义 |
|---:|---|
| `0` | 公网原本正常，或认证后已经恢复 |
| `2` | 当前没有符合条件的校园网连接 |
| `3` | 认证请求失败，或认证后的公网验证仍失败 |

### 前台持续监控

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\AutoLogin.ps1 -Live
```

安装后的正式任务使用同一 `-Live` 模式，只是以隐藏窗口运行。

### 只读诊断

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Diagnostics.ps1
```

附加当前公网检查并显示最新 100 行日志：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Diagnostics.ps1 -IncludeInternetCheck -LogTail 100
```

诊断脚本只读取连接资格、任务状态、监控进程和日志；`-IncludeInternetCheck` 会发送配置中的公网探测请求，但不会修改网卡。

### 临时覆盖连接模式

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\AutoLogin.ps1 -Live -Once -ConnectionMode Wifi
```

`-ConnectionMode` 接受 `Auto`、`Wifi`、`Ethernet`。高级用户还可以用 `-ConfigPath` 和 `-CredentialPath` 指定其他配置或凭据路径。

## 更新、凭据与卸载

### 更新现有安装

```powershell
git pull
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

重新安装会保留正式运行目录中的加密凭据。需要更换校园网账号或密码时：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -RefreshCredential
```

安装到其他目录，或只注册任务但不立即启动：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -InstallDirectory "D:\BITWebAutoLogin"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -NoStart
```

只预览安装计划：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -WhatIf
```

高级用户也可以单独创建或更新 DPAPI 凭据：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Setup-Credential.ps1
```

### 卸载后台任务

```powershell
# 预览
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall.ps1 -WhatIf

# 实际卸载
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall.ps1
```

卸载脚本只停止并移除 `BIT-Web AutoLogin` 及兼容的旧版任务，保留运行文件、设置、日志和凭据。若确认不再需要，可在卸载后手动删除 `%LOCALAPPDATA%\BITWebAutoLogin`。

## 配置

非敏感配置保存在 [`settings.json`](settings.json)，安装时会复制到正式运行目录。

| 配置项 | 默认值 | 用途 |
|---|---:|---|
| `ConnectionMode` | `Auto` | 连接筛选模式：`Auto`、`Wifi`、`Ethernet` |
| `Ssid` | `BIT-Web` | 允许认证的 Wi-Fi SSID |
| `EthernetIpv4Prefixes` | `["10."]` | 允许认证的物理有线 IPv4 前缀 |
| `PortalUrl` | `http://10.0.0.55/` | 校园网认证入口 |
| `ConnectivityChecks` | 2 个地址 | 公网探测地址及预期文本 |
| `PollSeconds` | `30` | 正常轮询间隔 |
| `InternetFailureConfirmations` | `2` | 认证前要求的连续失败轮数 |
| `FailureConfirmationIntervalSeconds` | `10` | 两轮断网确认之间的等待时间 |
| `InitialRetrySeconds` | `30` | 认证错误后的初始退避时间 |
| `MaxRetrySeconds` | `1800` | 最大退避时间，即 30 分钟 |
| `AuthenticationCooldownSeconds` | `300` | 认证请求后的防重复冷却时间 |
| `PostLoginWaitSeconds` | `5` | 首次登录后验证前等待时间 |
| `PostLoginVerifyAttempts` | `4` | 登录后的公网验证次数 |
| `PostLoginVerifyIntervalSeconds` | `5` | 后续公网验证间隔 |
| `RequestTimeoutSeconds` | `8` | 单次 HTTP 请求超时 |
| `LogRetentionDays` | `14` | 日志保留天数 |

普通 HTML 表单需要显式配置时，可使用 `LoginEndpoint`、`LoginMethod`、`UsernameField`、`PasswordField` 和 `ExtraFields`。跨源登录地址默认由 `AllowCrossOriginLoginEndpoint: false` 拒绝。

修改仓库中的 `settings.json` 后，需要重新运行 `Install.ps1` 才会复制到正式运行目录。不要把账号或密码写入该文件。

## 安全边界

- `credential.xml` 与 `logs/` 已加入 `.gitignore`，不会作为项目文件提交。
- `credential.xml` 的用户名在 XML 中可见，密码由 Windows DPAPI 保护，只能由创建它的 Windows 用户在同一台电脑上解密。
- 默认拒绝把凭据发送到与 `PortalUrl` 不同源的登录地址。
- 默认入口使用 HTTP。脚本会显示警告，但无法替校园网服务端增加 HTTPS；认证数据仍需按既有校园网协议传输。
- 有线筛选默认允许 `10.*`。如果电脑可能连接其他使用该地址段的物理有线网络，请收窄 `EthernetIpv4Prefixes`，或改用 `Wifi` 模式。
- 日志记录状态、HTTP 状态码和错误信息，不记录认证请求正文或完整响应正文。

## 项目结构

```text
.
├── Install.cmd                      # 可双击的一键安装入口
├── Install.ps1                      # 当前用户安装与升级
├── Uninstall.ps1                    # 停止并移除任务
├── AutoLogin.ps1                    # 监控循环与状态日志
├── RunHidden.vbs                    # 任务计划的无窗口启动器
├── BITWebAutoLogin.psm1             # 连接判断、表单与 Srun 认证实现
├── settings.json                    # 非敏感运行配置
├── scripts/
│   └── Setup-Credential.ps1         # 单独创建 DPAPI 凭据
├── tests/
│   ├── Offline.Tests.ps1            # 完全离线的逻辑回归测试
│   └── Test-Diagnostics.ps1         # 只读运行诊断
├── docs/
│   └── 全面测试流程-v1.1.md          # 人工验收流程
└── .github/workflows/
    └── powershell-tests.yml         # Windows CI
```

测试与文档保持在独立目录，不会被安装器复制到正式运行目录。

## 开发与测试

运行完全离线的回归测试：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Offline.Tests.ps1
```

该测试覆盖表单解析、凭据载荷、同源保护、Srun 编码向量、连接筛选、断网决策、重试上限、安装预览和防止修改网卡等逻辑。GitHub Actions 会在 `main`、`agent/**` 推送和 Pull Request 上解析所有 PowerShell 源码并执行同一组离线测试。

需要进行真实断网、睡眠唤醒、重启和长期运行验收时，请按 [`docs/全面测试流程-v1.1.md`](docs/全面测试流程-v1.1.md) 操作。测试中的断网、注销认证、插拔网线或切换 Wi-Fi 必须由使用者手动完成。

---

<div align="center">

<sub>BIT-Web Auto Login v1.2 · Windows 当前用户后台任务</sub>

</div>
