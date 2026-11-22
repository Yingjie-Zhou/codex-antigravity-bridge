# Codex ↔ Antigravity Bridge

让 Codex 使用官方 Antigravity CLI 的账号登录创建和接续工作会话，再由 Antigravity 主动把结果回传父 Codex 聊天。可在父聊天空闲后触发下一轮处理，无需 Gemini 或 OpenAI API Key。

这是一个可直接安装的 Codex skill，附带少量无第三方依赖的脚本。

## 桌面会话和线程联系

[Thread Contact](thread-contact/README.md) 支持 Windows 上的 Codex 与 Antigravity 桌面会话双向读写、Codex 深度链接，以及从两端 MCP 按需恢复连接。下文介绍独立的 Antigravity CLI 工作流。

## 已验证的能力

- 使用本机已有 Google 账号凭据创建 Antigravity 会话并读取真实回复。
- 通过会话 ID 跨进程续聊，保留上下文和中文内容。
- Antigravity 实际调用 MCP 回传工具，Codex 应用确认投递。
- 父 Codex 聊天上一轮结束后，回传消息触发新一轮处理。
- 稳定请求 ID、重复投递抑制和未知结果保留。

2026-10-24 的真实 Windows 测试使用 Antigravity CLI 1.4.6 和 Codex 桌面内置 CLI 0.163.0-alpha.10.2。原始账号凭据、聊天 ID、私人路径和完整会话日志不随仓库发布。

**接口边界：** Antigravity 侧使用官方 CLI 和工作区 MCP。Codex 回传侧是基于已安装桌面应用内部消息管道的自建适配器，不是公开稳定 API。应用升级后需要重新检查；应用重启后可从原父聊天刷新连接。

## 安装

把这个仓库放入 Codex 的技能目录，并以仓库目录名 `codex-antigravity-bridge` 保存。例如在 Windows PowerShell 中：

```powershell
git clone https://github.com/Yingjie-Zhou/codex-antigravity-bridge.git "$env:USERPROFILE\.codex\skills\codex-antigravity-bridge"
```

目标目录已有内容时先检查，不覆盖已有安装。让 Codex 重新发现技能后，直接提出：

> 使用 $codex-antigravity-bridge，让 Antigravity 在独立工作区完成这个任务，并把结果回传当前聊天。

前提是官方 `agy` 已安装并完成账号登录，且有 Python 3.10+ 和 Node.js 18+。回传需要从父 Codex 桌面聊天的执行环境配置；普通外部终端通常没有当前聊天的桌面工具上下文。

## 文件

| 文件 | 用途 |
| --- | --- |
| [SKILL.md](SKILL.md) | 派工、续聊、回传与验收流程 |
| [setup_bridge.ps1](scripts/setup_bridge.ps1) | 在任务工作区绑定当前父聊天并注册具名 MCP 工具 |
| [run_agy.py](scripts/run_agy.py) | 账号模式执行一轮 CLI 消息，保留会话 ID、事件与请求回执 |
| [callback_mcp.mjs](scripts/callback_mcp.mjs) | 向固定父聊天发送消息、查健康状态和投递回执 |
| [transport.md](references/transport.md) | 官方接口来源、内部管道边界和证据状态 |

## 使用边界

父 Codex 负责集成和验收，Antigravity 承担用户授权的具体工作。回传是外部代理数据，不构成新的用户授权。消息到达不等于工作正确，更不等于科学结论被接受。

适配器固定绑定父聊天，不接受其他目标。只增加三个具名 MCP 工具许可，不开启全局跳过权限审查，不自动建立互相唤醒的循环。

任务私有状态、连接上下文、配置备份和原始日志位于工作区的 `.codex-antigravity/`，必须留在 Git 之外。超时或投递结果未知时先核对原回执，不能换 ID 盲目重试。

## 本地协议测试

```text
node tests/callback_protocol.mjs
```

测试使用临时本机管道和 stdio，验证两个进程对同一请求只投递一次、正文冲突和改投其他聊天会被拒绝、连接中断后保留未知结果，以及进程重启后仍能复用回执。它不会调用模型或向真实聊天发送消息。真实账号和空闲唤起验证仍需使用者在自己的桌面环境中完成。
