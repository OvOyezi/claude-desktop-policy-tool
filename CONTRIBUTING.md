# 参与贡献

欢迎提交问题和改进建议。

## 开发原则

- 默认只读；任何注册表写操作都必须在明确确认之后发生。
- 删除前必须创建并验证可恢复备份。
- 不扩大到 `SOFTWARE\Policies\Claude` 之外的注册表范围。
- 所有面向普通用户的提示使用简体中文。
- 内部代码、清单字段和测试数据可以使用英文。
- 不提交真实 `.reg` 备份、API 密钥、令牌或企业设备信息。

## 提交前检查

运行：

```powershell
.\Claude-Policy-Tool.cmd --diagnose
.\Claude-Policy-Tool.cmd --self-test
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\build-release.ps1
```

自检只能使用 `HKCU\Software\ClaudePolicyToolTests` 下的随机路径，不得触碰真实 Claude 策略。
