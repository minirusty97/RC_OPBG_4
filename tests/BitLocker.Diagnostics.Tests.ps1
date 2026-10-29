#requires -version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '../BitLocker.Archive.psm1') -Force -PassThru
try {
 & $module {
  $script:DiagnosticMode=''
  function script:Read-ExplorerConfiguration { param($ConfigPath) [pscustomobject]@{CloudReadTimeoutSeconds=2;Settings=[pscustomobject]@{DomainControllers=@()}} }
  function script:Import-Module { [CmdletBinding()]param($Name) }
  function script:Connect-ExplorerGraph { [CmdletBinding()]param($Sources,[switch]$ForBitLocker,$ProgressQueue,$GraphAuthentication) }
  function New-DiagnosticFailure {
   param([int]$Status=403)
   $ex=New-Object InvalidOperationException('000011-000011-000011-000011-000011-000011-000011-000011')
   $ex | Add-Member NoteProperty ResponseStatusCode $Status
   $record=New-Object Management.Automation.ErrorRecord($ex,'SyntheticGraphFailure',[Management.Automation.ErrorCategory]::PermissionDenied,$null)
   $record.ErrorDetails=New-Object Management.Automation.ErrorDetails('{"error":{"code":"SyntheticServiceCode","message":"Bearer SYNTHETIC_PRIVATE_TOKEN","innerError":{"request-id":"77777777-7777-4777-8777-777777777777"}}}')
   return $record
  }
  function script:Get-ExplorerGraphCollection {
   param($Uri,$ResourcePath)
   if ($ResourcePath -eq '/v1.0/deviceManagement/managedDevices') {
    if ($script:DiagnosticMode -eq 'IntuneDenied') { throw (New-DiagnosticFailure) }
    $azure='11111111-1111-4111-8111-111111111111';if ($script:DiagnosticMode -eq 'BadIdentifier') { $azure='not-a-device-id' }
    return [pscustomobject]@{id='22222222-2222-4222-8222-222222222222';deviceName='PC-DIAGNOSTIC';operatingSystem='Windows';azureADDeviceId=$azure;serialNumber='SYNTHETIC'}
   }
   if ($ResourcePath -eq '/v1.0/informationProtection/bitlocker/recoveryKeys') {
    if ($script:DiagnosticMode -eq 'MetadataDenied') { throw (New-DiagnosticFailure) }
    if ($script:DiagnosticMode -eq 'BadRequest') { throw (New-DiagnosticFailure 400) }
    return [pscustomobject]@{id='33333333-3333-4333-8333-333333333333';deviceId='11111111-1111-4111-8111-111111111111'}
   }
   throw 'Unexpected endpoint in diagnostic test.'
  }
  function script:Invoke-MgGraphRequest { [CmdletBinding()]param($Method,$Uri,$OutputType,$Headers) throw (New-DiagnosticFailure) }
  function script:Read-BlLiveKeySource {
   param($Source,$Name,$DomainController,$TimeoutSeconds)
   if ($Source -ne 'Intune') { throw 'No AD controllers are configured in this diagnostic fixture.' }
   if ($script:DiagnosticMode -eq 'Timeout') { throw (New-Object TimeoutException('Tempo massimo di lettura BitLocker da Intune superato.')) }
   Read-BlKeysBySource -Source Intune -Name $Name
  }
  foreach ($case in @(@{Mode='IntuneDenied';Stage='Ricerca dispositivo Intune';Http=403},@{Mode='MetadataDenied';Stage='Elenco metadati BitLocker';Http=403},@{Mode='SecretDenied';Stage='Lettura password BitLocker';Http=403},@{Mode='BadRequest';Stage='Elenco metadati BitLocker';Http=400},@{Mode='BadIdentifier';Stage='Verifica Azure AD Device ID';Http=0},@{Mode='Timeout';Stage='Tempo massimo di lettura BitLocker superato';Http=0})) {
   $script:DiagnosticMode=$case.Mode
   $result=Find-ExplorerBitLockerKeys -Name PC-DIAGNOSTIC -ConfigPath synthetic.json
   $source=$result.Sources[0]
   if ($result.Records.Count -ne 0 -or $source.State -ne 'Errore' -or $source.Error -notlike ('*'+$case.Stage+'*')) { throw ('Lookup diagnostics lost stage '+$case.Mode) }
   if ($case.Http -and ($source.Error -notlike ('*HTTP '+$case.Http+'*') -or $source.Error -notlike '*SyntheticServiceCode*77777777-7777-4777-8777-777777777777*')) { throw ('Lookup diagnostics lost safe HTTP/Graph correlation metadata: '+$case.Mode) }
   if ($case.Http -eq 400 -and $source.Error -like '*Accesso negato*') { throw 'A malformed request was misdiagnosed as missing user permissions.' }
   if (($result | ConvertTo-Json -Depth 6) -match '000011-000011|SYNTHETIC_PRIVATE_TOKEN') { throw 'Lookup error exposed a raw response, token or recovery password.' }
  }
  'PASS: live key lookup distinguishes Intune inventory, Azure device ID, metadata listing, secret reading, bad requests and timeouts with safe HTTP/Graph correlation identifiers.'
  'PASS: lookup diagnostics retain source errors with zero recovered keys without exposing raw service messages, tokens or passwords or labelling every failure as a permission error.'
 }
}
finally { Remove-Module -ModuleInfo $module -Force }
