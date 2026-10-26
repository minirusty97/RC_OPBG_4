#requires -version 5.1
[CmdletBinding()]
param([string]$UiPath = (Join-Path $PSScriptRoot '../Start-ComputerExplorer.ps1'))
$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $UiPath).ProviderPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Computer Explorer does not parse.' }
$function = $ast.Find({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Start-RemovalOperation'}, $true)
$assignment = $function.Body.Find({param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$workerCode'}, $true)
$worker = $assignment.Right.Find({param($node) $node -is [System.Management.Automation.Language.ScriptBlockExpressionAst]}, $true)
if ($null -eq $worker) { throw 'Production removal worker not found.' }
$workerSource = $worker.ScriptBlock.ToString()
$workerSource = $workerSource.Substring(1, $workerSource.Length - 2)
$directory = Join-Path ([IO.Path]::GetTempPath()) ('removal-worker-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($directory)
$modulePath = Join-Path $directory 'SyntheticRemoval.psm1'
$moduleText = @'
function New-ExplorerRemovalPlan {
    param($Names, $Sources, $ConfigPath, $ProgressQueue)
    [pscustomobject]@{Operation='PrepareRemoval';Names=$Names;Sources=$Sources;ConfigPath=$ConfigPath}
}
function Invoke-ExplorerRemovalPlan {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([string]$PlanId, $ProgressQueue, $Cancellation, [switch]$IncludeAdChildren)
    [pscustomobject]@{Operation='Remove';PlanId=$PlanId;IncludeAdChildren=[bool]$IncludeAdChildren}
}
Export-ModuleMember -Function New-ExplorerRemovalPlan, Invoke-ExplorerRemovalPlan
'@
try {
    [IO.File]::WriteAllText($modulePath, $moduleText, (New-Object Text.UTF8Encoding($true)))
    foreach ($consent in @($false, $true)) {
        $pipeline = [PowerShell]::Create()
        try {
            [void]$pipeline.AddScript($workerSource).AddArgument($modulePath).AddArgument('Remove').AddArgument(@('PC-TEST')).AddArgument(@('AD')).AddArgument('synthetic.json').AddArgument('confirmed-plan').AddArgument($null).AddArgument($null).AddArgument($consent)
            $output = @($pipeline.Invoke())
            if ($pipeline.HadErrors -or $output.Count -ne 1 -or $output[0].Operation -ne 'Remove' -or $output[0].PlanId -ne 'confirmed-plan' -or $output[0].IncludeAdChildren -ne $consent) { throw ('Production worker lost explicit AD child consent: ' + $consent) }
        }
        finally { $pipeline.Dispose() }
    }
    'PASS: production asynchronous worker passes true and false child consent as booleans to the removal module.'
    $pipeline = [PowerShell]::Create()
    try {
        [void]$pipeline.AddScript($workerSource).AddArgument($modulePath).AddArgument('PrepareRemoval').AddArgument(@('PC-TEST')).AddArgument(@('AD')).AddArgument('synthetic.json').AddArgument('').AddArgument($null).AddArgument($null).AddArgument($false)
        $output = @($pipeline.Invoke())
        if ($pipeline.HadErrors -or $output.Count -ne 1 -or $output[0].Operation -ne 'PrepareRemoval' -or $output[0].ConfigPath -ne 'synthetic.json' -or $output[0].Names[0] -ne 'PC-TEST') { throw 'Production preview worker changed its arguments.' }
    }
    finally { $pipeline.Dispose() }
    'PASS: production preview worker preserves selected names, sources and configuration without invoking removal.'
    $lookupModule=Join-Path $directory 'BitLocker.Archive.psm1'
    [IO.File]::WriteAllText($lookupModule, 'function Find-ExplorerBitLockerKeys { param($Name,$ConfigPath,$ProgressQueue) [pscustomobject]@{Name=$Name;ConfigPath=$ConfigPath;Records=@();Live=$true} }; Export-ModuleMember -Function Find-ExplorerBitLockerKeys', (New-Object Text.UTF8Encoding($true)))
    $pipeline=[PowerShell]::Create()
    try {
        [void]$pipeline.AddScript($workerSource).AddArgument($modulePath).AddArgument('ReadKeys').AddArgument(@('PC-TEST')).AddArgument(@()).AddArgument('synthetic.json').AddArgument('').AddArgument($null).AddArgument($null).AddArgument($false)
        $output=@($pipeline.Invoke())
        if ($pipeline.HadErrors -or $output.Count -ne 1 -or $output[0].Name -ne 'PC-TEST' -or $output[0].ConfigPath -ne 'synthetic.json' -or -not $output[0].Live) { throw 'Live-key worker did not import the lookup module or preserve the full computer name.' }
    }
    finally { $pipeline.Dispose() }
    'PASS: the production live-key worker imports its lookup module and passes the full name without GLPI credentials or removal.'

}
finally { Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue }
