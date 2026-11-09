#requires -version 5.1
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'ComputerExplorer.Core.psm1') -ErrorAction Stop
. (Join-Path $PSScriptRoot 'ComputerExplorer.AdLog.ps1')
$script:LastParallelRows=$null;$script:ParallelRowsRevision=0

function New-ParallelSource {
    param([string]$Name, [string]$State = 'In attesa', [string]$ErrorText)
    [pscustomobject]@{ Name=$Name; State=$State; Records=@(); DcSources=@(); CheckedAtUtc=$null; FromCache=$false; Error=$ErrorText; Progress=''; CurrentTarget='' }
}

function Get-ExplorerReadWorkerScript {
    return {
        param($Job, $CorePath, $ConfigPath, $Fragment, $Configuration, $Cache, $UserToken, $AppToken, $Refresh,$GlpiLookupCache)
        $ErrorActionPreference = 'Stop'
        if ($Job.Kind -eq 'AD' -and $Job.Isolated) {
            . (Join-Path (Split-Path $CorePath -Parent) 'ComputerExplorer.AdRead.ps1')
            return Read-ExplorerAdProcess -CorePath $CorePath -ConfigPath $ConfigPath -Fragment $Fragment -DomainController $Job.DomainController -TimeoutSeconds $Job.TimeoutSeconds -AdSearchLog $Job.AdSearchLog
        }
        Import-Module $CorePath -ErrorAction Stop
        if ($Job.Kind -eq 'GraphAuth') {
            Connect-ExplorerGraph -Sources $Job.CloudSources -ProgressQueue $Job.AuthQueue -GraphAuthentication $Configuration.GraphAuthentication
            return [pscustomobject]@{ State='OK'; Error=$null }
        }
        $arguments = @{ Source=$Job.Kind; NameFragment=$Fragment; ConfigPath=$ConfigPath; Configuration=$Configuration; CloudCache=$Cache
            GlpiUserToken=$UserToken; GlpiAppToken=$AppToken; ForceCloudRefresh=$Refresh;GlpiLookupCache=$GlpiLookupCache }
        if ($null -ne $Job.PSObject.Properties['SerialDevices']) { $arguments.IntuneDevices=$Job.SerialDevices }
        if ($Job.Kind -eq 'AD') {
            $arguments.DomainController=$Job.DomainController
            if ($null -ne $Job.AdSearchLog) { $arguments.AdSearchLog=$Job.AdSearchLog }
        }
        if ($Job.Kind -in @('Entra','Intune','GLPI')) { $arguments.ProgressQueue=$Job.ReadProgress }
        Read-ExplorerSource @arguments
    }
}

function Start-ExplorerReadTask {
    param($Job, $Pool, [scriptblock]$Body, $ConfigPath, $Fragment, $Configuration, $Cache, $UserToken, $AppToken, $Refresh, $GlpiLookupCache)
    $pipeline = [PowerShell]::Create()
    try {
        $pipeline.RunspacePool = $Pool
        [void]$pipeline.AddScript($Body.ToString()).AddArgument($Job).AddArgument((Join-Path $PSScriptRoot 'ComputerExplorer.Core.psm1')).AddArgument($ConfigPath).AddArgument($Fragment).AddArgument($Configuration).AddArgument($Cache).AddArgument($UserToken).AddArgument($AppToken).AddArgument($Refresh).AddArgument($GlpiLookupCache)
        $operation = $pipeline.BeginInvoke()
        return [pscustomobject]@{ Job=$Job; Pipeline=$pipeline; Operation=$operation; StopOperation=$null; Watch=[Diagnostics.Stopwatch]::StartNew(); TimedOut=$false }
    }
    catch { $pipeline.Dispose(); throw }
}

function Stop-ExplorerReadTasks {
    param($Tasks)
    # Invia tutti gli stop prima di attenderli: nessun lettore resta in background.
    foreach ($task in $Tasks) {
        if (-not $task.Operation.IsCompleted -and $null -eq $task.StopOperation) {
            try { $task.StopOperation=$task.Pipeline.BeginStop($null, $null) } catch { }
        }
    }
    foreach ($task in $Tasks) {
        try { if ($null -ne $task.StopOperation) { $task.Pipeline.EndStop($task.StopOperation) } } catch { }
        $task.Watch.Stop(); $task.Pipeline.Dispose()
    }
}

function Send-ParallelSnapshot {
    param($Sources, $Controllers, [string]$Message, $Queue, [switch]$Complete, [switch]$ReuseRows)
    if (-not $ReuseRows -or $null -eq $script:LastParallelRows) { $script:LastParallelRows=@(Merge-ExplorerResults -Sources $Sources -DomainControllers $Controllers);$script:ParallelRowsRevision++ }
    $snapshot = [pscustomobject]@{
        Message=$Message; Complete=[bool]$Complete;RowsRevision=$script:ParallelRowsRevision
        Rows=@($script:LastParallelRows)
        Sources=@($Sources.Values | ForEach-Object {
            [pscustomobject]@{ Name=$_.Name; State=$_.State; Count=$_.Records.Count; CheckedAtUtc=$_.CheckedAtUtc
                FromCache=$_.FromCache; Error=$_.Error; DcSources=@($_.DcSources)
                CompletedAfterSeconds=$(if ($null -ne $_.PSObject.Properties['CompletedAfterSeconds']) { $_.CompletedAfterSeconds })
                Progress=$(if ($null -ne $_.PSObject.Properties['Progress']) { $_.Progress } else { '' })
                CurrentTarget=$(if ($null -ne $_.PSObject.Properties['CurrentTarget']) { $_.CurrentTarget } else { '' }) }
        })
    }
    if ($Complete -and $snapshot.Rows.Count -eq 0 -and @($snapshot.Sources | Where-Object { $_.State -eq 'Errore' }).Count -eq 0 -and
        @($snapshot.Sources | Where-Object { $_.State -eq 'OK' }).Count -gt 0) {
        $snapshot.Message+=' Nessun dispositivo trovato.'
    }
    if ($null -ne $Queue) { $Queue.Enqueue($snapshot) }
    if ($Complete) { return $snapshot }
}

function Invoke-ComputerExplorerParallelSearch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$NameFragment,
        [Parameter(Mandatory=$true)][string]$ConfigPath,
        [ValidateSet('AD','Entra','Intune','GLPI')][string[]]$EnabledSources=@('AD','Entra','Intune','GLPI'),
        [Security.SecureString]$GlpiUserToken, [Security.SecureString]$GlpiAppToken,
        [switch]$ForceCloudRefresh, $ProgressQueue,
        [switch]$ParallelAdReads, [ValidateRange(1,120)][int]$AdReadTimeoutSeconds=30,
        [string]$SearchLogPath
    )
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $log=$null
    if ($SearchLogPath) {
        $SearchLogPath=[IO.Path]::GetFullPath($SearchLogPath)
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($SearchLogPath))
        [IO.File]::Open($SearchLogPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write).Dispose()
        $log=@{Path=$SearchLogPath}
    }
    $enabled=@($EnabledSources | Sort-Object -Unique)
    Write-ExplorerSearchLog $log 'search.start' @{Sources=$enabled; ParallelAd=[bool]$ParallelAdReads; ForceCloudRefresh=[bool]$ForceCloudRefresh}
    try {
        $config=Read-ExplorerConfiguration $ConfigPath
        if ($ParallelAdReads) { $ConfigPath=(Resolve-Path -LiteralPath $ConfigPath -ErrorAction Stop).ProviderPath }
        $fragment=$NameFragment.Trim()
        if ($fragment.Length -lt $config.MinimumCharacters) { throw "Inserire almeno $($config.MinimumCharacters) caratteri." }
        $controllers=@(Get-ExplorerSearchControllers $config.Settings)
    }
    catch {
        Write-ExplorerSearchLog $log 'search.config.error' @{ElapsedMs=$watch.ElapsedMilliseconds} -Failure $_
        throw
    }
    $glpiLookupCache=[hashtable]::Synchronized(@{})
    $sources=[ordered]@{}
    foreach ($name in @('AD','Entra','Intune','GLPI')) {
        $state='Esclusa'; if ($enabled -contains $name) { $state='In attesa' }
        $sources[$name]=New-ParallelSource $name $state
    }
    if ($enabled -contains 'AD' -and ($controllers.Count -eq 0 -or $controllers -contains '')) {
        $sources.AD=New-ParallelSource 'AD' 'Errore' 'Configurare i Domain Controller nel JSON locale.'
    }
    $cloud=@($enabled | Where-Object { $_ -in @('Entra','Intune') })
    $readProgress=New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $jobs=New-Object 'System.Collections.Generic.List[object]'
    # Servizi indipendenti subito; il solo login Graph precede le due letture cloud.
    if ($enabled -contains 'GLPI') { [void]$jobs.Add([pscustomobject]@{Kind='GLPI';ReadProgress=$readProgress}) }
    if ($cloud.Count -gt 0) { [void]$jobs.Add([pscustomobject]@{Kind='GraphAuth';CloudSources=$cloud;AuthQueue=$ProgressQueue}) }
    $adPending=New-Object 'System.Collections.Generic.Queue[string]'
    $adRetry=New-Object 'System.Collections.Generic.Queue[string]'
    $adActive=[ordered]@{}
    $adResults=@{}
    $adFirstFailures=@{}
    $adConcurrency=1
    if ($ParallelAdReads) { $adConcurrency=[Math]::Max(1,[Math]::Min(5,$controllers.Count)) }
    Write-ExplorerSearchLog $log 'search.configured' @{Controllers=$controllers; AdConcurrency=$adConcurrency; AdTimeoutSeconds=$AdReadTimeoutSeconds}
    if ($sources.AD.State -eq 'In attesa') {
        foreach ($dc in $controllers) { $adPending.Enqueue($dc) }
        $sources.AD.Progress='0/{0} DC' -f $controllers.Count
    }
    foreach ($name in $cloud) { $sources[$name].Progress='Accesso Graph' }
    $pool=[RunspaceFactory]::CreateRunspacePool(1,3)
    $pool.ApartmentState='STA'; $pool.ThreadOptions='ReuseThread'
    $adPool=[RunspaceFactory]::CreateRunspacePool(1,$adConcurrency)
    $adPool.ApartmentState='STA'; $adPool.ThreadOptions='ReuseThread'
    $tasks=New-Object 'System.Collections.Generic.List[object]'
    $cache=Get-ExplorerCloudCache
    $body=Get-ExplorerReadWorkerScript
    $serialGlpiQueued=$false
    $script:LastParallelRows=$null;$script:ParallelRowsRevision=0
    $terminalEvent='search.interrupted'
    try {
        $pool.Open(); $adPool.Open()
        $arguments=@{Pool=$pool;Body=$body;ConfigPath=$ConfigPath;Fragment=$fragment;Configuration=$config;Cache=$cache
            UserToken=$GlpiUserToken;AppToken=$GlpiAppToken;Refresh=[bool]$ForceCloudRefresh;GlpiLookupCache=$glpiLookupCache}
        $adArguments=@{}; foreach ($key in $arguments.Keys) { $adArguments[$key]=$arguments[$key] }; $adArguments.Pool=$adPool
        foreach ($job in $jobs) {
            Write-ExplorerSearchLog $log 'source.start' @{Source=$job.Kind}
            [void]$tasks.Add((Start-ExplorerReadTask -Job $job @arguments))
        }
        Send-ParallelSnapshot $sources $controllers 'Ricerca avviata.' $ProgressQueue
        while ($tasks.Count -gt 0 -or $adPending.Count -gt 0 -or $adRetry.Count -gt 0) {
            $updated=$false;$dataUpdated=$false
            while ($adActive.Count -lt $adConcurrency) {
                $attempt=1
                if ($adPending.Count -gt 0) { $dc=$adPending.Dequeue() }
                elseif ($adRetry.Count -gt 0 -and $adActive.Count -eq 0) { $dc=$adRetry.Dequeue();$attempt=2 }
                else { break }
                $adLog=$null
                if ($null -ne $log) { $adLog=@{Path=$log.Path; Dc=$dc; Attempt=$attempt} }
                $adJob=[pscustomobject]@{
                    Kind='AD'; DomainController=$dc; Isolated=[bool]$ParallelAdReads; Attempt=$attempt; TimeoutSeconds=$AdReadTimeoutSeconds; AdSearchLog=$adLog
                }
                Write-ExplorerSearchLog $adLog 'ad.dispatch' @{ActiveReaders=($adActive.Count+1); ElapsedMs=$watch.ElapsedMilliseconds}
                [void]$tasks.Add((Start-ExplorerReadTask -Job $adJob @adArguments))
                $adActive[$dc]=$true
                $updated=$true
            }
            $sources.AD.CurrentTarget=@($adActive.Keys) -join ', '
            foreach ($task in @($tasks.ToArray())) {
                $job=$task.Job
                if (-not $task.Operation.IsCompleted) {
                    if ($job.Kind -in @('Entra','Intune') -and -not $task.TimedOut -and
                        $task.Watch.Elapsed.TotalSeconds -ge $config.CloudReadTimeoutSeconds) {
                        $task.TimedOut=$true
                        $sources[$job.Kind].Progress='Interruzione per timeout'
                        try { $task.StopOperation=$task.Pipeline.BeginStop($null,$null) }
                        catch { if (-not $task.Operation.IsCompleted) { throw } }
                        $updated=$true
                    }
                    continue
                }
                try {
                    if ($null -ne $task.StopOperation) { $task.Pipeline.EndStop($task.StopOperation) }
                    $output=@($task.Pipeline.EndInvoke($task.Operation))
                    if ($task.Pipeline.Streams.Error.Count -gt 0) { throw $task.Pipeline.Streams.Error[0] }
                    foreach ($warning in $task.Pipeline.Streams.Warning) { Write-Warning $warning.Message }
                    if ($output.Count -ne 1 -or $null -eq $output[0].PSObject.Properties['State'] -or
                        $output[0].State -notin @('OK','Errore','Esclusa')) { throw 'Risposta del lettore non valida o non conclusiva.' }
                    if ($job.Kind -ne 'GraphAuth') {
                        foreach ($field in @('Records','DcSources','CheckedAtUtc','FromCache','Error')) {
                            if ($null -eq $output[0].PSObject.Properties[$field]) { throw ('Risposta del lettore incompleta: ' + $field) }
                        }
                    }
                    $result=$output[0]
                }
                catch {
                    $failureLog=$log
                    if ($job.Kind -eq 'AD') { $failureLog=$job.AdSearchLog }
                    Write-ExplorerSearchLog $failureLog 'reader.error' @{Source=$job.Kind} -Failure $_
                    $result=New-ParallelSource $job.Kind 'Errore' $_.Exception.Message
                }
                finally { $task.Watch.Stop(); $task.Pipeline.Dispose(); [void]$tasks.Remove($task) }
                if ($task.TimedOut) {
                    $result=New-ParallelSource $job.Kind 'Errore' ('Tempo massimo di lettura {0} superato ({1} s). Fonte non verificabile; ripetere con Rileggi cloud.' -f $job.Kind,$config.CloudReadTimeoutSeconds)
                    foreach ($key in @($cache.Keys)) {
                        if ([string]$key -like ('*|'+$job.Kind)) { $cache.Remove($key) }
                    }
                }
                if ($job.Kind -ne 'AD') {
                    $sourceName=$job.Kind
                    if ($null -ne $job.PSObject.Properties['SerialDevices']) { $sourceName='GLPI.Serial' }
                    Write-ExplorerSearchLog $log 'source.end' @{Source=$sourceName; State=$result.State; ElapsedMs=$task.Watch.ElapsedMilliseconds; TimedOut=$task.TimedOut}
                }
                if ($job.Kind -eq 'GraphAuth') {
                    if ($result.State -eq 'OK') {
                        foreach ($name in $cloud) {
                            $sources[$name].Progress='Lettura'
                            Write-ExplorerSearchLog $log 'source.start' @{Source=$name}
                            [void]$tasks.Add((Start-ExplorerReadTask -Job ([pscustomobject]@{Kind=$name;ReadProgress=$readProgress}) @arguments))
                        }
                    }
                    else {
                        foreach ($name in $cloud) {
                            $sources[$name]=New-ParallelSource $name 'Errore' $result.Error
                            $sources[$name] | Add-Member -NotePropertyName CompletedAfterSeconds -NotePropertyValue $watch.Elapsed.TotalSeconds
                        }
                    }
                }
                elseif ($job.Kind -eq 'AD') {
                    $dc=$job.DomainController
                    $adActive.Remove($dc)
                    $sources.AD.CurrentTarget=@($adActive.Keys) -join ', '
                    if ($result.DcSources.Count -ne 1 -or $result.DcSources[0].DomainController -ine $dc) {
                        Write-ExplorerSearchLog $job.AdSearchLog 'ad.response.invalid' @{Sources=$result.DcSources.Count}
                        $detail=$result.Error
                        if (-not $detail) { $detail='Risposta AD mancante o riferita a un altro DC.' }
                        $result=New-ParallelSource 'AD' 'Errore' $detail
                        $result.DcSources=@([pscustomobject]@{DomainController=$dc;Stato='Errore';Verificato=$false;Trovati=$null;Errore=$detail})
                    }
                    $dcResult=$result.DcSources[0]
                    if ($null -ne $job.AdSearchLog) {
                        Write-ExplorerSearchLog $job.AdSearchLog 'ad.attempt.end' @{State=$dcResult.Stato; Verified=$dcResult.Verificato; Records=$dcResult.Trovati; ElapsedMs=$task.Watch.ElapsedMilliseconds}
                    }
                    $seconds=$task.Watch.Elapsed.TotalSeconds
                    $firstFailure=$adFirstFailures[$dc]
                    if ($ParallelAdReads -and $job.Attempt -eq 1 -and -not $dcResult.Verificato) {
                        $adConcurrency=1
                        $adFirstFailures[$dc]=[pscustomobject]@{Seconds=$seconds;Error=$dcResult.Errore}
                        $adRetry.Enqueue($dc)
                        Write-ExplorerSearchLog $job.AdSearchLog 'ad.retry.queued' @{ActiveReaders=$adActive.Count}
                        $sources.AD.Progress='{0}/{1} DC | ripiego sequenziale' -f $adResults.Count,$controllers.Count
                        $updated=$true
                        continue
                    }
                    $dcResult | Add-Member -NotePropertyMembers @{ Seconds=$seconds; Attempts=$job.Attempt; FirstFailure=$firstFailure }
                    $adResults[$dc]=$result
                    $sources.AD.Progress='{0}/{1} DC' -f $adResults.Count,$controllers.Count
                    if ($adRetry.Count -gt 0) { $sources.AD.Progress+=' | ripiego sequenziale' }
                    $completedResults=@(foreach ($configuredDc in $controllers) {
                        if ($adResults.ContainsKey($configuredDc)) { $adResults[$configuredDc] }
                    })
                    $sources.AD.DcSources=@($completedResults | ForEach-Object { $_.DcSources })
                    $sources.AD.Records=@($completedResults | ForEach-Object { $_.Records })
                    $sources.AD.CheckedAtUtc=[datetimeoffset]::UtcNow
                    $errors=@($sources.AD.DcSources | Where-Object { -not $_.Verificato } | ForEach-Object { "$($_.DomainController): $($_.Errore)" })
                    $sources.AD.Error=$errors -join ' | '
                    if ($adResults.Count -eq $controllers.Count) {
                        $sources.AD.State='OK'; if ($errors.Count -gt 0) { $sources.AD.State='Errore' }
                        $sources.AD | Add-Member -NotePropertyName CompletedAfterSeconds -NotePropertyValue $watch.Elapsed.TotalSeconds
                    }
                }
                else {
                    if ($job.Kind -eq 'GLPI' -and $null -ne $job.PSObject.Properties['SerialDevices']) { $result.Records=@(@($sources.GLPI.Records)+@($result.Records) | Sort-Object GlpiId -Unique) }
                    $result | Add-Member -NotePropertyName CompletedAfterSeconds -NotePropertyValue $watch.Elapsed.TotalSeconds
                    $sources[$job.Kind]=$result
                }
                $updated=$true;$dataUpdated=$true
            }
            if (-not $serialGlpiQueued -and $sources.Intune.State -eq 'OK' -and $sources.GLPI.State -eq 'OK') {
                $serialGlpiQueued=$true
                if (@(Get-ExplorerSerials $sources.Intune.Records).Count) {
                    $sources.GLPI.State='In attesa';$sources.GLPI | Add-Member -NotePropertyName Progress -NotePropertyValue 'Ricerca tramite seriali Intune' -Force
                    $sources.GLPI.CompletedAfterSeconds=$null
                    Write-ExplorerSearchLog $log 'source.start' @{Source='GLPI.Serial'}
                    [void]$tasks.Add((Start-ExplorerReadTask -Job ([pscustomobject]@{Kind='GLPI';ReadProgress=$readProgress;SerialDevices=@($sources.Intune.Records)}) @arguments))
                    $updated=$true;$dataUpdated=$true
                }
            }
            $notice=$null
            while ($readProgress.TryDequeue([ref]$notice)) {
                if ($sources.Contains($notice.Source) -and $sources[$notice.Source].State -eq 'In attesa' -and
                    $sources[$notice.Source].Progress -ne 'Interruzione per timeout') {
                    $sources[$notice.Source].Progress=$notice.Progress; $updated=$true
                }
            }
            if ($updated) {
                $pending=@($sources.Values | Where-Object { $_.State -eq 'In attesa' } | ForEach-Object { $_.Name })
                Send-ParallelSnapshot $sources $controllers ('In corso: ' + ($pending -join ', ')) $ProgressQueue -ReuseRows:(-not $dataUpdated)
            }
            if ($tasks.Count -gt 0) { [Threading.Thread]::Sleep(30) }
        }
        # All scheduled readers have terminated; errors are terminal outcomes too.
        foreach ($source in $sources.Values) {
            if ($source.State -eq 'In attesa') { $source.State='Errore'; $source.Error='Il lettore non ha restituito un esito conclusivo.' }
        }
        $errorCount=@($sources.Values | Where-Object { $_.State -eq 'Errore' }).Count
        $message='Ricerca completata in {0:N1} s.' -f $watch.Elapsed.TotalSeconds
        if ($errorCount -gt 0) { $message+=' Fonti con errori: {0}.' -f $errorCount }
        Send-ParallelSnapshot $sources $controllers $message $ProgressQueue -Complete
        $terminalEvent='search.end'
    }
    catch [System.Management.Automation.PipelineStoppedException] { throw }
    catch {
        $terminalEvent='search.failed'
        Write-ExplorerSearchLog $log 'search.error' -Failure $_
        throw
    }
    finally {
        Stop-ExplorerReadTasks $tasks
        $adPool.Close(); $adPool.Dispose(); $pool.Close(); $pool.Dispose(); $watch.Stop()
        Write-ExplorerSearchLog $log $terminalEvent @{AdState=$sources.AD.State; CompletedDc=$adResults.Count; ConfiguredDc=$controllers.Count; ElapsedMs=$watch.ElapsedMilliseconds}
    }
}

Export-ModuleMember -Function Invoke-ComputerExplorerParallelSearch
