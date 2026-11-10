# Claude Desktop 策略解锁与恢复工具 v1.1.0

2026-11-10

## 本次更新

从远程服务加载的推理设置在 Claude Desktop 中是只读的，即使本机没有注册表策略。选择“检查设置”可以查看当前配置是否启用了远程加载，应用正在运行时也会有提示。

- 没有注册表策略且远程配置已开启时，选择“解除限制”可以备份当前配置并关闭远程加载。若本地没有保存 API 连接信息，请在 Claude 中自行填写。
- 可以按提示完全退出并重新打开 Claude Desktop，让应用重新读取配置。检测到应用由另一个 Windows 账户运行时，工具会提示切换到该账户。
- “恢复备份”菜单可选择注册表策略或本地配置。

## 下载与使用

下载 `Claude-Desktop-Policy-Tool-v1.1.0.zip`，解压后双击 `Claude-Policy-Tool.cmd`。也可以直接下载单独提供的 `Claude-Policy-Tool.cmd`。用 `SHA256SUMS.txt` 可以校验 ZIP 和脚本的完整性。
