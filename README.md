# Claude Desktop 策略解锁与恢复工具

这是一个 Windows 小工具，用来处理 Claude Desktop 第三方推理设置显示“由组织管理”、API 地址或模型无法编辑的问题。它可以检查并移除 Claude 注册表策略，或关闭当前配置的远程加载。修改前会备份，之后可以从菜单恢复。

[下载最新版](https://github.com/OvOyezi/claude-desktop-policy-tool/releases/latest) · [更新日志](CHANGELOG.md)

## 使用

需要 Windows 10 或 11，以及 Windows PowerShell 5.1。

1. 下载并解压发布页中的 ZIP，双击 `Claude-Policy-Tool.cmd`。
2. 先选“检查设置”。如果推理设置受限，保存 Claude 中的工作，再选“解除限制”并按提示确认。
3. 回到 Claude Desktop 查看推理设置。如果工具提示手动重启，请先从系统托盘完全退出应用，再重新打开。

要撤销修改，选择“恢复备份”，再选注册表策略或本地配置。

## 注意事项

如果电脑由公司或学校管理，请先取得管理员同意。组织策略可能会重新下发。

解除限制后，如果本地没有保存 API 连接信息，请在 Claude 中自行填写。备份可能包含密钥，请妥善保管。

## 反馈与贡献

遇到问题或有改进建议，欢迎[提交 Issue](https://github.com/OvOyezi/claude-desktop-policy-tool/issues)。参与开发请参阅[贡献指南](CONTRIBUTING.md)，安全问题请参阅[安全说明](SECURITY.md)。

## 许可证

[MIT License](LICENSE)
