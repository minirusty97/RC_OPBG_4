#requires -version 5.1
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'ComputerExplorer.Core.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'GLPI.Inventory.psm1') -ErrorAction Stop
$script:BitLockerNoteMarker = '[AIT-BITLOCKER-V1]'

function Get-BlValue {
    param($Object,[string]$Name,$Default=$null)
    if ($null -ne $Object) {
        if ($Object -is [Collections.IDictionary]) { if ($Object.Contains($Name)) { return ,$Object[$Name] } }
        else { $property=$Object.PSObject.Properties[$Name]; if ($null -ne $property) { return ,$property.Value } }
    }
    return ,$Default
}

function ConvertTo-BlId {
    param($Value)
    if ($Value -is [byte[]]) { $Value=[guid]::new([byte[]]$Value) }
    $id=[guid]::Empty
    if (-not [guid]::TryParse([string]$Value,[ref]$id) -or $id -eq [guid]::Empty) { throw 'Identificativo BitLocker non valido.' }
    return $id.ToString()
}

function ConvertTo-BlPassword {
    param($Value)
    $text=([string]$Value).Trim()
    if ($text -notmatch '^\d{6}(-\d{6}){7}$') { throw 'Password di recupero BitLocker assente, non leggibile o non valida.' }
    foreach ($part in $text.Split('-')) { if ([int]$part -gt 720885 -or [int]$part % 11 -ne 0) { throw 'Password di recupero BitLocker non valida.' } }
    return $text
}

function Get-BlSerial {
    param($Value)
    $serial=([string]$Value).Trim().ToUpperInvariant()
    if (-not $serial -or $serial -match '^(UNKNOWN|NONE|N/?A|NOT (AVAILABLE|APPLICABLE|SPECIFIED)|DEFAULT STRING|SYSTEM SERIAL NUMBER|TO BE FILLED BY O\.?E\.?M\.?|0+|F+|-+)$') { return '' }
    return $serial
}

function Test-BlDeleted {
    param($Value)
    return ([string]$Value -in @('1','true'))
}

function Get-BlFingerprint {
    param([string]$Key)
    $hash=[Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Key))).Replace('-','') }
    finally { $hash.Dispose() }
}

function Get-ExplorerBitLockerKeys {
    [CmdletBinding()]
    param([object[]]$Targets)
    $keys=@{}
    $deviceIds=@(@($Targets | Where-Object Source -eq 'Intune')+@($Targets | Where-Object Source -eq 'Entra') | ForEach-Object { ConvertTo-BlId $_.LinkId } | Select-Object -Unique)
    foreach ($deviceId in $deviceIds) {
        $path='/v1.0/informationProtection/bitlocker/recoveryKeys'
        $uri='https://graph.microsoft.com'+$path+'?$filter='+[Uri]::EscapeDataString("deviceId eq '$deviceId'")
        try {
            $records=@(Get-ExplorerGraphCollection -Uri $uri -ResourcePath $path)
            foreach ($record in $records) {
                $keyId=ConvertTo-BlId $record.id
                if ((ConvertTo-BlId $record.deviceId) -ne $deviceId) { throw 'Chiave Graph esterna al dispositivo richiesto.' }
                $keyUri='https://graph.microsoft.com'+$path+'/'+$keyId+'?$select=id,deviceId,key,createdDateTime,volumeType'
                $response=Invoke-MgGraphRequest -Method GET -Uri $keyUri -OutputType PSObject -Headers @{'User-Agent'='AssistenteIT-BitLocker'} -ErrorAction Stop
                $secret=Get-BlValue $response 'value' $response
                if ((ConvertTo-BlId $secret.id) -ne $keyId -or (ConvertTo-BlId $secret.deviceId) -ne $deviceId) { throw 'Identita della chiave Graph cambiata.' }
                $key=ConvertTo-BlPassword (Get-BlValue $secret 'key')
                $origin='Entra:'+ $deviceId
                if (@($Targets | Where-Object { $_.Source -eq 'Intune' -and (ConvertTo-BlId $_.LinkId) -eq $deviceId }).Count -gt 0) { $origin='Intune:'+ $deviceId }
                if ($keys.ContainsKey($keyId)) {
                    if ($keys[$keyId].Password -cne $key) { throw 'Chiavi discordanti per lo stesso Recovery Key ID.' }
                    $keys[$keyId].Origins=@(@($keys[$keyId].Origins)+$origin | Sort-Object -Unique)
                }
                else { $keys[$keyId]=[pscustomobject]@{KeyId=$keyId;Password=$key;Volume=[string](Get-BlValue $secret 'volumeType');CreatedAt=[string](Get-BlValue $secret 'createdDateTime');Origins=@($origin);Fingerprint=(Get-BlFingerprint $key)} }
            }
        }
        catch { throw ('Lettura BitLocker da Entra ID non completata per Device ID '+$deviceId+'. Verificare accesso, BitlockerKey.Read.All e consenso delegato e ruolo del tecnico; nessuna eliminazione consentita.') }
    }
    foreach ($target in @($Targets | Where-Object Source -eq 'AD')) {
        foreach ($child in @($target.AdChildren | Where-Object ObjectClass -eq 'msFVE-RecoveryInformation')) {
            try {
                $record=Get-ADObject -Server $target.DomainController -Identity ([guid]$child.Id) -Properties @('msFVE-RecoveryPassword','msFVE-RecoveryGuid','msFVE-VolumeGuid','whenCreated') -ErrorAction Stop
                if ((ConvertTo-BlId $record.ObjectGUID) -ne $child.Id -or -not [string]::Equals([string]$record.DistinguishedName,[string]$child.DistinguishedName,[StringComparison]::OrdinalIgnoreCase)) { throw 'Oggetto BitLocker AD cambiato durante la lettura.' }
                $keyId=ConvertTo-BlId (Get-BlValue $record 'msFVE-RecoveryGuid')
                $key=ConvertTo-BlPassword (Get-BlValue $record 'msFVE-RecoveryPassword')
                $volume=''
                $rawVolume=Get-BlValue $record 'msFVE-VolumeGuid'
                if ($null -ne $rawVolume) { try { $volume=ConvertTo-BlId $rawVolume } catch { $volume='Non disponibile' } }
                $origin='AD:'+ $target.Id
                if ($keys.ContainsKey($keyId)) {
                    if ($keys[$keyId].Password -cne $key) { throw 'Chiavi discordanti per lo stesso Recovery Key ID.' }
                    $keys[$keyId].Origins=@(@($keys[$keyId].Origins)+$origin | Sort-Object -Unique)
                }
                else { $keys[$keyId]=[pscustomobject]@{KeyId=$keyId;Password=$key;Volume=$volume;CreatedAt=[string](Get-BlValue $record 'whenCreated');Origins=@($origin);Fingerprint=(Get-BlFingerprint $key)} }
            }
            catch { throw ('Lettura della chiave BitLocker AD non completata per l''oggetto '+$child.Id+'. Verificare permessi e disponibilita sul DC; nessuna eliminazione consentita.') }
        }
    }
    return @($keys.Values | Sort-Object KeyId)
}

function Get-BlKeyLookupWorkerScript {
    return {
        param($ModulePath,$Source,$Name,$DomainController)
        $ErrorActionPreference='Stop'
        $module=Import-Module $ModulePath -PassThru -ErrorAction Stop
        & $module { param($Source,$Name,$DomainController) Read-BlKeysBySource -Source $Source -Name $Name -DomainController $DomainController } $Source $Name $DomainController
    }
}

function Read-BlLiveKeySource {
    param([ValidateSet('Intune','AD')][string]$Source,[string]$Name,[string]$DomainController,[int]$TimeoutSeconds=90)
    $pipeline=[PowerShell]::Create();$operation=$null;$stop=$null
    try {
        $body=Get-BlKeyLookupWorkerScript
        [void]$pipeline.AddScript($body.ToString()).AddArgument((Join-Path $PSScriptRoot 'BitLocker.Archive.psm1')).AddArgument($Source).AddArgument($Name).AddArgument($DomainController)
        $operation=$pipeline.BeginInvoke()
        if (-not $operation.AsyncWaitHandle.WaitOne($TimeoutSeconds*1000)) {
            $stop=$pipeline.BeginStop($null,$null);$pipeline.EndStop($stop)
            throw ('Tempo massimo di lettura BitLocker da '+$Source+' superato ('+$TimeoutSeconds+' s).')
        }
        $records=@($pipeline.EndInvoke($operation))
        if ($pipeline.Streams.Error.Count -gt 0) { throw $pipeline.Streams.Error[0] }
        return $records
    }
    finally {
        if ($null -ne $operation -and -not $operation.IsCompleted) {
            try { $stop=$pipeline.BeginStop($null,$null);$pipeline.EndStop($stop) } catch { }
        }
        $pipeline.Dispose()
    }
}

function Read-BlKeysBySource {
    param([ValidateSet('Intune','AD')][string]$Source,[string]$Name,[string]$DomainController)
    $targets=New-Object 'Collections.Generic.List[object]'
    if ($Source -eq 'Intune') {
        Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
        $path='/v1.0/deviceManagement/managedDevices'
        $filter=[Uri]::EscapeDataString("deviceName eq '"+$Name.Replace("'","''")+"'")
        $uri='https://graph.microsoft.com'+$path+'?$filter='+$filter+'&$select=id,deviceName,azureADDeviceId,serialNumber,operatingSystem'
        foreach ($record in @(Get-ExplorerGraphCollection -Uri $uri -ResourcePath $path)) {
            if (-not [string]::Equals([string](Get-BlValue $record 'deviceName'),$Name,[StringComparison]::OrdinalIgnoreCase) -or
                [string](Get-BlValue $record 'operatingSystem') -notlike 'Windows*') { continue }
            [void]$targets.Add([pscustomobject]@{Source='Intune';Name=$Name;Id=(ConvertTo-BlId (Get-BlValue $record 'id'))
                LinkId=(ConvertTo-BlId (Get-BlValue $record 'azureADDeviceId'));SerialNumber=[string](Get-BlValue $record 'serialNumber')})
        }
    }
    else {
        Import-Module ActiveDirectory -ErrorAction Stop
        $escaped=$Name.Replace('\','\5c').Replace('*','\2a').Replace('(','\28').Replace(')','\29').Replace([string][char]0,'\00')
        foreach ($computer in @(Get-ADComputer -Server $DomainController -LDAPFilter ('(name='+$escaped+')') -Properties @('ObjectGUID','DistinguishedName') -ErrorAction Stop)) {
            if (-not [string]::Equals([string]$computer.Name,$Name,[StringComparison]::OrdinalIgnoreCase)) { throw 'Risposta AD estranea al nome richiesto.' }
            $rootDn=[string]$computer.DistinguishedName
            if (-not $rootDn) { throw 'Percorso AD del computer assente.' }
            $children=New-Object 'Collections.Generic.List[object]'
            foreach ($child in @(Get-ADObject -Server $DomainController -SearchBase $rootDn -SearchScope Subtree -LDAPFilter '(objectClass=msFVE-RecoveryInformation)' -Properties @('ObjectGUID') -ErrorAction Stop)) {
                if ($child.ObjectClass -ne 'msFVE-RecoveryInformation' -or -not ([string]$child.DistinguishedName).EndsWith(','+$rootDn,[StringComparison]::OrdinalIgnoreCase)) { throw 'Oggetto BitLocker estraneo al computer AD richiesto.' }
                [void]$children.Add([pscustomobject]@{Id=(ConvertTo-BlId $child.ObjectGUID);DistinguishedName=[string]$child.DistinguishedName;ObjectClass=[string]$child.ObjectClass})
            }
            [void]$targets.Add([pscustomobject]@{Source='AD';Name=$Name;Id=(ConvertTo-BlId $computer.ObjectGUID);DomainController=$DomainController;AdChildren=$children.ToArray()})
        }
    }
    foreach ($key in @(Get-ExplorerBitLockerKeys -Targets $targets.ToArray())) {
        $serials=@($targets | Where-Object { $_.Source -eq 'Intune' -and $key.Origins -contains ('Intune:'+ $_.LinkId) } | ForEach-Object { $_.SerialNumber } | Sort-Object -Unique)
        [pscustomobject]@{Name=$Name;KeyId=$key.KeyId;Password=$key.Password;Volume=$key.Volume;Origins=$key.Origins;Serial=($serials -join ', ');CreatedAt=$key.CreatedAt;ArchivedAtUtc=''}
    }
}

function Find-ExplorerBitLockerKeys {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Name,[Parameter(Mandatory=$true)][string]$ConfigPath,$ProgressQueue)
    $name=$Name.Trim()
    if (-not $name -or $name.Length -gt 255) { throw 'Inserire il nome esatto del computer.' }
    $config=Read-ExplorerConfiguration $ConfigPath
    $sources=New-Object 'Collections.Generic.List[object]';$records=New-Object 'Collections.Generic.List[object]'
    if ($null -ne $ProgressQueue) { $ProgressQueue.Enqueue([pscustomobject]@{Kind='RemovalProgress';Message='Ricerca chiavi BitLocker: dispositivo Intune e chiavi cloud...';Result=$null}) }
    try {
        Connect-ExplorerGraph -Sources Intune -ForBitLocker -ProgressQueue $ProgressQueue -GraphAuthentication (Get-BlValue $config 'GraphAuthentication')
        $found=@(Read-BlLiveKeySource -Source Intune -Name $name -TimeoutSeconds $config.CloudReadTimeoutSeconds)
        foreach ($record in $found) { [void]$records.Add($record) }
        [void]$sources.Add([pscustomobject]@{Name='Intune';State='OK';Count=$found.Count;Error=''})
    }
    catch {
        [void]$sources.Add([pscustomobject]@{Name='Intune';State='Errore';Count=0;Error='Lettura Intune/BitLocker non riuscita: verificare connessione, impostazioni Graph, Azure AD Device ID e consenso delegato BitlockerKey.Read.All e ruolo del tecnico. Se la richiesta e scaduta, riprovare.'})
    }
    if ($records.Count -eq 0) {
        $configuredControllers=Get-BlValue $config.Settings 'DomainControllers' @()
        $controllers=@($configuredControllers | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Select-Object -Unique)
        foreach ($dc in $controllers) {
            if ($null -ne $ProgressQueue) { $ProgressQueue.Enqueue([pscustomobject]@{Kind='RemovalProgress';Message=('Ricerca chiavi BitLocker: fallback AD su '+$dc+'...');Result=$null}) }
            try {
                $found=@(Read-BlLiveKeySource -Source AD -Name $name -DomainController $dc -TimeoutSeconds $config.CloudReadTimeoutSeconds)
                foreach ($record in $found) { [void]$records.Add($record) }
                [void]$sources.Add([pscustomobject]@{Name=('AD: '+$dc);State='OK';Count=$found.Count;Error=''})
                if ($found.Count -gt 0) { break }
            }
            catch { [void]$sources.Add([pscustomobject]@{Name=('AD: '+$dc);State='Errore';Count=0;Error='Lettura AD non riuscita: verificare disponibilita del DC e permessi sulle informazioni di recupero.'}) }
        }
        if ($controllers.Count -eq 0) { [void]$sources.Add([pscustomobject]@{Name='AD';State='Errore';Count=0;Error='Nessun Domain Controller configurato per la ricerca di riserva.'}) }
    }
    $unique=@{}
    foreach ($record in $records) {
        if ($unique.ContainsKey($record.KeyId)) {
            if ($unique[$record.KeyId].Password -cne $record.Password) { throw 'Fonti discordanti per lo stesso Key ID. Verificare le chiavi prima di usarle.' }
            $unique[$record.KeyId].Origins=@(@($unique[$record.KeyId].Origins)+@($record.Origins) | Sort-Object -Unique)
        }
        else { $unique[$record.KeyId]=$record }
    }
    [pscustomobject]@{Name=$name;Records=@($unique.Values | Sort-Object KeyId);Sources=$sources.ToArray();Live=$true}
}


function Invoke-BlGlpiRequest {
    param($Session,[ValidateSet('GET','POST')][string]$Method,[string]$Path,$Body,[hashtable]$Query=@{})
    if ($Path -notmatch '^(initSession|killSession|Computer/[1-9][0-9]*(/Notepad)?|Notepad(/[1-9][0-9]*)?)$' -or
        ($Method -eq 'POST' -and $Path -ne 'Notepad')) { throw 'Operazione GLPI non prevista per l''archivio BitLocker.' }
    $uri=$Session.BaseUri+'/'+$Path
    if ($Query.Count -gt 0) { $uri+='?'+((@($Query.Keys | Sort-Object | ForEach-Object { [Uri]::EscapeDataString($_)+'='+[Uri]::EscapeDataString([string]$Query[$_]) })) -join '&') }
    $arguments=@{Method=$Method;Uri=$uri;Headers=$Session.Headers;ContentType='application/json; charset=utf-8';TimeoutSec=$Session.Timeout;ErrorAction='Stop';UseBasicParsing=$true;MaximumRedirection=0}
    if ($Method -eq 'POST') { $arguments.Body=[Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 12 -Compress)) }
    try {
        $response=Invoke-WebRequest @arguments
        $data=$response.Content | ConvertFrom-Json -ErrorAction Stop
        return [pscustomobject]@{Data=$data;Headers=$response.Headers;Status=[int]$response.StatusCode}
    }
    catch { throw ('Operazione GLPI '+$Method+' '+$Path+' non riuscita. Verificare connessione e diritti di lettura/aggiornamento delle Note.') }
}

function Open-BlGlpiSession {
    param($Settings,[Security.SecureString]$UserToken,[Security.SecureString]$AppToken)
    $base=[Uri]([string](Get-BlValue $Settings 'BaseUri'))
    if (-not $base.IsAbsoluteUri -or $base.Scheme -notin @('http','https') -or $base.AbsolutePath.TrimEnd('/') -notmatch '/apirest\.php$' -or $base.UserInfo -or $base.Query -or $base.Fragment) { throw 'Configurare l''URL GLPI apirest.php per l''archivio BitLocker.' }
    if ($null -eq $UserToken -or $UserToken.Length -eq 0) { throw 'Token GLPI assente per l''archivio BitLocker.' }
    if (-not [bool](Get-BlValue $Settings 'UseAppToken' $true)) { $AppToken=$null }
    elseif ($null -eq $AppToken -or $AppToken.Length -eq 0) { throw 'App token GLPI assente per l''archivio BitLocker.' }
    $session=@{BaseUri=$base.AbsoluteUri.TrimEnd('/');Timeout=[int](Get-BlValue $Settings 'TimeoutSeconds' 20);Headers=@{Accept='application/json'}}
    foreach ($entry in @(@{Name='App-Token';Value=$AppToken},@{Name='Authorization';Value=$UserToken})) {
        if ($null -ne $entry.Value -and $entry.Value.Length -gt 0) {
            $pointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($entry.Value)
            try { $value=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer); if ($entry.Name -eq 'Authorization') { $value='user_token '+$value }; $session.Headers[$entry.Name]=$value }
            finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
        }
    }
    try { $result=Invoke-BlGlpiRequest -Session $session -Method GET -Path initSession }
    finally { $session.Headers.Remove('Authorization') }
    $token=[string](Get-BlValue $result.Data 'session_token')
    if (-not $token) { throw 'Sessione GLPI non valida.' }
    $session.Headers['Session-Token']=$token
    return $session
}

function Close-BlGlpiSession {
    param($Session)
    if ($null -ne $Session) {
        try { [void](Invoke-BlGlpiRequest -Session $Session -Method GET -Path killSession) }
        catch { Write-Warning 'Chiusura della sessione GLPI BitLocker non confermata.' }
        finally { $Session.Headers.Clear() }
    }
}

function Get-BlGlpiNotes {
    param($Session,[int]$ComputerId)
    $notes=New-Object 'Collections.Generic.List[object]'; $start=0; $total=-1; $seen=@{}
    do {
        $response=Invoke-BlGlpiRequest -Session $Session -Method GET -Path ('Computer/'+$ComputerId+'/Notepad') -Query @{range=($start.ToString()+'-'+($start+99));get_hateoas='false';sort='id';order='ASC'}
        $rows=@($response.Data)
        if ($rows.Count -eq 1 -and $null -eq $rows[0]) { $rows=@() }
        $range=[string]$response.Headers['Content-Range']
        if ($range -match '^(?:\w+\s+)?(\d+)-(\d+)/(\d+)$') {
            $offset=[int]$Matches[1]; $last=[int]$Matches[2]; $count=[int]$Matches[3]
            if (($total -ge 0 -and $count -ne $total) -or $offset -ne $start -or ($count -gt 0 -and $last-$offset+1 -ne $rows.Count)) { throw 'L''elenco delle Note GLPI e cambiato o incompleto. Ripetere la verifica.' }
            $total=$count
        }
        elseif ($rows.Count -eq 0 -and $start -eq 0 -and $response.Status -eq 200) { $total=0 }
        else { throw 'Paginazione delle Note GLPI non verificabile.' }
        foreach ($note in $rows) {
            $id=[int](Get-BlValue $note 'id')
            if ($id -le 0 -or $seen.ContainsKey($id) -or [string]$note.itemtype -cne 'Computer' -or [int]$note.items_id -ne $ComputerId) { throw 'Risposta Note GLPI non valida o riferita a un altro computer.' }
            $seen[$id]=$true; [void]$notes.Add($note)
        }
        $start+=$rows.Count
        if ($start -lt $total -and $rows.Count -eq 0) { throw 'Elenco Note GLPI interrotto.' }
        if ($total -gt 10000) { throw 'Troppe Note GLPI per una verifica completa.' }
    } while ($start -lt $total)
    if ($notes.Count -ne $total) { throw 'Elenco Note GLPI incompleto.' }
    return @($notes.ToArray())
}

function Read-BlNote {
    param($Note,[int]$ComputerId)
    $content=[Net.WebUtility]::HtmlDecode([string](Get-BlValue $Note 'content'))
    if ($content -notmatch [regex]::Escape($script:BitLockerNoteMarker)) { return $null }
    $match=[regex]::Match($content,([regex]::Escape($script:BitLockerNoteMarker)+'\s*(\{[\s\S]*\})'))
    if (-not $match.Success) { throw 'Nota archivio BitLocker non valida. Le note esistenti non vengono modificate.' }
    try { $record=$match.Groups[1].Value | ConvertFrom-Json -ErrorAction Stop }
    catch { throw 'Nota archivio BitLocker non leggibile. Le note esistenti non vengono modificate.' }
    if ($record.SchemaVersion -ne 1 -or [int]$record.ComputerId -ne $ComputerId) { throw 'La nota BitLocker non appartiene alla scheda GLPI verificata.' }
    [void](ConvertTo-BlId $record.KeyId); [void](ConvertTo-BlPassword $record.Password)
    return $record
}

function Get-ExplorerBitLockerPreview {
    [CmdletBinding()]
    param([string]$Name,[object[]]$Targets,$Settings,[Security.SecureString]$UserToken,[Security.SecureString]$AppToken)
    if (-not [bool](Get-BlValue $Settings 'Enabled' $false)) { throw 'GLPI deve essere configurato e abilitato prima di archiviare o eliminare i dispositivi.' }
    $query=@{BaseUri=([Uri]$Settings.BaseUri);NameFragment=$Name;UserToken=$UserToken;TimeoutSeconds=[int](Get-BlValue $Settings 'TimeoutSeconds' 20)}
    if ([bool](Get-BlValue $Settings 'UseAppToken' $true)) { $query.AppToken=$AppToken }
    $computers=@(Find-GlpiComputer @query | Where-Object { [string]::Equals([string]$_.Name,$Name,[StringComparison]::OrdinalIgnoreCase) -and -not (Test-BlDeleted $_.IsDeleted) })
    if ($computers.Count -ne 1) { throw 'Occorre una sola scheda GLPI attiva con il nome esatto. Risolvere assenze o duplicati prima dell''archiviazione.' }
    $computer=$computers[0]; $serial=Get-BlSerial $computer.SerialNumber
    if (-not $serial) { throw 'Seriale GLPI assente o generico: associazione dell''archivio non verificabile.' }
    $intune=@($Targets | Where-Object Source -eq 'Intune')
    foreach ($target in $intune) { if ((Get-BlSerial $target.SerialNumber) -cne $serial) { throw 'Seriale Intune diverso da GLPI, assente o generico. Archiviazione ed eliminazione bloccate.' } }
    $cloudIds=@($Targets | Where-Object Source -eq 'Entra' | ForEach-Object { ConvertTo-BlId $_.LinkId } | Sort-Object -Unique)
    $intuneIds=@($intune | ForEach-Object { ConvertTo-BlId $_.LinkId } | Sort-Object -Unique)
    $manual=$intune.Count -eq 0 -or @($cloudIds | Where-Object { $intuneIds -notcontains $_ }).Count -gt 0
    $keys=@(Get-ExplorerBitLockerKeys -Targets $Targets)
    $session=$null
    try {
        $session=Open-BlGlpiSession $Settings $UserToken $AppToken
        $live=(Invoke-BlGlpiRequest -Session $session -Method GET -Path ('Computer/'+$computer.GlpiId)).Data
        if ([int]$live.id -ne [int]$computer.GlpiId -or (Get-BlSerial $live.serial) -cne $serial -or -not [string]::Equals([string]$live.name,$Name,[StringComparison]::OrdinalIgnoreCase) -or (Test-BlDeleted $live.is_deleted)) { throw 'La scheda GLPI e cambiata durante la verifica.' }
        [void](Get-BlGlpiNotes -Session $session -ComputerId $computer.GlpiId)
    }
    finally { Close-BlGlpiSession $session }
    return [pscustomobject]@{ComputerId=[int]$computer.GlpiId;Name=[string]$computer.Name;Serial=$serial;EntityId=[int]$computer.EntityId;RequiresMappingConfirmation=$manual
        Keys=@($keys | Select-Object KeyId,Fingerprint,Volume,CreatedAt,Origins)}
}

function Test-ExplorerBitLockerSnapshot {
    param($Expected,$Current)
    foreach ($field in @('ComputerId','Name','Serial','EntityId')) { if ([string]$Expected.$field -ine [string]$Current.$field) { return $false } }
    if ($Expected.Keys.Count -ne $Current.Keys.Count) { return $false }
    foreach ($key in $Current.Keys) {
        $previous=@($Expected.Keys | Where-Object KeyId -eq $key.KeyId)
        if ($previous.Count -ne 1 -or $previous[0].Fingerprint -cne $key.Fingerprint -or (@($previous[0].Origins | Sort-Object) -join '|') -cne (@($key.Origins | Sort-Object) -join '|')) { return $false }
    }
    return $true
}

function Save-ExplorerBitLockerArchive {
    [CmdletBinding()]
    param($Preview,[object[]]$Targets,$Settings,[Security.SecureString]$UserToken,[Security.SecureString]$AppToken,$ProgressQueue)
    $keys=@(Get-ExplorerBitLockerKeys -Targets $Targets)
    $current=[pscustomobject]@{ComputerId=$Preview.ComputerId;Name=$Preview.Name;Serial=$Preview.Serial;EntityId=$Preview.EntityId;Keys=$keys}
    if (-not (Test-ExplorerBitLockerSnapshot $Preview $current)) { throw 'Le chiavi BitLocker sono cambiate dopo l''anteprima. Ripetere la verifica.' }
    $session=$null; $verified=New-Object 'Collections.Generic.List[object]'
    try {
        $session=Open-BlGlpiSession $Settings $UserToken $AppToken
        $live=(Invoke-BlGlpiRequest -Session $session -Method GET -Path ('Computer/'+$Preview.ComputerId)).Data
        if ([int]$live.id -ne $Preview.ComputerId -or (Get-BlSerial $live.serial) -cne $Preview.Serial -or [string]$live.name -ine $Preview.Name -or [int]$live.entities_id -ne $Preview.EntityId -or (Test-BlDeleted $live.is_deleted)) { throw 'Identita della scheda GLPI cambiata: salvataggio interrotto.' }
        $existing=@{}
        foreach ($note in @(Get-BlGlpiNotes $session $Preview.ComputerId)) {
            $record=Read-BlNote $note $Preview.ComputerId
            if ($null -ne $record) {
                if ($existing.ContainsKey($record.KeyId) -and $existing[$record.KeyId].Password -cne $record.Password) { throw 'Archivio GLPI con password discordanti per lo stesso Key ID.' }
                $existing[$record.KeyId]=$record
            }
        }
        foreach ($key in $keys) {
            if ($null -ne $ProgressQueue) { $ProgressQueue.Enqueue([pscustomobject]@{Kind='RemovalProgress';Message=('Archiviazione BitLocker '+$Preview.Name+' - '+$key.KeyId);Result=$null}) }
            if ($existing.ContainsKey($key.KeyId)) {
                if ($existing[$key.KeyId].Password -cne $key.Password -or [string]$existing[$key.KeyId].Serial -cne $Preview.Serial) { throw 'Chiave gia archiviata discordante: nessuna sovrascrittura consentita.' }
            }
            else {
                $record=[ordered]@{SchemaVersion=1;ComputerId=$Preview.ComputerId;Name=$Preview.Name;Serial=$Preview.Serial;KeyId=$key.KeyId;Password=$key.Password;Volume=$key.Volume;CreatedAt=$key.CreatedAt;Origins=$key.Origins;ArchivedAtUtc=[datetimeoffset]::UtcNow.ToString('o')}
                $text=$script:BitLockerNoteMarker+"`r`n"+($record | ConvertTo-Json -Depth 8)
                $content='<p><strong>Assistente IT - Archivio BitLocker</strong> - Key ID '+$key.KeyId+' - '+[datetime]::UtcNow.ToString('yyyy-MM-dd')+'</p><pre>'+[Net.WebUtility]::HtmlEncode($text)+'</pre>'
                $created=(Invoke-BlGlpiRequest -Session $session -Method POST -Path Notepad -Body @{input=@{itemtype='Computer';items_id=$Preview.ComputerId;content=$content}}).Data
                $id=[int](Get-BlValue $created 'id')
                if ($id -le 0) { throw 'GLPI non ha confermato la creazione della nota BitLocker.' }
                $saved=(Invoke-BlGlpiRequest -Session $session -Method GET -Path ('Notepad/'+$id)).Data
                if ([int]$saved.id -ne $id -or [int]$saved.items_id -ne $Preview.ComputerId -or [string]$saved.itemtype -cne 'Computer') { throw 'Nota BitLocker riletta da un computer diverso.' }
                $readBack=Read-BlNote $saved $Preview.ComputerId
                if ($null -eq $readBack -or $readBack.KeyId -cne $key.KeyId -or $readBack.Password -cne $key.Password -or [string]$readBack.Serial -cne $Preview.Serial) { throw 'Verifica della chiave BitLocker salvata su GLPI non riuscita.' }
            }
            [void]$verified.Add([pscustomobject]@{KeyId=$key.KeyId;Fingerprint=$key.Fingerprint})
        }
    }
    finally { Close-BlGlpiSession $session }
    return [pscustomobject]@{ComputerId=$Preview.ComputerId;Count=$verified.Count;Keys=$verified.ToArray()}
}

function Read-ExplorerBitLockerArchive {
    [CmdletBinding()]
    param([int]$ComputerId,$Settings,[Security.SecureString]$UserToken,[Security.SecureString]$AppToken)
    if ($ComputerId -le 0) { throw 'Selezionare una scheda GLPI valida.' }
    $session=$null; $records=New-Object 'Collections.Generic.List[object]'
    try {
        $session=Open-BlGlpiSession $Settings $UserToken $AppToken
        foreach ($note in @(Get-BlGlpiNotes $session $ComputerId)) {
            $record=Read-BlNote $note $ComputerId
            if ($null -ne $record) { [void]$records.Add($record) }
        }
    }
    finally { Close-BlGlpiSession $session }
    return @($records.ToArray())
}

Export-ModuleMember -Function Find-ExplorerBitLockerKeys,Get-ExplorerBitLockerKeys,Get-ExplorerBitLockerPreview,Test-ExplorerBitLockerSnapshot,Save-ExplorerBitLockerArchive,Read-ExplorerBitLockerArchive
