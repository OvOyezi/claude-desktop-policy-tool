# Claude Desktop 策略解锁与恢复工具 v1.0.1

发布日期：2026-11-05

## 本次更新

- 策略读取失败时停止写入。没有可移除策略时，解锁直接结束，不申请 UAC 或创建备份。
- 恢复前检查备份清单、注册表内容和路径，并导入经过校验的内容快照。备份路径必须是本地普通路径，不能通过链接重定向。
- 没有备份时，恢复直接结束；UAC 切换到不同 Windows 账户时停止，避免处理其他账户的策略。
- 修复 ClaudeCode 等相似名称导致的本地组策略误报，并改进特殊字符路径的处理和发布包构建检查。
- 含换行的 `REG_SZ` 等原生 `reg.exe` 无法完整恢复的数据会在删除策略之前被拒绝。

工具不会创建 API 或模型配置。未发现策略只说明检查范围内没有可移除的 Claude Desktop 策略，不能保证推理页面可以编辑。Claude Code 和 CC Switch 的配置不在本工具的处理范围内。

## 下载与使用

从 GitHub Release 下载 `Claude-Desktop-Policy-Tool-v1.0.1.zip`，解压后运行 `Claude-Policy-Tool.cmd`。也可以下载单独提供的 `Claude-Policy-Tool.cmd`，并使用 `SHA256SUMS.txt` 核对文件完整性。

如果电脑受域、Entra ID、Intune、MDM 或本地组策略管理，请先获得设备管理员授权。策略源未解除时，注册表策略可能被重新下发。

遇到问题时，请提供实际应用名称、版本和 `Claude-Policy-Tool.cmd --diagnose` 的输出；如果页面被锁定，请附上截图。发送前请遮挡凭据和其他敏感信息，不要公开上传策略备份。

## 测试范围

在 Windows 10 19045 AMD64 的 Windows PowerShell 5.1.19041.6456 中，分别使用 64 位和 32 位 PowerShell 进程运行测试，各通过 115 项，共 230 项。每次运行包括 8 组原有回归、8 项自检、58 项恢复边界、19 项备份路径、11 项运行边界和 11 项构建边界测试。

尚未在 Windows 11、ARM64 或 32 位 Windows 上测试，也未测试真实 Claude Desktop 图形界面和实际跨账户 UAC 对话框。
