#requires -version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '../BitLocker.Archive.psm1') -Force -PassThru
try {
 & $module {
  $script:AdReadFixture=@{Mode='Found';Password='000011-000022-000033-000044-000055-000066-000077-000088'}
  function script:Import-Module { [CmdletBinding()]param($Name) }
  function script:Get-ADComputer {
   [CmdletBinding()]param($Server,$LDAPFilter,$Properties)
   if ($script:AdReadFixture.Mode -eq 'NoComputer') { return @() }
   [pscustomobject]@{Name='PC-AD';ObjectGUID='11111111-1111-4111-8111-111111111111';DistinguishedName='CN=PC-AD,DC=invalid'}
  }
  function script:Get-ADObject {
   [CmdletBinding()]param($Server,$SearchBase,$SearchScope,$LDAPFilter,$Properties,$Identity)
   if (-not $Identity) {
    if ($LDAPFilter -ne '(objectClass=msFVE-RecoveryInformation)') { throw 'AD lookup enumerated unrelated children.' }
    if ($script:AdReadFixture.Mode -eq 'NoObjects') { return @() }
    if ($script:AdReadFixture.Mode -eq 'Denied') { throw (New-Object UnauthorizedAccessException('SYNTHETIC_PRIVATE_DATA')) }
   }
   $r=[pscustomobject]@{ObjectGUID='22222222-2222-4222-8222-222222222222';DistinguishedName='CN=Recovery,CN=PC-AD,DC=invalid';ObjectClass='msFVE-RecoveryInformation';'msFVE-RecoveryGuid'=([guid]'33333333-3333-4333-8333-333333333333').ToByteArray();'msFVE-RecoveryPassword'=$script:AdReadFixture.Password;whenCreated='2026-10-30'}
   if ($script:AdReadFixture.Mode -eq 'MissingPassword') { $r.'msFVE-RecoveryPassword'=$null }
   return $r
  }
  foreach ($mode in @('Found','NoComputer','NoObjects','Denied','MissingPassword')) {
   $script:AdReadFixture.Mode=$mode;$queue=New-Object 'Collections.Concurrent.ConcurrentQueue[object]';$failure=$null;$keys=@()
   try { $keys=@(Read-BlKeysBySource -Source AD -Name PC-AD -DomainController dc.invalid -DiagnosticQueue $queue) } catch { $failure=$_ }
   $events=$queue.ToArray()
   if ($mode -eq 'Found' -and ($keys.Count -ne 1 -or $keys[0].KeyId -ne '33333333-3333-4333-8333-333333333333')) { throw 'Binary AD Recovery GUID could not be read.' }
   if ($mode -eq 'NoComputer' -and ($failure -or @($events | Where-Object { $_.Stage -eq 'ADLookup' -and $_.Count -eq 0 }).Count -ne 1)) { throw 'Absent AD computer was not identified.' }
   if ($mode -eq 'NoObjects' -and ($failure -or @($events | Where-Object { $_.Stage -eq 'ADRecoveryObjects' -and $_.Count -eq 0 -and $_.Detail -like '*restrizioni ACL*' }).Count -ne 1)) { throw 'No visible recovery objects was treated as unreadable password or proof of physical absence.' }
   if ($mode -in @('Denied','MissingPassword')) {
    $expected='AccessDenied';if ($mode -eq 'MissingPassword') { $expected='MissingPassword' }
    if ($null -eq $failure -or $failure.Exception.Data['AssistenteIT.AdReason'] -ne $expected -or $keys.Count) { throw ('AD failure lost its concrete reason: '+$mode) }
    $again=New-BlAdError -Failure $failure -Stage ADLookup -Server dc.invalid
    if ($again.Data['AssistenteIT.AdReason'] -ne $expected -or $again.Data['AssistenteIT.AdStage'] -ne $failure.Exception.Data['AssistenteIT.AdStage']) { throw 'AD diagnostic reason did not survive wrapping.' }
   }
   if (($events | ConvertTo-Json -Depth 5) -match '000011-000022|SYNTHETIC_PRIVATE_DATA' -or ($failure -and $failure.Exception.Message -match '000011-000022|SYNTHETIC_PRIVATE_DATA')) { throw 'AD diagnostics exposed a password or raw exception.' }
  }
  'PASS: AD diagnostics distinguish absent computers, zero visible recovery objects, access denial and an existing object with unreadable password, preserving binary recovery GUIDs and safe errors.'
 }
}
finally { Remove-Module -ModuleInfo $module -Force }
