# Security Policy

## 凭据边界

桥接器不会要求把 API Key 写进仓库配置。启动脚本只从 WSL 的 Claude Code 用户配置读取已有的 `ANTHROPIC_API_KEY`，并将请求转发到本机 sidecar。

第三方 sidecar 和账号认证文件仍属于高敏感资产。能够读取这些文件或控制本机进程的程序，可能有能力使用对应账号。

## 不要提交的内容

- `config/bridge.local.json`
- `.claude/settings.json`
- Cockpit sidecar 的认证、manifest 或 quota state 文件
- OAuth token、Cookie、API Key
- 运行日志
- 账号邮箱、账号 ID、认证文件名

## 发布前检查

```powershell
./scripts/check-secrets.ps1
```

并人工检查 Git 历史，而不仅是当前工作树。密钥一旦提交过，即使后来删除，也应立即轮换。

## 监听范围

默认仅监听 `127.0.0.1`。除非明确了解风险，不要改为 `0.0.0.0`，否则局域网中的其他设备可能访问本地桥接器。
