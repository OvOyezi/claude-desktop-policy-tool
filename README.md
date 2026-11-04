# Claude Desktop 策略解锁与恢复工具

一个 Windows 单文件批处理工具，用于诊断、备份、移除和恢复导致 Claude Desktop 第三方推理配置显示“由组织管理”的注册表策略。

本项目不是 Anthropic 官方产品，也不隶属于 Anthropic。工具只处理以下注册表路径，按系统环境检查 HKLM 和 HKCU 的相应 32 位、64 位视图：

```text
HKLM\SOFTWARE\Policies\Claude
HKCU\SOFTWARE\Policies\Claude
```

工具不会修改 `ClaudeCode` 策略或其他软件的组策略，也不会创建 API 地址、API 密钥或模型配置，或编辑 Claude Code、CC Switch 的配置文件。CC Switch 也支持管理 Claude Desktop 的第三方推理配置，本工具不会创建或修改这类配置文件。目标策略中如果包含地址、凭据或模型设置，移除策略时这些设置也会被移除。

## 适用场景

如果 Claude Desktop 的第三方推理页面显示 `Organization-managed` 或“此配置由组织管理”，或网关地址、凭据类型和模型设置被锁定，可以先使用本工具检查。个人电脑曾导入 Claude Desktop 企业策略时，也可以检查并决定是否备份和移除策略。

如果电脑受公司域、Microsoft Entra ID、Intune、MDM 或本地组策略管理，请先获得设备管理员授权。策略可能在组策略刷新或重启后重新下发。

## 下载

当前版本：v1.0.1（2026-11-05）。

1. 打开本仓库的 [最新发布页面](https://github.com/OvOyezi/claude-desktop-policy-tool/releases/latest)。
2. 下载发布页列出的 ZIP 文件，解压后再运行，不要在压缩包预览窗口中直接运行。
3. 可使用发布页提供的 `SHA256SUMS.txt` 核对文件完整性。

也可以直接下载 Release 附件中的 `Claude-Policy-Tool.cmd`。请勿使用来源不明的转载文件。

## 系统要求与测试范围

| 项目 | 要求 |
| --- | --- |
| 操作系统 | Windows 10 或 Windows 11 |
| PowerShell | Windows PowerShell 5.1 |
| 权限 | 诊断无需管理员权限；解锁和恢复需要写入注册表时需要管理员权限 |
| 架构 | 面向 x64 和 ARM64；32 位 Windows 提供兼容处理，实际测试范围见下文 |
| 其他组件 | Windows 自带的 `reg.exe` 和 PowerShell JSON 组件 |

Claude Desktop 官方要求 Windows 10 或更高版本。工具会在写入前检查必要组件；缺少组件时显示中文诊断和修复建议，不删除注册表。

已在 Windows 10 19045（AMD64）虚拟机上使用 Windows PowerShell 5.1.19041.6456 测试：x64 和 x86 PowerShell 进程各通过 115 项，共 230 项。Windows 11、ARM64、32 位 Windows 操作系统和真实 Claude Desktop 图形界面尚未测试。自检仅使用随机的 `HKCU\Software\ClaudePolicyToolTests` 注册表路径，并在结束后清理。

## 使用教程

### 1. 运行诊断

双击 `Claude-Policy-Tool.cmd`，选择：

```text
1. 运行环境与策略诊断（只读，建议先运行）
```

诊断会显示 Windows 和 PowerShell 版本、进程架构、系统位数、管理员状态、Claude Desktop 安装检测结果，以及 HKLM/HKCU 的 32 位和 64 位策略状态。它还会检查域、Entra ID、MDM 和本地 `Registry.pol` 管理迹象，并显示备份位置及无法安全继续的兼容问题。

### 2. 解锁第三方推理设置

选择：

```text
2. 解锁 Claude Desktop 第三方推理设置
```

工具按以下顺序执行：

1. 读取指定范围内的策略。任何目标读取失败时停止写入，不将错误视为策略不存在。
2. 如果所有目标均可读取且没有策略，提示后结束，不申请 UAC、创建备份或修改注册表。
3. 发现策略时，显示处理范围、确认管理员权限，并检查运行环境和备份条件。
4. 如果设备受组织管理，要求额外确认已获得管理员授权。
5. 要求输入 `确认解锁`。
6. 导出策略，生成清单和 SHA-256 校验值；备份通过校验后，才删除目标 Claude 策略键。
7. 再次检查策略是否已移除。

成功后请保存工作，完全退出 Claude Desktop（包括系统托盘），再手动重新打开。工具不会强制结束 Claude，以免丢失会话或未保存的内容。

### 3. 恢复原始策略

选择：

```text
3. 恢复经过校验的策略备份
```

工具会备份恢复前的当前状态，并使用经过验证的备份恢复：

- 验证清单字段的类型和 SHA-256，以及每个注册表段落和数据行。
- 拒绝包含允许范围之外的注册表路径、删除指令或无法识别内容的文件。
- 使用校验时保存的内容快照导入；源文件在校验后发生变化不会改变导入内容。
- 恢复值、值类型和子项，再重新导出并逐文件比对。
- 中途出错时，尝试回滚到恢复前的状态。

跨电脑恢复会显示额外警告，并要求输入 `确认跨设备恢复`。没有备份时，操作直接结束，不申请 UAC 或创建备份目录。通过 UAC 使用不同 Windows 账户（账户 SID 不同）时，工具会停止，以免处理错误账户的 HKCU 策略或备份；请由设备管理员在需要处理策略的账户上下文中操作。

恢复只接受符合本工具备份规范的 `reg.exe export` UTF-16LE 格式，并校验注册表内容和数据类型。原生 `reg.exe` 无法完整往返的内容（例如含换行的 `REG_SZ`）会在删除策略前被拒绝，现有策略保持不变。请勿手工修改备份来绕过校验。

## 备份与安全

备份默认保存在：

```text
%LOCALAPPDATA%\ClaudePolicyTool\Backups
```

策略可能包含网关地址、自定义请求头、令牌或其他管理员配置。请勿将 `Backups` 目录提交到 GitHub，也不要把备份发送给不可信的人。发布 ZIP 不包含本机备份或 API 配置；工具不联网、不上传文件，也不收集遥测。

SHA-256 清单用于发现意外损坏或未同步修改，不是数字签名。即使有人重新生成清单，工具仍会阻止导入 Claude 策略范围之外的注册表路径。

工具只删除 `SOFTWARE\Policies\Claude`，不会删除父级 `Policies`，也不处理 `SOFTWARE\Policies\ClaudeCode`。写入注册表前必须完成备份并通过校验；删除或恢复失败时会尝试回滚。工具还会检查备份根目录、所有父目录、所选目录和备份文件的重解析点，拒绝符号链接或目录联接造成的重定向；备份必须位于本地普通路径。

## 常见问题

### 为什么选择解锁后提示未发现策略？

这表示所有目标均已成功读取，但在指定的 Claude Desktop 策略范围内没有找到可移除的策略。它不代表应用的推理页面一定可以编辑，工具也不会自动创建 API 或模型配置。如果诊断提示读取失败，请先处理错误，再重新诊断。

确认实际使用的应用及版本。如果是 Claude Desktop，请检查相关页面和组织管理状态，参考 [Claude Desktop 企业配置文档](https://support.claude.com/en/articles/12622667-enterprise-configuration-for-claude-desktop)或联系设备管理员。Claude Code 的设置请参考 [Claude Code 文档](https://code.claude.com/docs/en/settings)；如果通过 CC Switch 管理配置，也可查看 [CC Switch 项目](https://github.com/farion1231/cc-switch)。

仍需帮助时，请提供应用名称、版本和 `Claude-Policy-Tool.cmd --diagnose` 的输出；如果页面被锁定，请附上截图。发送前请遮挡 API 密钥、令牌、网关地址等敏感信息，不要公开上传策略备份。

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

确认文件来自本仓库的 GitHub Release，并核对 SHA-256。如果电脑由组织管理，请联系管理员，不要绕过组织安全策略。

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

脚本会规范化 `.cmd` 的 UTF-8/CRLF 格式、运行隔离自检，生成 ZIP 和 `SHA256SUMS.txt`。

## 官方资料

- [安装 Claude Desktop](https://support.claude.com/en/articles/10065433-install-claude-desktop)
- [Windows 企业配置](https://support.claude.com/en/articles/12622667-enterprise-configuration-for-claude-desktop)
- [Windows 部署说明](https://support.claude.com/en/articles/12622703-deploy-claude-desktop-for-windows)
- [Claude Code 设置文件](https://code.claude.com/docs/en/settings)

## 许可证

[MIT License](LICENSE)
