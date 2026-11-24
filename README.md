# Codex ↔ Antigravity Bridge

让 Codex 和 Antigravity 使用已有账号跨会话协作。仓库提供 Windows 桌面会话桥 **Thread Contact**，以及用于创建、接续独立工作会话的 **Antigravity CLI 技能**。

| 你想做什么 | 从哪里开始 |
| --- | --- |
| 读取已有的桌面对话，或向指定桌面会话发送消息 | [Thread Contact 桌面版](#thread-contact-桌面版) |
| 启动或续接独立的 Antigravity 工作会话，让结果回到父 Codex 聊天 | [Antigravity CLI 技能](#antigravity-cli-技能) |

## Thread Contact 桌面版

适用于 Windows 上已登录的 Codex 与 Antigravity 桌面应用。此路径使用桌面会话，安装时无需 `agy`。

- **Antigravity → Codex**。给出 `codex://threads/<线程ID>` 深度链接，用 `read_codex_thread_link` 分页读取近期或更早的对话，或用 `send_codex_thread_link` 向该线程发消息。远端链接保留原 `hostId`。
- **Codex → Antigravity**。给出 Antigravity 桌面会话 ID，用 `read_antigravity_desktop.ps1` 或 `send_antigravity_desktop.ps1` 操作已有会话。可逐页读取已渲染的历史。目标会话需已打开或在桌面侧栏可见。
- **按需恢复**。Codex 重启或连接失效后，可从任一端的 MCP 调用 `rebind_bridge`，也可运行 `start_bridge.ps1 -Discover`。恢复入口独立于桥进程，日常使用无需开启轮询。

从负责代投的本机 Codex 聊天完成初始绑定，再登记两端的 MCP 服务。可选的 SSH 回环转发适用于已有 SSH 访问的远端 Codex。 [桌面版配置与命令](thread-contact/README.md)

## Antigravity CLI 技能

使用官方 `agy` 和已有 Google 账号登录创建工作会话，之后用会话 ID 跨进程续接。Antigravity 可通过工作区 MCP 把结果回传到绑定的父 Codex 聊天。Windows 实测使用 Antigravity CLI 1.4.6 和 Codex 桌面内置 CLI 0.163.0-alpha.10.2，验证了中文上下文续接、回传实际到达，以及父聊天空闲后被唤起。此路径无需 Gemini 或 OpenAI API Key。

安装前准备好已登录的 `agy`、Python 3.10+ 和 Node.js 18+。从父 Codex 桌面聊天的执行环境配置回传，以便绑定真实聊天和桌面工具上下文。

```powershell
git clone https://github.com/Yingjie-Zhou/codex-antigravity-bridge.git "$env:USERPROFILE\.codex\skills\codex-antigravity-bridge"
```

若该目录已有安装，先检查现有内容。Codex 重新发现技能后，可以提出：

> 使用 $codex-antigravity-bridge，让 Antigravity 在独立工作区完成这个任务，并把结果回传当前聊天。

| 文件 | 用途 |
| --- | --- |
| [SKILL.md](SKILL.md) | 派工、续聊、回传与验收 |
| [setup_bridge.ps1](scripts/setup_bridge.ps1) | 绑定父聊天并登记三个具名 MCP 工具 |
| [run_agy.py](scripts/run_agy.py) | 使用官方 CLI 运行或续接会话，保存会话 ID、原始事件和请求回执 |
| [callback_mcp.mjs](scripts/callback_mcp.mjs) | 向绑定的父聊天回传，检查连接和投递回执 |
| [transport.md](references/transport.md) | 接口来源、传输限制和到达证据 |

## 投递与兼容性

发送消息需有覆盖该任务和收件人的用户授权。每条逻辑消息使用稳定请求 ID，结果未知时用同一 ID 查询回执。应用确认投递后，可到目标聊天核对实际收到的内容。科研或代码成果仍由相应负责人验收。

两种路径的 Codex 接入均依赖桌面内部工具管道，应用升级后应复查兼容性。桌面版的 `thread-contact/runtime/` 和 CLI 工作区的 `.codex-antigravity/` 包含私有配置、凭据或日志，请保存在本地。

## CLI 回传协议测试

```text
node tests/callback_protocol.mjs
```

测试使用临时本机管道和 stdio，覆盖重复投递抑制、同 ID 正文冲突、目标覆盖拒绝、断连后保留未知结果，以及进程重启后复用回执。测试只向隔离环境投递。
