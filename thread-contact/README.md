# Thread Contact

在 Windows 上连接 Codex 与 Antigravity 桌面会话。Antigravity 可按 Codex 深度链接读写近期对话，Codex 可按 Antigravity 会话 ID 读写桌面会话。远端 Codex 可选用 SSH 回环转发。两端使用已有桌面登录。

## 初始绑定

需要已安装、正在运行的 Windows Codex 桌面应用和已登录的 Antigravity 桌面应用。桥使用 Codex 随应用安装的 Node 和内部工具管道，升级后应检查兼容性。

在负责代投的本机 Codex 聊天中打开终端，把工作目录切至本文件所在目录，执行：

```powershell
$owner = ([guid]$env:CODEX_THREAD_ID).ToString()
if ($owner -eq [guid]::Empty.ToString()) { throw '请从负责代投的本机 Codex 聊天运行。' }
$runtime = New-Item -ItemType Directory -Force -Path (Join-Path $PWD 'runtime')
$config = Join-Path $runtime.FullName 'bridge-config.json'
if (Test-Path -LiteralPath $config) { throw '配置已存在，请沿用现有绑定。' }

$bytes = New-Object byte[] 32
$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
$settings = @{
    owner_thread_id = $owner
    default_target_thread_id = $owner
    local_port = 18437
    token = ([BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()
    pipe_path = ''
    remotes = @()
}
[IO.File]::WriteAllText($config, ($settings | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
.\start_bridge.ps1 -ExpectedOwner $owner
```

端口占用时选择另一个空闲端口。运行文件、凭据和回执位于当前用户的私有 `runtime/`。桥仅监听回环地址。

## 按需恢复

Codex 重启或连接失效时，运行 `.\start_bridge.ps1 -Discover`，或从任一端 MCP 调用 `rebind_bridge`。恢复入口独立于桥进程，可按需冷启动并检查桌面读写接口。恢复后沿用原请求 ID 查询投递状态。日常使用无需启动轮询。

- **Codex** 在用户的 Codex MCP 配置中登记以下服务，替换脚本绝对路径和本机代投聊天 UUID。
- **Antigravity** 在桥所属的 Codex 聊天中运行 `.\setup_antigravity.ps1`。在 **Customizations → Installed → MCP Servers** 核对 `thread_contact_antigravity`。

```toml
[mcp_servers.thread_contact_recovery]
command = "powershell.exe"
args = ["-NoLogo", "-NoProfile", "-NonInteractive", "-File", 'C:\path\thread-contact\start_antigravity_mcp.ps1', "-Owner", "<本机代投聊天 UUID>", "-RecoveryOnly"]
```

## 双向通信

| 方向 | 操作 |
| --- | --- |
| Antigravity → Codex | 用 `read_codex_thread_link` 按 `codex://threads/<线程ID>` 读取最多三轮，远端链接保留 `hostId`。获用户授权后，用 `send_codex_thread_link` 向该链接发送，用 `codex_thread_link_receipt` 查询。绑定的本机代投聊天也可使用 `notify_codex` 和 `callback_receipt`。 |
| Codex → Antigravity | 用 `powershell.exe -NoProfile -STA -File .\read_antigravity_desktop.ps1 -ConversationId <UUID> -TurnLimit 3` 读取。获用户授权后，用 `send_antigravity_desktop.ps1` 传入 `-ConversationId`、`-RequestId` 和 UTF-8 的 `-MessageFile`。目标会话需在桌面打开或在侧栏可见，发送通过正常桌面输入框。 |

发送须使用稳定的请求 ID。结果未知时查同一请求回执，避免重复发送。已有任务授权可用于同范围的反馈和交付。新权限、新预算或新收件人按对应的用户授权执行。消息头标明代投来源。桌面提交或应用 ACK 后可在目标聊天核对实际接收。

## 可选远端连接

有现成 SSH 访问时，在私有桥配置的 `remotes` 登记受信任执行端。每项包含 `ssh_host`（本机 SSH 别名）、`host_id`（Codex 识别的远端 hostId）和 `remote_port`（远端回环端口）。改动后用 `.\stop_bridge.ps1`、`.\start_bridge.ps1 -Discover` 重建转发。

远端使用 Python 3.6+ 运行 `thread_contact.py`。把 `url`（远端回环转发地址）、`token`、`source_host_id` 写入权限 0600 的 `~/.config/codex-thread-contact/client.json`。可以用 `THREAD_CONTACT_CONFIG` 指定另一私有配置。运行 `python3 thread_contact.py health` 检查实际转发，或用 `mcp` 参数注册 stdio MCP。可选的 `install_remote.py` 从标准输入读取私有部署 JSON，字段为 `client_base64`、`url`、`token`、`source_host_id`，可另指定 `readme_base64` 和 `managed_config_path`。

桥以本机所有者的 Codex 上下文代投。拥有共享桥令牌的客户端可以请求读取和代投，请只将执行端接入同一信任范围。配置、凭据、消息记录及身份标识应留在本机。
