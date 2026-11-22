param(
    [Parameter(Mandatory=$true)][guid]$ConversationId,
    [Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z0-9_.-]{1,100}$')][string]$RequestId,
    [Parameter(Mandatory=$true)][string]$MessageFile
)
$ErrorActionPreference = 'Stop'
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    throw 'Run with powershell.exe -NoProfile -STA -File.'
}
$message = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $MessageFile).Path).Trim()
if (-not $message -or [Text.Encoding]::UTF8.GetByteCount($message) -gt 24000) { throw 'Message must have 1 to 24000 UTF-8 bytes.' }
$id = $ConversationId.ToString()
$receipt = Join-Path $PSScriptRoot ('runtime\agy-desktop-send-' + $RequestId + '.json')
$sha = [Security.Cryptography.SHA256]::Create()
try { $messageHash = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($message)) | ForEach-Object {$_.ToString('x2')}) }
finally { $sha.Dispose() }
if (Test-Path -LiteralPath $receipt) {
    $old = Get-Content -LiteralPath $receipt -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($old.conversation_id -ne $id -or $old.message_sha256 -ne $messageHash) { throw 'Request ID already belongs to different content or conversation.' }
    $old | ConvertTo-Json -Compress
    return
}

Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Windows.Forms
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class AntigravityDesktopFocus {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr target);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
}
'@
$windows = @(Get-Process -Name 'Antigravity' | Where-Object MainWindowHandle -ne 0)
if ($windows.Count -ne 1) { throw 'Open one Antigravity desktop window showing the target conversation in the sidebar.' }
$window = $windows[0]
$root = [System.Windows.Automation.AutomationElement]::FromHandle($window.MainWindowHandle)
$scope = [System.Windows.Automation.TreeScope]::Descendants
function Find-Named($Name) {
    $filter = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty,$Name)
    $root.FindFirst($scope,$filter)
}
function Read-Composer($Element) {
    $text = $Element.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern).DocumentRange.GetText(-1).Trim()
    if ($text -eq $Element.Current.Name -and -not $Element.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value) {
        return ''
    }
    return $text
}
$links = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty,[System.Windows.Automation.ControlType]::Hyperlink)
$target = $null
foreach ($candidate in $root.FindAll($scope,$links)) {
    $value = $null
    if (-not $candidate.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern,[ref]$value)) { continue }
    $route = $null
    if ([uri]::TryCreate($value.Current.Value,[UriKind]::Absolute,[ref]$route) -and $route.Scheme -eq 'https' -and
        $route.Host -eq '127.0.0.1' -and $route.AbsolutePath -ceq ('/c/'+$id)) {
        $target = $candidate
        break
    }
}
if (-not $target) { throw 'The exact conversation ID was not found in the visible Antigravity desktop links.' }
$targetTitle = $target.Current.Name
if (-not $targetTitle) { throw 'The conversation has no accessible title.' }
$target.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
$composer = $null
for ($i=0; $i -lt 20 -and -not $composer; $i++) {
    Start-Sleep -Milliseconds 250
    $window.Refresh()
    $title = $window.MainWindowTitle
    $prefix = $targetTitle.Substring(0,[Math]::Min(15,$targetTitle.Length))
    if ($title.StartsWith($prefix,[StringComparison]::Ordinal)) { $composer = Find-Named 'Message input' }
}
if (-not $composer -or (Read-Composer $composer)) { throw 'Cannot verify the target composer or it has an existing draft.' }
if (Find-Named 'Stop generation') { throw 'The target conversation is currently generating.' }
[void][AntigravityDesktopFocus]::SetForegroundWindow($window.MainWindowHandle)
if ([AntigravityDesktopFocus]::GetForegroundWindow() -ne $window.MainWindowHandle) { throw 'Could not activate the target window.' }
$box = $composer.Current.BoundingRectangle
if ($box.IsEmpty -or $box.Width -lt 50 -or $box.Height -lt 18) { throw 'The target composer is not visible.' }
$pointer = [Windows.Forms.Cursor]::Position
[Windows.Forms.Cursor]::Position = [Drawing.Point]::new([int]($box.X+30),[int]($box.Y+14))
[AntigravityDesktopFocus]::mouse_event(2,0,0,0,[UIntPtr]::Zero)
[AntigravityDesktopFocus]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
[Windows.Forms.Cursor]::Position = $pointer
$focus = [System.Windows.Automation.AutomationElement]::FocusedElement
if ($focus.Current.Name -ne 'Message input' -or $focus.Current.ProcessId -ne $composer.Current.ProcessId) { throw 'Target composer did not gain focus.' }
$previousClipboard = [Windows.Forms.Clipboard]::GetDataObject()
$record = [ordered]@{request_id=$RequestId;conversation_id=$id;message_sha256=$messageHash;state='PENDING_OUTCOME_UNKNOWN_DO_NOT_RESEND';transport='Antigravity desktop composer';utc=[DateTime]::UtcNow.ToString('o')}
$encoding = [Text.UTF8Encoding]::new($false)
try {
    [Windows.Forms.Clipboard]::SetDataObject($message,$true,10,60)
    [Windows.Forms.SendKeys]::SendWait('^v')
    Start-Sleep -Milliseconds 450
    $send = Find-Named 'Send message'
    if ([AntigravityDesktopFocus]::GetForegroundWindow() -ne $window.MainWindowHandle -or
        (Read-Composer $composer) -cne $message -or -not $send -or -not $send.Current.IsEnabled) { throw 'The exact message was not verified in the target composer.' }
    $journal = [IO.File]::Open($receipt,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try {
        $bytes = $encoding.GetBytes(($record | ConvertTo-Json -Compress))
        $journal.Write($bytes,0,$bytes.Length)
        $journal.Flush()
    } finally { $journal.Dispose() }
    $send.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $record.state = 'SUBMITTED_IN_DESKTOP_UI'
    [IO.File]::WriteAllText($receipt,($record | ConvertTo-Json -Compress),$encoding)
    $record | ConvertTo-Json -Compress
} finally {
    try {
        if ($previousClipboard) { [Windows.Forms.Clipboard]::SetDataObject($previousClipboard,$true,10,60) }
        else { [Windows.Forms.Clipboard]::Clear() }
    } catch { Write-Warning 'Windows did not restore the prior clipboard object.' }
}
