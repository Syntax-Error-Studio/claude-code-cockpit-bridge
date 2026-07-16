# Architecture

## 组件

1. **Claude Code（WSL）**：发出 Anthropic Messages API 请求。
2. **本项目 Node 适配器（Windows，默认 7551）**：
   - 处理 Claude Code 的根路径探测；
   - 根据配置改写模型别名；
   - 注入 `thinking.type=adaptive`；
   - 注入 `output_config.effort`；
   - 保留 query string、SSE 和 chunked streaming。
3. **Cockpit sidecar（Windows，默认 7550）**：负责认证、账号路由和实际上游调用。
4. **启动器（PowerShell + WSL shell）**：配置 Claude Code、启动进程、预热和打开终端。

## 为什么不直接使用额外的代理接管层

每增加一层代理，就增加一份状态、熔断、路由和启动顺序。该方案让 Claude Code 直接连接适配器，再连接 Cockpit sidecar，降低本地链路复杂度。

## 请求改写

只有以下路径解析 JSON：

- `/v1/messages`
- `/v1/messages/count_tokens`

其他请求原样代理。`count_tokens` 只改写模型，不注入 thinking 参数。
