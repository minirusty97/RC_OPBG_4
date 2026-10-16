#requires -version 5.1
<#
    Connettore di consultazione GLPI REST API V1.
    Base iniziale per Computer Explorer: verificare sul GLPI aziendale prima dell'integrazione.
    Gli stati vengono letti dal server; non ci sono ID di stato prefissati.
    Vengono effettuate solo richieste GET, inclusa apertura/chiusura della sessione.
#>
Set-StrictMode -Version 2.0

function Get-GlpiValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return ,$Object[$Name] }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    # Preserva gli array, anche con zero o un solo elemento.
    if ($null -ne $property) { return ,$property.Value }
    return $null
}

function ConvertTo-GlpiSearchRecords {
    param($Data, [string]$IdOption, [string]$NameOption)
    if ($null -eq $Data) { return }

    if ($Data -is [Array] -or $Data -is [System.Collections.IList]) {
        foreach ($row in $Data) {
            [pscustomobject]@{ Values = $row; IndexedId = $null }
        }
        return
    }

    # Alcune risposte / versioni restituiscono direttamente la singola riga.
    $isSingleRow = $false
    foreach ($key in @($IdOption, $NameOption, 'Computer.id', 'Computer.name', 'id', 'name')) {
        $value = Get-GlpiValue $Data $key
        if ($value -is [string] -or $value -is [ValueType]) {
            $isSingleRow = $true
            break
        }
    }
    if ($isSingleRow) {
        [pscustomobject]@{ Values = $Data; IndexedId = $null }
        return
    }

    # Mappa indicizzata per ID Computer. Conserva anche la chiave dell'oggetto JSON.
    if ($Data -is [System.Collections.IDictionary]) {
        foreach ($key in $Data.Keys) {
            [pscustomobject]@{ Values = $Data[$key]; IndexedId = [string]$key }
        }
    }
    else {
        foreach ($property in $Data.PSObject.Properties) {
            [pscustomobject]@{ Values = $property.Value; IndexedId = $property.Name }
        }
    }
}

function Resolve-GlpiComputerId {
    param($Row, [string]$IdOption, [string]$IndexedId)
    $resolved = 0
    foreach ($key in @($IdOption, 'Computer.id', 'id') | Select-Object -Unique) {
        $raw = Get-GlpiValue $Row $key
        if ($null -eq $raw) { continue }
        $candidate = 0
        if (-not [int]::TryParse([string]$raw, [ref]$candidate) -or $candidate -le 0) {
            throw "Valore ID Computer non valido nella colonna GLPI '$key'."
        }
        if ($resolved -gt 0 -and $candidate -ne $resolved) {
            throw "ID Computer discordanti nella risposta GLPI."
        }
        $resolved = $candidate
    }

    if (-not [string]::IsNullOrWhiteSpace($IndexedId)) {
        $index = 0
        if (-not [int]::TryParse($IndexedId, [ref]$index) -or $index -le 0) {
            throw "Indice Computer non valido nella risposta GLPI."
        }
        if ($resolved -gt 0 -and $index -ne $resolved) {
            throw "ID Computer diverso dall'indice della riga GLPI."
        }
        $resolved = $index
    }

    if ($resolved -le 0) {
        $columns = @()
        if ($Row -is [System.Collections.IDictionary]) { $columns = @($Row.Keys) }
        elseif ($null -ne $Row) { $columns = @($Row.PSObject.Properties.Name) }
        throw "ID Computer assente nella risposta GLPI. Colonna attesa: $IdOption; colonne ricevute: $($columns -join ', ')."
    }
    return $resolved
}

function ConvertFrom-GlpiSecureString {
    param([Security.SecureString]$Value)
    if ($null -eq $Value) { return $null }
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

function Invoke-GlpiRead {
    param([hashtable]$Session, [string]$Path, [hashtable]$Query = @{})
    # La lista di percorsi evita l'uso del connettore per modificare gli asset.
    if ($Path -notmatch '^(initSession|killSession|listSearchOptions/Computer|search/Computer|Computer/[1-9][0-9]*|State/[1-9][0-9]*|Group/[1-9][0-9]*)$') {
        throw "Endpoint GLPI non previsto dal connettore di consultazione."
    }
    $uri = $Session.BaseUri + '/' + $Path
    if ($Query.Count -gt 0) {
        $pairs = foreach ($key in $Query.Keys) {
            [Uri]::EscapeDataString([string]$key) + '=' + [Uri]::EscapeDataString([string]$Query[$key])
        }
        $uri += '?' + ($pairs -join '&')
    }
    Invoke-RestMethod -Method GET -Uri $uri -Headers $Session.Headers `
        -ContentType 'application/json' -TimeoutSec $Session.TimeoutSeconds -ErrorAction Stop
}

function Find-GlpiComputer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Uri]$BaseUri,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$NameFragment,
        [Parameter(Mandatory = $true)][Security.SecureString]$UserToken,
        [Security.SecureString]$AppToken,
        [ValidateRange(1, 500)][int]$PageSize = 100,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 20
    )

    if (-not $BaseUri.IsAbsoluteUri -or $BaseUri.Scheme -notin @('http', 'https') -or
        -not [string]::IsNullOrWhiteSpace($BaseUri.UserInfo) -or
        -not [string]::IsNullOrWhiteSpace($BaseUri.Query)) {
        throw "Specificare l'URL completo di apirest.php, senza credenziali o query string."
    }
    if ($BaseUri.AbsolutePath.TrimEnd('/') -notmatch '/apirest\.php$') {
        throw "L'URL GLPI deve terminare con /apirest.php."
    }
    $fragment = $NameFragment.Trim()
    if ([string]::IsNullOrWhiteSpace($fragment)) { throw "Inserire una parte del nome macchina." }
    if ($UserToken.Length -eq 0) { throw "User token GLPI vuoto." }

    $session = @{
        BaseUri = $BaseUri.AbsoluteUri.TrimEnd('/')
        TimeoutSeconds = $TimeoutSeconds
        Headers = @{ Accept = 'application/json' }
    }
    $sessionOpened = $false
    $stateCache = @{}
    $groupCache = @{}
    $results = @{}

    try {
        if ($null -ne $AppToken -and $AppToken.Length -gt 0) {
            $session.Headers['App-Token'] = ConvertFrom-GlpiSecureString $AppToken
        }
        $session.Headers['Authorization'] = 'user_token ' + (ConvertFrom-GlpiSecureString $UserToken)
        try { $login = Invoke-GlpiRead -Session $session -Path 'initSession' }
        finally { $session.Headers.Remove('Authorization') }
        $token = Get-GlpiValue $login 'session_token'
        if ([string]::IsNullOrWhiteSpace($token)) { throw "GLPI non ha restituito una sessione valida." }
        $session.Headers['Session-Token'] = $token
        $token = $null
        $sessionOpened = $true

        # Identifica le colonne tramite tabella/campo; non assume numeri fissi.
        $options = Invoke-GlpiRead -Session $session -Path 'listSearchOptions/Computer'
        $nameOption = $null
        $idOption = $null
        foreach ($property in $options.PSObject.Properties) {
            if ((Get-GlpiValue $property.Value 'table') -eq 'glpi_computers') {
                $field = Get-GlpiValue $property.Value 'field'
                if ($field -eq 'name') { $nameOption = $property.Name }
                if ($field -eq 'id') { $idOption = $property.Name }
            }
        }
        if ($null -eq $nameOption -or $null -eq $idOption) {
            throw "Campi Nome e ID non identificati nelle opzioni di ricerca GLPI Computer."
        }

        $offset = 0
        do {
            $query = @{
                'criteria[0][field]' = $nameOption
                'criteria[0][searchtype]' = 'contains'
                'criteria[0][value]' = $fragment
                'forcedisplay[0]' = $idOption
                'forcedisplay[1]' = $nameOption
                # 0 / 1 evitano che PHP interpreti la stringa 'false' come true.
                'withindexes' = '1'
                'giveItems' = '0'
                'uid_cols' = '0'
                'is_deleted' = '0'
                'range' = "$offset-$($offset + $PageSize - 1)"
            }
            $page = Invoke-GlpiRead -Session $session -Path 'search/Computer' -Query $query
            $rawTotal = Get-GlpiValue $page 'totalcount'
            $total = 0
            if (-not [int]::TryParse([string]$rawTotal, [ref]$total) -or $total -lt 0) {
                throw "Risposta di ricerca GLPI non valida: conteggio totale mancante."
            }
            $data = Get-GlpiValue $page 'data'
            $records = @(ConvertTo-GlpiSearchRecords -Data $data -IdOption $idOption -NameOption $nameOption)
            if ($records.Count -eq 0 -and $offset -lt $total) {
                throw "Paginazione GLPI incompleta: risultati ancora attesi dal server."
            }

            foreach ($record in $records) {
                $row = $record.Values
                $id = Resolve-GlpiComputerId -Row $row -IdOption $idOption -IndexedId $record.IndexedId
                if ($results.ContainsKey($id)) { continue }
                $computer = Invoke-GlpiRead -Session $session -Path "Computer/$id"
                if ((Get-GlpiValue $computer 'id') -ne $id) { throw "Risposta Computer GLPI non valida." }
                $name = [string](Get-GlpiValue $computer 'name')
                if ($name.IndexOf($fragment, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }

                $stateId = [int](Get-GlpiValue $computer 'states_id')
                $stateName = 'Nessuno stato'
                if ($stateId -gt 0) {
                    if (-not $stateCache.ContainsKey($stateId)) {
                        $state = Invoke-GlpiRead -Session $session -Path "State/$stateId"
                        $label = [string](Get-GlpiValue $state 'completename')
                        if ([string]::IsNullOrWhiteSpace($label)) { $label = [string](Get-GlpiValue $state 'name') }
                        if ([string]::IsNullOrWhiteSpace($label)) { throw "Nome dello stato GLPI $stateId non leggibile." }
                        $stateCache[$stateId] = $label
                    }
                    $stateName = $stateCache[$stateId]
                }
                # "Gruppo" assegnatario (groups_id), non il gruppo tecnico (groups_id_tech).
                $groupId=0; $groupName=''; $groupPath=''; $groupError=$null
                $groupVerified=$false
                $rawGroup=Get-GlpiValue $computer 'groups_id'
                if ($null -ne $rawGroup -and [int]::TryParse([string]$rawGroup,[ref]$groupId) -and $groupId -ge 0) {
                    $groupVerified=$true
                    if ($groupId -gt 0) {
                        if (-not $groupCache.ContainsKey($groupId)) {
                            try {
                                $assignedGroup=Invoke-GlpiRead -Session $session -Path "Group/$groupId"
                                $label=[string](Get-GlpiValue $assignedGroup 'name')
                                if ((Get-GlpiValue $assignedGroup 'id') -ne $groupId -or [string]::IsNullOrWhiteSpace($label)) { throw 'Risposta Gruppo GLPI non valida.' }
                                $groupCache[$groupId]=@{Name=$label;Path=[string](Get-GlpiValue $assignedGroup 'completename');Error=$null}
                            }
                            catch { $groupCache[$groupId]=@{Name='';Path='';Error=$_.Exception.Message} }
                        }
                        $groupName=$groupCache[$groupId].Name; $groupPath=$groupCache[$groupId].Path
                        $groupError=$groupCache[$groupId].Error; $groupVerified=$null -eq $groupError
                    }
                }
                else { $groupError='Campo Gruppo GLPI assente o non valido.' }
                $results[$id] = [pscustomobject]@{
                    Source = 'GLPI'
                    Exists = $true
                    GlpiId = $id
                    Name = $name
                    GroupId = $groupId
                    GroupName = $groupName
                    GroupPath = $groupPath
                    GroupVerified = $groupVerified
                    GroupError = $groupError
                    StateId = $stateId
                    State = $stateName
                    SerialNumber = Get-GlpiValue $computer 'serial'
                    InventoryNumber = Get-GlpiValue $computer 'otherserial'
                    EntityId = Get-GlpiValue $computer 'entities_id'
                    IsDeleted = Get-GlpiValue $computer 'is_deleted'
                    LastModified = Get-GlpiValue $computer 'date_mod'
                    LastInventory = Get-GlpiValue $computer 'last_inventory_update'
                    Error = $null
                }
            }
            $offset += $records.Count
        } while ($offset -lt $total)
    }
    finally {
        if ($sessionOpened) {
            try { Invoke-GlpiRead -Session $session -Path 'killSession' | Out-Null }
            catch { Write-Warning "Chiusura della sessione GLPI non confermata dal server." }
        }
        $session.Headers.Clear()
    }

    # I risultati vengono emessi soltanto dopo aver completato tutte le pagine.
    # Un errore va rappresentato come Non verificabile, mai come Assente.
    return @($results.Values | Sort-Object -Property @('Name', 'GlpiId'))
}

Export-ModuleMember -Function Find-GlpiComputer
