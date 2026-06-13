# Claude Desktop 策略解锁与恢复工具 v1.0.0

首个公开版本。

## 主要功能

- 一键诊断 Claude Desktop 的组织管理策略来源。
- 解锁前自动创建并校验完整备份。
- 恢复后精确比对注册表内容。
- 中途失败自动回滚。
- 全简体中文交互与兼容性提示。
- 不联网、不收集遥测、不包含用户 API 配置。

## 下载

下载并解压 `Claude-Desktop-Policy-Tool-v1.0.0.zip`，然后双击 `Claude-Policy-Tool.cmd`。

建议同时下载 `SHA256SUMS.txt` 校验文件。

## 重要提醒

如果电脑受域、Entra ID、Intune、MDM 或本地组策略管理，请先获得管理员授权。策略源未解除时，注册表策略可能被重新下发。
