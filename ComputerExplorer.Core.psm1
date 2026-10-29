#requires -version 5.1
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'Glpi.Credentials.ps1')
. (Join-Path $PSScriptRoot 'Graph.Authentication.ps1')
$script:CloudCache = [hashtable]::Synchronized(@{})

function Get-ExplorerValue {
    param($Object, [string]$Name, $Default = $null)
    if ($null -ne $Object) {
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) { return ,$Object[$Name] }
        }
        else {
            $property = $Object.PSObject.Properties[$Name]
            if ($null -ne $property) { return ,$property.Value }
        }
    }
    return ,$Default
}

function Read-ExplorerConfiguration {
    param([Parameter(Mandatory = $true)][string]$ConfigPath)
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Configurazione assente: $ConfigPath. Copiare il modello in computer-explorer.config.local.json e configurare GLPI."
    }
    $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $search = Get-ExplorerValue $config 'Search'
    $minimum = [int](Get-ExplorerValue $search 'MinimumCharacters' 2)
    $cacheMinutes = [int](Get-ExplorerValue $search 'CloudCacheMinutes' 5)
    $cloudTimeout = [int](Get-ExplorerValue $search 'CloudReadTimeoutSeconds' 90)
    if ($cloudTimeout -lt 1 -or $cloudTimeout -gt 600) { throw 'Search.CloudReadTimeoutSeconds deve essere compreso fra 1 e 600.' }
    if ($minimum -lt 1 -or $minimum -gt 255) { throw 'Search.MinimumCharacters deve essere compreso fra 1 e 255.' }
    if ($cacheMinutes -lt 0 -or $cacheMinutes -gt 60) { throw 'Search.CloudCacheMinutes deve essere compreso fra 0 e 60.' }
    $graph=ConvertTo-ExplorerGraphAuthentication (Get-ExplorerValue $config 'Graph')
    [pscustomobject]@{ GraphAuthentication=$graph; Settings = $config; MinimumCharacters = $minimum; CloudCacheMinutes = $cacheMinutes; CloudReadTimeoutSeconds = $cloudTimeout }
}

function Get-ExplorerGraphCollection {
    param([string]$Uri, [string]$ResourcePath, $ProgressQueue, [string]$Source)
    $visited = @{}
    $records = @{}
    $next = $Uri
    $pageNumber = 0
    while (-not [string]::IsNullOrWhiteSpace($next)) {
        $parsed = $null
        if (-not [Uri]::TryCreate($next, [UriKind]::Absolute, [ref]$parsed) -or
            $parsed.Scheme -ne 'https' -or $parsed.Host -ne 'graph.microsoft.com' -or
            $parsed.Port -ne 443 -or $parsed.AbsolutePath -ne $ResourcePath -or
            $parsed.UserInfo.Length -gt 0 -or $parsed.Fragment.Length -gt 0) {
            throw 'Link di paginazione Graph non valido.'
        }
        if ($visited.ContainsKey($next)) { throw 'Graph ha ripetuto una pagina: raccolta incompleta.' }
        $visited[$next] = $true
        $pageNumber++
        if ($null -ne $ProgressQueue) {
            $ProgressQueue.Enqueue([pscustomobject]@{Source=$Source; Progress=('Pagina {0}, {1} record letti' -f $pageNumber,$records.Count)})
        }
        $page = Invoke-MgGraphRequest -Method GET -Uri $next -OutputType PSObject -ErrorAction Stop
        $values = Get-ExplorerValue $page 'value'
        if ($null -eq $values -or -not ($values -is [Array] -or $values -is [System.Collections.IList])) {
            throw 'Risposta Graph non valida: raccolta value assente.'
        }
        foreach ($record in $values) {
            $id = [guid]::Empty
            if (-not [guid]::TryParse([string](Get-ExplorerValue $record 'id'), [ref]$id) -or $id -eq [guid]::Empty) {
                throw 'Risposta Graph con ID non valido.'
            }
            $key = $id.ToString()
            if ($records.ContainsKey($key)) {
                foreach ($field in @('displayName', 'deviceName')) {
                    if ([string](Get-ExplorerValue $records[$key] $field) -ne [string](Get-ExplorerValue $record $field)) {
                        throw 'Graph ha restituito nomi discordanti per lo stesso ID.'
                    }
                }
            }
            else { $records[$key] = $record }
        }
        $next = [string](Get-ExplorerValue $page '@odata.nextLink')
    }
    # Nessuna pagina parziale viene emessa in caso di errore.
    return @($records.Values)
}

function Get-ExplorerCloudInventory {
    [CmdletBinding()]
    param(
        [ValidateSet('Entra', 'Intune')][string]$Source,
        [ValidateRange(0, 60)][int]$CacheMinutes = 5,
        [switch]$ForceRefresh, $ProgressQueue,
        [System.Collections.IDictionary]$Cache = $script:CloudCache
    )
    $context = Get-MgContext -ErrorAction Stop
    if ($null -eq $context) { throw 'Sessione Graph assente.' }
    $parts = @('TenantId', 'ClientId', 'Account', 'AuthType', 'Environment') | ForEach-Object { [string](Get-ExplorerValue $context $_) }
    $contextScopes = Get-ExplorerValue $context 'Scopes' @()
    $key = (@($parts) + @(($contextScopes | Sort-Object) -join ',') + @($Source)) -join '|'
    $now = [datetimeoffset]::UtcNow
    if (-not $ForceRefresh -and $CacheMinutes -gt 0 -and $Cache.Contains($key)) {
        $cached = $Cache[$key]
        if (($now - $cached.CheckedAtUtc).TotalMinutes -lt $CacheMinutes) {
            return [pscustomobject]@{ Records = $cached.Records; CheckedAtUtc = $cached.CheckedAtUtc; FromCache = $true }
        }
    }
    try {
        if ($Source -eq 'Entra') {
            $path = '/v1.0/devices'
            $uri = 'https://graph.microsoft.com/v1.0/devices?$select=id,deviceId,displayName,operatingSystem,trustType,accountEnabled,approximateLastSignInDateTime&$top=999'
        }
        else {
            $path = '/v1.0/deviceManagement/managedDevices'
            $uri = 'https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?$select=id,deviceName,azureADDeviceId,operatingSystem,serialNumber,userPrincipalName,lastSyncDateTime,complianceState&$top=100'
        }
        $raw = @(Get-ExplorerGraphCollection -Uri $uri -ResourcePath $path -ProgressQueue $ProgressQueue -Source $Source)
        $items = New-Object 'System.Collections.Generic.List[object]'
        foreach ($record in $raw) {
            if ($Source -eq 'Entra') {
                $name = ([string](Get-ExplorerValue $record 'displayName')).Trim()
                if ($name.Length -eq 0) { continue }
                [void]$items.Add([pscustomobject]@{
                    Name = $name; ObjectId = [string](Get-ExplorerValue $record 'id'); DeviceId = [string](Get-ExplorerValue $record 'deviceId')
                    OperatingSystem = Get-ExplorerValue $record 'operatingSystem'; TrustType = Get-ExplorerValue $record 'trustType'
                    AccountEnabled = Get-ExplorerValue $record 'accountEnabled'; LastSignIn = Get-ExplorerValue $record 'approximateLastSignInDateTime'
                })
            }
            else {
                if ([string](Get-ExplorerValue $record 'operatingSystem') -notlike 'Windows*') { continue }
                $name = ([string](Get-ExplorerValue $record 'deviceName')).Trim()
                if ($name.Length -eq 0) { continue }
                [void]$items.Add([pscustomobject]@{
                    Name = $name; ManagedDeviceId = [string](Get-ExplorerValue $record 'id'); AzureADDeviceId = [string](Get-ExplorerValue $record 'azureADDeviceId')
                    OperatingSystem = Get-ExplorerValue $record 'operatingSystem'; SerialNumber = Get-ExplorerValue $record 'serialNumber'
                    UserPrincipalName = Get-ExplorerValue $record 'userPrincipalName'; LastSync = Get-ExplorerValue $record 'lastSyncDateTime'
                    ComplianceState = Get-ExplorerValue $record 'complianceState'
                })
            }
        }
        $complete = [pscustomobject]@{ Records = $items.ToArray(); CheckedAtUtc = [datetimeoffset]::UtcNow; FromCache = $false }
        $Cache[$key] = $complete
        return $complete
    }
    catch {
        $Cache.Remove($key)
        throw
    }
}

function New-ExplorerSource {
    param([string]$Name, [string]$State = 'In attesa')
    [pscustomobject]@{ Name = $Name; State = $State; Records = @(); DcSources = @(); CheckedAtUtc = $null; FromCache = $false; Error = $null }
}

function Get-ExplorerPresence {
    param($Source, [int]$Count)
    if ($Source.State -ne 'OK') { return [pscustomobject]@{ Text = '?'; Color = 'Grigio' } }
    $color = 'Rosso'
    if ($Count -eq 1) { $color = 'Verde' }
    elseif ($Count -gt 1) { $color = 'Giallo' }
    [pscustomobject]@{ Text = [string]$Count; Color = $color }
}

function ConvertTo-ExplorerDate {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetimeoffset]) {
        if ($Value.Year -le 1601) { return $null }
        return $Value.LocalDateTime
    }
    if ($Value -is [datetime]) {
        if ($Value.Year -le 1601) { return $null }
        if ($Value.Kind -eq [DateTimeKind]::Utc) { return $Value.ToLocalTime() }
        return $Value
    }
    $text = ([string]$Value).Trim()
    if ($text.Length -eq 0) { return $null }
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $styles = [Globalization.DateTimeStyles]::None
    if ($text -match '(?i)(Z|[+-][0-9]{2}:[0-9]{2})$') {
        $date = [datetimeoffset]::MinValue
        if ([datetimeoffset]::TryParse($text, $culture, $styles, [ref]$date) -and $date.Year -gt 1601) { return $date.LocalDateTime }
    }
    else {
        # GLPI restituisce normalmente l'ora del server senza offset: conservarla.
        $date = [datetime]::MinValue
        $formats = [string[]]@('yyyy-MM-dd HH:mm:ss', 'yyyy-MM-dd HH:mm:ss.FFFFFFF', 'yyyy-MM-dd', 'yyyy-MM-ddTHH:mm:ss', 'yyyy-MM-ddTHH:mm:ss.FFFFFFF')
        if ([datetime]::TryParseExact($text, $formats, $culture, $styles, [ref]$date) -and $date.Year -gt 1601) { return $date }
    }
    return $null
}

function Get-ExplorerLatestDate {
    param([object[]]$Records, [string]$Property)
    $latest = $null
    foreach ($record in $Records) {
        $date = ConvertTo-ExplorerDate (Get-ExplorerValue $record $Property)
        if ($null -ne $date -and ($null -eq $latest -or $date -gt $latest)) { $latest = $date }
    }
    return $latest
}

function Format-ExplorerDate {
    param($Value)
    $date = ConvertTo-ExplorerDate $Value
    if ($null -eq $date) { return '—' }
    return $date.ToString('dd/MM/yyyy HH:mm')
}

function Get-ExplorerSerials {
    param([object[]]$Records)
    foreach ($record in $Records) {
        $serial=([string](Get-ExplorerValue $record 'SerialNumber')).Trim().ToUpperInvariant()
        # Do not treat firmware placeholders as hardware identities; keep real punctuation.
        if ($serial -and $serial -notmatch '^(UNKNOWN|NONE|N/?A|NOT (AVAILABLE|APPLICABLE|SPECIFIED)|DEFAULT STRING|SYSTEM SERIAL NUMBER|TO BE FILLED BY O\.?E\.?M\.?|0+|F+|-+)$') { $serial }
    }
}

function Merge-ExplorerResults {
    [CmdletBinding()]
    param([System.Collections.IDictionary]$Sources, [string[]]$DomainControllers)
    $groups = @{}
    foreach ($sourceName in @('AD', 'Entra', 'Intune', 'GLPI')) {
        foreach ($record in $Sources[$sourceName].Records) {
            $name = ([string](Get-ExplorerValue $record 'Name')).Trim()
            if ($name.Length -eq 0) { continue }
            $key = $name.ToUpperInvariant()
            if (-not $groups.ContainsKey($key)) {
                $groups[$key] = @{ Name = $name; AD = @(); Entra = @(); Intune = @(); GLPI = @() }
            }
            $groups[$key][$sourceName] += @($record)
        }
    }
    $verified = @($Sources.AD.DcSources | Where-Object { $_.Verificato }).Count
    foreach ($group in @($groups.Values | Sort-Object { $_.Name })) {
        $present = @($group.AD | ForEach-Object { $_.DomainController } | Sort-Object -Unique).Count
        $adColor = 'Grigio'
        if ($Sources.AD.State -eq 'OK' -and $verified -eq $DomainControllers.Count -and $DomainControllers.Count -gt 0) {
            $adColor = 'Rosso'
            if ($present -eq $DomainControllers.Count) { $adColor = 'Verde' }
            elseif ($present -gt 0) { $adColor = 'Giallo' }
        }
        $adText = '{0}/{1}' -f $present, $DomainControllers.Count
        if ($Sources.AD.State -eq 'Esclusa' -or ($Sources.AD.State -eq 'In attesa' -and $Sources.AD.DcSources.Count -eq 0)) { $adText = '?' }
        $paths = @($group.AD | ForEach-Object { $_.ParentPath } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        $guids = @($group.AD | ForEach-Object { $_.ObjectGUID } | Sort-Object -Unique)
        $entra = @( $group.Entra | Sort-Object ObjectId -Unique )
        $intune = @( $group.Intune | Sort-Object ManagedDeviceId -Unique )
        $glpi = @( $group.GLPI | Sort-Object GlpiId -Unique )
        $entraPresence = Get-ExplorerPresence $Sources.Entra $entra.Count
        $intunePresence = Get-ExplorerPresence $Sources.Intune $intune.Count
        $glpiPresence = Get-ExplorerPresence $Sources.GLPI $glpi.Count
        $notes = New-Object 'System.Collections.Generic.List[string]'
        if ($guids.Count -gt 1) { [void]$notes.Add('GUID AD diversi') }
        if ($paths.Count -gt 1) { [void]$notes.Add('Percorsi AD diversi') }
        $intuneSerials=@(Get-ExplorerSerials $intune | Sort-Object -Unique)
        $glpiSerials=@(Get-ExplorerSerials $glpi | Sort-Object -Unique)
        $serials=@(@($intuneSerials)+@($glpiSerials) | Sort-Object -Unique)
        $serialConflict=$serials.Count -gt 1
        $serialCheck='Non verificabile'; $serialColor='Grigio'
        if ($serialConflict) {
            $serialCheck='Conflitto'; $serialColor='Rosso'
            [void]$notes.Add('Seriali diversi: stesso nome, identita hardware non confermata. Eliminazione bloccata.')
        }
        elseif ($Sources.Intune.State -eq 'OK' -and $Sources.GLPI.State -eq 'OK' -and
            $intune.Count -gt 0 -and $glpi.Count -gt 0 -and $intuneSerials.Count -eq 1 -and $glpiSerials.Count -eq 1 -and
            @(Get-ExplorerSerials $intune).Count -eq $intune.Count -and @(Get-ExplorerSerials $glpi).Count -eq $glpi.Count) {
            $serialCheck='Coerente'; $serialColor='Verde'
        }
        $groupUnknown=@($glpi | Where-Object { (Get-ExplorerValue $_ 'GroupVerified') -ne $true }).Count -gt 0
        $censito=''; $censitoColor='Grigio'
        $censitoInfo='Nessuna scheda GLPI per questo nome.'
        if ($Sources.GLPI.State -ne 'OK') { $censito='?'; $censitoInfo='GLPI non verificato: '+$Sources.GLPI.State }
        elseif ($glpi.Count -gt 0) {
            $groupNames=@($glpi | ForEach-Object { [string](Get-ExplorerValue $_ 'GroupName') })
            $censitoInfo=(@($glpi | ForEach-Object { 'GLPI #'+$_.GlpiId+': '+[string](Get-ExplorerValue $_ 'GroupName')+' '+[string](Get-ExplorerValue $_ 'GroupError') }) -join ' | ')
            if ($groupUnknown -or $serialConflict) { $censito='?' }
            elseif (@($groupNames | Where-Object { $_.Trim() -ine 'CENSITO' }).Count -eq 0) { $censito='✓'; $censitoColor='Verde' }
            elseif (@($groupNames | Where-Object { $_.Trim() -ieq 'CENSITO' }).Count -gt 0) { $censito='?'; $censitoInfo+=' | Gruppi discordanti tra le schede.' }
            if ($groupUnknown) { [void]$notes.Add('Gruppo GLPI non verificabile') }
            if ($serialConflict) { $censitoInfo+=' | Associazione hardware in conflitto: censimento non confermato.' }
        }
        $deviceIds = @($entra | ForEach-Object { $_.DeviceId } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        foreach ($device in $intune) {
            $id = [string]$device.AzureADDeviceId
            if ($Sources.Entra.State -eq 'OK' -and -not [string]::IsNullOrWhiteSpace($id) -and
                $id -ne [guid]::Empty.ToString() -and $deviceIds -notcontains $id) {
                [void]$notes.Add('DeviceId Intune non presente nelle righe Entra dello stesso nome')
                break
            }
        }
        [pscustomobject]@{
            Name = $group.Name; AD = $adText; ADColor = $adColor; Verificati = ('{0}/{1}' -f $verified, $DomainControllers.Count)
            Entra = $entraPresence.Text; EntraColor = $entraPresence.Color; Intune = $intunePresence.Text; IntuneColor = $intunePresence.Color
            Censito=$censito; CensitoColor=$censitoColor; CensitoInfo=$censitoInfo
            IntuneSerial=($intuneSerials -join ' | '); GlpiSerial=($glpiSerials -join ' | ')
            SerialCheck=$serialCheck; SerialColor=$serialColor; SerialConflict=$serialConflict
            GLPI = $glpiPresence.Text; GLPIColor = $glpiPresence.Color
            ADLastModified = Get-ExplorerLatestDate -Records @($group.AD) -Property 'LastModified'
            EntraLastActivity = Get-ExplorerLatestDate -Records $entra -Property 'LastSignIn'
            IntuneLastCheckIn = Get-ExplorerLatestDate -Records $intune -Property 'LastSync'
            GlpiLastInventory = Get-ExplorerLatestDate -Records $glpi -Property 'LastInventory'
            StatoGLPI = (@($glpi | ForEach-Object { $_.State } | Sort-Object -Unique) -join ' | ')
            PercorsoAD = ($paths -join ' | '); Note = ($notes -join '; ')
            ADRecords = @($group.AD); EntraRecords = $entra; IntuneRecords = $intune; GlpiRecords = $glpi
        }
    }
}

function Send-ExplorerUpdate {
    param($Sources, [string[]]$Controllers, [string]$Message, $Queue, [switch]$Complete)
    $snapshot = [pscustomobject]@{
        Message = $Message; Complete = [bool]$Complete
        Rows = @(Merge-ExplorerResults -Sources $Sources -DomainControllers $Controllers)
        Sources = @($Sources.Values | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; State = $_.State; Count = $_.Records.Count; CheckedAtUtc = $_.CheckedAtUtc; FromCache = $_.FromCache; Error = $_.Error; DcSources = @($_.DcSources) }
        })
    }
    if ($null -ne $Queue) { $Queue.Enqueue($snapshot) }
    if ($Complete) { return $snapshot }
}

function Read-ExplorerSource {
    [CmdletBinding()]
    param(
        [ValidateSet('AD', 'Entra', 'Intune', 'GLPI')][string]$Source,
        [string]$NameFragment, [string]$ConfigPath, $Configuration,
        [string]$DomainController,
        [System.Collections.IDictionary]$CloudCache = $script:CloudCache,
        [Security.SecureString]$GlpiUserToken, [Security.SecureString]$GlpiAppToken,
        [switch]$ForceCloudRefresh, $ProgressQueue
    )
    $result = New-ExplorerSource $Source
    try {
        if ($null -eq $Configuration) { $Configuration = Read-ExplorerConfiguration $ConfigPath }
        if ($Source -eq 'AD') {
            $query = @{ NameFragment = $NameFragment; ConfigPath = $ConfigPath; PassThru = $true; ErrorAction = 'Stop' }
            if (-not [string]::IsNullOrWhiteSpace($DomainController)) { $query.DomainController = $DomainController }
            $ad = & (Join-Path $PSScriptRoot 'Test-AdLookup.ps1') @query
            $result.Records = @($ad.Computers); $result.DcSources = @($ad.Sources); $result.CheckedAtUtc = $ad.CheckedAtUtc
            $errors = @($ad.Sources | Where-Object { -not $_.Verificato } | ForEach-Object { "$($_.DomainController): $($_.Errore)" })
            $result.State = 'OK'
            if ($errors.Count -gt 0) { $result.State = 'Errore'; $result.Error = $errors -join ' | ' }
        }
        elseif ($Source -in @('Entra', 'Intune')) {
            # Il coordinatore autentica una sola volta prima di avviare i lettori.
            Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
            $inventory = Get-ExplorerCloudInventory -Source $Source -CacheMinutes $Configuration.CloudCacheMinutes -ForceRefresh:$ForceCloudRefresh -Cache $CloudCache -ProgressQueue $ProgressQueue
            $result.Records = @($inventory.Records | Where-Object { $_.Name.IndexOf($NameFragment, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
            $result.CheckedAtUtc = $inventory.CheckedAtUtc; $result.FromCache = $inventory.FromCache; $result.State = 'OK'
        }
        else {
            $glpi = Get-ExplorerValue $Configuration.Settings 'Glpi'
            if (-not [bool](Get-ExplorerValue $glpi 'Enabled' $false)) {
                $result.State = 'Esclusa'; $result.Error = 'GLPI disabilitato nella configurazione locale.'
            }
            else {
                Import-Module (Join-Path $PSScriptRoot 'GLPI.Inventory.psm1') -ErrorAction Stop
                $query = @{ BaseUri = [string](Get-ExplorerValue $glpi 'BaseUri'); NameFragment = $NameFragment; UserToken = $GlpiUserToken
                    PageSize = [int](Get-ExplorerValue $glpi 'PageSize' 100); TimeoutSeconds = [int](Get-ExplorerValue $glpi 'TimeoutSeconds' 20); ErrorAction = 'Stop' }
                if ([bool](Get-ExplorerValue $glpi 'UseAppToken' $true)) {
                    if ($null -eq $GlpiAppToken -or $GlpiAppToken.Length -eq 0) { throw 'App token GLPI mancante.' }
                    $query.AppToken = $GlpiAppToken
                }
                $result.Records = @(Find-GlpiComputer @query)
                $result.CheckedAtUtc = [datetimeoffset]::UtcNow; $result.State = 'OK'
            }
        }
    }
    catch {
        $result.State = 'Errore'; $result.Error = $_.Exception.Message
        if ($Source -eq 'AD' -and -not [string]::IsNullOrWhiteSpace($DomainController)) {
            $result.DcSources = @([pscustomobject]@{ DomainController = $DomainController; Stato = 'Errore'; Verificato = $false; Trovati = $null; Errore = $result.Error })
        }
    }
    return $result
}

function Invoke-ComputerExplorerSearch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$NameFragment,
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [ValidateSet('AD', 'Entra', 'Intune', 'GLPI')][string[]]$EnabledSources = @('AD', 'Entra', 'Intune', 'GLPI'),
        [Security.SecureString]$GlpiUserToken, [Security.SecureString]$GlpiAppToken,
        [switch]$ForceCloudRefresh, $ProgressQueue
    )
    $config = Read-ExplorerConfiguration $ConfigPath
    $fragment = $NameFragment.Trim()
    if ($fragment.Length -lt $config.MinimumCharacters) { throw "Inserire almeno $($config.MinimumCharacters) caratteri." }
    $configuredControllers = Get-ExplorerValue $config.Settings 'DomainControllers' @()
    $controllers = @($configuredControllers | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_.Length -gt 0 } | Sort-Object -Unique)
    $sources = [ordered]@{}
    foreach ($name in @('AD', 'Entra', 'Intune', 'GLPI')) {
        $state = 'Esclusa'
        if ($EnabledSources -contains $name) { $state = 'In attesa' }
        $sources[$name] = New-ExplorerSource $name $state
    }
    Send-ExplorerUpdate $sources $controllers 'Ricerca AD sui DC configurati...' $ProgressQueue
    if ($EnabledSources -contains 'AD') {
        $sources.AD = Read-ExplorerSource -Source AD -NameFragment $fragment -ConfigPath $ConfigPath -Configuration $config
    }
    $cloudSources = @($EnabledSources | Where-Object { $_ -in @('Entra', 'Intune') })
    Send-ExplorerUpdate $sources $controllers 'Graph: verifica sessione e accesso.' $ProgressQueue
    $graphError = $null
    if ($cloudSources.Count -gt 0) {
        try { Connect-ExplorerGraph -Sources $cloudSources -ProgressQueue $ProgressQueue -GraphAuthentication $config.GraphAuthentication }
        catch { $graphError = $_.Exception.Message }
    }
    foreach ($name in @('Entra', 'Intune', 'GLPI') | Where-Object { $EnabledSources -contains $_ }) {
        Send-ExplorerUpdate $sources $controllers ("Ricerca " + $name + '...') $ProgressQueue
        if ($name -in @('Entra', 'Intune') -and $null -ne $graphError) {
            $sources[$name].State = 'Errore'; $sources[$name].Error = $graphError
        }
        else {
            $sources[$name] = Read-ExplorerSource -Source $name -NameFragment $fragment -ConfigPath $ConfigPath -Configuration $config -GlpiUserToken $GlpiUserToken -GlpiAppToken $GlpiAppToken -ForceCloudRefresh:$ForceCloudRefresh
        }
    }
    Send-ExplorerUpdate $sources $controllers 'Ricerca completata.' $ProgressQueue -Complete
}

function Get-ExplorerCloudCache { return $script:CloudCache }

function Clear-ExplorerCloudCache { $script:CloudCache.Clear() }

Export-ModuleMember -Function New-ExplorerGraphOperationError, Initialize-ExplorerGraphSession, Get-ExplorerGraphPermissionStatus, Read-ExplorerSource, Get-ExplorerCloudCache, Connect-ExplorerGraph, Get-ExplorerGraphCollection, Clear-ExplorerCloudCache, Read-ExplorerConfiguration, Invoke-ComputerExplorerSearch, Merge-ExplorerResults, Format-ExplorerDate, Read-ExplorerGlpiCredentials, Save-ExplorerGlpiCredentials
