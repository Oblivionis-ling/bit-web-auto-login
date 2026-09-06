# 项目文档

这里仅保留维护当前 Stable 版本所需的文档。阶段任务书、RC checklist、过程截图和旧版 README 已在 `v1.3.0` 发布完成后清理；完整提交历史仍可通过 Git 查看。

## 当前文档

- [开发与维护](DEVELOPMENT.md)：架构、边界、版本协议和发布维护原则。
- [测试指南](TESTING.md)：本地测试、Release 构建和包验证命令。
- [v1.3.0 发布报告](releases/v1.3.0.md)：最终源码、资产哈希、真实升级和发布验收记录。
- [CHANGELOG](../CHANGELOG.md)：面向用户的版本变化。
- [README](../README.md)：安装、使用、安全边界和 FAQ。

## 文档维护规则

1. README 与 CHANGELOG 面向普通用户，不加入 RC 调试参数和阶段过程。
2. 长期有效的开发约束更新到 `DEVELOPMENT.md` 或 `TESTING.md`。
3. 每个正式版本最多保留一份最终发布报告；临时 checklist、截图和本机 snapshot 不进入仓库。
4. `credential.xml`、本机任务导出、安装目录 manifest、日志和用户路径信息不得进入文档或 Git。
