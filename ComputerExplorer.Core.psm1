#requires -version 5.1
Set-StrictMode -Version 2.0
$script:CloudCache = @{}

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
    if ($minimum -lt 1 -or $minimum -gt 255) { throw 'Search.MinimumCharacters deve essere compreso fra 1 e 255.' }
    if ($cacheMinutes -lt 0 -or $cacheMinutes -gt 60) { throw 'Search.CloudCacheMinutes deve essere compreso fra 0 e 60.' }
    [pscustomobject]@{ Settings = $config; MinimumCharacters = $minimum; CloudCacheMinutes = $cacheMinutes }
}

function Connect-ExplorerGraph {
    [CmdletBinding()]
    param([string[]]$Sources)
    try { Import-Module Microsoft.Graph.Authentication -ErrorAction Stop }
    catch { throw ('Modulo Microsoft.Graph.Authentication non caricabile. Verificare il modulo nella stessa versione di PowerShell usata per avviare la console. Dettaglio: ' + $_.Exception.Message) }
    $context = Get-MgContext -ErrorAction SilentlyContinue
    if ($null -ne $context -and (Get-ExplorerValue $context 'Environment' 'Global') -ne 'Global') {
        throw 'Questa console usa graph.microsoft.com. La sessione Graph corrente appartiene a un cloud diverso.'
    }
    # Una sessione applicativa già configurata viene riutilizzata; i diritti effettivi
    # vengono verificati dalle API. Non avviare un login delegato al suo posto.
    if ($null -ne $context -and (Get-ExplorerValue $context 'AuthType') -eq 'AppOnly') { return }
    $scopes = Get-ExplorerValue $context 'Scopes' @()
    $required = New-Object 'System.Collections.Generic.List[string]'
    if ($Sources -contains 'Entra' -and @($scopes | Where-Object {
        $_ -in @('Device.Read.All', 'Device.ReadWrite.All', 'Directory.Read.All', 'Directory.ReadWrite.All', 'Directory.AccessAsUser.All')
    }).Count -eq 0) { [void]$required.Add('Directory.AccessAsUser.All') }
    if ($Sources -contains 'Intune' -and @($scopes | Where-Object {
        $_ -in @('DeviceManagementManagedDevices.Read.All', 'DeviceManagementManagedDevices.ReadWrite.All')
    }).Count -eq 0) { [void]$required.Add('DeviceManagementManagedDevices.ReadWrite.All') }
    if ($null -eq $context -or $required.Count -gt 0) {
        # Mantiene gli ambiti già autorizzati dall'utente nel tool di rimozione.
        $loginScopes = @(@($scopes) + @($required.ToArray()) | Sort-Object -Unique)
        $arguments = @{ Scopes = $loginScopes; ContextScope = 'Process'; NoWelcome = $true; ErrorAction = 'Stop' }
        if ($null -ne $context) {
            foreach ($key in @('TenantId', 'ClientId')) {
                $value = [string](Get-ExplorerValue $context $key)
                if (-not [string]::IsNullOrWhiteSpace($value)) { $arguments[$key] = $value }
            }
        }
        Connect-MgGraph @arguments | Out-Null
    }
}

function Get-ExplorerGraphCollection {
    param([string]$Uri, [string]$ResourcePath)
    $visited = @{}
    $records = @{}
    $next = $Uri
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
        [switch]$ForceRefresh
    )
    $context = Get-MgContext -ErrorAction Stop
    if ($null -eq $context) { throw 'Sessione Graph assente.' }
    $parts = @('TenantId', 'ClientId', 'Account', 'AuthType', 'Environment') | ForEach-Object { [string](Get-ExplorerValue $context $_) }
    $contextScopes = Get-ExplorerValue $context 'Scopes' @()
    $key = (@($parts) + @(($contextScopes | Sort-Object) -join ',') + @($Source)) -join '|'
    $now = [datetimeoffset]::UtcNow
    if (-not $ForceRefresh -and $CacheMinutes -gt 0 -and $script:CloudCache.ContainsKey($key)) {
        $cached = $script:CloudCache[$key]
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
        $raw = @(Get-ExplorerGraphCollection -Uri $uri -ResourcePath $path)
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
        $script:CloudCache[$key] = $complete
        return $complete
    }
    catch {
        $script:CloudCache.Remove($key)
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
        if ($Sources.AD.State -in @('Esclusa', 'In attesa')) { $adText = '?' }
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
        $serials = @(@($intune) + @($glpi) | ForEach-Object { [string](Get-ExplorerValue $_ 'SerialNumber') } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim().ToUpperInvariant() } | Sort-Object -Unique)
        if ($serials.Count -gt 1) { [void]$notes.Add('Seriali diversi: verificare associazione') }
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
        try {
            $ad = & (Join-Path $PSScriptRoot 'Test-AdLookup.ps1') -NameFragment $fragment -ConfigPath $ConfigPath -PassThru -ErrorAction Stop
            $sources.AD.Records = @($ad.Computers); $sources.AD.DcSources = @($ad.Sources); $sources.AD.CheckedAtUtc = $ad.CheckedAtUtc
            $errors = @($ad.Sources | Where-Object { -not $_.Verificato } | ForEach-Object { "$($_.DomainController): $($_.Errore)" })
            $sources.AD.State = 'OK'
            if ($errors.Count -gt 0) { $sources.AD.State = 'Errore'; $sources.AD.Error = $errors -join ' | ' }
        }
        catch { $sources.AD.State = 'Errore'; $sources.AD.Error = $_.Exception.Message }
    }
    $cloudSources = @($EnabledSources | Where-Object { $_ -in @('Entra', 'Intune') })
    Send-ExplorerUpdate $sources $controllers 'Graph: verifica sessione e accesso. Se richiesto, completare il login nel browser.' $ProgressQueue
    $graphError = $null
    if ($cloudSources.Count -gt 0) {
        try { Connect-ExplorerGraph -Sources $cloudSources }
        catch { $graphError = $_.Exception.Message }
    }
    foreach ($name in $cloudSources) {
        Send-ExplorerUpdate $sources $controllers "Ricerca ${name}: lettura delle pagine o della cache..." $ProgressQueue
        try {
            if ($null -ne $graphError) { throw $graphError }
            $inventory = Get-ExplorerCloudInventory -Source $name -CacheMinutes $config.CloudCacheMinutes -ForceRefresh:$ForceCloudRefresh
            $sources[$name].Records = @($inventory.Records | Where-Object { $_.Name.IndexOf($fragment, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
            $sources[$name].CheckedAtUtc = $inventory.CheckedAtUtc; $sources[$name].FromCache = $inventory.FromCache; $sources[$name].State = 'OK'
        }
        catch { $sources[$name].State = 'Errore'; $sources[$name].Error = $_.Exception.Message }
    }
    Send-ExplorerUpdate $sources $controllers 'Ricerca GLPI: computer, stati e inventario...' $ProgressQueue
    if ($EnabledSources -contains 'GLPI') {
        try {
            $glpi = Get-ExplorerValue $config.Settings 'Glpi'
            if (-not [bool](Get-ExplorerValue $glpi 'Enabled' $false)) {
                $sources.GLPI.State = 'Esclusa'; $sources.GLPI.Error = 'GLPI disabilitato nella configurazione locale.'
            }
            else {
                Import-Module (Join-Path $PSScriptRoot 'GLPI.Inventory.psm1') -ErrorAction Stop
                $query = @{ BaseUri = [string](Get-ExplorerValue $glpi 'BaseUri'); NameFragment = $fragment; UserToken = $GlpiUserToken
                    PageSize = [int](Get-ExplorerValue $glpi 'PageSize' 100); TimeoutSeconds = [int](Get-ExplorerValue $glpi 'TimeoutSeconds' 20); ErrorAction = 'Stop' }
                if ([bool](Get-ExplorerValue $glpi 'UseAppToken' $true)) {
                    if ($null -eq $GlpiAppToken -or $GlpiAppToken.Length -eq 0) { throw 'App token GLPI mancante.' }
                    $query.AppToken = $GlpiAppToken
                }
                $sources.GLPI.Records = @(Find-GlpiComputer @query)
                $sources.GLPI.CheckedAtUtc = [datetimeoffset]::UtcNow; $sources.GLPI.State = 'OK'
            }
        }
        catch { $sources.GLPI.State = 'Errore'; $sources.GLPI.Error = $_.Exception.Message }
    }
    Send-ExplorerUpdate $sources $controllers 'Ricerca completata.' $ProgressQueue -Complete
}

Export-ModuleMember -Function Read-ExplorerConfiguration, Invoke-ComputerExplorerSearch, Merge-ExplorerResults, Format-ExplorerDate
