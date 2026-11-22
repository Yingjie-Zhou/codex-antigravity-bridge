$ErrorActionPreference = 'Stop'
$owner = $env:CODEX_THREAD_ID
$adapter = Join-Path $PSScriptRoot 'antigravity_mcp.mjs'
$launcher = Join-Path $PSScriptRoot 'start_antigravity_mcp.ps1'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$runtime = Join-Path $PSScriptRoot 'runtime'
$binding = Get-Content -LiteralPath (Join-Path $runtime 'bridge-config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $env:CODEX_APP_TOOLS_PIPE_PATH -or -not $owner -or $binding.owner_thread_id -ne $owner) {
    throw 'Run this from the local Codex chat that owns the existing Thread Contact bridge.'
}
$configPath = Join-Path $env:USERPROFILE '.gemini\config\mcp_config.json'
$name = 'thread_contact_antigravity'
$linkTools = @('read_codex_thread_link', 'send_codex_thread_link', 'codex_thread_link_receipt')
$addedTools = $linkTools + @('rebind_bridge')
$server = [ordered]@{
    command = $powershell
    args = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $launcher, '-Owner', $owner)
    enabledTools = @('callback_health', 'read_codex_inbox', 'notify_codex', 'callback_receipt') + $addedTools
    timeoutSeconds = 60
}
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw 'Desktop MCP config not found. Check the path shown by Antigravity Customizations.' }
$config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($null -eq $config) { $config = [pscustomobject]@{} }
if ($null -eq $config.mcpServers) {
    $config | Add-Member -MemberType NoteProperty -Name 'mcpServers' -Value ([pscustomobject]@{}) -Force
}
$existing = $config.mcpServers.PSObject.Properties[$name]
$changed = $false
if ($existing) {
    $registered = $existing.Value
    $installedPackageRoot = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'WindowsApps'
    $legacyPattern = '^' + [regex]::Escape($installedPackageRoot) +
        '\\OpenAI\.Codex_[^\\]+_2p2nqsd0c76g0\\app\\resources\\cua_node\\bin\\node\.exe$'
    $sameLauncher = $registered.command -eq $server.command -and
        ($registered.args -join [char]0) -eq ($server.args -join [char]0)
    $sameLegacyBinding = ($registered.command -match $legacyPattern -or
        $registered.command -eq $env:CODEX_MCP_NODE_PATH) -and
        @($registered.args).Count -eq 2 -and $registered.args[0] -eq $adapter -and $registered.args[1] -eq $owner
    if ($registered.url -or $registered.serverUrl -or -not ($sameLauncher -or $sameLegacyBinding)) {
        throw 'An existing desktop registration differs. Preserve it and resolve the binding before changing it.'
    }
    if ($sameLegacyBinding) {
        $registered.command = $server.command
        $registered.args = $server.args
        $changed = $true
    }
    if ($null -ne $registered.enabledTools) {
        $missing = @($addedTools | Where-Object { $_ -notin $registered.enabledTools })
        if ($missing.Count -gt 0) {
            $registered.enabledTools = @($registered.enabledTools) + $missing
            $changed = $true
        }
    }
} else {
    $config.mcpServers | Add-Member -MemberType NoteProperty -Name $name -Value $server
    $changed = $true
}
if ($changed) {
    $stamp = [Guid]::NewGuid().ToString('N')
    $backup = Join-Path $runtime ('antigravity-desktop-config.before-' + $stamp + '.json')
    $tempFile = $configPath + '.' + $stamp + '.tmp'
    $replaceBackup = $configPath + '.' + $stamp + '.bak'
    [IO.File]::WriteAllText($tempFile, ($config | ConvertTo-Json -Depth 70) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    [IO.File]::Replace($tempFile, $configPath, $replaceBackup)
    Move-Item -LiteralPath $replaceBackup -Destination $backup
}
[pscustomobject]@{config=$configPath; server=$name; binding='existing local bridge owner'} | ConvertTo-Json
