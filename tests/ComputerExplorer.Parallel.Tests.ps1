#requires -version 5.1
[CmdletBinding()]
param([string]$ModulePath=(Join-Path $PSScriptRoot '../ComputerExplorer.Parallel.psm1'))
$ErrorActionPreference='Stop'
$ModulePath=(Resolve-Path $ModulePath).ProviderPath
$configPath=Join-Path ([IO.Path]::GetTempPath()) ('parallel-'+[guid]::NewGuid().ToString('N')+'.json')

function New-TestState {
    param([bool]$Blocked=$false)
    $state=@{ Auth=(New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'); Reads=(New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]')
        Exited=(New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'); Started=(New-Object Threading.CountdownEvent(4))
        Kinds=(New-Object 'System.Collections.Concurrent.ConcurrentDictionary[string,bool]')
        AdEvents=(New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'); AdRunspaces=(New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]')
        AdGates=@{}; PendingDC=''; FailedSource=''
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
    if($state.Kinds.TryAdd($Job.Kind,$true)){[void]$state.Started.Signal()}
    if($Job.Kind -eq 'AD'){
        $state.AdEvents.Enqueue('start:'+$Job.DomainController)
        $state.AdRunspaces.Enqueue([string][Runspace]::DefaultRunspace.InstanceId)
    }
    try {
        while(-not $state.Gates[$Job.Kind].IsSet){Start-Sleep -Milliseconds 20}
        if($Job.Kind -eq 'AD' -and $state.AdGates.ContainsKey($Job.DomainController)){
            while(-not $state.AdGates[$Job.DomainController].IsSet){Start-Sleep -Milliseconds 20}
        }
        if($Job.Kind -eq $state.FailedSource){throw 'Synthetic source failure.'}
        if($Job.Kind -eq 'AD' -and ($Job.DomainController -eq $state.FailedDC -or $state.FailedDC -eq '*')){throw 'Synthetic unavailable DC.'}
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
        if($Job.Kind -eq 'AD' -and $Job.DomainController -eq $state.PendingDC){$result.State='In attesa'}
        return $result
    }
    finally{
        if($Job.Kind -eq 'AD'){$state.AdEvents.Enqueue('end:'+$Job.DomainController)}
        $state.Exited.Enqueue($Job.Kind)
    }
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
    foreach($gate in $Cache.State.Gates.Values){$gate.Dispose()};foreach($gate in $Cache.State.AdGates.Values){$gate.Dispose()};$Cache.State.Started.Dispose()
}

try {
    @{DomainControllers=@(1..5|ForEach-Object{"dc$_.example.invalid"});Search=@{MinimumCharacters=2;CloudCacheMinutes=5};Glpi=@{Enabled=$false}}|ConvertTo-Json -Depth 4|Set-Content $configPath -Encoding UTF8
    $cache=New-TestState $true;$task=$null
    try {
        $cache.State.AdGates['dc2.example.invalid']=New-Object Threading.ManualResetEventSlim($false)
        $queue=New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $task=Start-TestSearch $cache $queue
        if(-not $cache.State.Started.Wait(10000)){throw 'AD and all three independent sources did not overlap.'}
        if($cache.State.Auth.Count -ne 1){throw 'Graph authenticated more than once.'}
        if($cache.State.AdEvents.Count -ne 1){throw 'More than one DC started while the first DC was blocked.'}
        'PASS: one AD reader overlaps with Entra, Intune and GLPI; Graph authenticates once.'
        foreach($name in @('AD','Entra','Intune')){$cache.State.Gates[$name].Set()}
        $oneDC=$null;$deadline=[datetime]::UtcNow.AddSeconds(10)
        while([datetime]::UtcNow -lt $deadline){
            $snapshot=$null
            while($queue.TryDequeue([ref]$snapshot)){
                $ad=@($snapshot.Sources|Where-Object{$_.Name -eq 'AD'})[0]
                if(-not $snapshot.Complete -and $ad.DcSources.Count -eq 1 -and $snapshot.Rows.Count -eq 1 -and $snapshot.Rows[0].Entra -eq '1' -and $snapshot.Rows[0].Intune -eq '1'){$oneDC=$snapshot}
            }
            if($null -ne $oneDC){break};Start-Sleep -Milliseconds 20
        }
        if($null -eq $oneDC -or @($oneDC.Sources|Where-Object{$_.Name -eq 'AD'})[0].Progress -ne '1/5 DC'){throw 'A completed DC did not publish progress while the next DC was blocked.'}
        $cache.State.AdGates['dc2.example.invalid'].Set()
        'PASS: AD publishes each completed DC while the next DC and a separate source are still running.'
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
        $events=@($cache.State.AdEvents.ToArray())
        if($events.Count -ne 10 -or @($cache.State.AdRunspaces.ToArray()|Select-Object -Unique).Count -ne 1){throw 'AD reads did not reuse one dedicated runspace.'}
        for($i=0;$i -lt 5;$i++){
            $dc='dc{0}.example.invalid' -f ($i+1)
            if($events[$i*2] -ne ('start:'+$dc) -or $events[$i*2+1] -ne ('end:'+$dc)){throw 'DC queries overlapped or ran out of order.'}
        }
        if(@($oneDC.Sources|Where-Object{$_.Name -eq 'AD'})[0].DcSources.Count -ne 1){throw 'Later AD updates mutated an earlier snapshot.'}
        'PASS: all five DCs execute sequentially in one runspace; final aggregation preserves IDs, counts and immutable progress.'
    }
    finally{Close-TestSearch $task}
    try {
        foreach($refresh in @($false,$true)){
            $cache.State.Started.Reset(4);$cache.State.Kinds.Clear();$task=$null
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

    $cache=New-TestState;$cache.State.AuthFailure=$true;$cache.State.FailedDC='dc1.example.invalid';$task=$null
    try {
        $task=Start-TestSearch $cache (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]')
        $result=Complete-TestSearch $task
        if($result.Rows[0].AD -ne '4/5' -or $result.Rows[0].ADColor -ne 'Grigio' -or $result.Rows[0].Verificati -ne '4/5' -or $result.Rows[0].Entra -ne '?' -or $result.Rows[0].GLPI -ne '1' -or $cache.State.Reads.Count -ne 0){throw 'Source failures leaked absence, lost other results, or started cloud before auth.'}
        'PASS: failure on the first DC does not stop the next four DCs; authentication errors are terminal and unavailable sources stay gray.'
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
        if($cache.State.Exited.Count -ne 4 -or $cache.State.AdEvents.Count -ne 2){throw 'A reader survived cancellation or a queued DC started after cancellation.'}
        'PASS: cancellation stops all four active sources and never starts the remaining queued DCs.'
    }
    finally{Close-TestSearch $task;Close-TestState $cache}

    $cache=New-TestState;$cache.State.PendingDC='dc1.example.invalid';$task=$null
    try {
        $task=Start-TestSearch $cache (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]')
        $result=Complete-TestSearch $task
        $ad=@($result.Sources|Where-Object{$_.Name -eq 'AD'})[0]
        if($ad.State -ne 'Errore' -or $ad.DcSources.Count -ne 5 -or @($result.Sources|Where-Object{$_.State -eq 'In attesa'}).Count -gt 0){throw 'A malformed reader left a finished search pending.'}
        'PASS: a nonterminal reader response becomes a source error and all queued DCs still complete.'
    }
    finally{Close-TestSearch $task;Close-TestState $cache}

    $cache=New-TestState;$cache.State.FailedSource='Intune';$task=$null
    try {
        $task=Start-TestSearch $cache (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]')
        $result=Complete-TestSearch $task
        if(@($result.Sources|Where-Object{$_.Name -eq 'Intune'})[0].State -ne 'Errore' -or @($result.Sources|Where-Object{$_.State -eq 'OK'}).Count -ne 3 -or -not $result.Complete){throw 'An Intune failure blocked other sources or final completion.'}
        'PASS: an individual cloud reader failure completes with an error while the other three sources succeed.'
    }
    finally{Close-TestSearch $task;Close-TestState $cache}

    $cache=New-TestState;$cache.State.FailedDC='*';$cache.State.AuthFailure=$true;$cache.State.FailedSource='GLPI';$task=$null
    try {
        $task=Start-TestSearch $cache (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]')
        $result=Complete-TestSearch $task
        if($result.Rows.Count -ne 0 -or @($result.Sources|Where-Object{$_.State -eq 'Errore'}).Count -ne 4 -or -not $result.Complete){throw 'A search with errors in all four sources did not terminate.'}
        'PASS: errors in all four sources still produce a final completed search with no fabricated results.'
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
