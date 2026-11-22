[CmdletBinding()]
param([Parameter(Mandatory)][guid]$Owner, [switch]$RecoveryOnly)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'codex_desktop_runtime.ps1')
$desktop = Get-ThreadContactCodexDesktop
if (-not (Test-Path -LiteralPath $desktop.Node -PathType Leaf)) {
    throw 'The Codex-bundled Node runtime could not be located.'
}
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
$serverArgs = @((Join-Path $PSScriptRoot 'antigravity_mcp.mjs'), $Owner.ToString())
if ($RecoveryOnly) { $serverArgs += '--recovery-only' }
& $desktop.Node @serverArgs
exit $LASTEXITCODE
