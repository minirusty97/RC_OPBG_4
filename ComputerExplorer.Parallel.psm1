#requires -version 5.1
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'ComputerExplorer.Core.psm1') -ErrorAction Stop

function New-ParallelSource {
    param([string]$Name, [string]$State = 'In attesa', [string]$ErrorText)
    [pscustomobject]@{ Name=$Name; State=$State; Records=@(); DcSources=@(); CheckedAtUtc=$null; FromCache=$false; Error=$ErrorText; Progress=''; CurrentTarget='' }
}

function Get-ExplorerReadWorkerScript {
    return {
        param($Job, $CorePath, $ConfigPath, $Fragment, $Configuration, $Cache, $UserToken, $AppToken, $Refresh)
        $ErrorActionPreference = 'Stop'
        Import-Module $CorePath -ErrorAction Stop
        if ($Job.Kind -eq 'GraphAuth') {
            Connect-ExplorerGraph -Sources $Job.CloudSources -ProgressQueue $Job.AuthQueue
            return [pscustomobject]@{ State='OK'; Error=$null }
        }
        $arguments = @{ Source=$Job.Kind; NameFragment=$Fragment; ConfigPath=$ConfigPath; Configuration=$Configuration; CloudCache=$Cache
            GlpiUserToken=$UserToken; GlpiAppToken=$AppToken; ForceCloudRefresh=$Refresh }
        if ($Job.Kind -eq 'AD') { $arguments.DomainController=$Job.DomainController }
        if ($Job.Kind -in @('Entra','Intune')) { $arguments.ProgressQueue=$Job.ReadProgress }
        Read-ExplorerSource @arguments
    }
}

function Start-ExplorerReadTask {
    param($Job, $Pool, [scriptblock]$Body, $ConfigPath, $Fragment, $Configuration, $Cache, $UserToken, $AppToken, $Refresh)
    $pipeline = [PowerShell]::Create()
    try {
        $pipeline.RunspacePool = $Pool
        [void]$pipeline.AddScript($Body.ToString()).AddArgument($Job).AddArgument((Join-Path $PSScriptRoot 'ComputerExplorer.Core.psm1')).AddArgument($ConfigPath).AddArgument($Fragment).AddArgument($Configuration).AddArgument($Cache).AddArgument($UserToken).AddArgument($AppToken).AddArgument($Refresh)
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
    param($Sources, $Controllers, [string]$Message, $Queue, [switch]$Complete)
    $snapshot = [pscustomobject]@{
        Message=$Message; Complete=[bool]$Complete
        Rows=@(Merge-ExplorerResults -Sources $Sources -DomainControllers $Controllers)
        Sources=@($Sources.Values | ForEach-Object {
            [pscustomobject]@{ Name=$_.Name; State=$_.State; Count=$_.Records.Count; CheckedAtUtc=$_.CheckedAtUtc
                FromCache=$_.FromCache; Error=$_.Error; DcSources=@($_.DcSources)
                Progress=$(if ($null -ne $_.PSObject.Properties['Progress']) { $_.Progress } else { '' })
                CurrentTarget=$(if ($null -ne $_.PSObject.Properties['CurrentTarget']) { $_.CurrentTarget } else { '' }) }
        })
    }
    if ($Complete -and $snapshot.Rows.Count -eq 0 -and @($snapshot.Sources | Where-Object { $_.State -eq 'Errore' }).Count -eq 0) {
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
        [switch]$ForceCloudRefresh, $ProgressQueue
    )
    $config=Read-ExplorerConfiguration $ConfigPath
    $fragment=$NameFragment.Trim()
    if ($fragment.Length -lt $config.MinimumCharacters) { throw "Inserire almeno $($config.MinimumCharacters) caratteri." }
    $enabled=@($EnabledSources | Sort-Object -Unique)
    $property=$config.Settings.PSObject.Properties['DomainControllers']
    $controllers=@()
    if ($null -ne $property) { $controllers=@($property.Value | ForEach-Object { ([string]$_).Trim() } | Sort-Object -Unique) }
    $sources=[ordered]@{}
    foreach ($name in @('AD','Entra','Intune','GLPI')) {
        $state='Esclusa'; if ($enabled -contains $name) { $state='In attesa' }
        $sources[$name]=New-ParallelSource $name $state
    }
    if ($enabled -contains 'AD' -and ($controllers.Count -eq 0 -or $controllers -contains '')) {
        $sources.AD=New-ParallelSource 'AD' 'Errore' 'Configurare i Domain Controller nel JSON locale.'
    }
    $cloud=@($enabled | Where-Object { $_ -in @('Entra','Intune') })
    $jobs=New-Object 'System.Collections.Generic.List[object]'
    # Servizi indipendenti subito; il solo login Graph precede le due letture cloud.
    if ($enabled -contains 'GLPI') { [void]$jobs.Add([pscustomobject]@{Kind='GLPI'}) }
    if ($cloud.Count -gt 0) { [void]$jobs.Add([pscustomobject]@{Kind='GraphAuth';CloudSources=$cloud;AuthQueue=$ProgressQueue}) }
    # One AD runspace and one queued DC at a time, independent of cloud/GLPI.
    $adPending=New-Object 'System.Collections.Generic.Queue[string]'
    if ($sources.AD.State -eq 'In attesa') {
        foreach ($dc in $controllers) { $adPending.Enqueue($dc) }
        $sources.AD.Progress='0/{0} DC' -f $controllers.Count
    }
    foreach ($name in $cloud) { $sources[$name].Progress='Accesso Graph' }
    $pool=[RunspaceFactory]::CreateRunspacePool(1,3)
    $pool.ApartmentState='STA'; $pool.ThreadOptions='ReuseThread'
    $adPool=[RunspaceFactory]::CreateRunspacePool(1,1)
    $adPool.ApartmentState='STA'; $adPool.ThreadOptions='ReuseThread'
    $tasks=New-Object 'System.Collections.Generic.List[object]'
    $readProgress=New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $cache=Get-ExplorerCloudCache
    $body=Get-ExplorerReadWorkerScript
    $adCompleted=0
    $watch=[Diagnostics.Stopwatch]::StartNew()
    try {
        $pool.Open(); $adPool.Open()
        $arguments=@{Pool=$pool;Body=$body;ConfigPath=$ConfigPath;Fragment=$fragment;Configuration=$config;Cache=$cache
            UserToken=$GlpiUserToken;AppToken=$GlpiAppToken;Refresh=[bool]$ForceCloudRefresh}
        $adArguments=@{}; foreach ($key in $arguments.Keys) { $adArguments[$key]=$arguments[$key] }; $adArguments.Pool=$adPool
        foreach ($job in $jobs) { [void]$tasks.Add((Start-ExplorerReadTask -Job $job @arguments)) }
        if ($adPending.Count -gt 0) {
            $dc=$adPending.Dequeue(); $sources.AD.CurrentTarget=$dc
            [void]$tasks.Add((Start-ExplorerReadTask -Job ([pscustomobject]@{Kind='AD';DomainController=$dc}) @adArguments))
        }
        Send-ParallelSnapshot $sources $controllers 'Ricerca avviata. Se richiesto, completare il login Graph nel browser.' $ProgressQueue
        while ($tasks.Count -gt 0) {
            $updated=$false
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
                catch { $result=New-ParallelSource $job.Kind 'Errore' $_.Exception.Message }
                finally { $task.Watch.Stop(); $task.Pipeline.Dispose(); [void]$tasks.Remove($task) }
                if ($task.TimedOut) {
                    $result=New-ParallelSource $job.Kind 'Errore' ('Tempo massimo di lettura {0} superato ({1} s). Fonte non verificabile; ripetere con Rileggi cloud.' -f $job.Kind,$config.CloudReadTimeoutSeconds)
                    foreach ($key in @($cache.Keys)) {
                        if ([string]$key -like ('*|'+$job.Kind)) { $cache.Remove($key) }
                    }
                }
                if ($job.Kind -eq 'GraphAuth') {
                    if ($result.State -eq 'OK') {
                        foreach ($name in $cloud) { $sources[$name].Progress='Lettura'; [void]$tasks.Add((Start-ExplorerReadTask -Job ([pscustomobject]@{Kind=$name;ReadProgress=$readProgress}) @arguments)) }
                    }
                    else {
                        foreach ($name in $cloud) { $sources[$name]=New-ParallelSource $name 'Errore' $result.Error }
                    }
                }
                elseif ($job.Kind -eq 'AD') {
                    $adCompleted++
                    $sources.AD.Progress='{0}/{1} DC' -f $adCompleted,$controllers.Count
                    if ($result.DcSources.Count -eq 0) {
                        $result.DcSources=@([pscustomobject]@{DomainController=$job.DomainController;Stato='Errore';Verificato=$false;Trovati=$null;Errore=$result.Error})
                    }
                    $sources.AD.DcSources=@($sources.AD.DcSources)+@($result.DcSources)
                    $sources.AD.Records=@($sources.AD.Records)+@($result.Records)
                    $sources.AD.CheckedAtUtc=[datetimeoffset]::UtcNow
                    $errors=@($sources.AD.DcSources | Where-Object { -not $_.Verificato } | ForEach-Object { "$($_.DomainController): $($_.Errore)" })
                    $sources.AD.Error=$errors -join ' | '
                    if ($adPending.Count -gt 0) {
                        $dc=$adPending.Dequeue(); $sources.AD.CurrentTarget=$dc
                        [void]$tasks.Add((Start-ExplorerReadTask -Job ([pscustomobject]@{Kind='AD';DomainController=$dc}) @adArguments))
                    }
                    else {
                        $sources.AD.CurrentTarget=''
                        $sources.AD.State='OK'; if ($errors.Count -gt 0) { $sources.AD.State='Errore' }
                    }
                }
                else { $sources[$job.Kind]=$result }
                $updated=$true
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
                Send-ParallelSnapshot $sources $controllers ('In corso: ' + ($pending -join ', ')) $ProgressQueue
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
    }
    finally { Stop-ExplorerReadTasks $tasks; $adPool.Close(); $adPool.Dispose(); $pool.Close(); $pool.Dispose(); $watch.Stop() }
}

Export-ModuleMember -Function Invoke-ComputerExplorerParallelSearch
