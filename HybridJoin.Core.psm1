#requires -version 5.1
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'DeviceModules.Core.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'ComputerExplorer.Core.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'ComputerExplorer.Removal.psm1') -ErrorAction Stop
$script:HybridRows=@{}
$script:HybridCandidates=@{}
$script:HybridContext=''

function New-HybridComparison {
    param($AdComputer, [object[]]$EntraDevices)

    $result = New-HybridBaseComparison -AdComputer $AdComputer -EntraDevices $EntraDevices
    $guid = ConvertTo-DmId $AdComputer.ObjectGUID
    $identity = @()
    $deviceIds = @()
    $state = 'Non applicabile'
    if ($result.HybridCount) {
        $identity = @(foreach ($device in $result.HybridDevices) {
            $deviceId = [guid]::Empty
            $matchesAd = [guid]::TryParse([string]$device.deviceId, [ref]$deviceId) -and $deviceId.ToString() -eq $guid
            $matchState = 'Non corrisponde'
            if ($matchesAd) { $matchState = 'Corrisponde'; $deviceIds = @($guid) }
            [pscustomobject]@{
                ObjectId = [string]$device.id
                DeviceId = [string]$device.deviceId
                Name = [string]$device.displayName
                TrustType = [string]$device.trustType
                State = $matchState
            }
        })
        $state = 'Corrisponde'
        if (@($identity | Where-Object State -eq 'Non corrisponde').Count) {
            $state = 'Non corrisponde'
            $result.Severity = 'Error'
            $result.OverallState = 'ERRORE'
            if ($result.HybridCount -eq 1) { $result.HybridState = 'HYBRID DA VERIFICARE' }
            $result.Anomalies = (@($result.Anomalies, 'Device ID Entra Hybrid diverso dal GUID AD') | Where-Object { $_ }) -join '; '
        }
    }
    $properties = @{
        Name = $AdComputer.Name
        Key = $guid
        ADGuid = $guid
        IdentityState = $state
        IdentityRecords = $identity
        DeviceIds = $deviceIds
        EntraObjectIds = (@($EntraDevices | ForEach-Object id) -join ', ')
        EntraDeviceIds = (@($EntraDevices | ForEach-Object deviceId | Sort-Object -Unique) -join ', ')
    }
    $result | Add-Member -NotePropertyMembers $properties
    return $result
}

function Start-HybridRead {
    param($Pool, [scriptblock]$Reader, [string]$Source, [string]$Controller, $Query, $Access, $Queue)
    $pipeline = [PowerShell]::Create()
    try {
        $pipeline.RunspacePool = $Pool
        [void]$pipeline.AddScript($Reader.ToString()).AddArgument($PSScriptRoot).AddArgument($Source).AddArgument($Controller).AddArgument($Query).AddArgument($Access).AddArgument($Queue)
        $invocation = $pipeline.BeginInvoke()
        [pscustomobject]@{
            Source=$Source; Pipeline=$pipeline; Invocation=$invocation
            Watch=[Diagnostics.Stopwatch]::StartNew(); StopInvocation=$null
        }
    }
    catch { $pipeline.Dispose(); throw }
}

function Get-HybridReadSources {
    param([string]$Controller, [hashtable]$Query, $Access, $Queue, [int]$CloudTimeoutSeconds)

    $reader = {
        param($Root, $Source, $Controller, $Query, $Access, $Queue)
        $ErrorActionPreference = 'Stop'
        if ($Source -eq 'AD') {
            . (Join-Path $Root 'ComputerExplorer.AdRead.ps1')
            return Read-ExplorerAdProcess -CorePath (Join-Path $Root 'ComputerExplorer.Core.psm1') -DomainController $Controller -OuSearch $Query -TimeoutSeconds 30
        }
        Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
        Import-Module (Join-Path $Root 'DeviceModules.Core.psm1') -ErrorAction Stop
        [void](Assert-DmSession $Access)
        if ($Source -eq 'Entra') { return [pscustomobject]@{Records=@(Get-DmEntraInventory $Queue)} }
        Get-DmIntuneInventory -Access $Access -ProgressQueue $Queue
    }
    $pool = [RunspaceFactory]::CreateRunspacePool(1, 3)
    $tasks = New-Object 'Collections.Generic.List[object]'
    $results = @{}
    $adSeconds = 0
    try {
        $pool.Open()
        foreach ($source in @('AD', 'Entra', 'Intune')) {
            $tasks.Add((Start-HybridRead $pool $reader $source $Controller $Query $Access $Queue))
        }
        Send-DmProgress $Queue ('Lettura OU su ' + $Controller + ' e inventari Entra e Intune...')
        while ($tasks.Count) {
            foreach ($task in $tasks.ToArray()) {
                if (-not $task.Invocation.IsCompleted) {
                    if ($task.Source -ne 'AD' -and $null -eq $task.StopInvocation -and $task.Watch.Elapsed.TotalSeconds -ge $CloudTimeoutSeconds) {
                        try { $task.StopInvocation = $task.Pipeline.BeginStop($null, $null) }
                        catch { if (-not $task.Invocation.IsCompleted) { throw } }
                    }
                    continue
                }
                $data = $null
                $failure = ''
                try {
                    if ($null -ne $task.StopInvocation) {
                        $task.Pipeline.EndStop($task.StopInvocation)
                        throw ('Tempo massimo di lettura ' + $task.Source + ' superato (' + $CloudTimeoutSeconds + ' s).')
                    }
                    $output = @($task.Pipeline.EndInvoke($task.Invocation))
                    if ($task.Pipeline.Streams.Error.Count) { throw $task.Pipeline.Streams.Error[0] }
                    if ($output.Count -ne 1) { throw 'Risposta della fonte incompleta.' }
                    $data = $output[0]
                    if ($task.Source -eq 'AD' -and $data.DomainController -ine $Controller) { throw 'Risposta AD riferita a un altro DC.' }
                }
                catch [System.Management.Automation.PipelineStoppedException] { throw }
                catch { $failure = $_.Exception.Message }
                finally {
                    $task.Watch.Stop()
                    $task.Pipeline.Dispose()
                    [void]$tasks.Remove($task)
                }
                if ($failure) {
                    if ($task.Source -eq 'AD') { throw ('Lettura OU non completata su ' + $Controller + '. ' + $failure) }
                    if ($task.Source -eq 'Entra') { throw ('Lettura Entra non completata. ' + $failure) }
                    $data = [pscustomobject]@{Records=@(); State='Errore'; Error=$failure}
                }
                $results[$task.Source] = $data
                if ($task.Source -eq 'AD') { $adSeconds = $task.Watch.Elapsed.TotalSeconds }
            }
            if ($tasks.Count) { Start-Sleep -Milliseconds 40 }
        }

        [pscustomobject]@{
            AD = $results.AD
            AdSeconds = $adSeconds
            Entra = @($results.Entra.Records)
            Intune = $results.Intune
        }
    }
    finally {
        foreach ($task in $tasks) {
            if ($null -eq $task.StopInvocation -and -not $task.Invocation.IsCompleted) {
                try { $task.StopInvocation = $task.Pipeline.BeginStop($null, $null) } catch { }
            }
        }
        foreach ($task in $tasks) {
            try { if ($null -ne $task.StopInvocation) { $task.Pipeline.EndStop($task.StopInvocation) } } catch { }
            $task.Pipeline.Dispose()
        }
        $pool.Dispose()
    }
}

function Set-HybridIntuneState {
    param($Row, [string]$SourceState)
    $state = 'Da regolarizzare'
    $reason = 'Serve una sola identità Entra Hybrid abilitata, gestita da MDM e corrispondente al GUID AD.'
    if ($SourceState -ne 'OK') {
        $state = 'Non verificabile'
        $reason = 'Lettura Intune non disponibile.'
    }
    elseif ($Row.HybridCount -eq 1 -and $Row.IdentityState -eq 'Corrisponde' -and
        $Row.HybridDevices[0].accountEnabled -eq $true -and $Row.HybridDevices[0].isManaged -eq $true) {
        $reason = 'Nessun dispositivo Intune associato al Device ID Hybrid.'
        if ($Row.IntuneRecords.Count -eq 1) { $state = 'OK'; $reason = '' }
        elseif ($Row.IntuneRecords.Count -gt 1) { $reason = 'Più record Intune associati allo stesso Device ID Hybrid.' }
    }
    $Row | Add-Member -NotePropertyMembers @{IntuneState=$state; IntuneReason=$reason}
}

function Get-HybridJoinSnapshot {
    [CmdletBinding()]
    param([string]$ConfigPath,[string]$EnvPath,$GraphAccess,$ProgressQueue)
    $context = Assert-DmSession $GraphAccess
    $script:HybridRows = @{}
    $script:HybridCandidates = @{}
    $script:HybridContext = ''
    $settings = Read-DmSettings $ConfigPath HybridJoin
    $options = $settings.Options
    $ous = @($options.TargetOus | ForEach-Object { ([string]$_).Trim().TrimEnd(',') } | Sort-Object -Unique)
    if (-not $ous.Count -or @($ous | Where-Object { $_ -notmatch '^OU=' -or $_ -match '[\r\n\x00]' }).Count) {
        throw 'Configurare almeno una OU valida nelle Impostazioni Hybrid Join.'
    }
    if ($options.SearchScope -notin @('Base','OneLevel','Subtree')) { throw 'SearchScope Hybrid Join non valido.' }
    $server = ([string]$options.AdServer).Trim()
    if (-not $server) { $server = Get-ExplorerSearchControllers $settings.Config.Settings | Select-Object -First 1 }
    if (-not $server) { throw 'Configurare un server AD nelle Impostazioni.' }
    $query = @{TargetOus=$ous; SearchScope=$options.SearchScope}
    $reads = Get-HybridReadSources -Controller $server -Query $query -Access $GraphAccess -Queue $ProgressQueue -CloudTimeoutSeconds $settings.Config.CloudReadTimeoutSeconds

    $computers = @{}
    $ouMembers = [ordered]@{}
    foreach ($ou in $reads.AD.Ous) {
        $dn = $ou.DistinguishedName
        if (-not $ouMembers.Contains($dn)) { $ouMembers[$dn] = @{Name=$ou.Name; ComputerKeys=@{}} }
        foreach ($computer in $ou.Computers) {
            $guid = ConvertTo-DmId $computer.ObjectGUID
            $ouMembers[$dn].ComputerKeys[$guid] = $true
            if (-not $computers.ContainsKey($guid)) {
                $computer.ObjectGUID = $guid
                $computer | Add-Member -NotePropertyMembers @{HostKey=(ConvertTo-HostKey $computer.Name); Ous=@{}}
                $computers[$guid] = $computer
            }
            $computers[$guid].Ous[$dn] = $ou.Name
        }
    }

    $byHost = @{}
    $byGuid = @{}
    foreach ($device in $reads.Entra) {
        $hostKey = ConvertTo-HostKey ([string]$device.displayName)
        if ($hostKey) {
            if (-not $byHost.ContainsKey($hostKey)) { $byHost[$hostKey] = New-Object 'Collections.Generic.List[object]' }
            $byHost[$hostKey].Add($device)
        }
        $deviceId = [guid]::Empty
        if ($device.trustType -ieq 'ServerAd' -and [guid]::TryParse([string]$device.deviceId, [ref]$deviceId) -and $deviceId -ne [guid]::Empty) {
            $key = $deviceId.ToString()
            if (-not $byGuid.ContainsKey($key)) { $byGuid[$key] = New-Object 'Collections.Generic.List[object]' }
            $byGuid[$key].Add($device)
        }
    }
    $rows = @(foreach ($computer in ($computers.Values | Sort-Object Name,DistinguishedName)) {
        $matches = @{}
        $computer | Add-Member -NotePropertyMembers @{
            OUName=(@($computer.Ous.Values | Sort-Object -Unique) -join '; ')
            OUDistinguishedName=(@($computer.Ous.Keys | Sort-Object) -join '; ')
        }
        if ($computer.HostKey -and $byHost.ContainsKey($computer.HostKey)) {
            foreach ($device in $byHost[$computer.HostKey]) { $matches[[string]$device.id] = $device }
        }
        if ($byGuid.ContainsKey($computer.ObjectGUID)) {
            foreach ($device in $byGuid[$computer.ObjectGUID]) { $matches[[string]$device.id] = $device }
        }
        New-HybridComparison -AdComputer $computer -EntraDevices @($matches.Values)
    })
    $sources = Add-DmInventory -Rows $rows -Config $settings.Config -Access $GraphAccess -EnvPath $EnvPath -ProgressQueue $ProgressQueue -IncludeSupplier -IntuneInventory $reads.Intune
    if ((Assert-DmSession $GraphAccess) -cne $context) { throw 'Sessione cambiata durante la lettura. Aggiornare i dati.' }
    $sources | Add-Member -NotePropertyMembers @{AdServer=$server; AdSeconds=$reads.AdSeconds}

    $byKey = @{}
    foreach ($row in $rows) {
        Set-HybridIntuneState -Row $row -SourceState $sources.IntuneState
        $byKey[$row.Key] = $row
        if ($row.RegisteredCount) {
            # Detach candidate identities from the editable grid.
            $candidateRow = [pscustomobject]@{Name=$row.Name; ADGuid=$row.ADGuid; EntraDevices=@($row.EntraDevices | Where-Object trustType -eq 'Workplace')}
            $script:HybridRows[$row.Key] = $candidateRow | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        }
    }
    $stats = @(foreach ($dn in $ouMembers.Keys) {
        $ou = $ouMembers[$dn]
        $members = @($ou.ComputerKeys.Keys | ForEach-Object { $byKey[$_] })
        [pscustomobject]@{
            Name=$ou.Name; DistinguishedName=$dn; Count=$members.Count
            IntuneOk=@($members | Where-Object IntuneState -eq 'OK').Count
            IntuneUnknown=@($members | Where-Object IntuneState -eq 'Non verificabile').Count
        }
    })
    $statistics = [pscustomobject]@{
        Computers=$rows.Count
        HybridOk=@($rows | Where-Object HybridState -eq 'HYBRID OK').Count
        IntuneOk=@($rows | Where-Object IntuneState -eq 'OK').Count
        IntuneUnknown=@($rows | Where-Object IntuneState -eq 'Non verificabile').Count
        RegisteredComputers=$script:HybridRows.Count
    }
    $script:HybridContext = $context
    [pscustomobject]@{
        Rows=$rows; Sources=$sources; OuStatistics=@($stats | Sort-Object Name,DistinguishedName)
        Statistics=$statistics; CapturedAtUtc=[datetimeoffset]::UtcNow
    }
}

function Get-HybridCleanupCandidates {
    param($GraphAccess,$ProgressQueue)
    if ((Assert-DmSession $GraphAccess) -cne $script:HybridContext) { throw 'Aggiornare i dati dopo il cambio di sessione.' }
    $script:HybridCandidates=@{};$results=New-Object 'Collections.Generic.List[object]'
    foreach ($row in @($script:HybridRows.Values | Sort-Object Name,ADGuid)) {
        foreach ($device in @($row.EntraDevices)) {
            if ($device.trustType -ine 'Workplace') { continue }
            $id=ConvertTo-DmId $device.id
            if ($script:HybridCandidates.ContainsKey($id)) { continue }
            Send-DmProgress $ProgressQueue ('Lettura proprietari e utenti Registered: '+$device.displayName)
            $people=New-Object 'Collections.Generic.List[string]';$notes=New-Object 'Collections.Generic.List[string]'
            foreach ($relationship in @('registeredOwners','registeredUsers')) {
                try {
                    $members=@(Get-DmGraphItems -Uri ('https://graph.microsoft.com/v1.0/devices/'+$id+'/'+$relationship))
                    foreach ($member in $members) {
                        $name=[string](Get-DmValue $member 'displayName');$upn=[string](Get-DmValue $member 'userPrincipalName')
                        if (-not $name -and -not $upn) { $name='Utente non risolto';$upn=[string]$member.id }
                        [void]$people.Add($relationship+': '+$name+' <'+$upn+'>')
                    }
                }
                catch { [void]$notes.Add($relationship+': '+$_.Exception.Message) }
            }
            $candidate=[pscustomobject]@{Name=[string]$device.displayName;ObjectId=$id;DeviceId=[string]$device.deviceId;TrustType=[string]$device.trustType;IsManaged=(Get-DmValue $device 'isManaged');OnPremisesSyncEnabled=(Get-DmValue $device 'onPremisesSyncEnabled');ADName=$row.Name;ADGuid=$row.ADGuid;Users=(@($people | Sort-Object -Unique) -join '; ');UserNotes=($notes -join '; ');LastSignIn=(Get-DmValue $device 'approximateLastSignInDateTime')}
            $script:HybridCandidates[$id]=$candidate | ConvertTo-Json -Depth 8 | ConvertFrom-Json
            [void]$results.Add($candidate)
        }
    }
    [pscustomobject]@{Candidates=@($results.ToArray() | Sort-Object Name,ObjectId)}
}

function New-HybridCleanupPlan {
    param([string[]]$ObjectIds,[string]$ConfigPath,[string]$EnvPath,$GraphAccess,$ProgressQueue)
    $session=Assert-DmSession $GraphAccess -WriteId 'entra-remove'
    if ($session -cne $script:HybridContext) { throw 'Aggiornare i dati dopo il cambio di sessione.' }
    $ids=@($ObjectIds | ForEach-Object { ConvertTo-DmId $_ } | Sort-Object -Unique)
    if (-not $ids.Count) { throw 'Selezionare almeno una registrazione Workplace.' }
    $names=@(@(foreach ($id in $ids) {
        if (-not $script:HybridCandidates.ContainsKey($id)) { throw 'Registrazione non inclusa nella selezione verificata.' }
        $candidate=$script:HybridCandidates[$id]
        $live=Invoke-MgGraphRequest -Method GET -Uri ('https://graph.microsoft.com/v1.0/devices/'+$id+'?$select=id,deviceId,displayName,trustType,isManaged,onPremisesSyncEnabled') -OutputType PSObject -ErrorAction Stop
        if ((ConvertTo-DmId $live.id) -ne $id -or [string]$live.displayName -ine $candidate.Name -or [string]$live.deviceId -ine $candidate.DeviceId -or $live.trustType -ine 'Workplace' -or $live.onPremisesSyncEnabled -eq $true -or [string]$live.isManaged -ine [string]$candidate.IsManaged) { throw 'Registrazione cambiata. Aggiornare i dati e rivedere la selezione.' }
        $candidate.Name
    }) | Sort-Object -Unique)
    $config=Read-ExplorerConfiguration $ConfigPath;$credentials=$null
    try {
        $credentials=Read-ExplorerGlpiCredentials -Path $EnvPath -UseAppToken:([bool](Get-DmValue $config.Settings.Glpi 'UseAppToken' $true))
        Set-ExplorerRemovalReadOnly -ReadOnly:$false
        New-ExplorerRemovalPlan -Names $names -Sources Entra -RegisteredObjectIds $ids -ConfigPath $ConfigPath -GlpiCredentials $credentials -ProgressQueue $ProgressQueue
        # The removal plan retains the secure-string references until consumed.
        $credentials=$null
    }
    finally { if ($null -ne $credentials) { $credentials.User.Dispose();if ($null -ne $credentials.App) { $credentials.App.Dispose() } } }
}

function Invoke-HybridCleanupPlan {
    [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
    param([string]$PlanId,$Decision,$GraphAccess,$ProgressQueue)
    [void](Assert-DmSession $GraphAccess -WriteId 'entra-remove')
    if ($PSCmdlet.ShouldProcess('Registrazioni Workplace selezionate','Archivia BitLocker e pulisci Entra')) {
        Invoke-ExplorerRemovalPlan -PlanId $PlanId -ConfirmGlpiMapping:([bool]$Decision.ConfirmGlpiMapping) -ConfirmBitLockerLossFor $Decision.ConfirmBitLockerLossFor -Confirm:$false -ProgressQueue $ProgressQueue
    }
}

Export-ModuleMember -Function New-HybridComparison,Get-HybridJoinSnapshot,Get-HybridCleanupCandidates,New-HybridCleanupPlan,Invoke-HybridCleanupPlan

function ConvertTo-HostKey {
    param(
        [AllowNull()]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    $normalized = $Name.Trim().TrimEnd('$')

    if ($normalized.Contains('.')) {
        $normalized = $normalized.Split('.')[0]
    }

    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $null
    }

    return $normalized.ToUpperInvariant()
}

function Get-EntraJoinLabel {
    param(
        [AllowNull()]
        [string]$TrustType
    )

    if ([string]::IsNullOrWhiteSpace($TrustType)) {
        return 'Non specificato'
    }

    if ($TrustType -ieq 'ServerAd') {
        return 'Microsoft Entra hybrid joined'
    }

    if ($TrustType -ieq 'Workplace') {
        return 'Microsoft Entra registered'
    }

    if ($TrustType -ieq 'AzureAd') {
        return 'Microsoft Entra joined'
    }

    return "Altro ($TrustType)"
}

function Get-OwnershipLabel {
    param(
        [AllowNull()]
        [string]$Ownership
    )

    if ($Ownership -ieq 'company') {
        return 'Corporate'
    }

    if ($Ownership -ieq 'personal') {
        return 'Personal'
    }

    if ([string]::IsNullOrWhiteSpace($Ownership)) {
        return 'Non specificata'
    }

    return $Ownership
}

function ConvertTo-YesNo {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return '-'
    }

    if ([bool]$Value) {
        return 'Si'
    }

    return 'No'
}

function ConvertTo-DisplayDate {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return ''
    }

    if ($Value -is [System.DateTime]) {
        return ([System.DateTime]$Value).ToString('yyyy-MM-dd HH:mm')
    }

    try {
        $date = [System.DateTimeOffset]::Parse([string]$Value)
        return $date.ToLocalTime().ToString('yyyy-MM-dd HH:mm')
    }
    catch {
        return [string]$Value
    }
}


function New-HybridBaseComparison {
    param(
        [Parameter(Mandatory)]
        [object]$AdComputer,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$EntraDevices
    )

    $hybridDevices = @(
        $EntraDevices |
            Where-Object {
                [string]$_.trustType -ieq 'ServerAd'
            }
    )

    $registeredDevices = @(
        $EntraDevices |
            Where-Object {
                [string]$_.trustType -ieq 'Workplace'
            }
    )

    $entraJoinedDevices = @(
        $EntraDevices |
            Where-Object {
                [string]$_.trustType -ieq 'AzureAd'
            }
    )

    $otherDevices = @(
        $EntraDevices |
            Where-Object {
                [string]::IsNullOrWhiteSpace([string]$_.trustType) -or
                (
                    [string]$_.trustType -ine 'ServerAd' -and
                    [string]$_.trustType -ine 'Workplace' -and
                    [string]$_.trustType -ine 'AzureAd'
                )
            }
    )

    $personalDevices = @(
        $EntraDevices |
            Where-Object {
                [string]$_.deviceOwnership -ieq 'personal'
            }
    )

    $hybridNotManaged = @(
        $hybridDevices |
            Where-Object {
                -not [bool]$_.isManaged
            }
    )

    $hybridNotCorporate = @(
        $hybridDevices |
            Where-Object {
                [string]$_.deviceOwnership -ine 'company'
            }
    )

    $disabledEntraDevices = @(
        $EntraDevices |
            Where-Object {
                $null -ne $_.accountEnabled -and
                -not [bool]$_.accountEnabled
            }
    )

    $nonHybridDevices = @(
        $EntraDevices |
            Where-Object {
                [string]$_.trustType -ine 'ServerAd'
            }
    )

    $anomalies = [System.Collections.Generic.List[string]]::new()

    if (-not [bool]$AdComputer.Enabled) {
        $anomalies.Add('Account computer AD disabilitato')
    }

    $hybridState = ''
    $severity = ''

    if ($EntraDevices.Count -eq 0) {
        $hybridState = 'ASSENTE DA ENTRA'
        $severity = 'Error'
        $anomalies.Add('Nessuna entry Entra con questo hostname')
    }
    elseif ($hybridDevices.Count -eq 0) {
        $hybridState = 'SENZA HYBRID'
        $severity = 'Error'
        $anomalies.Add('Nessuna entry ServerAd (Hybrid)')
    }
    elseif ($hybridDevices.Count -gt 1) {
        $hybridState = 'HYBRID DUPLICATO'
        $severity = 'Error'
        $anomalies.Add(('{0} entry ServerAd (Hybrid)' -f $hybridDevices.Count))
    }
    else {
        $hybridState = 'HYBRID OK'
        $severity = 'Good'
    }

    if ($registeredDevices.Count -gt 0) {
        $anomalies.Add(
            ('{0} entry Microsoft Entra registered (Workplace)' -f
                $registeredDevices.Count)
        )
    }

    if ($entraJoinedDevices.Count -gt 0) {
        $anomalies.Add(
            ('{0} entry Microsoft Entra joined (AzureAd)' -f
                $entraJoinedDevices.Count)
        )
    }

    if ($otherDevices.Count -gt 0) {
        $anomalies.Add(
            ('{0} entry con trustType non riconosciuto' -f $otherDevices.Count)
        )
    }

    if ($personalDevices.Count -gt 0) {
        $anomalies.Add(
            ('{0} entry con ownership Personal' -f $personalDevices.Count)
        )
    }

    if ($hybridNotManaged.Count -gt 0) {
        $anomalies.Add(
            ('{0} entry Hybrid non gestita MDM' -f $hybridNotManaged.Count)
        )
    }

    if ($hybridNotCorporate.Count -gt 0) {
        $anomalies.Add(
            ('{0} entry Hybrid con ownership non Corporate' -f
                $hybridNotCorporate.Count)
        )
    }

    if ($disabledEntraDevices.Count -gt 0) {
        $anomalies.Add(
            ('{0} entry Entra disabilitata' -f $disabledEntraDevices.Count)
        )
    }

    if ($severity -eq 'Good' -and $anomalies.Count -gt 0) {
        $severity = 'Warning'
    }

    $overallState = if ($severity -eq 'Good') {
        'OK'
    }
    elseif ($severity -eq 'Warning') {
        'ATTENZIONE'
    }
    else {
        'ERRORE'
    }

    $hybridManagedText = '-'
    $hybridOwnershipText = '-'

    if ($hybridDevices.Count -gt 0) {
        if ($hybridNotManaged.Count -eq 0) {
            $hybridManagedText = 'Si'
        }
        elseif ($hybridNotManaged.Count -eq $hybridDevices.Count) {
            $hybridManagedText = 'No'
        }
        else {
            $managedCount = $hybridDevices.Count - $hybridNotManaged.Count
            $hybridManagedText = "$managedCount/$($hybridDevices.Count)"
        }

        $ownershipValues = @(
            $hybridDevices |
                ForEach-Object {
                    Get-OwnershipLabel -Ownership ([string]$_.deviceOwnership)
                } |
                Sort-Object -Unique
        )
        $hybridOwnershipText = $ownershipValues -join ', '
    }

    return [pscustomobject]@{
        HostName              = [string]$AdComputer.Name
        HostKey               = [string]$AdComputer.HostKey
        DNSHostName           = [string]$AdComputer.DNSHostName
        OUName                = [string]$AdComputer.OUName
        OUDistinguishedName   = [string]$AdComputer.OUDistinguishedName
        ADDistinguishedName   = [string]$AdComputer.DistinguishedName
        ADEnabled             = [bool]$AdComputer.Enabled
        ADOperatingSystem     = [string]$AdComputer.OperatingSystem
        ADOperatingSystemVersion = [string]$AdComputer.OperatingSystemVersion
        ADLastLogonDate       = $AdComputer.LastLogonDate
        ADPasswordLastSet     = $AdComputer.PasswordLastSet
        HybridState           = $hybridState
        OverallState          = $overallState
        Severity              = $severity
        EntraCount            = $EntraDevices.Count
        HybridCount           = $hybridDevices.Count
        RegisteredCount       = $registeredDevices.Count
        EntraJoinedCount      = $entraJoinedDevices.Count
        OtherCount            = $otherDevices.Count
        PersonalCount         = $personalDevices.Count
        AdditionalEntryCount  = $nonHybridDevices.Count
        HybridManagedText     = $hybridManagedText
        HybridOwnershipText   = $hybridOwnershipText
        HasAdditionalEntries  = $nonHybridDevices.Count -gt 0
        HasPersonal           = $personalDevices.Count -gt 0
        HasHybridNotManaged   = $hybridNotManaged.Count -gt 0
        HasHybridNotCorporate = $hybridNotCorporate.Count -gt 0
        HasDisabledEntraEntry = $disabledEntraDevices.Count -gt 0
        Anomalies             = $anomalies -join '; '
        EntraDevices          = @($EntraDevices)
        HybridDevices         = @($hybridDevices)
    }
}

