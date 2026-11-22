[CmdletBinding()]
param(
    [switch]$Discover,
    [switch]$Watch,
    [switch]$Json,
    [guid]$ExpectedOwner = [guid]::Empty,
    [ValidateRange(5, 300)][int]$IntervalSeconds = 10
)
$ErrorActionPreference = 'Stop'
$runtimeRoot = Join-Path $PSScriptRoot 'runtime'
$configPath = Join-Path $runtimeRoot 'bridge-config.json'
$pidFile = Join-Path $runtimeRoot 'bridge.pid'
$bridgePath = Join-Path $PSScriptRoot 'bridge.mjs'
$encoding = [Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot 'codex_desktop_runtime.ps1')

if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw 'Initial Thread Contact configuration is missing.'
}

function Find-CodexDesktopEndpoint {
    if (-not ('ThreadContactPipeServer' -as [type])) {
        Add-Type @'
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class ThreadContactPipeServer {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetNamedPipeServerProcessId(SafePipeHandle pipe, out uint processId);
}
'@
    }

    $desktop = Get-ThreadContactCodexDesktop
    $sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
    $endpoints = @()
    foreach ($path in [IO.Directory]::EnumerateFiles('\\.\pipe\', 'codex-app-tools-*')) {
        $name = [IO.Path]::GetFileName($path)
        if ($name -notmatch '^codex-app-tools-[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$') { continue }
        $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', $name, [IO.Pipes.PipeDirection]::InOut,
            [IO.Pipes.PipeOptions]::None, [Security.Principal.TokenImpersonationLevel]::Identification)
        try {
            $pipe.Connect(500)
            [uint32]$serverId = 0
            if (-not [ThreadContactPipeServer]::GetNamedPipeServerProcessId($pipe.SafePipeHandle, [ref]$serverId)) { continue }
            $server = Get-Process -Id $serverId -ErrorAction SilentlyContinue
            if ($server -and $server.SessionId -eq $sessionId -and $server.Path -eq $desktop.Executable) {
                $endpoints += [pscustomobject]@{ Pipe = "\\.\pipe\$name"; Node = $desktop.Node; ServerId = $serverId }
            }
        } catch [TimeoutException], [IO.IOException], [UnauthorizedAccessException] {
            continue
        } finally {
            $pipe.Dispose()
        }
    }
    if ($endpoints.Count -ne 1) {
        throw "Expected one verified Codex desktop pipe in this Windows session, found $($endpoints.Count)."
    }
    return $endpoints[0]
}

function Get-BridgeProcess {
    if (-not (Test-Path -LiteralPath $pidFile -PathType Leaf)) { return }
    [int]$bridgeId = 0
    if (-not [int]::TryParse([IO.File]::ReadAllText($pidFile).Trim(), [ref]$bridgeId) -or $bridgeId -le 0) { return }
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$bridgeId" -ErrorAction SilentlyContinue
    if ($process -and $process.CommandLine -and
        $process.CommandLine.IndexOf($bridgePath, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
        $process.CommandLine.IndexOf($configPath, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        return $process
    }
}

function Set-BridgeEndpoint($Endpoint, $AlreadyVerified) {
    $mutex = [Threading.Mutex]::new($false, 'Local\OpenAI.ThreadContact.Rebind')
    $locked = $false
    try {
        try { $locked = $mutex.WaitOne(15000) }
        catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Another Thread Contact rebind is in progress.' }
        $config = [IO.File]::ReadAllText($configPath) | ConvertFrom-Json
        if ($ExpectedOwner -ne [guid]::Empty -and $config.owner_thread_id -ne $ExpectedOwner.ToString()) {
            throw 'Thread Contact owner does not match this binding.'
        }
        $bridge = Get-BridgeProcess
        if ($bridge -and $config.pipe_path -eq $Endpoint.Pipe -and $AlreadyVerified -and
            $AlreadyVerified.Pid -eq $bridge.ProcessId -and $AlreadyVerified.Pipe -eq $Endpoint.Pipe -and
            $AlreadyVerified.ServerId -eq $Endpoint.ServerId) {
            return $AlreadyVerified
        }
        if (-not $bridge -and (-not $Endpoint.Node -or -not (Test-Path -LiteralPath $Endpoint.Node -PathType Leaf))) {
            throw 'The Codex-bundled Node runtime could not be located.'
        }
        $changedPipe = $config.pipe_path -ne $Endpoint.Pipe
        if ($changedPipe) {
            $config.pipe_path = $Endpoint.Pipe
            $temp = Join-Path $runtimeRoot ("bridge-config." + [guid]::NewGuid() + ".tmp")
            try {
                [IO.File]::WriteAllText($temp, ($config | ConvertTo-Json -Depth 16), $encoding)
                [IO.File]::Replace($temp, $configPath, [NullString]::Value)
            } finally {
                if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp }
            }
        }
        $started = -not $bridge
        if ($started) {
            $launch = @{
                FilePath = $Endpoint.Node
                ArgumentList = @(('"' + $bridgePath + '"'), ('"' + $configPath + '"'), '--service-logs')
                WindowStyle = 'Hidden'
                PassThru = $true
            }
            $bridge = Start-Process @launch
            $bridgeId = $bridge.Id
            [IO.File]::WriteAllText($pidFile, [string]$bridgeId, $encoding)
        } else {
            $bridgeId = $bridge.ProcessId
        }
        $request = @{
            Uri = "http://127.0.0.1:$($config.local_port)/call"
            Method = 'Post'
            Headers = @{ Authorization = "Bearer $($config.token)" }
            ContentType = 'application/json'
            Body = '{"op":"health"}'
            TimeoutSec = 3
        }
        $health = $null
        for ($attempt = 0; $attempt -lt 5; $attempt++) {
            try {
                $health = Invoke-RestMethod @request
                if ($health.ready -and @($health.app_tools.name | Where-Object { $_ -match '(^|__)read_thread$' }).Count -and
                    @($health.app_tools.name | Where-Object { $_ -match '(^|__)send_message_to_thread$' }).Count) { break }
                $health = $null
            } catch { $health = $null }
            if ($attempt -lt 4) { Start-Sleep -Milliseconds 300 }
        }
        if (-not $health) { throw 'Thread Contact could not verify the local Codex read and send tools.' }
        return [pscustomobject]@{
            Pid = $bridgeId
            Pipe = $Endpoint.Pipe
            ServerId = $Endpoint.ServerId
            Started = $started
            ChangedPipe = $changedPipe
        }
    } finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

if (-not $Watch) {
    $endpoint = if ($Discover -or -not $env:CODEX_APP_TOOLS_PIPE_PATH) { Find-CodexDesktopEndpoint }
        else { [pscustomobject]@{ Pipe = $env:CODEX_APP_TOOLS_PIPE_PATH; Node = $env:CODEX_MCP_NODE_PATH; ServerId = $null } }
    $ready = Set-BridgeEndpoint $endpoint $null
    if ($Json) {
        [ordered]@{ ready = $true; started = $ready.Started; rebound = $ready.ChangedPipe } | ConvertTo-Json -Compress
    } else {
        Write-Output "Thread Contact ready. PID=$($ready.Pid), started=$($ready.Started), rebound=$($ready.ChangedPipe)."
    }
    return
}

$ready = $null
$lastMessage = ''
while ($true) {
    try {
        $current = Set-BridgeEndpoint (Find-CodexDesktopEndpoint) $ready
        if (-not [object]::ReferenceEquals($current, $ready)) {
            $lastMessage = "Thread Contact ready. PID=$($current.Pid), started=$($current.Started), rebound=$($current.ChangedPipe)."
            Write-Output $lastMessage
        }
        $ready = $current
    } catch {
        $ready = $null
        $message = $_.Exception.Message
        if ($lastMessage -ne $message) {
            Write-Warning $message
            $lastMessage = $message
        }
    }
    Start-Sleep -Seconds $IntervalSeconds
}
