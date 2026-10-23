param(
    [Parameter(Mandatory=$true)][string]$Workspace,
    [string]$NodePath
)
$ErrorActionPreference = 'Stop'
$owner = $env:CODEX_THREAD_ID
if ($owner -notmatch '^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$' -or -not $env:CODEX_APP_TOOLS_PIPE_PATH) {
    throw 'Run setup from the parent Codex desktop chat terminal tool; its real thread and desktop pipe context are required.'
}
if (-not $NodePath) { $NodePath = $env:CODEX_MCP_NODE_PATH }
if (-not $NodePath) { $NodePath = (Get-Command node -ErrorAction Stop).Source }
if (-not (Test-Path -LiteralPath $NodePath -PathType Leaf)) { throw 'Node.js executable not found.' }
New-Item -ItemType Directory -Path $Workspace -Force | Out-Null
$workspacePath = (Resolve-Path -LiteralPath $Workspace).Path
$runtime = Join-Path $workspacePath '.codex-antigravity'
New-Item -ItemType Directory -Path $runtime -Force | Out-Null
$contextPath = Join-Path $runtime 'context.json'
$receiptDir = Join-Path $runtime 'receipts'
$utf8 = [Text.UTF8Encoding]::new($false)
$stamp = [Guid]::NewGuid().ToString('N')
function Read-JsonObject($FilePath) {
    if (Test-Path -LiteralPath $FilePath) { return (Get-Content -LiteralPath $FilePath -Raw -Encoding UTF8 | ConvertFrom-Json) }
    return [pscustomobject]@{}
}
function Set-Field($Object,$Name,$Value) {
    $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value -Force
}
function Backup-Existing($FilePath,$Label) {
    if (Test-Path -LiteralPath $FilePath) { Copy-Item -LiteralPath $FilePath -Destination (Join-Path $runtime ($Label+'.before-'+$stamp+'.json')) }
}
if (Test-Path -LiteralPath $contextPath) {
    $oldContext = Read-JsonObject $contextPath
    if ($oldContext.owner_thread_id -ne $owner -or $oldContext.target_thread_id -ne $owner) {
        throw 'This workspace belongs to another parent chat. Use a separate workspace; do not rebind its callbacks.'
    }
}
$settingsPath = Join-Path $env:USERPROFILE '.gemini\antigravity-cli\settings.json'
$settings = Read-JsonObject $settingsPath
if ($settings.modelProvider -eq 'gemini') { throw 'CLI is configured for API Key mode. Account-only operation requires a separate user decision to change that setting.' }
$agentsDir = Join-Path $workspacePath '.agents'
$mcpPath = Join-Path $agentsDir 'mcp_config.json'
$mcp = Read-JsonObject $mcpPath
if (-not $mcp.mcpServers) { Set-Field $mcp 'mcpServers' ([pscustomobject]@{}) }
$adapter = Join-Path $PSScriptRoot 'callback_mcp.mjs'
$server = [pscustomobject]@{command=$NodePath;args=@($adapter,$contextPath);enabledTools=@('notify_codex','callback_health','callback_receipt');timeoutSeconds=120}
$existing = $mcp.mcpServers.codex_antigravity
if ($existing -and ($existing.command -ne $server.command -or $existing.serverUrl -or $existing.url -or
    (($existing.args | ConvertTo-Json -Compress) -ne ($server.args | ConvertTo-Json -Compress)))) {
    throw 'A different codex_antigravity MCP server is already registered. Preserve it and choose a new workspace.'
}
# A matching bridge may have deliberate env, tool filters, or timeout overrides.
# Refresh its desktop context without replacing those user choices.
if ($existing) { $server = $existing }
$context = [ordered]@{owner_thread_id=$owner;target_thread_id=$owner;pipe_path=$env:CODEX_APP_TOOLS_PIPE_PATH;receipt_dir=$receiptDir}
[IO.File]::WriteAllText($contextPath,($context | ConvertTo-Json -Depth 5),$utf8)
# Validate receiver connectivity before changing agent configuration or permissions.
$healthRaw = (& $NodePath $adapter $contextPath --health | Out-String)
$healthExit = $LASTEXITCODE
$health = $healthRaw | ConvertFrom-Json
if ($healthExit -ne 0 -or -not $health.ready) { throw ('Desktop receiver unavailable: '+$health.error) }
New-Item -ItemType Directory -Path $agentsDir -Force | Out-Null
Backup-Existing $mcpPath 'mcp-config'
Set-Field $mcp.mcpServers 'codex_antigravity' $server
[IO.File]::WriteAllText($mcpPath,($mcp | ConvertTo-Json -Depth 30),$utf8)
New-Item -ItemType Directory -Path (Split-Path $settingsPath -Parent) -Force | Out-Null
Backup-Existing $settingsPath 'agy-settings'
if (-not $settings.permissions) { Set-Field $settings 'permissions' ([pscustomobject]@{}) }
$allows = @($settings.permissions.allow | Where-Object { $_ })
foreach ($rule in @('mcp(codex_antigravity/notify_codex)','mcp(codex_antigravity/callback_health)','mcp(codex_antigravity/callback_receipt)')) {
    if ($rule -notin $allows) { $allows += $rule }
}
Set-Field $settings.permissions 'allow' $allows
[IO.File]::WriteAllText($settingsPath,($settings | ConvertTo-Json -Depth 50),$utf8)
$ignore = Join-Path $workspacePath '.gitignore'
$ignoreText = if (Test-Path -LiteralPath $ignore) { [IO.File]::ReadAllText($ignore) } else { '' }
if (@($ignoreText -split '\r?\n' | Where-Object { $_.Trim() -eq '/.codex-antigravity/' }).Count -eq 0) {
    [IO.File]::AppendAllText($ignore,"`n/.codex-antigravity/`n",$utf8)
}
[pscustomobject]@{ready=$true;target_thread_id=$owner;workspace=$workspacePath;context_path=$contextPath;server='codex_antigravity';api_key_used=$false;transport='desktop-internal-tool-pipe'} | ConvertTo-Json -Depth 5
