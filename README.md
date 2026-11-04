# Claude Desktop 策略解锁与恢复工具

一个用于 Windows 的小工具。当 Claude Desktop 的第三方推理设置显示“由组织管理”，导致 API 地址或模型选项无法修改时，可以用它检查并移除本机的管理配置。

[下载最新版](https://github.com/OvOyezi/claude-desktop-policy-tool/releases/latest) · [更新日志](CHANGELOG.md)

## 功能

- 检查当前电脑上的 Claude Desktop 管理限制。
- 解锁前自动备份，之后可通过菜单恢复原有配置。
- 中文菜单，下载即可运行，全程离线。

## 使用

运行环境：Windows 10/11，Windows PowerShell 5.1。

1. 下载发布页中的 ZIP，解压后双击 `Claude-Policy-Tool.cmd`。
2. 先运行诊断，检测到需要移除的限制后，再选择解锁并按提示确认。
3. 保存当前工作，完全退出 Claude Desktop（包括系统托盘），再重新打开。

需要恢复时，在工具中选择“恢复经过校验的策略备份”。如果诊断提示“未发现策略”，则没有需要解锁的本机管理配置。

## 注意事项

公司或学校统一管理的电脑，请先取得管理员同意；相关限制可能会被自动重新设置。

移除管理配置时，其中保存的 API 地址、密钥或模型设置也会移除，需要时请在应用中重新配置。备份可能包含密钥等敏感信息，请妥善保管，勿公开上传。

## 反馈与贡献

遇到问题或有改进建议，欢迎[提交 Issue](https://github.com/OvOyezi/claude-desktop-policy-tool/issues)。参与开发请参阅[贡献指南](CONTRIBUTING.md)，安全问题请参阅[安全说明](SECURITY.md)。

## 许可证

[MIT License](LICENSE)
