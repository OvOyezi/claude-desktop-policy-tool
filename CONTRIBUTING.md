# 参与贡献

欢迎提交问题和改进建议。

## 开发原则

- 诊断保持只读。修改注册表或本地配置前，须经用户明确确认，并创建、验证可恢复的备份。
- 策略读取失败时停止写操作。确认没有注册表策略后，才能按本地配置的流程解锁，且无需申请 UAC。
- 注册表操作限定在 `SOFTWARE\Policies\Claude`。修改本地配置时，只处理受支持的 `Claude-3p\configLibrary` 中当前已应用的配置。
- 重启前确认 Claude Desktop 进程的身份和运行账户。
- 用户提示使用简体中文，内部代码、清单字段和测试数据可以使用英文。
- 不提交真实的注册表或本地配置备份、API 密钥、令牌及企业设备信息。

## 提交前检查

在项目根目录运行以下命令。

```powershell
.\Claude-Policy-Tool.cmd --diagnose
.\Claude-Policy-Tool.cmd --self-test
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\test-regressions.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\test-restore-boundaries.ps1 -ResultPath "$env:TEMP\claude-restore-tests.json"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\test-backup-paths.ps1 -ResultPath "$env:TEMP\claude-path-tests.json"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\test-runtime-edges.ps1 -ResultPath "$env:TEMP\claude-runtime-tests.json"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\test-local-config.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\test-build-boundaries.ps1 -ResultPath "$env:TEMP\claude-build-tests.json"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\build-release.ps1
```

注册表自检只使用 `HKCU\Software\ClaudePolicyToolTests` 下的随机路径。本地配置测试使用临时目录中的测试文件。构建脚本会删除并重建项目中的 `dist` 目录，请提前移走其中需要保留的文件。
