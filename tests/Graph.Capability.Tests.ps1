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
   if ($Uri -eq 'https://graph.microsoft.com/v1.0/informationProtection/bitlocker/recoveryKeys') {
    if (-not $Headers['User-Agent']) { throw 'Metadata request has no documented User-Agent.' }
    if ($script:Capability.Mode -eq 'Denied') {
     $ex=New-Object InvalidOperationException('Do not disclose this recovery password: 000011-000011-000011-000011-000011-000011-000011-000011')
     $ex | Add-Member NoteProperty ResponseStatusCode 403
     $record=New-Object Management.Automation.ErrorRecord($ex,'SyntheticGraphFailure',[Management.Automation.ErrorCategory]::PermissionDenied,$null)
     $record.ErrorDetails=New-Object Management.Automation.ErrorDetails('{"error":{"code":"Authorization_RequestDenied","message":"Bearer SYNTHETIC_TOKEN_DO_NOT_DISCLOSE","innerError":{"request-id":"77777777-7777-4777-8777-777777777777"}}}')
     throw $record
    }
    if ($script:Capability.Mode -eq 'Malformed') { return [pscustomobject]@{unexpected='body'} }
    if ($script:Capability.Mode -eq 'Empty') { return [pscustomobject]@{value=@()} }
    return [pscustomobject]@{value=@([pscustomobject]@{id='11111111-1111-4111-8111-111111111111';deviceId='22222222-2222-4222-8222-222222222222'});'@odata.nextLink'='https://graph.microsoft.com/v1.0/informationProtection/bitlocker/recoveryKeys?$skiptoken=not-followed'}
   }
   if ($Uri -notin @('https://graph.microsoft.com/v1.0/devices?$top=1&$select=id','https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?$top=1&$select=id')) { throw 'Unexpected endpoint, secret read, paging or deletion simulation.' }
   [pscustomobject]@{value=@()}
  }
  foreach ($mode in @('Success','Empty')) {
   $script:Capability.Mode=$mode;$script:Capability.Requests.Clear()
   $report=@(Get-ExplorerGraphPermissionStatus -Definitions $Definitions -Context $context -Probe)
   $bl=@($report | Where-Object Id -eq 'bitlocker-read')[0]
   if ($script:Capability.Requests.Count -ne 3 -or -not $bl.Available -or -not $bl.ScopeGranted -or $bl.OperationVerified -or $bl.Verification -ne 'MetadataVerified' -or $bl.CheckStatus -ne 'Parziale') { throw 'Metadata access, including an empty list, was presented as proof of secret access or scanned beyond one metadata page.' }
   if (@($report | Where-Object { $_.Id -in @('entra-remove','intune-remove') -and $_.Available -and -not $_.OperationVerified -and $_.Verification -eq 'NotTestable' }).Count -ne 2) { throw 'Granted delete scopes were reported as a verified deletion.' }
   if (@($report | Where-Object { $_.Id -in @('entra-read','intune-read') -and $_.OperationVerified -and $_.CheckStatus -eq 'Verificata' }).Count -ne 2) { throw 'Successful harmless reads were not independently verified.' }
  }
  'PASS: preflight performs only the two inventory GETs and one identified metadata page; it never reads a secret, follows metadata pages, simulates deletion or equates metadata/empty results with key access.'
  foreach ($mode in @('Denied','Malformed')) {
   $script:Capability.Mode=$mode
   $report=@(Get-ExplorerGraphPermissionStatus -Definitions $Definitions -Context $context -Probe)
   $bl=@($report | Where-Object Id -eq 'bitlocker-read')[0]
   if ($bl.Available -or -not $bl.ScopeGranted -or $bl.OperationVerified -or $bl.CheckStatus -ne 'Non disponibile') { throw 'Failed backend verification was hidden by a granted OAuth scope.' }
   if ($mode -eq 'Denied' -and ($bl.Detail -notlike '*HTTP 403*' -or $bl.Detail -notlike '*Authorization_RequestDenied*' -or $bl.Detail -notlike '*77777777-7777-4777-8777-777777777777*')) { throw 'Safe diagnostic identifiers were lost.' }
   $text=$report | ConvertTo-Json -Depth 5
   if ($text -match 'SYNTHETIC_TOKEN_DO_NOT_DISCLOSE|000011-000011') { throw 'Raw Graph errors or secrets leaked into the login report.' }
  }
  'PASS: a granted BitLocker scope with a denied/malformed metadata request is unavailable, with safe HTTP/code/correlation diagnostics and no raw body, token or password.'
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
