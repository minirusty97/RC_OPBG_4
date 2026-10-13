#requires -version 5.1
param(
    [Parameter(Mandatory = $true)][string]$NameFragment,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot 'computer-explorer.config.local.json'
}
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Configurazione assente: $ConfigPath. Crea computer-explorer.config.local.json dal modello oppure passa -ConfigPath."
}

$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $config.Glpi.Enabled -or [string]::IsNullOrWhiteSpace($config.Glpi.BaseUri)) {
    throw "Configurare Glpi.BaseUri con l'URL di apirest.php e impostare Glpi.Enabled su true."
}
Import-Module (Join-Path $PSScriptRoot 'GLPI.Inventory.psm1') -Force -ErrorAction Stop
$userToken = Read-Host 'User token GLPI' -AsSecureString
$appToken = $null
if ($config.Glpi.UseAppToken) { $appToken = Read-Host 'App token GLPI' -AsSecureString }

Find-GlpiComputer -BaseUri $config.Glpi.BaseUri -NameFragment $NameFragment `
    -UserToken $userToken -AppToken $appToken -PageSize $config.Glpi.PageSize `
    -TimeoutSeconds $config.Glpi.TimeoutSeconds |
    Format-Table -Property @('Name', 'GlpiId', 'State', 'SerialNumber', 'InventoryNumber', 'EntityId') -AutoSize
