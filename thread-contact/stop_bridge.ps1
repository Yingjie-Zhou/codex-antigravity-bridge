$ErrorActionPreference = 'Stop'
$runtimeRoot = Join-Path $PSScriptRoot 'runtime'
$pidFile = Join-Path $runtimeRoot 'bridge.pid'
if (-not (Test-Path -LiteralPath $pidFile)) { return }
$bridgePid = [int](Get-Content -LiteralPath $pidFile -Raw).Trim()
$bridge = Get-CimInstance Win32_Process -Filter "ProcessId=$bridgePid" -ErrorAction SilentlyContinue
if (-not $bridge) { return }
if (-not $bridge.CommandLine.Contains((Join-Path $PSScriptRoot 'bridge.mjs'))) { throw 'PID已被其他进程占用，拒绝停止。' }
$children = Get-CimInstance Win32_Process -Filter "ParentProcessId=$bridgePid"
$cfg = Get-Content -LiteralPath (Join-Path $runtimeRoot 'bridge-config.json') -Raw | ConvertFrom-Json
$remotePorts = if ($cfg.remotes) { @($cfg.remotes | ForEach-Object remote_port) } else { @($cfg.remote_port) }
foreach ($child in $children) {
    if ($child.Name -ne 'ssh.exe' -or -not $child.CommandLine) { continue }
    $isOwnForward = @($remotePorts | Where-Object { $child.CommandLine.Contains("127.0.0.1:$($_):127.0.0.1:$($cfg.local_port)") }).Count -gt 0
    if ($child.Name -eq 'ssh.exe' -and $isOwnForward) {
        Stop-Process -Id $child.ProcessId
    }
}
Stop-Process -Id $bridgePid
Write-Output '仅停止线程消息桥和其SSH隧道。'
