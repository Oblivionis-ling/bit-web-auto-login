# 测试指南

所有命令从仓库根目录运行。测试不得操作真实安装、真实计划任务或真实凭据；Installer 测试通过 `-TestMode` 使用系统临时目录。

## 快速回归

```powershell
$dotnet = "$env:LOCALAPPDATA\Microsoft\dotnet\dotnet.exe"

& $dotnet build .\manager\BITWebManager.sln --configuration Release
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Offline.Tests.ps1
```

当前 v1.3.0 基线：`.NET` 0 warnings / 0 errors，PowerShell Offline 29 passed。

## PowerShell 语法

```powershell
$failed = $false
$files = Get-ChildItem -Recurse -File -Include *.ps1,*.psm1 |
    Where-Object FullName -NotMatch '\\(?:artifacts|bin|obj|\.git)\\'

foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref]$tokens,
        [ref]$errors
    ) | Out-Null
    if ($errors.Count -gt 0) {
        $failed = $true
        $errors | ForEach-Object { Write-Error "$($file.FullName): $($_.Message)" }
    }
}
if ($failed) { exit 1 }
```

当前仓库基线为 15 个 PowerShell 文件、0 errors。CI 还会运行 `tests/Offline.Tests.ps1`。

## Stable Release 构建

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\build\Build-Release.ps1
```

输出位于 `artifacts/release/`：

```text
BITWebAutoLogin-v<version>-win-x64.zip
BITWebAutoLogin-v<version>-win-x64.zip.sha256
build-result.json
```

`artifacts/`、`bin/` 和 `obj/` 都是可重建内容，不进入 Git。

## 完整 Release 验证

```powershell
$dotnet = "$env:LOCALAPPDATA\Microsoft\dotnet\dotnet.exe"
$zip = '.\artifacts\release\BITWebAutoLogin-v1.3.0-win-x64.zip'

& $dotnet run `
  --project .\manager\BITWebManager.SmokeTests\BITWebManager.SmokeTests.csproj `
  --configuration Release --no-build -- `
  . --release-package $zip --release-version 1.3.0

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\tests\Installer.Native.Tests.ps1 -PackageZip $zip
```

当前 v1.3.0 基线：C# smoke + PackageValidator 43 passed，Native Installer 3 passed。

还必须人工核验：

- ZIP 文件名和唯一根目录版本一致；
- ZIP SHA-256 与 `.sha256` 一致；
- Manager/Updater ProductVersion 为产品版本，FileVersion 为四段数值；
- staged `settings.json` 与 `release-manifest.json` 版本一致；
- 包内无 `credential.xml`、tests、docs、snapshot、bin 或 obj；
- 解压后的 Manager `--health-check` 返回相同版本；
- Stable Manager 拒绝 `--qa-release-tag`；
- Stable Updater 拒绝 `BITWEB_RC_QA_FAIL_HEALTH_CHECK=1`。

## 真实环境测试

只有发布候选演练或正式升级验收才可操作真实环境。操作顺序固定为：

```text
只读 baseline → credential hash → settings/task/shortcut → 执行 → 再次比较 → health-check
```

不得记录或复制 credential 内容。网络下载失败若发生在 Updater handoff 前，应保持当前安装不变；切换网络或代理节点后可以重新发起一次完整下载。
