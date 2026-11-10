# 安全说明

## 支持范围

当前维护版本为 `1.x`。请优先使用 GitHub Releases 中的最新版本。

## 报告安全问题

本仓库目前未启用 GitHub 私密漏洞报告功能。如需报告，请先提交一条不含漏洞细节和敏感信息的联系请求，与维护者确认私下报告方式。[提交 Issue](https://github.com/OvOyezi/claude-desktop-policy-tool/issues/new)

公开 Issue 请省略以下信息。

- 注册表或本地配置备份
- API 密钥、令牌或自定义请求头
- 企业域、MDM 或设备身份信息
- 包含用户名和内部路径的完整日志

报告中可以提供已经脱敏的错误信息、Windows 版本、PowerShell 版本和复现步骤。

## 安全边界

本地配置备份保存在 `%LOCALAPPDATA%\ClaudePolicyTool\LocalConfigBackups`，可能包含服务地址、请求头和凭据。恢复时会核对文件的 SHA-256、当前电脑、Windows 账户和配置目录。

已取得当前用户或管理员权限的恶意程序仍可修改配置和备份。SHA-256 清单用于完整性检查，不构成发布者数字签名。
