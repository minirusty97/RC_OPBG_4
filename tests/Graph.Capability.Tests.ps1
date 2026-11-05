#requires -version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $root 'ComputerExplorer.Core.psm1') -Force -PassThru
$definitions=(Get-Content (Join-Path $root 'assistente-it.json') -Raw | ConvertFrom-Json).Modules[0].GraphPermissions
try {
 & $module {
  param($Definitions)
  $script:Capability=@{Mode='Success';Requests=(New-Object 'Collections.Generic.List[string]')}
  $context=[pscustomobject]@{Scopes=@($Definitions | ForEach-Object { $_.AnyOf[0] } | Sort-Object -Unique)}
  function script:Invoke-MgGraphRequest {
   [CmdletBinding()]param($Method,$Uri,$OutputType,$Headers)
   if ($Method -ne 'GET') { throw 'Capability verification attempted a write.' }
   [void]$script:Capability.Requests.Add($Uri)
   if ($Uri -notin @('https://graph.microsoft.com/v1.0/devices?$top=1&$select=id','https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?$top=1&$select=id')) { throw 'Unexpected endpoint, BitLocker metadata, secret read, paging or deletion simulation.' }
   if ($Uri -like '*managedDevices*') {
    if ($script:Capability.Mode -eq 'Denied') {
     $ex=New-Object InvalidOperationException('SYNTHETIC_PRIVATE_BODY')
     $ex | Add-Member NoteProperty ResponseStatusCode 403
     $record=New-Object Management.Automation.ErrorRecord($ex,'SyntheticGraphFailure',[Management.Automation.ErrorCategory]::PermissionDenied,$null)
     $record.ErrorDetails=New-Object Management.Automation.ErrorDetails('{"error":{"code":"Authorization_RequestDenied","message":"Bearer SYNTHETIC_TOKEN_DO_NOT_DISCLOSE","innerError":{"request-id":"77777777-7777-4777-8777-777777777777"}}}')
     throw $record
    }
    if ($script:Capability.Mode -eq 'Malformed') { return [pscustomobject]@{unexpected='body'} }
   }
   [pscustomobject]@{value=@();'@odata.nextLink'='https://graph.microsoft.com/v1.0/devices?$skiptoken=not-followed'}
  }
  $report=@(Get-ExplorerGraphPermissionStatus -Definitions $Definitions -Context $context -Probe)
  if ($script:Capability.Requests.Count -ne 2 -or @($report | Where-Object { $_.Id -in @('bitlocker-read','entra-remove','intune-remove') -and $_.Available -and -not $_.OperationVerified -and $_.Verification -eq 'ScopeOnly' }).Count -ne 3) { throw 'BitLocker or write capability was probed or not gated by scope.' }
  if (@($report | Where-Object { $_.Id -in @('entra-read','intune-read') -and $_.OperationVerified -and $_.CheckStatus -eq 'Verificata' }).Count -ne 2) { throw 'Successful harmless reads were not independently verified.' }
  'PASS: access checks only test limited inventory reads. BitLocker and write capabilities are gated by granted scopes without metadata, secret or write requests.'
  foreach ($mode in @('Denied','Malformed')) {
   $script:Capability.Mode=$mode
   $report=@(Get-ExplorerGraphPermissionStatus -Definitions $Definitions -Context $context -Probe)
   $intune=@($report | Where-Object Id -eq 'intune-read')[0]
   if ($intune.Available -or -not $intune.ScopeGranted -or $intune.OperationVerified -or $intune.CheckStatus -ne 'Non disponibile') { throw 'Failed backend verification was hidden by a granted OAuth scope.' }
   if (@($report | Where-Object { $_.Id -eq 'intune-remove' -and $_.Available }).Count) { throw 'Write availability survived failed prerequisite read.' }
   if ($mode -eq 'Denied' -and ($intune.Detail -notlike '*HTTP 403*' -or $intune.Detail -notlike '*Authorization_RequestDenied*' -or $intune.Detail -notlike '*77777777-7777-4777-8777-777777777777*')) { throw 'Safe diagnostic identifiers were lost.' }
   if (($report | ConvertTo-Json -Depth 5) -match 'SYNTHETIC_TOKEN_DO_NOT_DISCLOSE|SYNTHETIC_PRIVATE_BODY') { throw 'Raw Graph error or token leaked into the login report.' }
  }
  'PASS: denied or malformed reads remain unavailable despite granted scopes, with safe diagnostics and related writes disabled.'
  $context.Scopes=@('Device.Read.All');$script:Capability.Requests.Clear()
  $report=@(Get-ExplorerGraphPermissionStatus -Definitions $Definitions -Context $context -Probe)
  if ($script:Capability.Requests.Count -ne 1 -or @($report | Where-Object Id -eq 'bitlocker-read')[0].ScopeGranted) { throw 'Missing consent caused an unauthorized probe or an implicit permission request.' }
  'PASS: missing scopes skip their probes rather than requesting consent or changing identity.'
 } $definitions
 $worker=[PowerShell]::Create()
 try {
  [void]$worker.AddScript({param($Root)
   $ErrorActionPreference='Stop';Import-Module (Join-Path $Root 'ComputerExplorer.Core.psm1') -Force
   $ex=New-Object InvalidOperationException('SYNTHETIC_PRIVATE_BODY');$ex | Add-Member NoteProperty ResponseStatusCode 400
   $record=New-Object Management.Automation.ErrorRecord($ex,'GraphFailure',[Management.Automation.ErrorCategory]::InvalidArgument,$null)
   $record.ErrorDetails=New-Object Management.Automation.ErrorDetails('{"error":{"code":"BadRequest","message":"SYNTHETIC_PRIVATE_BODY"}}')
   throw (New-ExplorerGraphOperationError -Failure $record -Stage BitLockerSecret)
  }.ToString()).AddArgument($root)
  $failure=$null
  try { $null=$worker.Invoke() } catch { $failure=$_ }
  if ($null -eq $failure -and $worker.Streams.Error.Count) { $failure=$worker.Streams.Error[0] }
  if ($null -eq $failure) { throw 'Synthetic worker did not fail.' }
  $safe=New-ExplorerGraphOperationError -Failure $failure -Stage IntuneLookup
  if ($safe.Message -notlike '*Lettura password BitLocker*HTTP 400*Graph BadRequest*' -or $safe.Message -like '*SYNTHETIC_PRIVATE_BODY*' -or $safe.Data['AssistenteIT.GraphStage'] -ne 'BitLockerSecret') { throw 'Asynchronous diagnostics lost the real stage/status or exposed the raw response.' }
  'PASS: safe diagnostic stage and HTTP/Graph code survive a real worker runspace without being replaced by a generic consent error.'
 }
 finally { $worker.Dispose() }
}
finally { Remove-Module -ModuleInfo $module -Force }
