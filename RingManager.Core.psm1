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
    if ((Get-DmValue $Group 'isAssignableToRole') -ne $false) { return 'Assegnabile a ruoli o proprieta non leggibile' }
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
        if ($entry.CanAssign -isnot [bool]) { throw 'La scelta Destinazione del gruppo deve essere un valore booleano.' }
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
        [void]$groups.Add([pscustomobject]@{Id=$id;Name=$name;Label=$label;Destination=[bool]$entry.CanAssign;IsWritable=([bool]$entry.CanAssign -and -not $reason);Reason=$reason;MemberCount=0})
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
        foreach ($member in $members) { $id=ConvertTo-DmId $member.id;if (-not $index.ContainsKey($id)) { $index[$id]=New-Object 'Collections.Generic.List[string]' };[void]$index[$id].Add($group.Label) }
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
    $eligible=@($devices | Where-Object { Test-RingEligible $_ })
    $rows=@(foreach ($device in @($eligible | Sort-Object displayName,id)) {
        $id=ConvertTo-DmId $device.id;$deviceId=ConvertTo-DmId $device.deviceId
        $rings=@();if ($members.ContainsKey($id)) { $rings=@($members[$id].ToArray() | Sort-Object -Unique) }
        [pscustomobject]@{Key=$id;Name=[string]$device.displayName;ObjectId=$id;DeviceId=$deviceId;DeviceIds=@($deviceId);Rings=($rings -join ', ');Orphan=($rings.Count -eq 0);State=$(if ($rings.Count -gt 1) {'Piu Ring'} elseif ($rings.Count) {'Assegnato'} else {'Orfano'});TargetRing='';LastSignIn=(Get-DmValue $device 'approximateLastSignInDateTime')}
    })
    $sources=Add-DmInventory -Rows $rows -Config $settings.Config -Access $GraphAccess -EnvPath $EnvPath -ProgressQueue $ProgressQueue
    if ((Assert-DmSession $GraphAccess -ReadIds @('entra-read','groups-read')) -cne $context) { throw 'Sessione cambiata durante la lettura. Aggiornare i dati.' }
    foreach ($row in $rows) { $script:RingRows[$row.Key]=$row | ConvertTo-Json -Depth 15 | ConvertFrom-Json }
    $script:RingContext=$context
    [pscustomobject]@{Rows=$rows;Groups=$groups;Sources=$sources;CapturedAtUtc=[datetimeoffset]::UtcNow;Summary=($devices.Count.ToString()+' dispositivi Entra; '+$eligible.Count+' Windows Hybrid Corporate MDM abilitati; '+@($rows | Where-Object Orphan).Count+' orfani. '+$groups.Count+' Ring verificati, inclusi quelli solo monitorati.')}
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

function New-RingAssignmentPlan {
    [CmdletBinding()]
    param([object[]]$Assignments,[string]$ConfigPath,$GraphAccess,$ProgressQueue)
    $context=Assert-DmSession $GraphAccess -ReadIds @('entra-read','groups-read') -WriteId 'groups-write'
    if ($context -cne $script:RingContext) { throw 'Aggiornare i dati dopo il cambio di sessione.' }
    $script:RingPlans=@{}
    $settings=Read-DmSettings $ConfigPath RingManager;$groups=@(Get-RingGroups $settings.Options $ProgressQueue)
    $members=Get-RingMemberIndex $groups $ProgressQueue
    $items=New-Object 'Collections.Generic.List[object]';$seen=@{}
    foreach ($assignment in $Assignments) {
        $id=ConvertTo-DmId $assignment.ObjectId
        if ($seen.ContainsKey($id) -or -not $script:RingRows.ContainsKey($id)) { throw 'Selezione duplicata o esterna all''ultima ricerca.' };$seen[$id]=$true
        $expected=$script:RingRows[$id]
        if (-not $expected.Orphan -or $members.ContainsKey($id)) { throw ($expected.Name+' appartiene gia a un Ring. Aggiornare i dati.') }
        $dest=@($groups | Where-Object { $_.Label -ieq [string]$assignment.TargetRing -and $_.IsWritable })
        if ($dest.Count -ne 1) { throw 'Ring di destinazione non assegnabile, cambiato o non configurato.' }
        Assert-RingDeviceSame $expected (Get-RingDeviceLive $id)
        [void]$items.Add([pscustomobject]@{ObjectId=$id;DeviceId=$expected.DeviceId;Name=$expected.Name;TargetRing=$dest[0].Label;GroupId=$dest[0].Id;GroupName=$dest[0].Name})
    }
    if (-not $items.Count) { throw 'Selezionare almeno un PC orfano e un Ring di destinazione.' }
    if ((Assert-DmSession $GraphAccess -ReadIds @('entra-read','groups-read') -WriteId 'groups-write') -cne $context) { throw 'Sessione cambiata durante la preparazione.' }
    $id=[guid]::NewGuid().ToString();$created=[datetimeoffset]::UtcNow
    $script:RingPlans[$id]=[pscustomobject]@{Id=$id;CreatedAt=$created;Context=$context;ConfigPath=$ConfigPath;GroupSignature=(Get-RingGroupSignature $groups);Items=$items.ToArray();MonitoredIds=@($groups | ForEach-Object { $_.Id })}
    [pscustomobject]@{PlanId=$id;CreatedAtUtc=$created;Items=@($items | Select-Object Name,ObjectId,DeviceId,TargetRing,GroupName)}
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
        $state='Bloccato';$errorText='';$posted=$false
        try {
            if ((Assert-DmSession $GraphAccess -ReadIds @('entra-read','groups-read') -WriteId 'groups-write') -cne $plan.Context) { throw 'Sessione cambiata.' }
            $settings=Read-DmSettings $plan.ConfigPath RingManager
            $groups=@(Get-RingGroups $settings.Options $ProgressQueue)
            if ((Get-RingGroupSignature $groups) -cne $plan.GroupSignature) { throw 'Identita o caratteristiche dei gruppi cambiate. Ripetere anteprima e conferma.' }
            Assert-RingDeviceSame $item (Get-RingDeviceLive $item.ObjectId)
            $memberships=@(Get-DmGraphItems -Uri ('https://graph.microsoft.com/v1.0/devices/'+$item.ObjectId+'/transitiveMemberOf?$select=id'))
            if (@($memberships | Where-Object { $plan.MonitoredIds -contains [string]$_.id }).Count) { $state='Gia assegnato';throw 'Il PC appartiene ora a un Ring: nessuna aggiunta eseguita.' }
            if ($PSCmdlet.ShouldProcess(($item.Name+' / '+$item.ObjectId),('Aggiungi a '+$item.GroupName))) {
                Send-DmProgress $ProgressQueue ('Assegnazione: '+$item.Name+' a '+$item.TargetRing)
                $body=@{'@odata.id'=('https://graph.microsoft.com/v1.0/devices/'+$item.ObjectId)} | ConvertTo-Json -Compress
                $posted=$true
                [void](Invoke-MgGraphRequest -Method POST -Uri ('https://graph.microsoft.com/v1.0/groups/'+$item.GroupId+'/members/$ref') -Body $body -ContentType 'application/json' -ErrorAction Stop)
                $verified=$false
                for ($attempt=0;$attempt -lt 3 -and -not $verified;$attempt++) {
                    try { $member=Invoke-MgGraphRequest -Method GET -Uri ('https://graph.microsoft.com/v1.0/groups/'+$item.GroupId+'/members/'+$item.ObjectId+'?$select=id') -OutputType PSObject -ErrorAction Stop;$verified=(ConvertTo-DmId $member.id) -eq $item.ObjectId }
                    catch { if ($attempt -eq 2) { throw } }
                    if (-not $verified -and $attempt -lt 2) { Start-Sleep -Milliseconds 300 }
                }
                if (-not $verified) { throw 'Rilettura dell''appartenenza non confermata.' }
                $state='Assegnato e verificato'
            }
            else { $state='Simulato' }
        }
        catch {
            $errorText=$_.Exception.Message
            if ($posted) { $state='Esito da verificare';$safe=New-ExplorerGraphOperationError -Failure $_ -Stage InitialRead;$errorText='Richiesta di aggiunta inviata; aggiornare i dati prima di riprovare. '+$safe.Message }
        }
        [void]$results.Add([pscustomobject]@{AtUtc=[datetimeoffset]::UtcNow.ToString('o');Name=$item.Name;ObjectId=$item.ObjectId;DeviceId=$item.DeviceId;TargetRing=$item.TargetRing;GroupId=$item.GroupId;State=$state;Error=$errorText})
    }
    [pscustomobject]@{Results=$results.ToArray();Assigned=@($results | Where-Object State -eq 'Assegnato e verificato').Count;Failed=@($results | Where-Object State -notin @('Assegnato e verificato','Simulato')).Count}
}

Export-ModuleMember -Function Test-RingWritable,Test-RingEligible,Get-RingManagerSnapshot,New-RingAssignmentPlan,Invoke-RingAssignmentPlan
