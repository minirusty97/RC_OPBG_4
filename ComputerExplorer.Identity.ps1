#requires -version 5.1

function ConvertTo-ExplorerIdentityGuid {
    param($Value)
    $id=[guid]::Empty
    if ([guid]::TryParse(([string]$Value).Trim(),[ref]$id) -and $id -ne [guid]::Empty) { return $id.ToString() }
    return ''
}

function Get-ExplorerHybridLookupIds {
    param([object[]]$EntraRecords,[object[]]$AdRecords,[string[]]$Controllers)
    foreach ($record in @($EntraRecords | Where-Object { (Get-ExplorerValue $_ 'TrustType') -eq 'ServerAd' })) {
        $id=ConvertTo-ExplorerIdentityGuid (Get-ExplorerValue $record 'DeviceId')
        if (-not $id) { continue }
        $present=@($AdRecords | Where-Object { (ConvertTo-ExplorerIdentityGuid (Get-ExplorerValue $_ 'ObjectGUID')) -eq $id } | ForEach-Object { $_.DomainController } | Sort-Object -Unique)
        if (@($Controllers | Where-Object { $present -notcontains $_ }).Count) { $id }
    }
}

function Read-ExplorerHybridAd {
    [CmdletBinding()]
    param([string[]]$DeviceIds,[string[]]$Controllers,[string]$Name='')
    $result=New-ExplorerSource 'HybridAD'
    $ids=@($DeviceIds | ForEach-Object { ConvertTo-ExplorerIdentityGuid $_ } | Where-Object { $_ } | Sort-Object -Unique)
    if (-not $ids.Count -or -not $Controllers.Count) { $result.State='Errore';$result.Error='GUID hybrid o Domain Controller non disponibili.';return $result }
    try { Import-Module ActiveDirectory -ErrorAction Stop }
    catch { $result.State='Errore';$result.Error='Modulo ActiveDirectory non disponibile per la verifica hybrid.';return $result }
    $records=New-Object 'Collections.Generic.List[object]'
    $checks=New-Object 'Collections.Generic.List[object]'
    $escapedName=$Name.Replace('\','\5c').Replace('*','\2a').Replace('(','\28').Replace(')','\29').Replace([string][char]0,'\00')
    foreach ($dc in $Controllers) {
        $dcRecords=New-Object 'Collections.Generic.List[object]'
        try {
            # GUID bytes follow the AD little-endian representation. Bounded OR
            # batches avoid one network call per device; DCs remain sequential.
            for ($start=0;$start -lt $ids.Count;$start+=40) {
                $criteria=New-Object 'Collections.Generic.List[string]'
                foreach ($id in $ids[$start..([Math]::Min($start+39,$ids.Count-1))]) {
                    $bytes=([guid]$id).ToByteArray()
                    [void]$criteria.Add('(objectGUID='+((@($bytes | ForEach-Object { '\'+$_.ToString('x2') })) -join '')+')')
                }
                if ($start -eq 0 -and $Name) { [void]$criteria.Add('(name='+$escapedName+')') }
                $filter='(|'+($criteria -join '')+')'
                $found=@(Get-ADComputer -Server $dc -LDAPFilter $filter -Properties @('ObjectGUID','DistinguishedName','CanonicalName','DNSHostName','SamAccountName','Enabled','Modified') -ErrorAction Stop)
                foreach ($computer in $found) {
                    $id=ConvertTo-ExplorerIdentityGuid $computer.ObjectGUID
                    $recordName=([string]$computer.Name).Trim()
                    if (-not $id -or -not $recordName -or ($ids -notcontains $id -and (-not $Name -or $recordName -ine $Name))) { throw 'Risposta AD estranea agli identificativi richiesti.' }
                    [void]$dcRecords.Add([pscustomobject]@{Name=$recordName;ObjectGUID=$id;DomainController=$dc;DistinguishedName=[string]$computer.DistinguishedName})
                }
            }
            foreach ($record in @($dcRecords.ToArray() | Sort-Object ObjectGUID -Unique)) { [void]$records.Add($record) }
            [void]$checks.Add([pscustomobject]@{DomainController=$dc;Verificato=$true;Errore=''})
        }
        catch { [void]$checks.Add([pscustomobject]@{DomainController=$dc;Verificato=$false;Errore=('Lettura AD tramite GUID non riuscita su '+$dc+'.')}) }
    }
    $result.Records=$records.ToArray();$result.DcSources=$checks.ToArray();$result.CheckedAtUtc=[datetimeoffset]::UtcNow
    $errors=@($checks | Where-Object { -not $_.Verificato } | ForEach-Object { $_.Errore })
    $result.State='OK';if ($errors.Count) { $result.State='Errore';$result.Error=$errors -join ' ' }
    return $result
}

function Get-ExplorerHybridIdentity {
    [CmdletBinding()]
    param([string]$Name,[object[]]$AdRecords=@(),[object[]]$EntraRecords=@(),[object[]]$AllAdRecords=@(),
        [bool]$AdComplete=$false,[bool]$EntraComplete=$false,[bool]$LookupComplete=$false,[string]$LookupError='')
    $all=@(@($AdRecords)+@($AllAdRecords) | Sort-Object DomainController,ObjectGUID -Unique)
    $sameName=@($all | Where-Object { [string](Get-ExplorerValue $_ 'Name') -ieq $Name })
    $nameGuids=@($sameName | ForEach-Object { ConvertTo-ExplorerIdentityGuid (Get-ExplorerValue $_ 'ObjectGUID') } | Where-Object { $_ } | Sort-Object -Unique)
    $details=New-Object 'Collections.Generic.List[object]'
    foreach ($record in @($EntraRecords | Sort-Object ObjectId -Unique)) {
        $trust=[string](Get-ExplorerValue $record 'TrustType')
        $id=ConvertTo-ExplorerIdentityGuid (Get-ExplorerValue $record 'DeviceId')
        $state='Non applicabile';$color='Grigio';$message='Confronto AD escluso per questo tipo di join.';$confirm=$false
        $matches=@()
        if ($trust -eq 'ServerAd') {
            $matches=@($all | Where-Object { $id -and (ConvertTo-ExplorerIdentityGuid (Get-ExplorerValue $_ 'ObjectGUID')) -eq $id })
            $state='Non verificabile';$color='Giallo';$message='Verifica AD o Entra incompleta.'
            if (-not $id) { $message='Device ID Entra assente o non valido.' }
            elseif ($AdComplete -and $EntraComplete -and -not $LookupError) {
                $other=@($nameGuids | Where-Object { $_ -ne $id })
                if ($matches.Count -and -not $other.Count) {
                    $state='Corrisponde';$color='Verde';$message='Device ID Entra uguale al GUID AD.'
                    $names=@($matches | ForEach-Object { $_.Name } | Sort-Object -Unique)
                    if (@($names | Where-Object { $_ -ine $Name }).Count) { $message+=' Nome AD: '+($names -join ', ')+'.' }
                }
                elseif ($other.Count -and ($matches.Count -or $LookupComplete)) {
                    $state='Non corrisponde';$color='Rosso';$confirm=$true
                    $message='GUID degli oggetti AD omonimi differente dal Device ID Entra: '+($other -join ', ')+'.'
                    if ($matches.Count) { $message+=' Oggetto AD atteso trovato con un altro nome.' }
                }
                elseif ($LookupComplete) { $state='Assente in AD';$color='Giallo';$message='Nessun oggetto AD trovato per nome o Device ID sui DC verificati.' }
                else { $message='Ricerca AD tramite GUID in attesa.' }
            }
            if ($LookupError) { $message=$LookupError }
        }
        elseif ($trust -notin @('Workplace','AzureAd')) { $state='Non verificabile';$color='Giallo';$message='Tipo di join Entra non disponibile o non riconosciuto.' }
        if (-not $EntraComplete) { $state='Non verificabile';$color='Giallo';$message='Fonte Entra non verificata.';$confirm=$false }
        [void]$details.Add([pscustomobject]@{EntraObjectId=[string](Get-ExplorerValue $record 'ObjectId');DeviceId=$id;TrustType=$trust;State=$state;Color=$color;Detail=$message;RequiresConfirmation=$confirm;AdMatches=@($matches | Select-Object Name,ObjectGUID,DomainController,DistinguishedName)})
    }
    $hybrids=@($details | Where-Object TrustType -eq 'ServerAd')
    $needs=@($details | Where-Object RequiresConfirmation).Count -gt 0
    $state='Non applicabile';$color='Grigio'
    if (-not $EntraComplete) { $state='Non verificabile';$color='Giallo' }
    elseif ($needs) { $state='Non corrisponde';$color='Rosso' }
    elseif (@($details | Where-Object State -eq 'Non verificabile').Count) { $state='Non verificabile';$color='Giallo' }
    elseif (@($hybrids | Where-Object State -eq 'Assente in AD').Count) { $state='Assente in AD';$color='Giallo' }
    elseif ($hybrids.Count -gt 0) { $state='Corrisponde';$color='Verde' }
    elseif ($EntraRecords.Count -eq 0) { $state='Assente in Entra' }
    # Canonical non-secret snapshot: also catches a renamed or replaced AD
    # namesake between preview and writes. DC replicas never count as duplicates.
    $signature=@($state,[string]$needs,[string]$AdComplete,[string]$EntraComplete)
    $signature+=@($details | ForEach-Object { $_.EntraObjectId+'|'+$_.DeviceId+'|'+$_.TrustType+'|'+$_.State })
    $hybridIds=@($hybrids | ForEach-Object { $_.DeviceId })
    $relevant=@($all | Where-Object { [string](Get-ExplorerValue $_ 'Name') -ieq $Name -or $hybridIds -contains (ConvertTo-ExplorerIdentityGuid (Get-ExplorerValue $_ 'ObjectGUID')) })
    $signature+=@($relevant | Sort-Object DomainController,ObjectGUID | ForEach-Object { $entry=$_;$points=foreach ($field in @('DomainController','ObjectGUID','Name','DistinguishedName')) { [string](Get-ExplorerValue $entry $field) };$points -join '|' })
    [pscustomobject]@{State=$state;Color=$color;RequiresConfirmation=$needs;Records=$details.ToArray();Signature=($signature -join "`n")}
}
