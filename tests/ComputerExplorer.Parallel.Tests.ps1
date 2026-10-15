#requires -version 5.1
[CmdletBinding()]
param([string]$ModulePath=(Join-Path $PSScriptRoot '../ComputerExplorer.Parallel.psm1'))
$ErrorActionPreference='Stop'
$ModulePath=(Resolve-Path $ModulePath).ProviderPath
$configPath=Join-Path ([IO.Path]::GetTempPath()) ('parallel-'+[guid]::NewGuid().ToString('N')+'.json')

function New-TestState {
    param([bool]$Blocked=$false)
    $state=@{ Auth=(New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'); Reads=(New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]')
        Exited=(New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'); Started=(New-Object Threading.CountdownEvent(8))
        Gates=@{}; AuthFailure=$false; FailedDC='' }
    foreach($name in @('AD','Entra','Intune','GLPI')) {
        $state.Gates[$name]=New-Object Threading.ManualResetEventSlim((-not $Blocked))
    }
    return [hashtable]::Synchronized(@{State=$state})
}

$worker={
    param($Job,$CorePath,$ConfigPath,$Fragment,$Configuration,$Cache,$UserToken,$AppToken,$Refresh)
    $state=$Cache.State
    if($Job.Kind -eq 'GraphAuth') {
        $state.Auth.Enqueue('auth')
        if($state.AuthFailure){throw 'Synthetic Graph auth failure.'}
        return [pscustomobject]@{State='OK';Error=$null}
    }
    [void]$state.Started.Signal()
    try {
        while(-not $state.Gates[$Job.Kind].IsSet){Start-Sleep -Milliseconds 20}
        if($Job.Kind -eq 'AD' -and $Job.DomainController -eq $state.FailedDC){throw 'Synthetic unavailable DC.'}
        $result=[pscustomobject]@{Name=$Job.Kind;State='OK';Records=@();DcSources=@();CheckedAtUtc=[datetimeoffset]::UtcNow;FromCache=$false;Error=$null}
        $name='PC-PARALLEL'
        if($Job.Kind -eq 'AD') {
            $result.DcSources=@([pscustomobject]@{DomainController=$Job.DomainController;Stato='OK';Verificato=$true;Trovati=1;Errore=$null})
            $result.Records=@([pscustomobject]@{Name=$name;DomainController=$Job.DomainController;ObjectGUID='11111111-1111-4111-8111-111111111111';ParentPath='example.invalid/Lab';LastModified=[datetime]'2026-10-15T09:00:00'})
        }
        elseif($Job.Kind -in @('Entra','Intune')) {
            $key='Fixture-'+$Job.Kind
            if(-not $Refresh -and $Cache.ContainsKey($key)){
                $result.Records=$Cache[$key].Records;$result.CheckedAtUtc=$Cache[$key].CheckedAtUtc;$result.FromCache=$true
            }
            else {
                $state.Reads.Enqueue($Job.Kind)
                if($Job.Kind -eq 'Entra'){$result.Records=@([pscustomobject]@{Name=$name;ObjectId='22222222-2222-4222-8222-222222222222';DeviceId='33333333-3333-4333-8333-333333333333'})}
                else{$result.Records=@([pscustomobject]@{Name=$name;ManagedDeviceId='44444444-4444-4444-8444-444444444444';AzureADDeviceId='33333333-3333-4333-8333-333333333333';SerialNumber='SYNTHETIC'})}
                $Cache[$key]=[pscustomobject]@{Records=$result.Records;CheckedAtUtc=$result.CheckedAtUtc}
            }
        }
        else {$result.Records=@([pscustomobject]@{Name=$name;GlpiId=1;State='Assegnato';SerialNumber='SYNTHETIC';LastInventory='2026-10-15 09:00:00'})}
        return $result
    }
    finally{$state.Exited.Enqueue($Job.Kind)}
}

function Start-TestSearch {
    param($Cache,$Queue,[string[]]$Sources=@('AD','Entra','Intune','GLPI'),[bool]$Refresh=$false)
    $runspace=[RunspaceFactory]::CreateRunspace();$runspace.Open()
    $pipeline=[PowerShell]::Create();$pipeline.Runspace=$runspace
    [void]$pipeline.AddScript({
        param($ModulePath,$ConfigPath,$Cache,$Queue,$Worker,$Sources,$Refresh)
        $module=Import-Module $ModulePath -Force -PassThru -ErrorAction Stop
        & $module {
            param($ConfigPath,$Cache,$Queue,$Worker,$Sources,$Refresh)
            $script:TestCache=$Cache;$script:TestWorker=[scriptblock]::Create($Worker)
            function script:Get-ExplorerCloudCache{return $script:TestCache}
            function script:Get-ExplorerReadWorkerScript{return $script:TestWorker}
            Invoke-ComputerExplorerParallelSearch -NameFragment 'PC-' -ConfigPath $ConfigPath -EnabledSources $Sources -ProgressQueue $Queue -ForceCloudRefresh:$Refresh
        } $ConfigPath $Cache $Queue $Worker $Sources $Refresh
    }.ToString()).AddArgument($ModulePath).AddArgument($configPath).AddArgument($Cache).AddArgument($Queue).AddArgument($worker.ToString()).AddArgument($Sources).AddArgument($Refresh)
    return [pscustomobject]@{Pipeline=$pipeline;Runspace=$runspace;Operation=$pipeline.BeginInvoke()}
}

function Complete-TestSearch {
    param($Task)
    $out=@($Task.Pipeline.EndInvoke($Task.Operation))
    if($Task.Pipeline.HadErrors){throw ($Task.Pipeline.Streams.Error|Out-String)}
    if($out.Count -ne 1 -or -not $out[0].Complete){throw 'Parallel search did not return one completed snapshot.'}
    return $out[0]
}
function Close-TestSearch {
    param($Task)
    if($null -ne $Task){if(-not $Task.Operation.IsCompleted){$Task.Pipeline.Stop()};$Task.Pipeline.Dispose();$Task.Runspace.Close();$Task.Runspace.Dispose()}
}
function Close-TestState {
    param($Cache)
    foreach($gate in $Cache.State.Gates.Values){$gate.Dispose()};$Cache.State.Started.Dispose()
}

try {
    @{DomainControllers=@(1..5|ForEach-Object{"dc$_.example.invalid"});Search=@{MinimumCharacters=2;CloudCacheMinutes=5};Glpi=@{Enabled=$false}}|ConvertTo-Json -Depth 4|Set-Content $configPath -Encoding UTF8
    $cache=New-TestState $true;$task=$null
    try {
        $queue=New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $task=Start-TestSearch $cache $queue
        if(-not $cache.State.Started.Wait(10000)){throw 'Eight source readers did not overlap.'}
        if($cache.State.Auth.Count -ne 1){throw 'Graph authenticated more than once.'}
        'PASS: all five DCs and the three other sources overlap; a single Graph auth gates cloud reads.'
        foreach($name in @('AD','Entra','Intune')){$cache.State.Gates[$name].Set()}
        $partial=$null;$deadline=[datetime]::UtcNow.AddSeconds(10)
        while([datetime]::UtcNow -lt $deadline){
            $snapshot=$null
            while($queue.TryDequeue([ref]$snapshot)){
                if(-not $snapshot.Complete -and $snapshot.Rows.Count -eq 1 -and $snapshot.Rows[0].AD -eq '5/5' -and $snapshot.Rows[0].Entra -eq '1' -and $snapshot.Rows[0].Intune -eq '1'){$partial=$snapshot}
            }
            if($null -ne $partial){break};Start-Sleep -Milliseconds 20
        }
        if($null -eq $partial -or $partial.Rows[0].GLPI -ne '?' -or $partial.Rows[0].GLPIColor -ne 'Grigio'){throw 'Slow GLPI prevented progressive results or was shown as absent.'}
        'PASS: a slow source does not delay results from completed sources.'
        $cache.State.Gates.GLPI.Set()
        $complete=Complete-TestSearch $task
        if($complete.Rows.Count -ne 1 -or $complete.Rows[0].ADColor -ne 'Verde' -or $complete.Rows[0].GLPI -ne '1' -or $cache.State.Exited.Count -ne 8){throw 'Parallel union lost records or readers.'}
        'PASS: final aggregation preserves all source IDs, counts and completed DCs.'
    }
    finally{Close-TestSearch $task}
    try {
        foreach($refresh in @($false,$true)){
            $cache.State.Started.Reset(8);$task=$null
            try{
                $task=Start-TestSearch -Cache $cache -Queue (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]') -Refresh $refresh
                $result=Complete-TestSearch $task
                $expected=2;if($refresh){$expected=4}
                if($cache.State.Reads.Count -ne $expected -or @($result.Sources|Where-Object{$_.Name -in @('Entra','Intune') -and $_.FromCache -ne (-not $refresh)}).Count -gt 0){throw 'Shared cache or forced refresh lost across worker pools.'}
            }
            finally{Close-TestSearch $task}
        }
        'PASS: shared complete cloud cache survives new worker pools and honors forced refresh.'
    }
    finally{Close-TestState $cache}

    $cache=New-TestState;$cache.State.AuthFailure=$true;$cache.State.FailedDC='dc5.example.invalid';$task=$null
    try {
        $task=Start-TestSearch $cache (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]')
        $result=Complete-TestSearch $task
        if($result.Rows[0].AD -ne '4/5' -or $result.Rows[0].ADColor -ne 'Grigio' -or $result.Rows[0].Verificati -ne '4/5' -or $result.Rows[0].Entra -ne '?' -or $result.Rows[0].GLPI -ne '1' -or $cache.State.Reads.Count -ne 0){throw 'Source failures leaked absence, lost other results, or started cloud before auth.'}
        'PASS: DC and authentication failures remain isolated; unavailable sources are gray.'
    }
    finally{Close-TestSearch $task;Close-TestState $cache}

    $cache=New-TestState;$task=$null
    try {
        $task=Start-TestSearch -Cache $cache -Queue (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]') -Sources AD
        $result=Complete-TestSearch $task
        if($cache.State.Auth.Count -ne 0 -or $cache.State.Exited.Count -ne 5 -or $result.Rows[0].GLPI -ne '?'){throw 'Excluded sources were queried.'}
        'PASS: excluded cloud and GLPI sources launch no readers or login.'
    }
    finally{Close-TestSearch $task;Close-TestState $cache}

    $cache=New-TestState $true;$task=$null
    try {
        $task=Start-TestSearch $cache (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]')
        if(-not $cache.State.Started.Wait(10000)){throw 'Cancellation fixture failed to start readers.'}
        $stop=$task.Pipeline.BeginStop($null,$null);$task.Pipeline.EndStop($stop)
        try{$null=$task.Pipeline.EndInvoke($task.Operation)}catch{}
        if($cache.State.Exited.Count -ne 8){throw 'A reader survived cancellation.'}
        'PASS: cancelling the coordinator stops and disposes all eight active source readers.'
    }
    finally{Close-TestSearch $task;Close-TestState $cache}

    $module=Import-Module $ModulePath -Force -PassThru
    $result=Invoke-ComputerExplorerParallelSearch -NameFragment 'PC-' -ConfigPath $configPath -EnabledSources GLPI
    if(-not $result.Complete -or @($result.Sources|Where-Object{$_.Name -eq 'GLPI'})[0].State -ne 'Esclusa'){throw 'Default worker could not read the disabled GLPI configuration.'}
    'PASS: production worker imports the real core module and handles unconfigured sources.'
    $shared = & $module { $cache=Get-ExplorerCloudCache; $cache['synthetic-cache-marker']=$true; return $cache }
    $removal = Import-Module (Join-Path (Split-Path $ModulePath -Parent) 'ComputerExplorer.Removal.psm1') -Force -PassThru
    & $removal { Clear-ExplorerCloudCache }
    if ($shared.ContainsKey('synthetic-cache-marker')) { throw 'Removal module does not invalidate the parallel reader cache.' }
    'PASS: sequential removal invalidates the exact cache shared by the parallel readers.'
}
finally{Remove-Item -LiteralPath $configPath -Force -ErrorAction SilentlyContinue}
