# Troubleshooting

## `auth_unavailable: no auth available`

含义：sidecar 已收到请求，但没有可用账号认证。

处理：打开 Cockpit Tools，刷新/唤醒账号，确认账号加入 API 服务且状态可用。

## 端口 7550 无法启动

- 检查是否已经有 sidecar 在监听；
- 检查 `cockpitExe` 路径；
- 检查 sidecar 的 config、manifest 和 quota state 路径；
- 查看 `logs/sidecar.err.log`。

## 端口 7551 无法启动

- 检查 Windows `node.exe`；
- 检查 `config/bridge.local.json` JSON 语法；
- 查看 `logs/adapter.err.log`。

## Claude Code 显示模型不存在

通常是：

1. 修改了配置但没有重启 7551；
2. 别名没有定义；
3. 实际模型不在 `GET /v1/models` 返回列表中；
4. 账号没有该模型权限。

## API 请求成功但交互模式报错

用诊断快捷方式检查：

- 适配器是否记录 `[rewrite]`；
- sidecar 是否记录 `status: 200`；
- SSE 是否返回 `text/event-stream`；
- query string（例如 `?beta=true`）是否保留。
