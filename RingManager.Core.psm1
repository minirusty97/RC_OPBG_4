#requires -version 5.1
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'DeviceModules.Core.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'ComputerExplorer.Core.psm1') -ErrorAction Stop
$script:RingRows=@{}
$script:RingContext=''
$script:RingPlans=@{}

function Test-RingWritable {
    param($Group)
    $types=Get-DmValue $Group 'groupTypes'
    if ((Get-DmValue $Group 'securityEnabled') -ne $true) { return 'Non e un gruppo di sicurezza' }
    if ($types -contains 'Unified') { return 'Gruppo Microsoft 365' }
    if ($types -contains 'DynamicMembership') { return 'Appartenenza dinamica' }
    if ((Get-DmValue $Group 'onPremisesSyncEnabled') -eq $true) { return 'Sincronizzato da AD' }
    # Graph exposes this optional property as null for normal groups. Only true is role-assignable.
    if ((Get-DmValue $Group 'isAssignableToRole') -eq $true) { return 'Gruppo assegnabile a ruoli Entra' }
    if ((Get-DmValue $Group 'mailEnabled') -ne $false) { return 'Gruppo abilitato alla posta o proprieta non leggibile' }
    if ($null -eq $types -or -not ($types -is [Array] -or $types -is [Collections.IList])) { return 'Tipo di appartenenza non leggibile' }
    return ''
}

function Get-RingGroups {
    param($Options,$ProgressQueue)
    $configured=Get-DmValue $Options 'Groups' @()
    if (-not $configured.Count) { throw 'Selezionare almeno un gruppo nelle Impostazioni Ring Intune.' }
    $groups=New-Object 'Collections.Generic.List[object]';$seen=@{};$labels=@{}
    foreach ($entry in $configured) {
        $name=([string]$entry.Name).Trim();$label=([string]$entry.Label).Trim();$configuredId=[string]$entry.Id
        if ($entry.CanAssign -isnot [bool]) { throw 'La scelta Modifica del gruppo deve essere un valore booleano.' }
        if (-not $label -or $label.Length -gt 120 -or $label -match '[\r\n\x00]' -or $labels.ContainsKey($label)) { throw 'Etichette dei gruppi mancanti o duplicate nelle Impostazioni.' };$labels[$label]=$true
        $select='id,displayName,groupTypes,onPremisesSyncEnabled,securityEnabled,mailEnabled,isAssignableToRole'
        if ($configuredId) {
            $id=ConvertTo-DmId $configuredId
            try { $group=Invoke-MgGraphRequest -Method GET -Uri ('https://graph.microsoft.com/v1.0/groups/'+$id+'?$select='+$select) -OutputType PSObject -ErrorAction Stop }
            catch { throw ('Gruppo selezionato non leggibile: '+$label+' / '+$id+'. Rivedere le Impostazioni. '+(New-ExplorerGraphOperationError -Failure $_ -Stage InitialRead).Message) }
            if ((ConvertTo-DmId $group.id) -ne $id) { throw 'Il gruppo riletto non corrisponde all ID selezionato.' }
            $name=[string]$group.displayName
        }
        else {
            if (-not $name -or $name -match '[\r\n\x00]') { throw 'Gruppo senza ID o nome nelle Impostazioni.' }
            $filter=[uri]::EscapeDataString("displayName eq '"+$name.Replace("'","''")+"'")
            $found=@(Get-DmGraphItems -Uri ('https://graph.microsoft.com/v1.0/groups?$filter='+$filter+'&$select='+$select) -ProgressQueue $ProgressQueue)
            if ($found.Count -ne 1 -or [string]$found[0].displayName -ine $name) { throw ('Occorre un solo gruppo con nome esatto: '+$name+'. Trovati: '+$found.Count+'. Selezionare il gruppo nelle Impostazioni; elenco orfani non pubblicato.') }
            $group=$found[0];$id=ConvertTo-DmId $group.id
        }
        if ($seen.ContainsKey($id)) { throw 'Lo stesso gruppo e selezionato piu volte.' };$seen[$id]=$true
        $reason=Test-RingWritable $group
        [void]$groups.Add([pscustomobject]@{Id=$id;Name=$name;Label=$label;Destination=[bool]$entry.CanAssign;IsWritable=([bool]$entry.CanAssign -and -not $reason);Reason=$reason;MemberCount=0;DeviceCount=0})
    }
    return $groups.ToArray()
}

function Get-RingMemberIndex {
    param([object[]]$Groups,$ProgressQueue)
    $index=@{}
    foreach ($group in $Groups) {
        # Uncast collection avoids eventual-consistency casts and also sees nested memberships.
        $members=@(Get-DmGraphItems -Uri ('https://graph.microsoft.com/v1.0/groups/'+$group.Id+'/transitiveMembers?$select=id&$top=999') -ProgressQueue $ProgressQueue)
        $group.MemberCount=$members.Count
        foreach ($member in $members) { $id=ConvertTo-DmId $member.id;if (-not $index.ContainsKey($id)) { $index[$id]=New-Object 'Collections.Generic.List[string]' };[void]$index[$id].Add($group.Id) }
    }
    return ,$index
}

function Test-RingEligible {
    param($Device)
    return ([string](Get-DmValue $Device 'trustType') -ieq 'ServerAd' -and
        [string](Get-DmValue $Device 'deviceOwnership') -ieq 'company' -and
        (Get-DmValue $Device 'isManaged') -eq $true -and
        [string](Get-DmValue $Device 'operatingSystem') -like 'Windows*' -and
        (Get-DmValue $Device 'accountEnabled') -eq $true)
}

function Get-RingManagerSnapshot {
    [CmdletBinding()]
    param([string]$ConfigPath,[string]$EnvPath,$GraphAccess,$ProgressQueue)
    $context=Assert-DmSession $GraphAccess -ReadIds @('entra-read','groups-read')
    $script:RingRows=@{};$script:RingContext='';$script:RingPlans=@{}
    $settings=Read-DmSettings $ConfigPath RingManager
    $groups=@(Get-RingGroups -Options $settings.Options -ProgressQueue $ProgressQueue)
    $members=Get-RingMemberIndex -Groups $groups -ProgressQueue $ProgressQueue
    $devices=@(Get-DmEntraInventory $ProgressQueue)
    $groupsById=@{}
    foreach ($group in $groups) { $groupsById[$group.Id]=$group }
    $eligible=@(foreach ($device in $devices) {
        $id=ConvertTo-DmId $device.id
        foreach ($groupId in $members[$id]) { $groupsById[$groupId].DeviceCount++ }
        if (Test-RingEligible $device) { $device }
    })
    $rows=@(foreach ($device in @($eligible | Sort-Object displayName,id)) {
        $id=ConvertTo-DmId $device.id;$deviceId=ConvertTo-DmId $device.deviceId
        $currentIds=@();if ($members.ContainsKey($id)) { $currentIds=@($members[$id].ToArray() | Sort-Object -Unique) }
        $rings=@($currentIds | ForEach-Object { $groupsById[$_].Label })
        [pscustomobject]@{Key=$id;Name=[string]$device.displayName;ObjectId=$id;DeviceId=$deviceId;DeviceIds=@($deviceId);Rings=($rings -join ', ');CurrentGroupIds=$currentIds;Orphan=($rings.Count -eq 0);State=$(if ($rings.Count -gt 1) {'Piu Ring'} elseif ($rings.Count) {'Assegnato'} else {'Orfano'});TargetRing='';LastSignIn=(Get-DmValue $device 'approximateLastSignInDateTime')}
    })
    $sources=Add-DmInventory -Rows $rows -Config $settings.Config -Access $GraphAccess -EnvPath $EnvPath -ProgressQueue $ProgressQueue -IncludeSupplier
    if ((Assert-DmSession $GraphAccess -ReadIds @('entra-read','groups-read')) -cne $context) { throw 'Sessione cambiata durante la lettura. Aggiornare i dati.' }
    foreach ($row in $rows) { $script:RingRows[$row.Key]=$row | ConvertTo-Json -Depth 15 | ConvertFrom-Json }
    $script:RingContext=$context
    $orphans=@($rows | Where-Object Orphan).Count
    $statistics=[pscustomobject]@{DeviceTotal=$devices.Count;EligibleTotal=$eligible.Count;AlreadyAssigned=($eligible.Count-$orphans);OrphanRemaining=$orphans}
    [pscustomobject]@{Rows=$rows;Groups=$groups;Sources=$sources;CapturedAtUtc=[datetimeoffset]::UtcNow;Statistics=$statistics;Summary=($devices.Count.ToString()+' dispositivi Entra; '+$eligible.Count+' Windows Hybrid Corporate MDM abilitati; '+$orphans+' orfani. '+$groups.Count+' Ring verificati, inclusi quelli solo monitorati.')}
}

function Get-RingDeviceLive {
    param([string]$Id)
    Invoke-MgGraphRequest -Method GET -Uri ('https://graph.microsoft.com/v1.0/devices/'+(ConvertTo-DmId $Id)+'?$select=id,deviceId,displayName,trustType,deviceOwnership,isManaged,operatingSystem,accountEnabled') -OutputType PSObject -ErrorAction Stop
}

function Assert-RingDeviceSame {
    param($Expected,$Current)
    if (-not (Test-RingEligible $Current) -or (ConvertTo-DmId $Current.id) -ne $Expected.ObjectId -or
        (ConvertTo-DmId $Current.deviceId) -ne $Expected.DeviceId -or [string]$Current.displayName -ine $Expected.Name) { throw 'Identita, nome o requisiti del PC cambiati. Aggiornare i dati.' }
}

function Get-RingGroupSignature {
    param([object[]]$Groups)
    return (@($Groups | Sort-Object Id | ForEach-Object { $_.Id+'|'+$_.Name+'|'+$_.Label+'|'+$_.Destination+'|'+$_.IsWritable+'|'+$_.Reason }) -join "`n")
}

function Get-RingMembershipState {
    param([string]$ObjectId,[string[]]$MonitoredIds)
    $id=ConvertTo-DmId $ObjectId
    $direct=@(Get-DmGraphItems -Uri ('https://graph.microsoft.com/v1.0/devices/'+$id+'/memberOf?$select=id'))
    $transitive=@(Get-DmGraphItems -Uri ('https://graph.microsoft.com/v1.0/devices/'+$id+'/transitiveMemberOf?$select=id'))
    [pscustomobject]@{Direct=@($direct | ForEach-Object { ConvertTo-DmId $_.id } | Where-Object { $MonitoredIds -contains $_ } | Sort-Object -Unique);All=@($transitive | ForEach-Object { ConvertTo-DmId $_.id } | Where-Object { $MonitoredIds -contains $_ } | Sort-Object -Unique)}
}

function Test-RingSameIds {
    param([string[]]$Expected,[string[]]$Actual)
    return (@($Expected | Sort-Object -Unique) -join '|') -ceq (@($Actual | Sort-Object -Unique) -join '|')
}

function Assert-RingDirectTarget {
    param([string]$GroupId,[string]$ObjectId)
    $record=Invoke-MgGraphRequest -Method GET -Uri ('https://graph.microsoft.com/v1.0/groups/'+(ConvertTo-DmId $GroupId)+'/members/'+(ConvertTo-DmId $ObjectId)+'?$select=id') -OutputType PSObject -ErrorAction Stop
    if ((ConvertTo-DmId $record.id) -ne $ObjectId) { throw 'Appartenenza diretta al gruppo di destinazione non confermata.' }
}

function New-RingAssignmentPlan {
    [CmdletBinding()]
    param([object[]]$Assignments,[string]$ConfigPath,$GraphAccess,$ProgressQueue)
    $context=Assert-DmSession $GraphAccess -ReadIds @('entra-read','groups-read') -WriteId 'groups-write'
    if ($context -cne $script:RingContext) { throw 'Aggiornare i dati dopo il cambio di sessione.' }
    $script:RingPlans=@{}
    $settings=Read-DmSettings $ConfigPath RingManager;$groups=@(Get-RingGroups $settings.Options $ProgressQueue)
    $members=Get-RingMemberIndex $groups $ProgressQueue
    $byId=@{};foreach ($group in $groups) { $byId[$group.Id]=$group }
    $monitored=@($groups | ForEach-Object { $_.Id })
    $items=New-Object 'Collections.Generic.List[object]';$seen=@{}
    foreach ($assignment in $Assignments) {
        $id=ConvertTo-DmId $assignment.ObjectId
        if ($seen.ContainsKey($id) -or -not $script:RingRows.ContainsKey($id)) { throw 'Selezione duplicata o esterna all ultima ricerca.' };$seen[$id]=$true
        $expected=$script:RingRows[$id];$current=@();if ($members.ContainsKey($id)) { $current=$members[$id].ToArray() }
        $expectedIds=Get-DmValue $expected 'CurrentGroupIds' @()
        if (-not (Test-RingSameIds $expectedIds $current)) { throw ($expected.Name+': appartenenze cambiate. Aggiornare i dati.') }
        $dest=@($groups | Where-Object { $_.Label -ieq [string]$assignment.TargetRing -and $_.IsWritable })
        if ($dest.Count -ne 1) { throw 'Gruppo di destinazione non modificabile o non configurato.' }
        Assert-RingDeviceSame $expected (Get-RingDeviceLive $id)
        $membership=Get-RingMembershipState -ObjectId $id -MonitoredIds $monitored
        if (-not (Test-RingSameIds $current $membership.All)) { throw 'Appartenenze cambiate durante la preparazione.' }
        $origins=@($current | Where-Object { $_ -ne $dest[0].Id })
        foreach ($origin in $origins) {
            if (-not $byId[$origin].IsWritable) { throw ($expected.Name+': origine '+$byId[$origin].Label+' impostata solo per controllo o non modificabile. Abilitare Modifica nelle impostazioni oppure verificare il tipo del gruppo.') }
            if ($membership.Direct -notcontains $origin) { throw ($expected.Name+': appartenenza a '+$byId[$origin].Label+' ereditata da un gruppo annidato. Non e possibile rimuoverla sul solo PC.') }
        }
        $action='Assegna';if ($origins.Count) { $action='Sposta' } elseif ($membership.Direct -contains $dest[0].Id) { $action='Gia nel Ring' }
        [void]$items.Add([pscustomobject]@{ObjectId=$id;DeviceId=$expected.DeviceId;Name=$expected.Name;TargetRing=$dest[0].Label;GroupId=$dest[0].Id;GroupName=$dest[0].Name;Action=$action;InitialMembershipIds=@($current);InitialDirectIds=@($membership.Direct);RemoveGroupIds=$origins;RemoveGroups=(@($origins | ForEach-Object { $byId[$_].Name+' / '+$_ }) -join '; ')})
    }
    if (-not $items.Count) { throw 'Selezionare almeno un PC e un gruppo di destinazione.' }
    if ((Assert-DmSession $GraphAccess -ReadIds @('entra-read','groups-read') -WriteId 'groups-write') -cne $context) { throw 'Sessione cambiata durante la preparazione.' }
    $id=[guid]::NewGuid().ToString();$created=[datetimeoffset]::UtcNow
    $script:RingPlans[$id]=[pscustomobject]@{Id=$id;CreatedAt=$created;Context=$context;ConfigPath=$ConfigPath;GroupSignature=(Get-RingGroupSignature $groups);Items=$items.ToArray();MonitoredIds=$monitored}
    [pscustomobject]@{PlanId=$id;CreatedAtUtc=$created;Items=@($items | Select-Object Name,ObjectId,DeviceId,TargetRing,GroupId,GroupName,Action,RemoveGroups)}
}

function Invoke-RingAssignmentPlan {
    [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
    param([string]$PlanId,$GraphAccess,$ProgressQueue)
    $context=Assert-DmSession $GraphAccess -ReadIds @('entra-read','groups-read') -WriteId 'groups-write'
    if (-not $script:RingPlans.ContainsKey($PlanId)) { throw 'Anteprima non valida o gia utilizzata.' }
    $plan=$script:RingPlans[$PlanId];$script:RingPlans.Remove($PlanId)
    if (([datetimeoffset]::UtcNow-$plan.CreatedAt).TotalMinutes -gt 5 -or $context -cne $plan.Context) { throw 'Anteprima scaduta o sessione cambiata. Ripetere la verifica.' }
    $results=New-Object 'Collections.Generic.List[object]'
    foreach ($item in $plan.Items) {
        $state='Bloccato';$errorText='';$stage='Verifica';$writes=$false;$targetVerified=$false;$removed=New-Object 'Collections.Generic.List[string]'
        try {
            if ((Assert-DmSession $GraphAccess -ReadIds @('entra-read','groups-read') -WriteId 'groups-write') -cne $plan.Context) { throw 'Sessione cambiata.' }
            $settings=Read-DmSettings $plan.ConfigPath RingManager;$groups=@(Get-RingGroups $settings.Options $ProgressQueue)
            if ((Get-RingGroupSignature $groups) -cne $plan.GroupSignature) { throw 'Identita, impostazioni o caratteristiche dei gruppi cambiate.' }
            $byId=@{};foreach ($group in $groups) { $byId[$group.Id]=$group }
            Assert-RingDeviceSame $item (Get-RingDeviceLive $item.ObjectId)
            $membership=Get-RingMembershipState -ObjectId $item.ObjectId -MonitoredIds $plan.MonitoredIds
            if (-not (Test-RingSameIds $item.InitialMembershipIds $membership.All) -or -not (Test-RingSameIds $item.InitialDirectIds $membership.Direct)) { throw 'Appartenenze cambiate dopo l anteprima. Aggiornare dati e conferma.' }
            if ($item.Action -eq 'Gia nel Ring') { Assert-RingDirectTarget $item.GroupId $item.ObjectId;$state='Gia nel Ring' }
            elseif ($PSCmdlet.ShouldProcess(($item.Name+' / '+$item.ObjectId),($item.Action+' verso '+$item.GroupName+'; rimuovi solo origini confermate: '+$item.RemoveGroups))) {
                $stage='Aggiunta destinazione'
                if ($membership.Direct -notcontains $item.GroupId) {
                    Send-DmProgress $ProgressQueue ('Inserimento '+$item.Name+' in '+$item.TargetRing)
                    $body=@{'@odata.id'=('https://graph.microsoft.com/v1.0/devices/'+$item.ObjectId)} | ConvertTo-Json -Compress
                    $writes=$true
                    [void](Invoke-MgGraphRequest -Method POST -Uri ('https://graph.microsoft.com/v1.0/groups/'+$item.GroupId+'/members/$ref') -Body $body -ContentType 'application/json' -ErrorAction Stop)
                }
                $stage='Verifica destinazione'
                for ($attempt=0;$attempt -lt 3 -and -not $targetVerified;$attempt++) {
                    try { Assert-RingDirectTarget $item.GroupId $item.ObjectId;$targetVerified=$true } catch { if ($attempt -eq 2) { throw };Start-Sleep -Milliseconds 300 }
                }
                $expectedDirect=@(@($item.InitialDirectIds)+@($item.GroupId) | Sort-Object -Unique)
                foreach ($origin in $item.RemoveGroupIds) {
                    $stage='Rimozione origine '+$byId[$origin].Label
                    if ((Assert-DmSession $GraphAccess -ReadIds @('entra-read','groups-read') -WriteId 'groups-write') -cne $plan.Context) { throw 'Sessione cambiata.' }
                    Assert-RingDeviceSame $item (Get-RingDeviceLive $item.ObjectId)
                    Assert-RingDirectTarget $item.GroupId $item.ObjectId
                    $liveGroup=Invoke-MgGraphRequest -Method GET -Uri ('https://graph.microsoft.com/v1.0/groups/'+$origin+'?$select=id,displayName,groupTypes,onPremisesSyncEnabled,securityEnabled,mailEnabled,isAssignableToRole') -OutputType PSObject -ErrorAction Stop
                    if ((ConvertTo-DmId $liveGroup.id) -ne $origin -or (Test-RingWritable $liveGroup)) { throw 'Gruppo di origine cambiato o non piu modificabile.' }
                    $live=Get-RingMembershipState -ObjectId $item.ObjectId -MonitoredIds $plan.MonitoredIds
                    if (-not (Test-RingSameIds $expectedDirect $live.Direct) -or -not (Test-RingSameIds $expectedDirect $live.All)) { throw 'Appartenenze dirette cambiate durante lo spostamento.' }
                    $writes=$true
                    # The literal /$ref is mandatory: only membership is removed, never the device object.
                    [void](Invoke-MgGraphRequest -Method DELETE -Uri ('https://graph.microsoft.com/v1.0/groups/'+$origin+'/members/'+$item.ObjectId+'/$ref') -ErrorAction Stop)
                    $expectedDirect=@($expectedDirect | Where-Object { $_ -ne $origin });$confirmed=$false
                    for ($attempt=0;$attempt -lt 3 -and -not $confirmed;$attempt++) {
                        $readback=Get-RingMembershipState -ObjectId $item.ObjectId -MonitoredIds $plan.MonitoredIds
                        $confirmed=$readback.Direct -notcontains $origin -and $readback.Direct -contains $item.GroupId
                        if (-not $confirmed -and $attempt -lt 2) { Start-Sleep -Milliseconds 300 }
                    }
                    if (-not $confirmed) { throw 'Rimozione inviata ma rilettura delle appartenenze non confermata.' }
                    [void]$removed.Add($origin)
                }
                Assert-RingDirectTarget $item.GroupId $item.ObjectId
                $state='Assegnato e verificato';if ($item.RemoveGroupIds.Count) { $state='Spostato e verificato' }
            }
            else { $state='Simulato' }
        }
        catch {
            $errorText=$_.Exception.Message
            if ($writes) {
                $state='Esito da verificare';if ($targetVerified) { $state='Parziale: destinazione verificata' }
                $safe=New-ExplorerGraphOperationError -Failure $_ -Stage InitialRead
                $errorText=$stage+': '+$safe.Message+'. Aggiornare i dati prima di riprovare; nessuna rimozione viene tentata senza destinazione verificata.'
            }
        }
        [void]$results.Add([pscustomobject]@{AtUtc=[datetimeoffset]::UtcNow.ToString('o');Name=$item.Name;ObjectId=$item.ObjectId;DeviceId=$item.DeviceId;Action=$item.Action;TargetRing=$item.TargetRing;GroupId=$item.GroupId;RemoveGroups=$item.RemoveGroups;RemovedGroupIds=($removed -join ', ');State=$state;Stage=$stage;Error=$errorText})
    }
    $success=@('Assegnato e verificato','Spostato e verificato','Gia nel Ring','Simulato')
    [pscustomobject]@{Results=$results.ToArray();Assigned=@($results | Where-Object State -eq 'Assegnato e verificato').Count;Moved=@($results | Where-Object State -eq 'Spostato e verificato').Count;Failed=@($results | Where-Object { $_.State -notin $success }).Count}
}

Export-ModuleMember -Function Test-RingWritable,Test-RingEligible,Get-RingManagerSnapshot,New-RingAssignmentPlan,Invoke-RingAssignmentPlan
