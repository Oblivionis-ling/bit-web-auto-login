# 开发与维护

## 项目结构

```text
manager/BITWebManager/       WPF Native Manager
manager/BITWebUpdater/       self-update helper
manager/BITWebVersioning/    受限 Stable/RC 版本模型
scripts/                     Manager 的 PowerShell JSON bridge 与包语法检查
tests/                       PowerShell 和 Installer 隔离测试
build/Build-Release.ps1      Stable/RC self-contained 发布构建
build/New-AppIcon.ps1        生成多尺寸 Native Manager ICO
AutoLogin.ps1                后台监控循环
BITWebAutoLogin.psm1         连接判断与认证核心
Install.ps1 / Uninstall.ps1  当前用户安装和任务维护
```

Manager 只负责展示状态和编排操作。实际安装、任务、凭据和认证逻辑继续由 PowerShell 层实现；Updater 只接收已经验证并准备好的更新包。

## 环境

- Windows 10/11 x64
- Windows PowerShell 5.1
- .NET SDK `8.0.424`（允许同一 feature band 的最新 patch，见 `global.json`）
- Git

最终 Manager 和 Updater 以 `win-x64` self-contained single-file 方式发布，用户不需要安装 Git 或 .NET Desktop Runtime。

## 不变量与安全边界

- 不创建、切换、启用、禁用或修改网络适配器。
- `credential.xml` 使用当前 Windows 用户的 DPAPI；不得写入日志、Release、snapshot 或测试夹具。
- 更新源固定为 `Oblivionis-ling/bit-web-auto-login`，不接受任意仓库或 URL。
- Stable 通道只调用 `/releases/latest`，并拒绝 draft、prerelease 和非 Stable tag。
- 下载后必须继续执行 redirect allowlist、SHA-256、ZIP 路径、必要文件、manifest、版本和 PowerShell 语法校验。
- Updater 必须验证 Manager handoff，备份旧安装，并在新 Manager health-check 失败时自动回滚。
- 更新、修复和安装必须保留既有 DPAPI 凭据与用户 settings；清除凭据只能由独立的二次确认操作触发。

登录核心保护文件：

```text
AutoLogin.ps1
BITWebAutoLogin.psm1
BITWebAutoLogin.Management.psm1
Uninstall.ps1
```

修改这些文件或 `Install.ps1` 的业务语义时，必须单独审查并重新执行真实环境迁移测试。

## 版本协议

产品版本只支持：

```text
MAJOR.MINOR.PATCH
MAJOR.MINOR.PATCH-rc.N
```

其中 `N >= 1` 且不允许前导零。比较顺序为 base version 数值比较；相同 base 下 RC 小于 Stable，两个 RC 按 ordinal 数值比较。

```text
1.3.0-rc.1 < 1.3.0-rc.2 < 1.3.0 < 1.3.1-rc.1 < 1.3.1
```

Canonical Stable 版本位于：

```text
manager/Directory.Build.props
settings.json
```

Release/Product/Informational Version 表示完整 Stable 或 RC 版本；Windows Assembly/File Version 只使用四段数值，例如 `1.3.0.0`。更新比较不得读取 FileVersion。

RC 构建必须显式传入 `-ReleaseVersion`，且 base version 必须等于 canonical Stable。隐藏 `--qa-release-tag` 和 `BITWEB_RC_QA_FAIL_HEALTH_CHECK` 只允许 RC binary 使用；Stable binary 必须硬拒绝。

## 发布维护原则

1. 运行 [完整测试](TESTING.md)。
2. 从干净、已提交的源码构建 Stable，不为 Stable 传 `-ReleaseVersion`。
3. 校验 ZIP、SHA、manifest、settings、Manager/Updater ProductVersion 和 health-check。
4. tag 必须指向已经验证的源码提交。
5. Release 只上传 ZIP 与 `.sha256`；Stable 必须 `draft=false`、`prerelease=false`。
6. 发布后从 GitHub 重新下载资产并再次验证，不能只信任上传源文件。
7. 已发布 tag 和同名资产不可覆盖；修复使用新版本号。

当前非阻塞 backlog：GitHub 大文件断点续传、安全清理 helper handoff 后的 `%TEMP%` workspace、Authenticode 签名。不要把这些维护项与无关功能改动混在同一补丁中。
