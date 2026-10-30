#requires -version 5.1
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'DeviceModules.Core.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'ComputerExplorer.Core.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'ComputerExplorer.Removal.psm1') -ErrorAction Stop
$script:HybridRows=@{}
$script:HybridCandidates=@{}
$script:HybridContext=''

function New-HybridComparison {
    param($AdComputer,[object[]]$EntraDevices)
    $result=New-HybridBaseComparison -AdComputer $AdComputer -EntraDevices $EntraDevices
    $guid=ConvertTo-DmId $AdComputer.ObjectGUID
    $identity=@($EntraDevices | Where-Object { $_.trustType -ieq 'ServerAd' } | ForEach-Object {
        $deviceId=[guid]::Empty;$valid=[guid]::TryParse([string]$_.deviceId,[ref]$deviceId) -and $deviceId -ne [guid]::Empty
        $state='Non corrisponde';if ($valid -and $deviceId.ToString() -ieq $guid) { $state='Corrisponde' }
        [pscustomobject]@{ObjectId=[string]$_.id;DeviceId=[string]$_.deviceId;Name=[string]$_.displayName;TrustType=[string]$_.trustType;State=$state}
    })
    $state='Non applicabile'
    if ($identity.Count) {
        $state='Corrisponde'
        if (@($identity | Where-Object State -ne 'Corrisponde').Count) { $state='Non corrisponde';$result.Severity='Error';$result.OverallState='ERRORE';$result.HybridState='GUID NON CORRISPONDENTE';$result.Anomalies+='; Device ID Entra Hybrid diverso dal GUID AD' }
    }
    $ids=@(@($guid)+@($EntraDevices | ForEach-Object { [string]$_.deviceId }) | Sort-Object -Unique)
    foreach ($property in @{Name=$AdComputer.Name;Key=$guid;ADGuid=$guid;IdentityState=$state;IdentityRecords=$identity;DeviceIds=$ids;EntraObjectIds=(@($EntraDevices | ForEach-Object { $_.id }) -join ', ');EntraDeviceIds=(@($EntraDevices | ForEach-Object { $_.deviceId } | Sort-Object -Unique) -join ', ')}.GetEnumerator()) { $result | Add-Member -Force NoteProperty $property.Key $property.Value }
    return $result
}

function Get-HybridJoinSnapshot {
    [CmdletBinding()]
    param([string]$ConfigPath,[string]$EnvPath,$GraphAccess,$ProgressQueue)
    $context=Assert-DmSession $GraphAccess
    $script:HybridRows=@{};$script:HybridCandidates=@{};$script:HybridContext=''
    $settings=Read-DmSettings $ConfigPath HybridJoin;$options=$settings.Options
    $ous=@($options.TargetOus | ForEach-Object { ([string]$_).Trim().TrimEnd(',') } | Sort-Object -Unique)
    if ($ous.Count -eq 0 -or @($ous | Where-Object { -not $_ -or $_ -notmatch '^OU=' -or $_ -match '[\r\n\x00]' }).Count) { throw 'Configurare almeno una OU valida nelle Impostazioni Hybrid Join.' }
    if ($options.SearchScope -notin @('Base','OneLevel','Subtree')) { throw 'SearchScope Hybrid Join non valido.' }
    $server=([string]$options.AdServer).Trim()
    if (-not $server) { $controllers=Get-DmValue $settings.Config.Settings 'DomainControllers' @();if ($controllers.Count) { $server=[string]$controllers[0] } }
    if (-not $server) { throw 'Configurare un server AD nelle Impostazioni.' }
    Import-Module ActiveDirectory -ErrorAction Stop
    Send-DmProgress $ProgressQueue ('Lettura dominio AD su '+$server+'...')
    $domain=Get-ADDomain -Server $server -ErrorAction Stop;$domainDn=[string]$domain.DistinguishedName
    if (-not $domainDn -or $domainDn -notmatch '^DC=') { throw 'Distinguished Name del dominio AD non valido.' }
    $computers=@{};$stats=New-Object 'Collections.Generic.List[object]'
    foreach ($relative in $ous) {
        $dn=$relative
        if ($dn -notmatch ',DC=') { $dn+=','+$domainDn }
        if (-not $dn.EndsWith(','+$domainDn,[StringComparison]::OrdinalIgnoreCase)) { throw 'OU esterna al dominio configurato.' }
        Send-DmProgress $ProgressQueue ('Lettura OU: '+$dn)
        $ou=Get-ADOrganizationalUnit -Server $server -Identity $dn -ErrorAction Stop
        $found=@(Get-ADComputer -Server $server -Filter '*' -SearchBase $dn -SearchScope $options.SearchScope -Properties DNSHostName,Enabled,OperatingSystem,OperatingSystemVersion,LastLogonDate,PasswordLastSet,ObjectGUID -ErrorAction Stop)
        [void]$stats.Add([pscustomobject]@{Name=$ou.Name;DistinguishedName=$dn;Count=$found.Count})
        foreach ($computer in $found) {
            $id=ConvertTo-DmId $computer.ObjectGUID
            if (-not $computers.ContainsKey($id)) {
                $computers[$id]=[pscustomobject]@{Name=[string]$computer.Name;ObjectGUID=$id;HostKey=(ConvertTo-HostKey $computer.Name);DNSHostName=[string]$computer.DNSHostName;Enabled=$computer.Enabled;OperatingSystem=$computer.OperatingSystem;OperatingSystemVersion=$computer.OperatingSystemVersion;LastLogonDate=$computer.LastLogonDate;PasswordLastSet=$computer.PasswordLastSet;DistinguishedName=[string]$computer.DistinguishedName;OUName=[string]$ou.Name;OUDistinguishedName=$dn}
            }
        }
    }
    $devices=@(Get-DmEntraInventory $ProgressQueue);$byHost=@{};$byGuid=@{}
    foreach ($device in $devices) {
        $hostKey=ConvertTo-HostKey ([string]$device.displayName)
        if ($hostKey) { if (-not $byHost.ContainsKey($hostKey)) { $byHost[$hostKey]=New-Object 'Collections.Generic.List[object]' };[void]$byHost[$hostKey].Add($device) }
        if ($device.trustType -ieq 'ServerAd') { $id=[string]$device.deviceId;if ($id) { if (-not $byGuid.ContainsKey($id)) { $byGuid[$id]=New-Object 'Collections.Generic.List[object]' };[void]$byGuid[$id].Add($device) } }
    }
    $rows=@(foreach ($computer in @($computers.Values | Sort-Object Name,DistinguishedName)) {
        $matches=@{}
        if ($byHost.ContainsKey($computer.HostKey)) { foreach ($device in $byHost[$computer.HostKey]) { $matches[[string]$device.id]=$device } }
        if ($byGuid.ContainsKey($computer.ObjectGUID)) { foreach ($device in $byGuid[$computer.ObjectGUID]) { $matches[[string]$device.id]=$device } }
        New-HybridComparison -AdComputer $computer -EntraDevices @($matches.Values)
    })
    $sources=Add-DmInventory -Rows $rows -Config $settings.Config -Access $GraphAccess -EnvPath $EnvPath -ProgressQueue $ProgressQueue
    if ((Assert-DmSession $GraphAccess) -cne $context) { throw 'Sessione cambiata durante la lettura. Aggiornare i dati.' }
    # Keep a detached canonical snapshot: the editable UI cannot invent candidates.
    foreach ($row in $rows) { $script:HybridRows[$row.Key]=$row | ConvertTo-Json -Depth 20 | ConvertFrom-Json }
    $script:HybridContext=$context
    [pscustomobject]@{Rows=$rows;Sources=$sources;OuStatistics=$stats.ToArray();TotalEntra=$devices.Count;CapturedAtUtc=[datetimeoffset]::UtcNow;Summary=($rows.Count.ToString()+' PC AD; '+@($rows | Where-Object Severity -eq 'Error').Count+' errori Hybrid; '+@($rows | Where-Object RegisteredCount -gt 0).Count+' PC con Registered. AD: '+$server)}
}

function Get-HybridCleanupCandidates {
    param([string[]]$RowKeys,$GraphAccess,$ProgressQueue)
    if ((Assert-DmSession $GraphAccess) -cne $script:HybridContext) { throw 'Aggiornare i dati dopo il cambio di sessione.' }
    $script:HybridCandidates=@{};$results=New-Object 'Collections.Generic.List[object]'
    foreach ($key in @($RowKeys | Sort-Object -Unique)) {
        if (-not $script:HybridRows.ContainsKey($key)) { throw 'Computer non incluso nell''ultima ricerca. Aggiornare i dati.' }
        $row=$script:HybridRows[$key]
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
    [pscustomobject]@{Candidates=$results.ToArray()}
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

