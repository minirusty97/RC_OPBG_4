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
function Set-ExplorerRemovalReadOnly { param([switch]$ReadOnly) }
function New-ExplorerRemovalPlan {
    param($Names, $Sources, $ConfigPath, $ProgressQueue, $SearchTargets)
    [pscustomobject]@{Operation='PrepareRemoval';Names=$Names;Sources=$Sources;ConfigPath=$ConfigPath;SearchTargets=$SearchTargets}
}
function Invoke-ExplorerRemovalPlan {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([string]$PlanId, $ProgressQueue, $Cancellation, [switch]$IncludeAdChildren,[string[]]$ConfirmBitLockerLossFor=@(),[string[]]$ConfirmHybridMismatchFor=@(),[string[]]$ConfirmUnreadableAdChildrenFor=@())
    [pscustomobject]@{Operation='Remove';PlanId=$PlanId;IncludeAdChildren=[bool]$IncludeAdChildren;LossNames=$ConfirmBitLockerLossFor;HybridNames=$ConfirmHybridMismatchFor;UnreadableNames=$ConfirmUnreadableAdChildrenFor}
}
Export-ModuleMember -Function Set-ExplorerRemovalReadOnly, New-ExplorerRemovalPlan, Invoke-ExplorerRemovalPlan
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
    $pipeline=[PowerShell]::Create()
    try {
        [void]$pipeline.AddScript($workerSource).AddArgument($modulePath).AddArgument('Remove').AddArgument(@('PC-TEST')).AddArgument(@('AD')).AddArgument('synthetic.json').AddArgument('confirmed-plan').AddArgument($null).AddArgument($null).AddArgument($false).AddArgument($null).AddArgument($false).AddArgument(0).AddArgument($false).AddArgument(@('PC-TEST')).AddArgument(@('PC-TEST')).AddArgument(@('PC-TEST'))
        $output=@($pipeline.Invoke())
        if ($pipeline.HadErrors -or $output.Count -ne 1 -or $output[0].LossNames.Count -ne 1 -or $output[0].LossNames[0] -ne 'PC-TEST' -or $output[0].HybridNames.Count -ne 1 -or $output[0].HybridNames[0] -ne 'PC-TEST' -or $output[0].UnreadableNames.Count -ne 1 -or $output[0].UnreadableNames[0] -ne 'PC-TEST') { throw 'Production worker lost per-computer BitLocker loss confirmation.' }
    }
    finally { $pipeline.Dispose() }
    'PASS: production worker preserves the exact names explicitly confirmed for deletion without a GLPI archive.'

    $targetId = '11111111-1111-4111-8111-111111111111'
    $searchTargets = @{'PC-TEST'=@([pscustomobject]@{Source='AD';Id=$targetId;DomainController='dc1.example.invalid'})}
    foreach ($scope in @($searchTargets,$null)) {
        $pipeline = [PowerShell]::Create()
        try {
            [void]$pipeline.AddScript($workerSource)
            foreach ($argument in @($modulePath,'PrepareRemoval',@('PC-TEST'),@('AD'),'synthetic.json','',$null,$null,$false,$null,$false,0,$false,$null,$null,$null,$scope)) {
                [void]$pipeline.AddArgument($argument)
            }
            if ($null -eq $scope) {
                $rejected = $false
                try { $null = $pipeline.Invoke() } catch { $rejected = $_.Exception.Message -like '*Ripetere la ricerca*' }
                if (-not $rejected) { throw 'Production preview worker accepted deletion without a search selection.' }
                continue
            }
            $output = @($pipeline.Invoke())
            if ($pipeline.HadErrors -or $output.Count -ne 1 -or $output[0].Operation -ne 'PrepareRemoval' -or
                $output[0].ConfigPath -ne 'synthetic.json' -or $output[0].Names[0] -ne 'PC-TEST' -or
                $output[0].Sources[0] -ne 'AD' -or $output[0].SearchTargets['PC-TEST'][0].Id -ne $targetId) {
                throw 'Production preview worker changed its arguments or dropped the search selection.'
            }
        }
        finally { $pipeline.Dispose() }
    }
    'PASS: production preview worker requires and preserves the selected IDs from the search.'
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
