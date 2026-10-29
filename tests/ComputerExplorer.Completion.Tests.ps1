#requires -version 5.1
[CmdletBinding()]
param([string]$UiPath = (Join-Path $PSScriptRoot '../Start-ComputerExplorer.ps1'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# Exercise the production timer callback with real asynchronous pipelines.
# Only controls/rendering are replaced, so this also runs without WinForms.
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Resolve-Path $UiPath).ProviderPath, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw 'UI script does not parse.' }
$GraphAccess=$null
foreach ($name in @('Update-ExplorerCounters', 'Set-SearchBusy', 'Test-UiReadOnly')) {
    $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if ($null -eq $definition) { throw ('UI helper not found: ' + $name) }
    Set-Item -Path ('Function:' + $name) -Value $definition.Body.GetScriptBlock()
}
$ticks = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Member.Value -eq 'Add_Tick' }, $true))
if ($ticks.Count -ne 1) { throw 'Expected one production UI timer callback.' }
$tick = $ticks[0].Arguments[0].ScriptBlock.GetScriptBlock()

function Show-ExplorerSnapshot {
    param($Snapshot)
    $script:Latest = $Snapshot; $script:StageMessage = $Snapshot.Message
    $status.Text = $Snapshot.Message
    Update-ExplorerCounters
    if (-not $Snapshot.Complete -and $script:FinishDuringRender) {
        $script:FinishDuringRender = $false
        $script:Release.Set()
        if (-not $script:Invocation.AsyncWaitHandle.WaitOne(5000)) { throw 'Worker did not finish during partial rendering.' }
    }
}
function Close-ExplorerGraphLogin {}
function Stop-ExplorerSearch { throw ('Unexpected UI failure: ' + $status.Text) }

function Start-TestOperation {
    param([bool]$QueueFinal = $true, [bool]$Fail = $false)
    $script:Latest = $null; $script:Operation = 'Search'; $script:Stopping = $false
    $script:CloseRequested = $false; $script:RemovalCancellation = $null
    $script:RemovalNeedsRefresh = $true; $script:FinishDuringRender = $false
    $script:StartedAt = [datetime]::Now; $script:StageMessage = 'In corso'
    $script:Queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $script:Release = New-Object Threading.ManualResetEventSlim($false)
    $script:Partial = [pscustomobject]@{ Complete=$false; Message='In corso: GLPI'; Rows=@('PC-TEST'); Sources=@([pscustomobject]@{Name='GLPI';State='In attesa';Error=$null}) }
    $script:Final = [pscustomobject]@{ Complete=$true; Message='Ricerca completata'; Rows=@('PC-TEST'); Sources=@([pscustomobject]@{Name='GLPI';State='OK';Error=$null}) }
    $script:Queue.Enqueue($script:Partial)
    $script:TestWorker = [RunspaceFactory]::CreateRunspace(); $script:TestWorker.Open()
    $script:Pipeline = [PowerShell]::Create(); $script:Pipeline.Runspace = $script:TestWorker
    [void]$script:Pipeline.AddScript({
        param($Queue, $Release, $Final, $QueueFinal, $Fail)
        $ErrorActionPreference = 'Stop'
        if (-not $Release.Wait(5000)) { throw 'Test worker was not released.' }
        if ($QueueFinal) { $Queue.Enqueue($Final) }
        if ($Fail) { throw 'Synthetic search failure after publishing an update.' }
        return $Final
    }.ToString()).AddArgument($script:Queue).AddArgument($script:Release).AddArgument($script:Final).AddArgument($QueueFinal).AddArgument($Fail)
    Set-SearchBusy $true
    $script:Invocation = $script:Pipeline.BeginInvoke()
}
function Close-TestOperation {
    $script:Release.Set()
    if ($null -ne $script:Pipeline) { $script:Pipeline.Stop(); $script:Pipeline.Dispose(); $script:Pipeline=$null }
    $script:TestWorker.Close(); $script:TestWorker.Dispose(); $script:Release.Dispose()
}
function Assert-CompletedView {
    if ($null -eq $script:Latest -or -not $script:Latest.Complete -or $script:StageMessage -ne 'Ricerca completata') { throw 'Finished search left the view in progress.' }
    if ($script:Busy -or $script:RemovalNeedsRefresh -or -not $deleteButton.Enabled -or -not $searchButton.Enabled -or $cancelButton.Enabled) { throw 'Finished search did not release controls for selected rows.' }
    if ($null -ne $script:Pipeline -or $null -ne $script:Invocation) { throw 'Completed pipeline was not disposed.' }
}

$grid = [pscustomobject]@{ Rows=@('PC-TEST'); SelectedRows=@([pscustomobject]@{Tag=[pscustomobject]@{Name='PC-TEST'}}) }
$counterLabel = [pscustomobject]@{Text=''}; $status = [pscustomobject]@{Text=''}
$deleteButton = [pscustomobject]@{Enabled=$false}; $searchButton = [pscustomobject]@{Enabled=$true}
$findKeysButton=[pscustomobject]@{Enabled=$false};$config=[pscustomobject]@{MinimumCharacters=2}
$archiveButton=[pscustomobject]@{Enabled=$false}; $readArchiveButton=[pscustomobject]@{Enabled=$false}
$nameBox = [pscustomobject]@{Enabled=$true;Text='PC-TEST'}; $tokensButton = [pscustomobject]@{Enabled=$true}
$forceRefresh = [pscustomobject]@{Enabled=$true}; $cancelButton = [pscustomobject]@{Enabled=$false}
$sourceChecks = [ordered]@{AD=[pscustomobject]@{Enabled=$true}}
$timer = [pscustomobject]@{Enabled=$true}
$timer | Add-Member -MemberType ScriptMethod -Name Stop -Value {$this.Enabled=$false}

Start-TestOperation
try {
    $script:Release.Set()
    if (-not $script:Invocation.AsyncWaitHandle.WaitOne(5000)) { throw 'Worker did not finish before timer tick.' }
    & $tick
    Assert-CompletedView
    'PASS: a search completed before the UI tick releases the selected rows for deletion.'
}
finally { Close-TestOperation }

Start-TestOperation
try {
    $script:FinishDuringRender = $true
    & $tick
    Assert-CompletedView
    'PASS: completion arriving during a partial redraw cannot leave the view in progress.'
}
finally { Close-TestOperation }

Start-TestOperation -QueueFinal $false
try {
    $script:Release.Set()
    if (-not $script:Invocation.AsyncWaitHandle.WaitOne(5000)) { throw 'Worker did not return the terminal result.' }
    & $tick
    Assert-CompletedView
    'PASS: the returned terminal result completes the view independently of progress notifications.'
}
finally { Close-TestOperation }

Start-TestOperation
try {
    & $tick
    if (-not $script:Busy -or $script:Latest.Complete -or $deleteButton.Enabled) { throw 'Partial results enabled deletion before worker completion.' }
    'PASS: selected partial results remain unavailable for deletion while a source is running.'
}
finally { Close-TestOperation }

Start-TestOperation
try {
    $script:Final.Sources[0].State='Errore'; $script:Final.Sources[0].Error='Synthetic source failure'
    $script:Release.Set()
    if (-not $script:Invocation.AsyncWaitHandle.WaitOne(5000)) { throw 'Worker with a source error did not finish.' }
    & $tick
    Assert-CompletedView
    'PASS: a terminal source error releases the search and permits actions on selected completed results.'
}
finally { Close-TestOperation }

Start-TestOperation
try {
    $script:Final.Sources[0].State='In attesa'
    $script:Release.Set()
    if (-not $script:Invocation.AsyncWaitHandle.WaitOne(5000)) { throw 'Inconsistent final fixture did not finish.' }
    & $tick
    if ($deleteButton.Enabled) { throw 'A Complete flag enabled deletion with a source still pending.' }
    'PASS: the final flag alone cannot enable deletion while a source has a nonterminal state.'
}
finally { Close-TestOperation }

Start-TestOperation -Fail $true
try {
    $script:Stopping = $true
    $script:Release.Set()
    if (-not $script:Invocation.AsyncWaitHandle.WaitOne(5000)) { throw 'Failing worker did not finish.' }
    & $tick
    if ($script:Busy -or $script:Latest.Complete -or $deleteButton.Enabled -or -not $script:RemovalNeedsRefresh) { throw 'Failed search left an actionable completed view.' }
    'PASS: a failed or stopped worker invalidates a previously queued final update.'
}
finally { Close-TestOperation }

$GraphAccess=[pscustomobject]@{ReadOnly=$true}
Start-TestOperation
try {
    $script:Release.Set()
    if (-not $script:Invocation.AsyncWaitHandle.WaitOne(5000)) { throw 'Read-only worker did not finish.' }
    & $tick
    if ($script:Busy -or -not $script:Latest.Complete -or $deleteButton.Enabled -or $archiveButton.Enabled -or -not $readArchiveButton.Enabled -or -not $findKeysButton.Enabled) { throw 'Completed read-only search enabled writing or disabled recovery reads.' }
    'PASS: completing a read-only search keeps removal and archive writes disabled while recovery reads remain available.'
}
finally { Close-TestOperation; $GraphAccess=$null }
