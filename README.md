# Claude Desktop 策略解锁与恢复工具

一个面向 Windows 的单文件批处理工具，用来诊断、备份、移除和恢复导致 Claude Desktop 第三方推理配置显示“由组织管理”的注册表策略。

本项目不是 Anthropic 官方产品，也不隶属于 Anthropic。它只处理以下注册表范围：

```text
HKLM\SOFTWARE\Policies\Claude
HKCU\SOFTWARE\Policies\Claude
```

不会修改 `ClaudeCode` 策略、第三方 API 地址、API 密钥、模型配置或其他软件的组策略。

## 适用场景

Claude Desktop 的第三方推理页面出现以下情况：

- 显示 `Organization-managed` 或“此配置由组织管理”。
- 网关地址、凭据类型和模型设置均被锁定。
- 个人电脑上曾经导入过 Claude Desktop 企业策略。
- 需要在解除策略后，保留一份可验证、可恢复的原始策略备份。

如果电脑确实受公司域、Microsoft Entra ID、Intune、MDM 或本地组策略管理，请先获得设备管理员授权。策略可能在组策略刷新或重启后重新下发。

## 下载

推荐从 GitHub 的 **Releases** 页面下载，不要使用来源不明的转载文件。

1. 打开仓库右侧的 **Releases**。
2. 进入最新版本。
3. 下载 `Claude-Desktop-Policy-Tool-v1.0.0.zip`。
4. 解压 ZIP，不要直接在压缩包预览窗口中运行。
5. 可使用发布页提供的 `SHA256SUMS.txt` 核对文件完整性。

也可以直接下载 Release 附件中的 `Claude-Policy-Tool.cmd`。

## 系统要求

| 项目 | 要求 |
| --- | --- |
| 操作系统 | Windows 10 或 Windows 11 |
| PowerShell | Windows PowerShell 5.1 |
| 权限 | 检查无需管理员权限；解锁和恢复需要 UAC 管理员授权 |
| 架构 | x64、ARM64；32 位 Windows 仅提供兼容处理，不是主要测试环境 |
| 其他组件 | Windows 自带的 `reg.exe` 和 PowerShell JSON 组件 |

Claude Desktop 官方要求 Windows 10 或更高版本。工具会在写入前检查必要组件；缺少组件时只显示中文诊断和修复建议，不删除注册表。

## 使用教程

### 1. 先运行诊断

双击 `Claude-Policy-Tool.cmd`，选择：

```text
1. 运行环境与策略诊断（只读，建议先运行）
```

诊断会显示：

- Windows 和 PowerShell 版本。
- 系统架构与管理员状态。
- Claude Desktop 是否已安装。
- HKLM/HKCU 的 32 位和 64 位策略状态。
- 是否检测到域、Entra ID、MDM 或本地 `Registry.pol`。
- 备份保存位置和无法安全继续的兼容问题。

### 2. 解锁第三方推理设置

选择：

```text
2. 解锁 Claude Desktop 第三方推理设置
```

工具会按照以下顺序执行：

1. 检查必要组件和备份目录。
2. 请求管理员权限。
3. 显示将要处理的策略范围。
4. 如果设备受组织管理，要求额外确认已获得管理员授权。
5. 要求输入 `确认解锁`。
6. 完整导出策略、生成清单和 SHA-256 校验值。
7. 校验备份后才删除精确的 Claude 策略键。
8. 再次确认策略确实消失。

成功后，请保存工作，完全退出 Claude Desktop（包括系统托盘），再手动重新打开。工具不会强制结束 Claude，避免造成会话或未保存内容丢失。

### 3. 恢复原始策略

选择：

```text
3. 恢复经过校验的策略备份
```

恢复前，工具会先备份当前状态。随后它会：

- 验证备份清单和 SHA-256。
- 拒绝包含允许范围之外注册表路径的文件。
- 恢复值、值类型和子项。
- 重新导出并逐文件比对恢复结果。
- 发生中途错误时，自动回滚到恢复前状态。

跨电脑恢复会显示额外警告，并要求输入 `确认跨设备恢复`。

## 备份位置与隐私

备份默认保存在：

```text
%LOCALAPPDATA%\ClaudePolicyTool\Backups
```

策略中可能含有网关地址、自定义请求头、令牌或其他管理员配置，因此：

- 不要把 `Backups` 目录提交到 GitHub。
- 不要把备份发送给不可信的人。
- 发布 ZIP 不包含任何本机备份或 API 配置。
- 工具不联网、不上传文件，也不收集遥测。

SHA-256 清单用于发现意外损坏或未同步修改，不是数字签名。即使有人重新生成清单，工具仍会阻止导入 Claude 策略范围之外的注册表路径。

## 安全设计

- 默认入口是只读诊断。
- 写操作前必须完成备份并通过校验。
- 只删除 `SOFTWARE\Policies\Claude`，不会删除父级 `Policies`。
- 不处理 `SOFTWARE\Policies\ClaudeCode`。
- 恢复前再次创建安全备份。
- 删除或恢复失败时尝试事务回滚。
- 检测备份目录符号链接和目录联接，防止备份被重定向。
- 不自动终止 Claude Desktop。
- 测试仅使用随机的 `HKCU\Software\ClaudePolicyToolTests` 路径，并在结束后清理。

## 常见问题

### 提示缺少 Windows PowerShell 5.1

使用“启用或关闭 Windows 功能”、DISM 或系统修复功能恢复 Windows PowerShell。不要从未知网站下载替代版 `powershell.exe`。

### 提示缺少 `reg.exe` 或 JSON 组件

以管理员身份运行：

```powershell
DISM /Online /Cleanup-Image /RestoreHealth
sfc /scannow
```

完成后重启 Windows，再运行诊断。

### 解锁后策略再次出现

电脑可能受域、Intune、MDM 或本地组策略管理。联系设备管理员解除策略源；单独删除注册表值通常只会暂时生效。

### Windows 安全策略阻止脚本

请确认文件来自本仓库的 GitHub Release，并核对 SHA-256。如果电脑由组织管理，请联系管理员，不要绕过组织安全策略。

### 中文显示异常

工具会自动切换 UTF-8。仍有乱码时，建议在最新 Windows 10/11 的“命令提示符”或 Windows Terminal 中运行，并确认使用支持中文的字体。

## 命令行参数

```text
Claude-Policy-Tool.cmd --diagnose
Claude-Policy-Tool.cmd --status
Claude-Policy-Tool.cmd --unlock
Claude-Policy-Tool.cmd --restore
Claude-Policy-Tool.cmd --self-test
Claude-Policy-Tool.cmd --help
```

## 构建发布包

仓库维护者可以运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\build-release.ps1
```

脚本会规范化 `.cmd` 的 UTF-8/CRLF 格式、运行隔离自检、生成 ZIP 和 `SHA256SUMS.txt`。

## 官方资料

- [安装 Claude Desktop](https://support.claude.com/en/articles/10065433-install-claude-desktop)
- [Windows 企业配置](https://support.claude.com/en/articles/12622667-enterprise-configuration-for-claude-desktop)
- [Windows 部署说明](https://support.claude.com/en/articles/12622703-deploy-claude-desktop-for-windows)

## 许可证

[MIT License](LICENSE)
