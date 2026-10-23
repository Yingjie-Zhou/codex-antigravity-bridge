# 接口、兼容性与验收依据

## 官方 Antigravity 端

- [安装与账号登录](https://www.antigravity.google/docs/install?tab=cli)：使用官方 CLI 和系统凭据库，必要时重新完成浏览器登录。
- [非交互调用与续聊](https://www.antigravity.google/docs/cli/headless/)：`-p`、JSON/NDJSON 输出、`--conversation`、标准输入流式会话。
- [工作区 MCP](https://www.antigravity.google/docs/mcp?tab=cli)：工作区配置为 `.agents/mcp_config.json`，全局 MCP 配置为 `~/.gemini/config/mcp_config.json`。
- [具名权限规则](https://www.antigravity.google/docs/permissions?tab=cli)：`mcp(server/tool)`。用户明确的 Deny/Ask 优先级不因新增 Allow 而消失。

2026-10-24 的真实 Windows 验证使用 Antigravity CLI 1.4.6。它证明账号登录、创建会话、跨进程续聊、中文回复及自建 MCP 回传可行；不是对其他版本的永久兼容保证。重新安装或版本变化时核对实际帮助和官方文档。

## Codex 接收端

[官方 CLI 文档](https://learn.chatgpt.com/docs/cli/reference#codex-queue)提供 `codex queue --thread ... --message ...`。使用前必须确认它连接的是目标聊天实际所属的服务。某个 CLI 的默认守护进程不可达，不等于桌面聊天也不可达。不要为回传启动另一个服务并恢复同一在途聊天。

本技能附带的适配器复用本机已验证的 `thread-contact` 消息机制，通过 `CODEX_APP_TOOLS_PIPE_PATH` 连接已安装的 Codex 桌面工具。它是用户自行建立的桥接，不是公开的 MCP 服务地址，也不是 OpenAI 承诺稳定的 API。

管道协议是 4 字节小端长度前缀加 UTF-8 JSON-RPC。适配器先发现 `tools/list` 中的真实 `send_message_to_thread` 工具与命名空间，再调用 `tools/call`。`callerSource=codex`、父聊天 ID 和本机 host 表示**本机代投执行身份**，不冒称 Antigravity 拥有原生 Codex 调用身份。Antigravity 的实际来源应由其 CLI 事件中的 `call_mcp_tool` 记录核对。

2026-10-24 的空闲唤起验证使用 Codex 桌面内置 CLI 0.163.0-alpha.10.2。上一轮结束后 34 秒，Antigravity 的消息触发父聊天新一轮处理。仓库只保留此结果摘要，不发布原聊天 ID、绝对路径或原始消息记录。

## 状态与恢复

回传回执按 request_id 的 SHA-256 文件名保存。独占创建 pending 文件后才投递；不同进程竞争同一 ID 也不会各发一次。完成后原子更新回执。相同 ID 换正文或延迟会拒绝。

| 状态 | 含义与操作 |
| --- | --- |
| `NOT_FOUND` | 没有该 ID 的本地记录；单凭它不能排除其他通道曾经投递。 |
| `PENDING_OUTCOME_UNKNOWN_DO_NOT_RESEND` | 已占用请求，可能仍执行或已中断。先核对原进程和目标聊天。 |
| `APP_ACKNOWLEDGED` | 应用确认投递；仍需父聊天的实际接收证据。 |
| `APP_REJECTED` | 应用返回拒绝，保留原结果。 |
| `OUTCOME_UNKNOWN_DO_NOT_RESEND` | 请求可能已生效但没拿到可确认的结果，禁止换 ID 自动重发。 |

超时或进程中断不清除请求记录。不要通过删除状态、换 ID 或新建会话绕过未知结果。必要时让用户决定新的尝试。

setup 只绑定其真实所属的父聊天。在同一父聊天中重复运行可刷新桌面管道；它拒绝占用其他聊天的工作区。配置备份也可能含敏感信息，始终保留在私有运行目录。复制或公开技能时，仅复制技能代码和说明。

## 可观察证据

至少保留：任务请求 ID、实际 AGY conversation_id、原始 CLI 事件位置、MCP 工具参数与返回、应用投递回执、父聊天收到的唯一标记。验证空闲唤起时，另外记录父聊天上一轮结束与接收轮开始的时间。

有界读取父聊天最近轮次即可，过滤出匹配标记和轮次元数据。不要为验证通信读取无关研究聊天、全历史或大型科学数据。ACK、对方回复、采用成果和科学接受分别记录。
