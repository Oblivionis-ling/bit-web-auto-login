# BIT-Web 自动登录 v1.0

这是一个面向 Windows 的校园网 Web 认证脚本。它支持校园网有线连接和 `BIT-Web` Wi‑Fi；在符合安全条件的连接上检测到公网不可用时，尝试登录 `http://10.0.0.55/`。

准备启用长期运行前，请按 [全面测试流程-v1.0.md](./全面测试流程-v1.0.md) 完成验收。

## v1.0 的安全边界

- 不创建、删除或修改任何有线或 Wi‑Fi 配置。
- 不调用网卡连接、断开、启用或禁用命令，不会主动切换当前网络。
- Windows 负责按已有配置自动连回 `BIT-Web`，脚本只处理网页认证。
- 有线模式只接受活动的物理以太网网卡，并要求 IPv4 地址匹配配置的安全前缀，默认是校园网使用的 `10.*`。
- 默认运行 `AutoLogin.ps1` 是安全预览模式，不访问网络、不读取凭据。
- 只有显式添加 `-Live` 才会进行公网检测和校园网认证。
- 自动启动安装器默认也只预览，只有显式添加 `-Apply` 才会创建任务计划。
- 登录接口只能与入口网址同源，防止账号密码被意外发送到其他服务器。
- 使用 Microsoft 与 Firefox 两个独立公网探测地址，任一成功即视为在线。
- 只有连续两轮探测都失败才提交认证；认证接口接受后进入 5 分钟冷却。
- 登录后会多次验证公网恢复，避免瞬时探测失败造成重复登录。

本版本已识别学校使用的深澜（Srun）JavaScript 认证流程，支持 challenge、HMAC‑MD5、SHA‑1 和 SRBX1 参数计算；同时保留普通 HTML 表单兼容路径。

## 文件说明

- `AutoLogin.ps1`：主监控脚本，版本 v1.0。
- `BITWebAutoLogin.psm1`：HTML 表单识别、请求构造、联网检测和重试逻辑。
- `settings.json`：非敏感配置，不含账号密码。
- `Setup-Credential.ps1`：由用户手动创建 DPAPI 加密凭据。
- `Install-AutoStart.ps1`：由用户手动安装“登录 Windows 后启动”的任务计划。
- `Uninstall-AutoStart.ps1`：由用户手动卸载任务计划。
- `tests/Offline.Tests.ps1`：完全离线的逻辑测试。

## 回来后的推荐测试顺序

先打开 PowerShell 并进入本文件夹。以下每一步都需要你亲自执行。

### 1. 安全预览

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\AutoLogin.ps1
```

该命令不会发出网络请求，也不会读取账号密码。

默认连接模式为 `Auto`。可以在命令行临时指定：

```powershell
# 有线或 BIT-Web Wi-Fi 均可
.\AutoLogin.ps1 -ConnectionMode Auto

# 只允许 BIT-Web Wi-Fi
.\AutoLogin.ps1 -ConnectionMode Wifi

# 只允许符合安全前缀的物理有线网卡
.\AutoLogin.ps1 -ConnectionMode Ethernet
```

也可以修改 `settings.json` 中的 `ConnectionMode`，可选值为 `Auto`、`Wifi`、`Ethernet`。`EthernetIpv4Prefixes` 默认为 `["10."]`。

### 2. 保存加密凭据

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup-Credential.ps1
```

密码由 Windows DPAPI 加密，只能由当前 Windows 用户在当前电脑上解密；账号会显示在 `credential.xml` 中。请不要把该文件发给他人。

### 3. 在场进行一次真实测试

确认电脑已经连到 `BIT-Web`，然后运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\AutoLogin.ps1 -Live -Once
```

退出码含义：

- `0`：公网原本正常，或认证后已恢复。
- `2`：当前没有符合所选模式的连接，脚本没有发送认证信息。
- `3`：认证失败，查看 `logs` 下当天的日志。

日志不会主动记录账号、密码、表单内容或完整响应正文。

### 4. 预览并安装自动启动

先预览，不修改系统：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-AutoStart.ps1
```

确认单次真实测试成功后，再由你安装：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-AutoStart.ps1 -Apply
```

该任务会在当前用户登录 Windows 时启动常驻监控。监控每 30 秒检查一次；认证请求本身失败后从 30 秒开始指数退避，最长等待 30 分钟，达到上限后仍会每 30 分钟持续尝试。默认 `Auto` 模式会接受符合安全条件的校园网有线连接或 `BIT-Web` Wi‑Fi。Wi‑Fi 完全断开时只等待 Windows 自动重连。

### 5. 卸载自动启动

预览：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall-AutoStart.ps1
```

实际卸载：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall-AutoStart.ps1 -Apply
```

卸载只删除任务计划，不会删除凭据、脚本或日志。

## 登录页兼容性

默认情况下，脚本先读取入口页。检测到深澜（Srun）页面时，会按照页面自身使用的 challenge、HMAC‑MD5、SHA‑1 和 SRBX1 流程调用同源认证接口；否则寻找普通 HTML `<form>`，保留隐藏字段和提交按钮字段，再向同源 `action` 地址提交。

如果日志显示无法识别表单，需要根据浏览器开发者工具中正常登录请求填写 `settings.json`：

- `LoginEndpoint`：登录接口相对路径或同源完整地址。
- `LoginMethod`：`GET` 或 `POST`，通常是 `POST`。
- `UsernameField`：账号参数名。
- `PasswordField`：密码参数名。
- `ExtraFields`：运营商、登录动作等固定参数。

不要把账号或密码直接写入 `settings.json`。跨源登录默认被拒绝；不建议开启 `AllowCrossOriginLoginEndpoint`。

## 已知安全提示

入口地址目前配置为 HTTP。如果网页登录本身也是 HTTP，账号密码可能以未加密形式在校园网内传输。脚本无法修复服务端未提供 HTTPS 的问题，只会复现正常网页登录流程。
