#requires -version 5.1
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'ComputerExplorer.Core.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'GLPI.Inventory.psm1') -ErrorAction Stop

function Get-DmValue {
    param($Object,[string]$Name,$Default=$null)
    if ($null -ne $Object) {
        if ($Object -is [Collections.IDictionary]) { if ($Object.Contains($Name)) { return ,$Object[$Name] } }
        else { $p=$Object.PSObject.Properties[$Name];if ($null -ne $p) { return ,$p.Value } }
    }
    return ,$Default
}

function ConvertTo-DmId {
    param($Value)
    $id=[guid]::Empty
    if (-not [guid]::TryParse([string]$Value,[ref]$id) -or $id -eq [guid]::Empty) { throw 'Identificativo oggetto assente o non valido.' }
    return $id.ToString()
}

function Send-DmProgress {
    param($Queue,[string]$Message)
    if ($null -ne $Queue) { $Queue.Enqueue([pscustomobject]@{Message=$Message}) }
}

function Test-DmPermission {
    param($Access,[string]$Id)
    $permissions=Get-DmValue $Access 'Permissions' @()
    return @($permissions | Where-Object { $_.Id -eq $Id -and $_.Available }).Count -eq 1
}

function Assert-DmSession {
    param($Access,[string[]]$ReadIds=@('entra-read'),[string]$WriteId='')
    if ($null -eq $Access -or -not [bool](Get-DmValue $Access 'CanOpen' $false)) { throw 'Eseguire Accesso dal wrapper prima di aprire il modulo.' }
    foreach ($id in $ReadIds) { if (-not (Test-DmPermission $Access $id)) { throw ('Lettura non autorizzata: '+$id+'. Ripetere Accesso dal wrapper.') } }
    if ($WriteId -and ([bool](Get-DmValue $Access 'ReadOnly' $true) -or -not (Test-DmPermission $Access $WriteId))) { throw 'Modulo in sola lettura: operazione di scrittura non consentita.' }
    $context=Get-MgContext -ErrorAction Stop
    if ($null -eq $context -or [string](Get-DmValue $context 'AuthType') -ne 'Delegated' -or
        [string](Get-DmValue $context 'Environment') -notin @('','Global') -or
        [string](Get-DmValue $context 'TenantId') -ine [string]$Access.TenantId -or
        [string](Get-DmValue $context 'ClientId') -ine [string]$Access.ClientId -or
        [string](Get-DmValue $context 'Account') -ine [string]$Access.Account) { throw 'Sessione Graph cambiata. Chiudere i moduli e ripetere Accesso dal wrapper.' }
    $scopes=Get-DmValue $context 'Scopes' @()
    return ((@($context.TenantId,$context.ClientId,$context.Account,$context.AuthType)+@(($scopes | Sort-Object) -join ',')) -join '|')
}

function Read-DmSettings {
    param([string]$ConfigPath,[ValidateSet('HybridJoin','RingManager')][string]$Section,[switch]$SettingsOnly)
    if ($SettingsOnly) { $config=[pscustomobject]@{Settings=(Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)} }
    else { $config=Read-ExplorerConfiguration $ConfigPath }
    $defaults=Get-Content (Join-Path $PSScriptRoot 'computer-explorer.config.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $sectionDefaults=Get-DmValue $defaults $Section
    $custom=Get-DmValue $config.Settings $Section
    $values=[ordered]@{}
    foreach ($property in $sectionDefaults.PSObject.Properties) { $values[$property.Name]=Get-DmValue $custom $property.Name $property.Value }
    [pscustomobject]@{Config=$config;Options=[pscustomobject]$values}
}

function Get-DmGraphItems {
    param([Parameter(Mandatory=$true)][string]$Uri,[hashtable]$Headers=@{},$ProgressQueue)
    $path=([uri]$Uri).AbsolutePath;$visited=@{};$records=@{}
    while ($Uri) {
        $parsed=$null
        if (-not [uri]::TryCreate($Uri,[UriKind]::Absolute,[ref]$parsed) -or $parsed.Scheme -ne 'https' -or
            $parsed.Host -ne 'graph.microsoft.com' -or $parsed.Port -ne 443 -or $parsed.UserInfo -or $parsed.Fragment -or
            $parsed.AbsolutePath -ne $path -or $visited.ContainsKey($Uri) -or $visited.Count -ge 10000) { throw 'Paginazione Graph non valida o incompleta.' }
        $visited[$Uri]=$true
        Send-DmProgress $ProgressQueue ('Lettura '+$path+': '+$records.Count+' oggetti...')
        try { $page=Invoke-MgGraphRequest -Method GET -Uri $Uri -Headers $Headers -OutputType PSObject -ErrorAction Stop }
        catch { throw (New-ExplorerGraphOperationError -Failure $_ -Stage InitialRead) }
        $items=Get-DmValue $page 'value'
        if ($null -eq $items -or -not ($items -is [Array] -or $items -is [Collections.IList])) { throw 'Raccolta Graph value assente o non valida.' }
        foreach ($item in $items) {
            $id=ConvertTo-DmId (Get-DmValue $item 'id')
            if ($records.ContainsKey($id)) {
                if (($records[$id] | ConvertTo-Json -Depth 10 -Compress) -cne ($item | ConvertTo-Json -Depth 10 -Compress)) { throw 'Graph ha restituito dati discordanti per lo stesso Object ID.' }
            }
            else { $records[$id]=$item }
        }
        $Uri=[string](Get-DmValue $page '@odata.nextLink' '')
    }
    return @($records.Values)
}

function Get-DmEntraInventory {
    param($ProgressQueue)
    Get-DmGraphItems -Uri 'https://graph.microsoft.com/v1.0/devices?$select=id,deviceId,displayName,trustType,deviceOwnership,isManaged,isCompliant,accountEnabled,operatingSystem,operatingSystemVersion,registrationDateTime,approximateLastSignInDateTime,onPremisesSyncEnabled&$top=999' -ProgressQueue $ProgressQueue
}

function Add-DmInventory {
    param([object[]]$Rows,$Config,$Access,[string]$EnvPath,$ProgressQueue)
    $intune=@();$intuneState='Non autorizzato';$intuneError='Lettura Intune non disponibile nella verifica iniziale.'
    if (Test-DmPermission $Access 'intune-read') {
        try {
            $inventory=Get-DmGraphItems -Uri 'https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?$select=id,deviceName,azureADDeviceId,operatingSystem,serialNumber,userPrincipalName,lastSyncDateTime,complianceState&$top=100' -ProgressQueue $ProgressQueue
            $intune=@($inventory | Where-Object { [string](Get-DmValue $_ 'operatingSystem') -like 'Windows*' })
            $intuneState='OK';$intuneError=''
        }
        catch { $intuneState='Errore';$intuneError=$_.Exception.Message }
    }
    $byDevice=@{}
    foreach ($item in $intune) {
        $id=[string](Get-DmValue $item 'azureADDeviceId');$parsed=[guid]::Empty
        if (-not [guid]::TryParse($id,[ref]$parsed) -or $parsed -eq [guid]::Empty) { continue }
        $key=$parsed.ToString();if (-not $byDevice.ContainsKey($key)) { $byDevice[$key]=New-Object 'Collections.Generic.List[object]' };[void]$byDevice[$key].Add($item)
    }
    foreach ($row in $Rows) {
        $matches=@{};$ids=Get-DmValue $row 'DeviceIds' @()
        foreach ($id in $ids) { if ($byDevice.ContainsKey([string]$id)) { foreach ($item in $byDevice[[string]$id]) { $matches[[string]$item.id]=$item } } }
        $serials=@(Get-ExplorerSerials @($matches.Values | ForEach-Object { [pscustomobject]@{SerialNumber=(Get-DmValue $_ 'serialNumber')} }) | Sort-Object -Unique)
        $row | Add-Member -Force NoteProperty IntuneRecords @($matches.Values)
        $row | Add-Member -Force NoteProperty IntuneSerial ($serials -join ', ')
        $row | Add-Member -Force NoteProperty SerialConflict ($serials.Count -gt 1)
        $row | Add-Member -Force NoteProperty GlpiRecords @()
        $row | Add-Member -Force NoteProperty GlpiMatchBy $(if ($serials.Count) {'Seriale Intune'} else {'Nome esatto'})
        $row | Add-Member -Force NoteProperty GlpiState 'Non verificabile'
        $row | Add-Member -Force NoteProperty GlpiError ''
    }
    $glpi=Get-DmValue $Config.Settings 'Glpi';$glpiState='Disabilitato';$glpiError='Abilitare GLPI nelle Impostazioni.';$credentials=$null
    if ([bool](Get-DmValue $glpi 'Enabled' $false)) {
        try {
            $credentials=Read-ExplorerGlpiCredentials -Path $EnvPath -UseAppToken:([bool](Get-DmValue $glpi 'UseAppToken' $true))
            if ($null -eq $credentials) { throw 'Configurare i token GLPI nelle Impostazioni del wrapper.' }
            $arguments=@{BaseUri=[uri]$glpi.BaseUri;UserToken=$credentials.User;PageSize=[int](Get-DmValue $glpi 'PageSize' 100);TimeoutSeconds=[int](Get-DmValue $glpi 'TimeoutSeconds' 20)}
            if ([bool](Get-DmValue $glpi 'UseAppToken' $true)) { $arguments.AppToken=$credentials.App }
            $allSerials=@($Rows | Where-Object { $_.IntuneSerial -and -not $_.SerialConflict } | ForEach-Object { $_.IntuneSerial } | Sort-Object -Unique)
            $names=@($Rows | Where-Object { -not $_.IntuneSerial } | ForEach-Object { $_.Name } | Sort-Object -Unique)
            $serialRecords=@();$nameRecords=@()
            Send-DmProgress $ProgressQueue 'Ricerca GLPI per seriale Intune e nome esatto...'
            if ($allSerials.Count) { $serialRecords=@(Find-GlpiComputer @arguments -SerialNumber $allSerials) }
            if ($names.Count) { $nameRecords=@(Find-GlpiComputer @arguments -ExactName $names) }
            foreach ($row in $Rows) {
                if ($row.SerialConflict) { $row.GlpiState='Conflitto seriali';$row.GlpiError='Più seriali Intune per la stessa identita: verificare i dettagli.';continue }
                if ($row.IntuneSerial) { $row.GlpiRecords=@($serialRecords | Where-Object { ([string]$_.SerialNumber).Trim() -ieq $row.IntuneSerial }) }
                else { $row.GlpiRecords=@($nameRecords | Where-Object { $_.Name -ieq $row.Name }) }
                $row.GlpiState='Assente';if ($row.GlpiRecords.Count -eq 1) { $row.GlpiState='Presente' } elseif ($row.GlpiRecords.Count -gt 1) { $row.GlpiState='Duplicati ('+$row.GlpiRecords.Count+')' }
            }
            $glpiState='OK';$glpiError=''
        }
        catch { $glpiState='Errore';$glpiError=$_.Exception.Message;foreach ($row in $Rows) { $row.GlpiRecords=@();$row.GlpiState='Non verificabile';$row.GlpiError=$glpiError } }
        finally { if ($null -ne $credentials) { $credentials.User.Dispose();if ($null -ne $credentials.App) { $credentials.App.Dispose() } } }
    }
    foreach ($row in $Rows) {
        $row | Add-Member -Force NoteProperty GlpiIds (@($row.GlpiRecords | ForEach-Object { $_.GlpiId }) -join ', ')
        $row | Add-Member -Force NoteProperty GlpiNames (@($row.GlpiRecords | ForEach-Object { $_.Name } | Sort-Object -Unique) -join ', ')
        $row | Add-Member -Force NoteProperty GlpiStatus (@($row.GlpiRecords | ForEach-Object { $_.State } | Sort-Object -Unique) -join ', ')
        $row | Add-Member -Force NoteProperty GlpiGroup (@($row.GlpiRecords | ForEach-Object { $_.GroupPath } | Sort-Object -Unique) -join ', ')
        $row | Add-Member -Force NoteProperty Censito $(if (@($row.GlpiRecords | Where-Object { $_.GroupVerified -and $_.GroupName -ieq 'CENSITO' }).Count) { 'Si' } else { '' })
    }
    [pscustomobject]@{IntuneState=$intuneState;IntuneError=$intuneError;GlpiState=$glpiState;GlpiError=$glpiError}
}

function ConvertTo-DmCsvValue {
    param($Value)
    $text=[string]$Value
    if ($text -match '^[\s]*[=+@-]|^[\t\r\n]') { return "'"+$text }
    return $text
}

function Get-DmAvailableGroups {
    param([string]$Prefix,$Access,$ProgressQueue)
    $context=Assert-DmSession $Access -ReadIds @('groups-read')
    $query='?$select=id,displayName,groupTypes,onPremisesSyncEnabled,securityEnabled,mailEnabled,isAssignableToRole&$top=999'
    if ($Prefix) { $query+='&$filter='+[uri]::EscapeDataString("startswith(displayName,'"+$Prefix.Replace("'","''")+"')") }
    $groups=@(Get-DmGraphItems -Uri ('https://graph.microsoft.com/v1.0/groups'+$query) -ProgressQueue $ProgressQueue)
    if ((Assert-DmSession $Access -ReadIds @('groups-read')) -cne $context) { throw 'Sessione cambiata durante la lettura dei gruppi.' }
    return @($groups | Sort-Object displayName,id)
}

function Read-DmHybridScriptDefaults {
    param([Parameter(Mandatory=$true)][string]$Path)
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    if ($errors.Count -or $null -eq $ast.ParamBlock) { throw 'Script non valido o senza parametri. Nessun codice e stato eseguito.' }
    $parameter=@($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'TargetOuRelativeDistinguishedNames' })
    if ($parameter.Count -ne 1 -or $null -eq $parameter[0].DefaultValue) { throw 'Parametro TargetOuRelativeDistinguishedNames non trovato nello script.' }
    try { $raw=$parameter[0].DefaultValue.SafeGetValue() }
    catch { throw 'Le OU devono essere valori costanti nello script; importazione interrotta senza eseguire codice.' }
    $ous=@($raw | ForEach-Object { ([string]$_).Trim().TrimEnd(',') } | Sort-Object -Unique)
    if (-not $ous.Count -or @($ous | Where-Object { -not $_ -or $_ -notmatch '^OU=' -or $_.Length -gt 4096 -or $_ -match '[\r\n\x00]' }).Count) { throw 'Elenco OU dello script non valido.' }
    $server='';$serverParameter=@($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'AdServer' })
    if ($serverParameter.Count -eq 1 -and $null -ne $serverParameter[0].DefaultValue) { try { $value=[string]$serverParameter[0].DefaultValue.SafeGetValue();if ($value -match '^[a-zA-Z0-9][a-zA-Z0-9.-]*$') { $server=$value } } catch { } }
    [pscustomobject]@{TargetOus=$ous;AdServer=$server}
}

Export-ModuleMember -Function Read-DmHybridScriptDefaults,Get-DmAvailableGroups,Get-DmValue,ConvertTo-DmId,Send-DmProgress,Test-DmPermission,Assert-DmSession,Read-DmSettings,Get-DmGraphItems,Get-DmEntraInventory,Add-DmInventory,ConvertTo-DmCsvValue
