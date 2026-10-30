#requires -version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '../BitLocker.Archive.psm1') -Force -PassThru
try {
 & $module {
  $script:TraceFixture=@{Mode='Success';Password='000011-000011-000011-000011-000011-000011-000011-000011'}
  function script:Import-Module { [CmdletBinding()]param($Name) }
  function script:Get-MgContext { [CmdletBinding()]param() [pscustomobject]@{AuthType='Delegated';TenantId='55555555-5555-4555-8555-555555555555';ClientId='66666666-6666-4666-8666-666666666666';Scopes=@('BitlockerKey.Read.All','DeviceManagementManagedDevices.Read.All');AccessToken='SYNTHETIC_PRIVATE_TOKEN'} }
  function script:Get-ExplorerGraphCollection {
   param($Uri,$ResourcePath)
   if ($ResourcePath -eq '/v1.0/deviceManagement/managedDevices') {
    if ($script:TraceFixture.Mode -eq 'NoDevice') { return @() }
    return [pscustomobject]@{id='22222222-2222-4222-8222-222222222222';deviceName='PC-TRACE';operatingSystem='Windows';azureADDeviceId='11111111-1111-4111-8111-111111111111';serialNumber='SERIAL-TRACE'}
   }
   if ($script:TraceFixture.Mode -eq 'NoKey') { return @() }
   return [pscustomobject]@{id='33333333-3333-4333-8333-333333333333';deviceId='11111111-1111-4111-8111-111111111111'}
  }
  function script:Invoke-MgGraphRequest {
   [CmdletBinding()]param($Method,$Uri,$OutputType,$Headers)
   if ($Method -ne 'GET' -or -not $Headers['User-Agent'] -or -not $Uri.EndsWith('?$select=key',[StringComparison]::Ordinal)) { throw 'Unexpected secret request.' }
   $response=[pscustomobject]@{id='33333333-3333-4333-8333-333333333333';deviceId='11111111-1111-4111-8111-111111111111';key=$script:TraceFixture.Password;volumeType='operatingSystemVolume';createdDateTime='2026-10-30T10:00:00Z'}
   if ($script:TraceFixture.Mode -eq 'MissingPassword') { $response.key=$null }
   if ($script:TraceFixture.Mode -eq 'InvalidPassword') { $response.key='123456-123456-123456-123456-123456-123456-123456-123456' }
   if ($script:TraceFixture.Mode -eq 'WrongDevice') { $response.deviceId='44444444-4444-4444-8444-444444444444' }
   return $response
  }
  foreach ($mode in @('Success','NoDevice','NoKey','MissingPassword','InvalidPassword','WrongDevice')) {
   $script:TraceFixture.Mode=$mode;$queue=New-Object 'Collections.Concurrent.ConcurrentQueue[object]';$failure=$null;$keys=@()
   try { $keys=@(Read-BlKeysBySource -Source Intune -Name PC-TRACE -DiagnosticQueue $queue) } catch { $failure=$_ }
   $trace=$queue.ToArray()
   $errorText='';if ($null -ne $failure) { $errorText=$failure.Exception.Message }
   $sources=@([pscustomobject]@{Name='Intune';State=$(if($failure){'Errore'}else{'OK'});Count=$keys.Count;Error=$errorText})
   $text=ConvertTo-BlDiagnosticText -Name PC-TRACE -Sources $sources -Diagnostics $trace
   if ($text -match '000011-000011|123456-123456|SYNTHETIC_PRIVATE_TOKEN' -or $text -notlike '*AuthType=Delegated*BitlockerKey.Read.All=True*') { throw 'Diagnostics lost the worker session or disclosed a password/token.' }
   if ($mode -eq 'Success' -and ($keys.Count -ne 1 -or @($trace | Where-Object { $_.Stage -eq 'BitLockerResponse' -and $_.State -eq 'OK' }).Count -ne 1 -or $text -notlike '*11111111-1111-4111-8111-111111111111*33333333-3333-4333-8333-333333333333*')) { throw 'Successful phase tracing lost IDs or validation status.' }
   if ($mode -eq 'NoDevice' -and (@($trace | Where-Object Stage -eq 'BitLockerMetadata').Count -ne 0 -or $text -notlike '*IntuneLookup*Numero=0*')) { throw 'No Intune device was reported as an empty key list.' }
   if ($mode -eq 'NoKey' -and ($failure -or $text -notlike '*BitLockerMetadata*Numero=0*' -or @($trace | Where-Object Stage -eq 'BitLockerSecret').Count)) { throw 'An empty metadata list caused a secret read or an invented error.' }
   if ($mode -in @('MissingPassword','InvalidPassword','WrongDevice') -and ($null -eq $failure -or $text -notlike '*BitLockerResponse*Errore*' -or $keys.Count)) { throw 'An invalid response was accepted or lost its exact failure phase.' }
  }
  'PASS: phase reports distinguish absent Intune devices, zero cloud keys, successful password validation and invalid secret responses, with the actual worker scopes/IDs and no password/token in diagnostics.'
 }
}
finally { Remove-Module -ModuleInfo $module -Force }
