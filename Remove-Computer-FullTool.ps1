#requires -version 5.1

<#
    Tool: Rimozione computer da Active Directory, Microsoft Entra ID e Intune
    Funzioni:
    - Cerca il computer su più Domain Controller
    - Cerca tutte le occorrenze del dispositivo in Entra ID
    - Cerca le registrazioni Windows in Intune per nome esatto e DeviceId Entra
    - Elimina le registrazioni Intune prima degli oggetti AD / Entra ID
    - Elimina gli oggetti AD trovati
    - Elimina gli oggetti Entra ID trovati

    Note:
    - Richiede modulo ActiveDirectory
    - Richiede modulo Microsoft.Graph.Identity.DirectoryManagement
    - Per Entra ID richiede login interattivo Microsoft Graph
    - Mantiene Directory.AccessAsUser.All per Entra; per Intune richiede
      DeviceManagementManagedDevices.ReadWrite.All e un ruolo Intune adeguato
    - Intune usa Invoke-MgGraphRequest: nessun modulo DeviceManagement aggiuntivo
    - Elimina da Intune avvia anche il ritiro dei dispositivi Windows dalla gestione
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ============================================================
# CONFIGURAZIONE - MODIFICA QUI
# ============================================================

$ToolTitle = "Rimozione Computer AD / Entra ID / Intune"

$DomainControllers = @(
    "srvDC1.opbg.dom",
    "srvDC2.opbg.dom",
    "srvDCBA1.opbg.dom",
    "srvDCPA1.opbg.dom",
    "srvDCSM1.opbg.dom"
)

$GraphScopes = @(
    "Directory.AccessAsUser.All"
)

# Ambiti aggiuntivi richiesti soltanto quando Intune è selezionato.
$IntuneGraphScopes = @(
    "DeviceManagementManagedDevices.ReadWrite.All"
)

# Se $true, la ricerca Entra viene fatta automaticamente insieme alla ricerca AD
$EnableEntraSearchByDefault = $true

# Se $true, la cancellazione Entra viene proposta insieme alla cancellazione AD
$EnableEntraDeleteByDefault = $true
$EnableIntuneSearchByDefault = $true
$EnableIntuneDeleteByDefault = $true
$AutoInstallGraphModule = $true
# ============================================================
# VARIABILI GLOBALI
# ============================================================

$script:AdSearchResults = @()
$script:EntraSearchResults = @()
$script:IntuneSearchResults = @()
$script:IntuneSearchSucceeded = $false
$script:SearchComputerName = $null
$script:SearchSelection = $null
$script:GraphConnected = $false

# ============================================================
# FUNZIONI GENERALI
# ============================================================

function Show-Info {
    param(
        [string]$Message,
        [string]$Title = $ToolTitle
    )

    [System.Windows.Forms.MessageBox]::Show(
        $Message,
        $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
}

function Show-Warning {
    param(
        [string]$Message,
        [string]$Title = $ToolTitle
    )

    [System.Windows.Forms.MessageBox]::Show(
        $Message,
        $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    ) | Out-Null
}

function Show-ErrorBox {
    param(
        [string]$Message,
        [string]$Title = $ToolTitle
    )

    [System.Windows.Forms.MessageBox]::Show(
        $Message,
        $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}

function Ask-Confirm {
    param(
        [string]$Message,
        [string]$Title = $ToolTitle
    )

    $result = [System.Windows.Forms.MessageBox]::Show(
        $Message,
        $Title,
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button2
    )

    return ($result -eq [System.Windows.Forms.DialogResult]::Yes)
}

function Normalize-ComputerName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName
    )

    return $ComputerName.Trim().TrimEnd('$').ToUpper()
}

function Escape-LdapFilterValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    # Escape LDAP filter special chars: \ * ( ) NUL
    $escaped = $Value -replace '\\', '\5c'
    $escaped = $escaped -replace '\*', '\2a'
    $escaped = $escaped -replace '\(', '\28'
    $escaped = $escaped -replace '\)', '\29'
    $escaped = $escaped -replace "`0", '\00'

    return $escaped
}

function Escape-ODataString {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return $Value.Replace("'", "''")
}

function Set-Status {
    param(
        [string]$Text
    )

    $lblStatus.Text = $Text
    $form.Refresh()
}

function Clear-Grid {
    $grid.Rows.Clear()
    $script:AdSearchResults = @()
    $script:EntraSearchResults = @()
    $script:IntuneSearchResults = @()
    $script:IntuneSearchSucceeded = $false
    $script:SearchComputerName = $null
    $script:SearchSelection = $null
}

function Add-GridRow {
    param(
        [string]$Source,
        [string]$State,
        [string]$Name,
        [string]$Type,
        [string]$LastSeen,
        [string]$Identifier,
        [string]$Detail
    )

    [void]$grid.Rows.Add(
        $Source,
        $State,
        $Name,
        $Type,
        $LastSeen,
        $Identifier,
        $Detail
    )
}

# ============================================================
# ACTIVE DIRECTORY
# ============================================================

function Ensure-ADModule {
    if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
        throw "Modulo ActiveDirectory non trovato. Installare RSAT Active Directory Tools."
    }

    Import-Module ActiveDirectory -ErrorAction Stop
}

function Search-ComputerOnDomainControllers {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName
    )

    Ensure-ADModule

    $normalizedName = Normalize-ComputerName $ComputerName
    $samAccountName = "$normalizedName`$"
    $ldapSafeSam    = Escape-LdapFilterValue $samAccountName

    $results = foreach ($dc in $DomainControllers) {
        try {
            $found = Get-ADComputer `
                -Server $dc `
                -LDAPFilter "(sAMAccountName=$ldapSafeSam)" `
                -Properties @("DistinguishedName", "DNSHostName", "Enabled", "LastLogonDate", "ObjectGUID", "SID") `
                -ErrorAction Stop

            if ($found) {
                foreach ($computer in $found) {
                    [pscustomobject]@{
                        Source            = $dc
                        Exists            = $true
                        Name              = $computer.Name
                        SamAccountName    = $computer.SamAccountName
                        DistinguishedName = $computer.DistinguishedName
                        DNSHostName       = $computer.DNSHostName
                        Enabled           = $computer.Enabled
                        LastLogonDate     = $computer.LastLogonDate
                        ObjectGUID        = $computer.ObjectGUID
                        SID               = $computer.SID.Value
                        Error             = $null
                    }
                }
            }
            else {
                [pscustomobject]@{
                    Source            = $dc
                    Exists            = $false
                    Name              = $normalizedName
                    SamAccountName    = $samAccountName
                    DistinguishedName = $null
                    DNSHostName       = $null
                    Enabled           = $null
                    LastLogonDate     = $null
                    ObjectGUID        = $null
                    SID               = $null
                    Error             = $null
                }
            }
        }
        catch {
            [pscustomobject]@{
                Source            = $dc
                Exists            = $false
                Name              = $normalizedName
                SamAccountName    = $samAccountName
                DistinguishedName = $null
                DNSHostName       = $null
                Enabled           = $null
                LastLogonDate     = $null
                ObjectGUID        = $null
                SID               = $null
                Error             = $_.Exception.Message
            }
        }
    }

    return $results
}

function Remove-ComputerFromDomainControllers {
    param(
        [Parameter(Mandatory = $true)]
        [array]$AdResults
    )

    Ensure-ADModule

    $targets = $AdResults | Where-Object {
        $_.Exists -eq $true -and
        -not [string]::IsNullOrWhiteSpace($_.DistinguishedName)
    }

    $deleteResults = foreach ($target in $targets) {
        try {
            Remove-ADComputer `
                -Server $target.Source `
                -Identity $target.DistinguishedName `
                -Confirm:$false `
                -ErrorAction Stop

            [pscustomobject]@{
                Source     = $target.Source
                Name       = $target.Name
                Identifier = $target.DistinguishedName
                Deleted    = $true
                Error      = $null
            }
        }
        catch {
            [pscustomobject]@{
                Source     = $target.Source
                Name       = $target.Name
                Identifier = $target.DistinguishedName
                Deleted    = $false
                Error      = $_.Exception.Message
            }
        }
    }

    return $deleteResults
}

# ============================================================
# MICROSOFT ENTRA ID / GRAPH
# ============================================================
function Ensure-GraphModule {
    $moduleName = "Microsoft.Graph.Identity.DirectoryManagement"

    # 1. Controllo se il modulo è già disponibile
    $module = Get-Module -ListAvailable -Name $moduleName |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if ($module) {
        Import-Module $module.Path -Force -ErrorAction Stop
        return
    }

    # 2. Se non c'è, provo installazione automatica
    $installConfirm = [System.Windows.Forms.MessageBox]::Show(
        "Il modulo Microsoft Graph non è installato.`r`n`r`nVuoi installarlo automaticamente adesso?`r`n`r`nModulo: $moduleName",
        "Modulo Graph mancante",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )

    if ($installConfirm -ne [System.Windows.Forms.DialogResult]::Yes) {
        throw "Modulo $moduleName mancante. Installazione annullata dall'utente."
    }

    try {
        Set-Status "Installazione modulo Microsoft Graph in corso..."

        # Necessario su molte installazioni Windows PowerShell 5.1
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        # Verifica NuGet provider
        $nugetProvider = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue

        if (-not $nugetProvider) {
            Install-PackageProvider `
                -Name NuGet `
                -MinimumVersion 2.8.5.201 `
                -Force `
                -ErrorAction Stop | Out-Null
        }

        # Verifica repository PSGallery
        $psGallery = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue

        if (-not $psGallery) {
            Register-PSRepository -Default -ErrorAction Stop
            $psGallery = Get-PSRepository -Name PSGallery -ErrorAction Stop
        }

        # Evita prompt interattivi
        if ($psGallery.InstallationPolicy -ne "Trusted") {
            Set-PSRepository `
                -Name PSGallery `
                -InstallationPolicy Trusted `
                -ErrorAction Stop
        }

        # Se il tool gira come admin installo per tutti, altrimenti per l'utente corrente
        $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
        $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

        if ($isAdmin) {
            $scope = "AllUsers"
        }
        else {
            $scope = "CurrentUser"
        }

        Install-Module `
            -Name $moduleName `
            -Repository PSGallery `
            -Scope $scope `
            -Force `
            -AllowClobber `
            -Confirm:$false `
            -ErrorAction Stop

        # 3. Ricontrollo dopo installazione
        $module = Get-Module -ListAvailable -Name $moduleName |
            Sort-Object Version -Descending |
            Select-Object -First 1

        if (-not $module) {
            throw "Installazione completata, ma il modulo non risulta caricabile nel runtime corrente."
        }

        Import-Module $module.Path -Force -ErrorAction Stop

        Set-Status "Modulo Microsoft Graph installato e caricato correttamente."
    }
    catch {
        throw @"
Errore durante installazione/caricamento del modulo Microsoft Graph.

Modulo richiesto:
$moduleName

Errore:
$($_.Exception.Message)

Possibili cause:
- PC senza accesso Internet
- proxy aziendale
- PowerShell Gallery bloccata
- esecuzione senza privilegi sufficienti
- TLS/PowerShellGet non funzionante
"@
    }
}

function Ensure-GraphConnection {
    param(
        [switch]$IncludeIntune
    )

    Ensure-GraphModule

    $ctx = Get-MgContext -ErrorAction SilentlyContinue

    # Riutilizza il login esistente. L'ambito Intune è indipendente da quelli Directory.
    $requiredScopes = @($GraphScopes)
    if ($IncludeIntune) {
        $requiredScopes = @($requiredScopes + $IntuneGraphScopes | Select-Object -Unique)
    }

    $missingScope = $true

    if ($ctx -and $ctx.Scopes) {
        $missingScope = $false

        foreach ($scope in $requiredScopes) {
            if ($ctx.Scopes -notcontains $scope) {
                $missingScope = $true
                break
            }
        }
    }

    if (-not $ctx -or $missingScope) {
        Connect-MgGraph `
            -Scopes $requiredScopes `
            -ContextScope Process `
            -NoWelcome `
            -ErrorAction Stop | Out-Null
    }

    $script:GraphConnected = $true
}

function Search-EntraDevices {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName
    )

    Ensure-GraphConnection

    $normalizedName = Normalize-ComputerName $ComputerName
    $safeName       = Escape-ODataString $normalizedName

    $properties = @(
        "id",
        "deviceId",
        "displayName",
        "accountEnabled",
        "trustType",
        "profileType",
        "operatingSystem",
        "operatingSystemVersion",
        "registrationDateTime",
        "approximateLastSignInDateTime"
    )

    $devices = Get-MgDevice `
        -All `
        -Filter "displayName eq '$safeName'" `
        -Property $properties `
        -ErrorAction Stop

    # ulteriore filtro locale per evitare qualsiasi rischio su nomi simili
    $devices = $devices | Where-Object {
        $_.DisplayName -and
        ((Normalize-ComputerName $_.DisplayName) -eq $normalizedName)
    }

    foreach ($device in $devices) {
        [pscustomobject]@{
            Source                    = "Entra ID"
            Exists                    = $true
            DisplayName               = $device.DisplayName
            ObjectId                  = $device.Id
            DeviceId                  = $device.DeviceId
            AccountEnabled            = $device.AccountEnabled
            TrustType                 = $device.TrustType
            ProfileType               = $device.ProfileType
            OperatingSystem           = $device.OperatingSystem
            OperatingSystemVersion    = $device.OperatingSystemVersion
            RegistrationDateTime      = $device.RegistrationDateTime
            ApproximateLastSignIn     = $device.ApproximateLastSignInDateTime
            Error                     = $null
        }
    }
}

function Remove-EntraDevices {
    param(
        [Parameter(Mandatory = $true)]
        [array]$EntraResults
    )

    Ensure-GraphConnection

    $targets = $EntraResults | Where-Object {
        $_.Exists -eq $true -and
        -not [string]::IsNullOrWhiteSpace($_.ObjectId)
    }

    $deleteResults = foreach ($target in $targets) {
        try {
            # Nota: il parametro si chiama -DeviceId, ma qui va passato l'ID oggetto Graph, cioè $target.ObjectId
            Remove-MgDevice `
                -DeviceId $target.ObjectId `
                -Confirm:$false `
                -ErrorAction Stop

            [pscustomobject]@{
                Source     = "Entra ID"
                Name       = $target.DisplayName
                Identifier = $target.ObjectId
                Deleted    = $true
                Error      = $null
            }
        }
        catch {
            [pscustomobject]@{
                Source     = "Entra ID"
                Name       = $target.DisplayName
                Identifier = $target.ObjectId
                Deleted    = $false
                Error      = $_.Exception.Message
            }
        }
    }

    return $deleteResults
}

# ============================================================
# MICROSOFT INTUNE / GRAPH
# ============================================================

function Get-IntuneManagedDevicePages {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Filter
    )

    $properties = "id,deviceName,azureADDeviceId,serialNumber,userPrincipalName,operatingSystem,osVersion,lastSyncDateTime,enrolledDateTime,managementAgent,complianceState"
    $encodedFilter = [Uri]::EscapeDataString($Filter)
    $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=$encodedFilter&`$select=$properties"
    $devices = New-Object 'System.Collections.Generic.List[object]'

    do {
        $page = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject -ErrorAction Stop
        if ($null -eq $page -or $null -eq $page.PSObject.Properties["value"]) {
            throw "Risposta Intune non valida: impossibile verificare le registrazioni."
        }
        foreach ($device in @($page.value)) {
            if ($null -ne $device) {
                [void]$devices.Add($device)
            }
        }
        $uri = $page.'@odata.nextLink'
    } while (-not [string]::IsNullOrWhiteSpace($uri))

    # Non restituisce risultati parziali se una pagina fallisce.
    return $devices.ToArray()
}

function Search-IntuneDevices {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName,
        [array]$EntraResults = @()
    )

    Ensure-GraphConnection -IncludeIntune

    $normalizedName = Normalize-ComputerName $ComputerName
    $safeName = Escape-ODataString $normalizedName
    $queries = @(
        [pscustomobject]@{
            Filter = "deviceName eq '$safeName'"
            EntraDeviceId = $null
        }
    )

    # Una query per ID: evita i risultati incompleti dei filtri Intune con più OR.
    # Usa DeviceId Entra, non l'ObjectId. La ricerca per nome funziona anche senza Entra.
    $entraDeviceIds = @($EntraResults | Where-Object { $_.Exists -and -not $_.Error } |
        Select-Object -ExpandProperty DeviceId -Unique)
    foreach ($id in $entraDeviceIds) {
        $parsedId = [Guid]::Empty
        if ([Guid]::TryParse([string]$id, [ref]$parsedId) -and $parsedId -ne [Guid]::Empty) {
            $queries += [pscustomobject]@{
                Filter = "azureADDeviceId eq '$($parsedId.ToString())'"
                EntraDeviceId = $parsedId.ToString()
            }
        }
    }

    $matches = @{}
    foreach ($query in $queries) {
        $devices = @(Get-IntuneManagedDevicePages -Filter $query.Filter)
        foreach ($device in $devices) {
            # Tool per computer Windows. Delete su alcune piattaforme mobili esegue Wipe.
            if ($device.operatingSystem -ne "Windows" -or
                [string]::IsNullOrWhiteSpace($device.id)) {
                continue
            }

            # Verifica anche localmente il risultato dei filtri Graph.
            if ($query.EntraDeviceId) {
                if ($device.azureADDeviceId -ne $query.EntraDeviceId) { continue }
                $matchedBy = "DeviceId Entra"
            }
            else {
                if ([string]::IsNullOrWhiteSpace($device.deviceName) -or
                    (Normalize-ComputerName $device.deviceName) -ne $normalizedName) {
                    continue
                }
                $matchedBy = "Nome esatto"
            }

            # Una registrazione trovata sia per nome sia per ID compare una sola volta.
            $matches[[string]$device.id] = [pscustomobject]@{
                Source          = "Intune"
                Exists          = $true
                DeviceName      = $device.deviceName
                ManagedDeviceId = $device.id
                EntraDeviceId   = $device.azureADDeviceId
                SerialNumber    = $device.serialNumber
                UserPrincipalName = $device.userPrincipalName
                OperatingSystem = $device.operatingSystem
                OsVersion       = $device.osVersion
                LastSync        = $device.lastSyncDateTime
                Enrolled        = $device.enrolledDateTime
                ManagementAgent = $device.managementAgent
                ComplianceState = $device.complianceState
                MatchedBy       = $matchedBy
                Error           = $null
            }
        }
    }

    return @($matches.Values | Sort-Object -Property @("DeviceName", "ManagedDeviceId"))
}

function Remove-IntuneDevices {
    param(
        [Parameter(Mandatory = $true)]
        [array]$IntuneResults
    )

    Ensure-GraphConnection -IncludeIntune

    $targets = $IntuneResults | Where-Object {
        $_.Exists -eq $true -and -not $_.Error -and
        -not [string]::IsNullOrWhiteSpace($_.ManagedDeviceId)
    } | Sort-Object ManagedDeviceId -Unique

    foreach ($target in $targets) {
        try {
            if ($target.OperatingSystem -ne "Windows") {
                throw "Il tool elimina da Intune soltanto registrazioni Windows."
            }
            $parsedId = [Guid]::Empty
            if (-not [Guid]::TryParse([string]$target.ManagedDeviceId, [ref]$parsedId) -or
                $parsedId -eq [Guid]::Empty) {
                throw "ID dispositivo Intune non valido."
            }

            $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$($parsedId.ToString())"
            Invoke-MgGraphRequest -Method DELETE -Uri $uri -ErrorAction Stop | Out-Null

            [pscustomobject]@{
                Source = "Intune"
                Name = $target.DeviceName
                Identifier = $target.ManagedDeviceId
                Deleted = $true
                Error = $null
            }
        }
        catch {
            [pscustomobject]@{
                Source = "Intune"
                Name = $target.DeviceName
                Identifier = $target.ManagedDeviceId
                Deleted = $false
                Error = $_.Exception.Message
            }
        }
    }
}

# ============================================================
# GUI
# ============================================================

$form = New-Object System.Windows.Forms.Form
$form.Text = $ToolTitle
$form.Size = New-Object System.Drawing.Size(1120, 720)
$form.StartPosition = "CenterScreen"
$form.MinimumSize = New-Object System.Drawing.Size(1120, 600)

$fontDefault = New-Object System.Drawing.Font("Segoe UI", 9)
$fontTitle   = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$form.Font = $fontDefault

# Titolo
$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "Rimozione computer da Active Directory, Microsoft Entra ID e Intune"
$lblTitle.Font = $fontTitle
$lblTitle.AutoSize = $true
$lblTitle.Location = New-Object System.Drawing.Point(15, 15)
$form.Controls.Add($lblTitle)

# Label input
$lblComputer = New-Object System.Windows.Forms.Label
$lblComputer.Text = "Nome computer:"
$lblComputer.AutoSize = $true
$lblComputer.Location = New-Object System.Drawing.Point(18, 60)
$form.Controls.Add($lblComputer)

# Textbox input
$txtComputer = New-Object System.Windows.Forms.TextBox
$txtComputer.Location = New-Object System.Drawing.Point(120, 56)
$txtComputer.Size = New-Object System.Drawing.Size(220, 25)
$txtComputer.CharacterCasing = "Upper"
$form.Controls.Add($txtComputer)

# Checkbox AD
$chkAD = New-Object System.Windows.Forms.CheckBox
$chkAD.Text = "Active Directory / DC"
$chkAD.Checked = $true
$chkAD.AutoSize = $true
$chkAD.Location = New-Object System.Drawing.Point(360, 58)
$form.Controls.Add($chkAD)

# Checkbox Entra
$chkEntra = New-Object System.Windows.Forms.CheckBox
$chkEntra.Text = "Microsoft Entra ID"
$chkEntra.Checked = $EnableEntraSearchByDefault
$chkEntra.AutoSize = $true
$chkEntra.Location = New-Object System.Drawing.Point(525, 58)
$form.Controls.Add($chkEntra)

# Checkbox Intune
$chkIntune = New-Object System.Windows.Forms.CheckBox
$chkIntune.Text = "Microsoft Intune"
$chkIntune.Checked = $EnableIntuneSearchByDefault
$chkIntune.AutoSize = $true
$chkIntune.Location = New-Object System.Drawing.Point(680, 58)
$form.Controls.Add($chkIntune)

# Bottone Cerca
$btnSearch = New-Object System.Windows.Forms.Button
$btnSearch.Text = "Cerca"
$btnSearch.Location = New-Object System.Drawing.Point(810, 53)
$btnSearch.Size = New-Object System.Drawing.Size(75, 32)
$form.Controls.Add($btnSearch)

# Bottone Cancella
$btnDelete = New-Object System.Windows.Forms.Button
$btnDelete.Text = "Elimina trovati"
$btnDelete.Location = New-Object System.Drawing.Point(895, 53)
$btnDelete.Size = New-Object System.Drawing.Size(110, 32)
$btnDelete.Enabled = $false
$form.Controls.Add($btnDelete)

# Bottone Pulisci
$btnClear = New-Object System.Windows.Forms.Button
$btnClear.Text = "Pulisci"
$btnClear.Location = New-Object System.Drawing.Point(1015, 53)
$btnClear.Size = New-Object System.Drawing.Size(70, 32)
$form.Controls.Add($btnClear)

# Griglia
$grid = New-Object System.Windows.Forms.DataGridView
$grid.Location = New-Object System.Drawing.Point(15, 105)
$grid.Size = New-Object System.Drawing.Size(1070, 500)
$grid.Anchor = "Top, Bottom, Left, Right"
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.ReadOnly = $true
$grid.SelectionMode = "FullRowSelect"
$grid.MultiSelect = $false
$grid.AutoSizeColumnsMode = "Fill"
$grid.RowHeadersVisible = $false

[void]$grid.Columns.Add("Source", "Origine")
[void]$grid.Columns.Add("State", "Stato")
[void]$grid.Columns.Add("Name", "Nome")
[void]$grid.Columns.Add("Type", "Tipo / Trust")
[void]$grid.Columns.Add("LastSeen", "Ultimo accesso / sync")
[void]$grid.Columns.Add("Identifier", "DN / ObjectId / IntuneId")
[void]$grid.Columns.Add("Detail", "Dettaglio")

$grid.Columns["Source"].FillWeight = 90
$grid.Columns["State"].FillWeight = 80
$grid.Columns["Name"].FillWeight = 120
$grid.Columns["Type"].FillWeight = 110
$grid.Columns["LastSeen"].FillWeight = 120
$grid.Columns["Identifier"].FillWeight = 260
$grid.Columns["Detail"].FillWeight = 300

$form.Controls.Add($grid)

# Status
$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = "Pronto."
$lblStatus.AutoSize = $false
$lblStatus.Location = New-Object System.Drawing.Point(15, 620)
$lblStatus.Size = New-Object System.Drawing.Size(1070, 25)
$lblStatus.Anchor = "Bottom, Left, Right"
$form.Controls.Add($lblStatus)

# Info prerequisiti
$lblInfo = New-Object System.Windows.Forms.Label
$lblInfo.Text = "Prerequisiti: RSAT AD + Microsoft Graph. Intune: solo PC Windows; Elimina avvia anche il ritiro dalla gestione."
$lblInfo.AutoSize = $false
$lblInfo.Location = New-Object System.Drawing.Point(15, 648)
$lblInfo.Size = New-Object System.Drawing.Size(1070, 25)
$lblInfo.Anchor = "Bottom, Left, Right"
$form.Controls.Add($lblInfo)

# ============================================================
# EVENTI GUI
# ============================================================

$btnClear.Add_Click({
    Clear-Grid
    $btnDelete.Enabled = $false
    Set-Status "Pronto."
})

$btnSearch.Add_Click({
    $computerName = $txtComputer.Text

    if ([string]::IsNullOrWhiteSpace($computerName)) {
        Show-Warning "Inserire il nome del computer."
        return
    }

    if (-not ($chkAD.Checked -or $chkEntra.Checked -or $chkIntune.Checked)) {
        Show-Warning "Selezionare almeno un'origine in cui cercare."
        return
    }

    $computerName = Normalize-ComputerName $computerName

    Clear-Grid
    $btnDelete.Enabled = $false

    try {
        $btnSearch.Enabled = $false
        $btnDelete.Enabled = $false
        $btnClear.Enabled = $false
        $txtComputer.Enabled = $false
        $chkAD.Enabled = $false
        $chkEntra.Enabled = $false
        $chkIntune.Enabled = $false

        Set-Status "Ricerca in corso per $computerName..."

        if ($chkAD.Checked) {
            Set-Status "Ricerca Active Directory sui domain controller..."

            $script:AdSearchResults = @(Search-ComputerOnDomainControllers -ComputerName $computerName)

            foreach ($r in $script:AdSearchResults) {
                if ($r.Error) {
                    Add-GridRow `
                        -Source $r.Source `
                        -State "Errore" `
                        -Name $r.Name `
                        -Type "AD" `
                        -LastSeen "" `
                        -Identifier "" `
                        -Detail $r.Error
                }
                elseif ($r.Exists) {
                    Add-GridRow `
                        -Source $r.Source `
                        -State "Trovato" `
                        -Name $r.Name `
                        -Type "AD Computer" `
                        -LastSeen "$($r.LastLogonDate)" `
                        -Identifier $r.DistinguishedName `
                        -Detail "Enabled=$($r.Enabled); DNS=$($r.DNSHostName); GUID=$($r.ObjectGUID)"
                }
                else {
                    Add-GridRow `
                        -Source $r.Source `
                        -State "Non trovato" `
                        -Name $r.Name `
                        -Type "AD" `
                        -LastSeen "" `
                        -Identifier "" `
                        -Detail "Nessun oggetto computer trovato su questo DC"
                }
            }
        }

        # Un solo login cloud con gli ambiti delle origini selezionate.
        $graphConnectionError = $null
        if ($chkEntra.Checked -or $chkIntune.Checked) {
            try {
                Ensure-GraphConnection -IncludeIntune:($chkIntune.Checked)
            }
            catch {
                $graphConnectionError = $_.Exception.Message
            }
        }

        if ($chkEntra.Checked) {
            Set-Status "Ricerca Microsoft Entra ID..."

            try {
                if ($graphConnectionError) { throw $graphConnectionError }
                $script:EntraSearchResults = @(Search-EntraDevices -ComputerName $computerName)

                if ($script:EntraSearchResults.Count -gt 0) {
                    foreach ($r in $script:EntraSearchResults) {
                        Add-GridRow `
                            -Source "Entra ID" `
                            -State "Trovato" `
                            -Name $r.DisplayName `
                            -Type "$($r.TrustType) / $($r.ProfileType)" `
                            -LastSeen "$($r.ApproximateLastSignIn)" `
                            -Identifier $r.ObjectId `
                            -Detail "DeviceId=$($r.DeviceId); Enabled=$($r.AccountEnabled); OS=$($r.OperatingSystem) $($r.OperatingSystemVersion); Registered=$($r.RegistrationDateTime)"
                    }
                }
                else {
                    Add-GridRow `
                        -Source "Entra ID" `
                        -State "Non trovato" `
                        -Name $computerName `
                        -Type "Cloud device" `
                        -LastSeen "" `
                        -Identifier "" `
                        -Detail "Nessuna occorrenza Entra ID con displayName esatto"
                }
            }
            catch {
                Add-GridRow `
                    -Source "Entra ID" `
                    -State "Errore" `
                    -Name $computerName `
                    -Type "Cloud device" `
                    -LastSeen "" `
                    -Identifier "" `
                    -Detail $_.Exception.Message
            }
        }

        if ($chkIntune.Checked) {
            Set-Status "Ricerca registrazioni Windows in Microsoft Intune..."

            try {
                if ($graphConnectionError) { throw $graphConnectionError }
                $script:IntuneSearchResults = @(Search-IntuneDevices -ComputerName $computerName -EntraResults $script:EntraSearchResults)
                $script:IntuneSearchSucceeded = $true

                if ($script:IntuneSearchResults.Count -gt 0) {
                    foreach ($r in $script:IntuneSearchResults) {
                        Add-GridRow `
                            -Source "Intune" `
                            -State "Trovato" `
                            -Name $r.DeviceName `
                            -Type "$($r.OperatingSystem) / $($r.ManagementAgent)" `
                            -LastSeen "$($r.LastSync)" `
                            -Identifier $r.ManagedDeviceId `
                            -Detail "Seriale=$($r.SerialNumber); Utente=$($r.UserPrincipalName); EntraDeviceId=$($r.EntraDeviceId); Match=$($r.MatchedBy); Compliance=$($r.ComplianceState); Iscritto=$($r.Enrolled)"
                    }
                }
                else {
                    Add-GridRow `
                        -Source "Intune" `
                        -State "Non trovato" `
                        -Name $computerName `
                        -Type "Windows managed device" `
                        -LastSeen "" `
                        -Identifier "" `
                        -Detail "Nessuna registrazione Windows con nome esatto o DeviceId Entra corrispondente"
                }
            }
            catch {
                $script:IntuneSearchSucceeded = $false
                Add-GridRow `
                    -Source "Intune" `
                    -State "Errore" `
                    -Name $computerName `
                    -Type "Windows managed device" `
                    -LastSeen "" `
                    -Identifier "" `
                    -Detail $_.Exception.Message
            }
        }

        $script:SearchComputerName = $computerName
        $script:SearchSelection = "$($chkAD.Checked)|$($chkEntra.Checked)|$($chkIntune.Checked)"
        $adFound = @($script:AdSearchResults | Where-Object { $_.Exists -eq $true -and -not $_.Error }).Count
        $entraFound = @($script:EntraSearchResults | Where-Object { $_.Exists -eq $true -and -not $_.Error }).Count
        $intuneFound = @($script:IntuneSearchResults | Where-Object { $_.Exists -eq $true -and -not $_.Error }).Count

        if (($adFound + $entraFound + $intuneFound) -gt 0) {
            $btnDelete.Enabled = $true
        }

        if ($chkIntune.Checked -and $EnableIntuneDeleteByDefault -and -not $script:IntuneSearchSucceeded) {
            $btnDelete.Enabled = $false
            Set-Status "Ricerca Intune fallita. Eliminazione disabilitata: verificare l'errore e ripetere la ricerca."
        }
        else {
            Set-Status "Ricerca completata. AD: $adFound. Entra ID: $entraFound. Intune: $intuneFound."
        }
    }
    catch {
        Show-ErrorBox "Errore durante la ricerca:`r`n$($_.Exception.Message)"
        Set-Status "Errore durante la ricerca."
    }
    finally {
        $btnSearch.Enabled = $true
        $btnClear.Enabled = $true
        $txtComputer.Enabled = $true
        $chkAD.Enabled = $true
        $chkEntra.Enabled = $true
        $chkIntune.Enabled = $true
    }
})

$btnDelete.Add_Click({
    $computerName = $txtComputer.Text

    if ([string]::IsNullOrWhiteSpace($computerName)) {
        Show-Warning "Inserire il nome del computer."
        return
    }

    $computerName = Normalize-ComputerName $computerName

    $currentSelection = "$($chkAD.Checked)|$($chkEntra.Checked)|$($chkIntune.Checked)"
    if ($script:SearchComputerName -ne $computerName -or
        $script:SearchSelection -ne $currentSelection) {
        Show-Warning "Nome computer o origini modificati. Eseguire nuovamente Cerca prima di eliminare."
        return
    }

    if ($chkIntune.Checked -and $EnableIntuneDeleteByDefault -and -not $script:IntuneSearchSucceeded) {
        Show-ErrorBox "La ricerca Intune non è riuscita. Correggere l'errore e ripetere Cerca prima di eliminare."
        return
    }

    $adTargets = @(
        $script:AdSearchResults | Where-Object {
            $_.Exists -eq $true -and
            -not $_.Error -and
            -not [string]::IsNullOrWhiteSpace($_.DistinguishedName)
        }
    )

    $entraTargets = @(
        $script:EntraSearchResults | Where-Object {
            $_.Exists -eq $true -and
            -not $_.Error -and
            -not [string]::IsNullOrWhiteSpace($_.ObjectId)
        }
    )

    $intuneTargets = @(
        $script:IntuneSearchResults | Where-Object {
            $_.Exists -eq $true -and -not $_.Error -and
            -not [string]::IsNullOrWhiteSpace($_.ManagedDeviceId)
        }
    )

    $adDeleteCount = 0
    $entraDeleteCount = 0
    $intuneDeleteCount = 0
    if ($chkAD.Checked) { $adDeleteCount = $adTargets.Count }
    if ($chkEntra.Checked -and $EnableEntraDeleteByDefault) { $entraDeleteCount = $entraTargets.Count }
    if ($chkIntune.Checked -and $EnableIntuneDeleteByDefault) { $intuneDeleteCount = $intuneTargets.Count }

    if (($adDeleteCount + $entraDeleteCount + $intuneDeleteCount) -eq 0) {
        Show-Warning "Non ci sono oggetti trovati da eliminare."
        return
    }

    $confirmText = @"
Confermi l'eliminazione del computer $computerName?

Oggetti Active Directory da eliminare: $adDeleteCount
Oggetti Entra ID da eliminare: $entraDeleteCount
Registrazioni Intune da eliminare: $intuneDeleteCount

Verranno eliminate tutte le occorrenze trovate nelle origini selezionate.
"@

    if ($intuneDeleteCount -gt 0) {
        $confirmText += "`r`nIntune: Elimina avvia anche il ritiro dei PC Windows dalla gestione.`r`nOrdine: Intune, Active Directory, Entra ID.`r`n"
    }
    $confirmText += "`r`nL'operazione è distruttiva. Procedere?"

    if (-not (Ask-Confirm $confirmText)) {
        Set-Status "Eliminazione annullata dall'utente."
        return
    }

    try {
        $btnSearch.Enabled = $false
        $btnDelete.Enabled = $false
        $btnClear.Enabled = $false
        $txtComputer.Enabled = $false
        $chkAD.Enabled = $false
        $chkEntra.Enabled = $false
        $chkIntune.Enabled = $false

        Set-Status "Eliminazione in corso..."

        if ($intuneDeleteCount -gt 0) {
            Set-Status "Eliminazione registrazioni Microsoft Intune..."
            $intuneDeleteResults = @(Remove-IntuneDevices -IntuneResults $intuneTargets)

            foreach ($r in $intuneDeleteResults) {
                if ($r.Deleted) {
                    Add-GridRow `
                        -Source "Intune" `
                        -State "Eliminato" `
                        -Name $r.Name `
                        -Type "Windows managed device" `
                        -LastSeen "" `
                        -Identifier $r.Identifier `
                        -Detail "Eliminazione accettata da Intune; ritiro dalla gestione avviato"
                }
                else {
                    Add-GridRow `
                        -Source "Intune" `
                        -State "Errore eliminazione" `
                        -Name $r.Name `
                        -Type "Windows managed device" `
                        -LastSeen "" `
                        -Identifier $r.Identifier `
                        -Detail $r.Error
                }
            }

            if (@($intuneDeleteResults | Where-Object { -not $_.Deleted }).Count -gt 0 -or
                $intuneDeleteResults.Count -ne $intuneTargets.Count) {
                throw "Una o più registrazioni Intune non sono state eliminate. Eliminazione AD / Entra interrotta; verificare la griglia e ripetere Cerca."
            }
        }
        elseif ($chkIntune.Checked -and -not $EnableIntuneDeleteByDefault -and $intuneTargets.Count -gt 0) {
            Add-GridRow `
                -Source "Intune" `
                -State "Saltato" `
                -Name $computerName `
                -Type "Windows managed device" `
                -LastSeen "" `
                -Identifier "" `
                -Detail "Eliminazione Intune disabilitata da configurazione"
        }

        if ($chkAD.Checked -and $adTargets.Count -gt 0) {
            Set-Status "Eliminazione oggetti Active Directory..."

            $adDeleteResults = @(Remove-ComputerFromDomainControllers -AdResults $adTargets)

            foreach ($r in $adDeleteResults) {
                if ($r.Deleted) {
                    Add-GridRow `
                        -Source $r.Source `
                        -State "Eliminato" `
                        -Name $r.Name `
                        -Type "AD Computer" `
                        -LastSeen "" `
                        -Identifier $r.Identifier `
                        -Detail "Oggetto eliminato correttamente"
                }
                else {
                    Add-GridRow `
                        -Source $r.Source `
                        -State "Errore eliminazione" `
                        -Name $r.Name `
                        -Type "AD Computer" `
                        -LastSeen "" `
                        -Identifier $r.Identifier `
                        -Detail $r.Error
                }
            }
        }

        if ($chkEntra.Checked -and $EnableEntraDeleteByDefault -and $entraTargets.Count -gt 0) {
            Set-Status "Eliminazione oggetti Microsoft Entra ID..."

            $entraDeleteResults = @(Remove-EntraDevices -EntraResults $entraTargets)

            foreach ($r in $entraDeleteResults) {
                if ($r.Deleted) {
                    Add-GridRow `
                        -Source "Entra ID" `
                        -State "Eliminato" `
                        -Name $r.Name `
                        -Type "Cloud device" `
                        -LastSeen "" `
                        -Identifier $r.Identifier `
                        -Detail "Oggetto Entra ID eliminato correttamente"
                }
                else {
                    Add-GridRow `
                        -Source "Entra ID" `
                        -State "Errore eliminazione" `
                        -Name $r.Name `
                        -Type "Cloud device" `
                        -LastSeen "" `
                        -Identifier $r.Identifier `
                        -Detail $r.Error
                }
            }
        }
        elseif ($chkEntra.Checked -and -not $EnableEntraDeleteByDefault -and $entraTargets.Count -gt 0) {
            Add-GridRow `
                -Source "Entra ID" `
                -State "Saltato" `
                -Name $computerName `
                -Type "Cloud device" `
                -LastSeen "" `
                -Identifier "" `
                -Detail "Eliminazione Entra disabilitata da configurazione"
        }

        Set-Status "Eliminazione completata."
        Show-Info "Operazione completata. Verificare la griglia per eventuali errori."
    }
    catch {
        Show-ErrorBox "Errore durante l'eliminazione:`r`n$($_.Exception.Message)"
        Set-Status "Errore durante l'eliminazione."
    }
    finally {
        $btnSearch.Enabled = $true
        $btnClear.Enabled = $true
        $txtComputer.Enabled = $true
        $chkAD.Enabled = $true
        $chkEntra.Enabled = $true
        $chkIntune.Enabled = $true
        # Dopo qualsiasi tentativo di eliminazione richiede una ricerca aggiornata.
        $script:SearchComputerName = $null
        $script:SearchSelection = $null
        $btnDelete.Enabled = $false
    }
})

$invalidateSearch = {
    if ($null -ne $script:SearchComputerName) {
        $script:SearchComputerName = $null
        $script:SearchSelection = $null
        $btnDelete.Enabled = $false
        Set-Status "Nome computer o origini modificati. Eseguire nuovamente Cerca."
    }
}
$txtComputer.Add_TextChanged($invalidateSearch)
$chkAD.Add_CheckedChanged($invalidateSearch)
$chkEntra.Add_CheckedChanged($invalidateSearch)
$chkIntune.Add_CheckedChanged($invalidateSearch)

$txtComputer.Add_KeyDown({
    if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
        $btnSearch.PerformClick()
    }
})

# ============================================================
# AVVIO
# ============================================================

[void]$form.ShowDialog()
