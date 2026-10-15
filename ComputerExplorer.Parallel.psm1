#requires -version 5.1
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'ComputerExplorer.Core.psm1') -ErrorAction Stop

function New-ParallelSource {
    param([string]$Name, [string]$State = 'In attesa', [string]$ErrorText)
    [pscustomobject]@{ Name=$Name; State=$State; Records=@(); DcSources=@(); CheckedAtUtc=$null; FromCache=$false; Error=$ErrorText }
}

function Get-ExplorerReadWorkerScript {
    return {
        param($Job, $CorePath, $ConfigPath, $Fragment, $Configuration, $Cache, $UserToken, $AppToken, $Refresh)
        $ErrorActionPreference = 'Stop'
        Import-Module $CorePath -ErrorAction Stop
        if ($Job.Kind -eq 'GraphAuth') {
            Connect-ExplorerGraph -Sources $Job.CloudSources
            return [pscustomobject]@{ State='OK'; Error=$null }
        }
        $arguments = @{ Source=$Job.Kind; NameFragment=$Fragment; ConfigPath=$ConfigPath; Configuration=$Configuration; CloudCache=$Cache
            GlpiUserToken=$UserToken; GlpiAppToken=$AppToken; ForceCloudRefresh=$Refresh }
        if ($Job.Kind -eq 'AD') { $arguments.DomainController=$Job.DomainController }
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
        return [pscustomobject]@{ Job=$Job; Pipeline=$pipeline; Operation=$operation; StopOperation=$null }
    }
    catch { $pipeline.Dispose(); throw }
}

function Stop-ExplorerReadTasks {
    param($Tasks)
    # Invia tutti gli stop prima di attenderli: nessun lettore resta in background.
    foreach ($task in $Tasks) {
        if (-not $task.Operation.IsCompleted) {
            try { $task.StopOperation=$task.Pipeline.BeginStop($null, $null) } catch { }
        }
    }
    foreach ($task in $Tasks) {
        try { if ($null -ne $task.StopOperation) { $task.Pipeline.EndStop($task.StopOperation) } } catch { }
        $task.Pipeline.Dispose()
    }
}

function Send-ParallelSnapshot {
    param($Sources, $Controllers, [string]$Message, $Queue, [switch]$Complete)
    $snapshot = [pscustomobject]@{
        Message=$Message; Complete=[bool]$Complete
        Rows=@(Merge-ExplorerResults -Sources $Sources -DomainControllers $Controllers)
        Sources=@($Sources.Values | ForEach-Object {
            [pscustomobject]@{ Name=$_.Name; State=$_.State; Count=$_.Records.Count; CheckedAtUtc=$_.CheckedAtUtc
                FromCache=$_.FromCache; Error=$_.Error; DcSources=@($_.DcSources) }
        })
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
    if ($cloud.Count -gt 0) { [void]$jobs.Add([pscustomobject]@{Kind='GraphAuth';CloudSources=$cloud}) }
    if ($sources.AD.State -eq 'In attesa') {
        foreach ($dc in $controllers) { [void]$jobs.Add([pscustomobject]@{Kind='AD';DomainController=$dc}) }
    }
    Send-ParallelSnapshot $sources $controllers 'Ricerche in parallelo. Se richiesto, completare il login Graph nel browser.' $ProgressQueue
    $pool=[RunspaceFactory]::CreateRunspacePool(1,8)
    $pool.ApartmentState='STA'; $pool.ThreadOptions='ReuseThread'
    $tasks=New-Object 'System.Collections.Generic.List[object]'
    $cache=Get-ExplorerCloudCache
    $body=Get-ExplorerReadWorkerScript
    $adCompleted=0
    $watch=[Diagnostics.Stopwatch]::StartNew()
    try {
        $pool.Open()
        $arguments=@{Pool=$pool;Body=$body;ConfigPath=$ConfigPath;Fragment=$fragment;Configuration=$config;Cache=$cache
            UserToken=$GlpiUserToken;AppToken=$GlpiAppToken;Refresh=[bool]$ForceCloudRefresh}
        foreach ($job in $jobs) { [void]$tasks.Add((Start-ExplorerReadTask -Job $job @arguments)) }
        while ($tasks.Count -gt 0) {
            $updated=$false
            foreach ($task in @($tasks.ToArray())) {
                if (-not $task.Operation.IsCompleted) { continue }
                $job=$task.Job
                try {
                    $output=@($task.Pipeline.EndInvoke($task.Operation))
                    if ($task.Pipeline.Streams.Error.Count -gt 0) { throw $task.Pipeline.Streams.Error[0] }
                    foreach ($warning in $task.Pipeline.Streams.Warning) { Write-Warning $warning.Message }
                    if ($output.Count -ne 1 -or $null -eq $output[0].PSObject.Properties['State']) { throw 'Risposta del lettore non valida.' }
                    $result=$output[0]
                }
                catch { $result=New-ParallelSource $job.Kind 'Errore' $_.Exception.Message }
                finally { $task.Pipeline.Dispose(); [void]$tasks.Remove($task) }
                if ($job.Kind -eq 'GraphAuth') {
                    if ($result.State -eq 'OK') {
                        foreach ($name in $cloud) { [void]$tasks.Add((Start-ExplorerReadTask -Job ([pscustomobject]@{Kind=$name}) @arguments)) }
                    }
                    else {
                        foreach ($name in $cloud) { $sources[$name]=New-ParallelSource $name 'Errore' $result.Error }
                    }
                }
                elseif ($job.Kind -eq 'AD') {
                    $adCompleted++
                    if ($result.DcSources.Count -eq 0) {
                        $result.DcSources=@([pscustomobject]@{DomainController=$job.DomainController;Stato='Errore';Verificato=$false;Trovati=$null;Errore=$result.Error})
                    }
                    $sources.AD.DcSources=@($sources.AD.DcSources)+@($result.DcSources)
                    $sources.AD.Records=@($sources.AD.Records)+@($result.Records)
                    $sources.AD.CheckedAtUtc=[datetimeoffset]::UtcNow
                    $errors=@($sources.AD.DcSources | Where-Object { -not $_.Verificato } | ForEach-Object { "$($_.DomainController): $($_.Errore)" })
                    $sources.AD.Error=$errors -join ' | '
                    if ($adCompleted -eq $controllers.Count) {
                        $sources.AD.State='OK'; if ($errors.Count -gt 0) { $sources.AD.State='Errore' }
                    }
                }
                else { $sources[$job.Kind]=$result }
                $updated=$true
            }
            if ($updated) {
                $pending=@($sources.Values | Where-Object { $_.State -eq 'In attesa' } | ForEach-Object { $_.Name })
                Send-ParallelSnapshot $sources $controllers ('In corso: ' + ($pending -join ', ')) $ProgressQueue
            }
            if ($tasks.Count -gt 0) { [Threading.Thread]::Sleep(30) }
        }
        Send-ParallelSnapshot $sources $controllers ('Ricerca completata in {0:N1} s.' -f $watch.Elapsed.TotalSeconds) $ProgressQueue -Complete
    }
    finally { Stop-ExplorerReadTasks $tasks; $pool.Close(); $pool.Dispose(); $watch.Stop() }
}

Export-ModuleMember -Function Invoke-ComputerExplorerParallelSearch
