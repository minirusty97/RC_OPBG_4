#requires -version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$NameFragment,
    [string]$ConfigPath,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Get-AdCanonicalParent {
    param([string]$CanonicalName)
    if ([string]::IsNullOrWhiteSpace($CanonicalName)) { return $null }
    $lastSeparator = -1
    $escaped = $false
    for ($i = 0; $i -lt $CanonicalName.Length; $i++) {
        if ($escaped) { $escaped = $false; continue }
        if ($CanonicalName[$i] -eq '\') { $escaped = $true; continue }
        if ($CanonicalName[$i] -eq '/') { $lastSeparator = $i }
    }
    if ($lastSeparator -ge 0) { return $CanonicalName.Substring(0, $lastSeparator) }
    return $null
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot 'computer-explorer.config.local.json'
}
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Configurazione assente: $ConfigPath. Usare il JSON locale oppure passare -ConfigPath."
}
$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$dcProperty = $config.PSObject.Properties['DomainControllers']
if ($null -eq $dcProperty) { throw 'Definire DomainControllers nella configurazione locale.' }
$controllers = @($dcProperty.Value | ForEach-Object {
    $dc = ([string]$_).Trim()
    if ([string]::IsNullOrWhiteSpace($dc)) { throw 'Domain Controller vuoto nella configurazione.' }
    $dc
} | Sort-Object -Unique)
if ($controllers.Count -eq 0) { throw 'Configurare almeno un Domain Controller.' }

$minimumCharacters = 2
$searchProperty = $config.PSObject.Properties['Search']
if ($null -ne $searchProperty -and $null -ne $searchProperty.Value) {
    $minimumProperty = $searchProperty.Value.PSObject.Properties['MinimumCharacters']
    if ($null -ne $minimumProperty) { $minimumCharacters = [int]$minimumProperty.Value }
}
if ($minimumCharacters -lt 1 -or $minimumCharacters -gt 255) {
    throw 'Search.MinimumCharacters deve essere compreso fra 1 e 255.'
}
$fragment = $NameFragment.Trim()
if ($fragment.Length -lt $minimumCharacters) {
    throw "Inserire almeno $minimumCharacters caratteri per la ricerca."
}

# Il frammento resta letterale: gli asterischi della ricerca vengono aggiunti qui.
$escapedFragment = $fragment.Replace('\', '\5c').Replace('*', '\2a').Replace('(', '\28').Replace(')', '\29').Replace([string][char]0, '\00')
$ldapFilter = '(|(name=*{0}*)(dNSHostName=*{0}*)(sAMAccountName=*{0}*))' -f $escapedFragment
Import-Module -Name ActiveDirectory -ErrorAction Stop

$sources = New-Object 'System.Collections.Generic.List[object]'
$computers = New-Object 'System.Collections.Generic.List[object]'
foreach ($dc in $controllers) {
    Write-Verbose "Ricerca AD su $dc..."
    try {
        $query = @{
            Server = $dc
            LDAPFilter = $ldapFilter
            Properties = @('CanonicalName', 'DNSHostName', 'SamAccountName', 'DistinguishedName', 'ObjectGUID', 'Enabled')
            ErrorAction = 'Stop'
        }
        $found = @(Get-ADComputer @query)
        $dcComputers = New-Object 'System.Collections.Generic.List[object]'
        foreach ($computer in $found) {
            if ($null -eq $computer) { continue }
            $name = ([string]$computer.Name).Trim()
            $guid = [guid]::Empty
            if ([string]::IsNullOrWhiteSpace($name) -or
                -not [guid]::TryParse([string]$computer.ObjectGUID, [ref]$guid) -or
                $guid -eq [guid]::Empty) {
                throw 'Risposta AD con nome o ObjectGUID non valido.'
            }
            [void]$dcComputers.Add([pscustomobject]@{
                Name = $name
                DomainController = $dc
                ObjectGUID = $guid.ToString()
                DistinguishedName = [string]$computer.DistinguishedName
                CanonicalName = [string]$computer.CanonicalName
                ParentPath = Get-AdCanonicalParent ([string]$computer.CanonicalName)
                DNSHostName = [string]$computer.DNSHostName
                SamAccountName = [string]$computer.SamAccountName
                Enabled = $computer.Enabled
            })
        }
        foreach ($computer in $dcComputers) { [void]$computers.Add($computer) }
        [void]$sources.Add([pscustomobject]@{
            DomainController = $dc
            Stato = 'OK'
            Verificato = $true
            Trovati = $dcComputers.Count
            Errore = $null
        })
    }
    catch {
        [void]$sources.Add([pscustomobject]@{
            DomainController = $dc
            Stato = 'Errore'
            Verificato = $false
            Trovati = $null
            Errore = $_.Exception.Message
        })
    }
}

$verifiedCount = @($sources | Where-Object { $_.Verificato }).Count
$summary = @($computers | Group-Object -Property { $_.Name.ToUpperInvariant() } | ForEach-Object {
    $group = $_
    $presentCount = @($group.Group.DomainController | Sort-Object -Unique).Count
    $paths = @($group.Group.ParentPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    $guidCount = @($group.Group.ObjectGUID | Sort-Object -Unique).Count
    $state = 'Parziale'
    $color = 'Giallo'
    if ($verifiedCount -lt $controllers.Count) { $state = 'Non verificabile'; $color = 'Grigio' }
    elseif ($presentCount -eq $controllers.Count) { $state = 'Presente'; $color = 'Verde' }
    $path = $paths -join ' | '
    if ([string]::IsNullOrWhiteSpace($path)) { $path = 'Non disponibile' }
    [pscustomobject]@{
        Name = $group.Name
        AD = '{0}/{1}' -f $presentCount, $controllers.Count
        Verificati = '{0}/{1}' -f $verifiedCount, $controllers.Count
        StatoAD = $state
        Colore = $color
        PercorsoAD = $path
        IdentitaDiverse = ($guidCount -gt 1)
        PercorsiDiversi = ($paths.Count -gt 1)
    }
} | Sort-Object -Property Name)

$result = [pscustomobject]@{
    NameFragment = $fragment
    CheckedAtUtc = [datetimeoffset]::UtcNow
    Sources = $sources.ToArray()
    Computers = $computers.ToArray()
    Summary = $summary
}
if ($PassThru) { return $result }

Write-Host 'Esito delle interrogazioni AD:'
$result.Sources | Format-Table -Property DomainController, Stato, Trovati, Errore -AutoSize -Wrap
Write-Host 'Computer trovati:'
if ($summary.Count -eq 0) {
    Write-Host 'Nessun risultato da mostrare. Gli eventuali errori dei DC sono indicati sopra.'
}
else {
    $summary | Format-Table -Property Name, AD, Verificati, Colore, PercorsoAD, IdentitaDiverse -AutoSize -Wrap
}
