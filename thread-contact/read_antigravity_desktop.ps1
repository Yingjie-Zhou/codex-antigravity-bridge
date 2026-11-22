param(
    [Parameter(Mandatory=$true)][guid]$ConversationId,
    [ValidateRange(1,3)][int]$TurnLimit = 1,
    [switch]$MetadataOnly
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes

$windows = @(Get-Process -Name Antigravity -ErrorAction SilentlyContinue | Where-Object MainWindowHandle -ne 0)
if ($windows.Count -ne 1) { throw 'Open one Antigravity desktop window.' }
$root = [System.Windows.Automation.AutomationElement]::FromHandle($windows[0].MainWindowHandle)
$element = [System.Windows.Automation.AutomationElement]
$scope = [System.Windows.Automation.TreeScope]
$id = $ConversationId.ToString()

function Find-ConversationRoute($ControlType) {
    $condition = [System.Windows.Automation.PropertyCondition]::new($element::ControlTypeProperty,$ControlType)
    foreach ($candidate in $root.FindAll($scope::Descendants,$condition)) {
        $value = $null
        if (-not $candidate.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern,[ref]$value)) { continue }
        $route = $null
        if ([uri]::TryCreate($value.Current.Value,[UriKind]::Absolute,[ref]$route) -and
            $route.Scheme -eq 'https' -and $route.Host -eq '127.0.0.1' -and $route.AbsolutePath -ceq "/c/$id") {
            return $candidate
        }
    }
}

$documentType = [System.Windows.Automation.ControlType]::Document
$document = Find-ConversationRoute $documentType
if (-not $document) {
    $link = Find-ConversationRoute ([System.Windows.Automation.ControlType]::Hyperlink)
    if (-not $link) { throw 'The exact conversation ID is unavailable in the desktop sidebar. Open it in Antigravity and retry.' }
    $link.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}
$logCondition = [System.Windows.Automation.PropertyCondition]::new($element::NameProperty,'Conversation Log')
$log = $null
for ($attempt = 0; $attempt -lt 20 -and -not $log; $attempt++) {
    $document = Find-ConversationRoute $documentType
    if ($document) { $log = $document.FindFirst($scope::Descendants,$logCondition) }
    if (-not $log) { Start-Sleep -Milliseconds 250 }
}
if (-not $log) { throw 'Cannot verify the exact desktop route and rendered conversation log.' }

$container = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($log)
$cache = [System.Windows.Automation.CacheRequest]::new()
foreach ($property in $element::NameProperty,$element::ClassNameProperty,$element::ControlTypeProperty) { $cache.Add($property) }
$cache.Push()
try { $nodes = $container.FindAll($scope::Children,[System.Windows.Automation.Condition]::TrueCondition) }
finally { $cache.Pop() }
$current = Find-ConversationRoute $documentType
if (-not $current -or -not $current.Equals($document)) { throw 'The desktop conversation changed during reading.' }

$turns = [Collections.Generic.List[object]]::new()
$message = $null
foreach ($node in $nodes) {
    $name = $node.Cached.Name
    $type = $node.Cached.ControlType.ProgrammaticName
    if ($type -eq 'ControlType.Text' -and $node.Cached.ClassName -like 'sr-only*') {
        if ($name -ceq 'You said') {
            $message = @{ role='input'; state='visible'; parts=[Collections.Generic.List[string]]::new() }
            $turns.Add(@{ input=$message; reply=$null })
            continue
        }
        if ($turns.Count -and $name -cin @('Agent said','Agent working')) {
            $state = if ($name -ceq 'Agent said') {'complete'} else {'in_progress'}
            $message = @{ role='agent'; state=$state; parts=[Collections.Generic.List[string]]::new() }
            $turns[$turns.Count-1].reply = $message
            continue
        }
    }
    if (-not $message) { continue }
    if (($type -eq 'ControlType.Button' -and $name -ceq 'Copy' -and $message.role -eq 'input') -or
        ($type -eq 'ControlType.Group' -and $name -ceq 'Response actions')) {
        $message = $null
        continue
    }
    if ($type -ne 'ControlType.Text' -or -not $name -or $name -match '^status: (inProgress|completed|failed)$') { continue }
    if ($message.role -eq 'input' -and $message.parts.Count -and $name -match '^(?:just now|\d+\s*[smhdw]\s+ago)$') { continue }
    $message.parts.Add($name)
}
if (-not $turns.Count) { throw 'No recognizable input turns in the rendered desktop log.' }

$visible = foreach ($turn in ($turns | Select-Object -Last $TurnLimit)) {
    $messages = foreach ($item in @($turn.input,$turn.reply)) {
        if (-not $item) { continue }
        $body = ($item.parts -join $(if ($item.role -eq 'input') {"`n"} else {' '})).Trim()
        $row = [ordered]@{ui_role=$item.role; state=$item.state; visible_characters=$body.Length}
        if (-not $MetadataOnly) { $row.text = $body.Substring(0,[Math]::Min(2000,$body.Length)) }
        $row
    }
    @{ messages=@($messages) }
}
[ordered]@{
    conversation_id=$id
    source='Antigravity desktop accessibility tree'
    scope='Recent rendered text; UI roles do not identify the human author. Up to 2000 characters per message.'
    turns=@($visible)
} | ConvertTo-Json -Depth 6 -Compress
