# 参与贡献

欢迎提交问题和改进建议。

## 开发原则

- 默认只读；任何注册表写操作都必须在明确确认之后发生。
- 策略读取失败不能视为不存在；无法确认策略状态时不得写入。
- 没有可移除策略时，解锁不得申请 UAC、创建备份或写入注册表。
- 删除前必须创建并验证可恢复备份。
- 不扩大到 `SOFTWARE\Policies\Claude` 之外的注册表范围。
- 面向普通用户的提示使用简体中文；内部代码、清单字段和测试数据可以使用英文。
- 不提交真实 `.reg` 备份、API 密钥、令牌或企业设备信息。

## 提交前检查

在项目根目录运行：

```powershell
.\Claude-Policy-Tool.cmd --diagnose
.\Claude-Policy-Tool.cmd --self-test
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\test-regressions.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\test-restore-boundaries.ps1 -ResultPath "$env:TEMP\claude-restore-tests.json"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\test-backup-paths.ps1 -ResultPath "$env:TEMP\claude-path-tests.json"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\test-runtime-edges.ps1 -ResultPath "$env:TEMP\claude-runtime-tests.json"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\test-build-boundaries.ps1 -ResultPath "$env:TEMP\claude-build-tests.json"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\build-release.ps1
```

自检只能使用 `HKCU\Software\ClaudePolicyToolTests` 下的随机路径，不得触碰真实 Claude 策略。构建脚本会删除并重建项目中的 `dist` 目录，请提前移走其中需要保留的文件。
