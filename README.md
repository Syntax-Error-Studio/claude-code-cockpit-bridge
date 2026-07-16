# Claude Code Cockpit Bridge

让 **WSL 中的 Claude Code** 通过一个本地、可审计的 Anthropic Messages 兼容层访问 Windows 上的 Cockpit sidecar，并支持：

- Claude 角色名到实际模型的映射；
- `high` / `xhigh` 推理强度注入；
- `/v1/messages` 与 `/v1/messages/count_tokens`；
- SSE / chunked 流式响应透明转发；
- Windows 与 WSL 一键启动、停止、诊断；
- 启动预热与 `auth_unavailable` 定向提示；
- 配置文件驱动，不在源码里保存 API Key。

> 本项目不是 OpenAI、Anthropic、Cockpit Tools 或 CC Switch 的官方项目，也不包含或重新分发它们的二进制文件。

## 架构

```text
Claude Code in WSL
  -> http://127.0.0.1:7551  Claude Code Cockpit Bridge
  -> http://127.0.0.1:7550  Cockpit sidecar
  -> configured model account
```

CC Switch 可以用来把 `ANTHROPIC_API_KEY` 写入 WSL 的 Claude 配置，但使用本桥接器时，应关闭 CC Switch 的代理接管模式，避免再经过额外的本地代理层。

## 环境要求

- Windows 10/11；
- WSL 2；
- Windows Node.js 20 或更高版本；
- WSL 中已经安装 Claude Code；
- 已安装并配置 Cockpit Tools；
- Cockpit sidecar 所需的 `config.json`、`manifest.json` 与 `quota-reserve.json` 已存在；
- WSL 的 `~/.claude/settings.json` 中已经有 `ANTHROPIC_API_KEY`。

## 安装

克隆或下载仓库后，在 Windows 中双击：

```text
Install.cmd
```

安装器会询问或自动检测：

- WSL 发行版；
- WSL 项目目录；
- Claude Code 路径；
- Windows `node.exe`；
- `cockpit-cliproxy.exe`。

默认安装到：

```text
%LOCALAPPDATA%\CockpitClaudeBridge
```

安装完成后，桌面会出现：

- `Claude Code - Cockpit Bridge`
- `Stop Cockpit Claude Bridge`
- `Diagnose Cockpit Claude Bridge`

## 默认模型映射

默认配置位于 `config/bridge.example.json`。安装后的实际配置位于：

```text
%LOCALAPPDATA%\CockpitClaudeBridge\config\bridge.local.json
```

默认示例：

| Claude 角色 | 别名 | 实际模型 | 推理强度 |
| --- | --- | --- | --- |
| Opus | `cockpit-gpt55-xhigh` | `gpt-5.5` | `xhigh` |
| Sonnet | `cockpit-terra-xhigh` | `gpt-5.6-terra` | `xhigh` |
| Fable | `cockpit-sol-xhigh` | `gpt-5.6-sol` | `xhigh` |
| Haiku | `cockpit-gpt54-high` | `gpt-5.4` | `high` |

修改配置后，需要先停止服务，再重新启动，让 Node 适配器重新读取映射。

## `auth_unavailable` 怎么处理

出现：

```text
auth_unavailable: no auth available
```

代表请求已经到达 Cockpit sidecar，但账号池里没有可用认证。打开 Cockpit Tools，刷新或唤醒加入 API 服务的账号，确认至少一个账号可用，然后重新启动。

它不是端口、Node 或 SSE 的错误。

## 测试

```bash
npm test
```

测试覆盖：

- 配置校验；
- 模型和 effort 改写；
- count_tokens；
- query string；
- SSE 流式透传；
- 无效 JSON；
- 大请求限制；
- 上游不可用；
- 明显密钥和个人路径扫描。

PowerShell 语法测试在 Windows GitHub Actions 中运行：

```powershell
./tests/powershell-syntax.ps1
```

## 安全

不要提交：

- `config/bridge.local.json`；
- `~/.claude/settings.json`；
- Cockpit 认证 JSON；
- API Key、Cookie、OAuth token；
- `logs/`；
- 账号邮箱或账号 ID。

提交前可运行：

```powershell
./scripts/check-secrets.ps1
```

更多内容见 [SECURITY.md](SECURITY.md)。

## 已知限制

- 安装和真实 sidecar 联调必须在 Windows + WSL 环境完成；
- 模型是否可用取决于 Cockpit 返回的模型列表和账号权限；
- 正在生成中的请求发生账号额度耗尽时，可能先失败一次，后续重试才切换账号；
- 本项目不管理或刷新第三方账号认证。

## 许可证

MIT。仅覆盖本仓库中的原创代码，不覆盖第三方程序。
