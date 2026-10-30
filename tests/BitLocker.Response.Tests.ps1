#requires -version 5.1
param([string]$ModulePath=(Join-Path $PSScriptRoot '../BitLocker.Archive.psm1'))
$ErrorActionPreference='Stop'
$module=Import-Module $ModulePath -Force -PassThru
try {
 & $module {
  $script:ResponseFixture=@{Password='000011-000022-000033-000044-000055-000066-000077-000088';Shape='Projected';Requests=(New-Object 'Collections.Generic.List[string]')}
  $target=[pscustomobject]@{Source='Intune';Id='22222222-2222-4222-8222-222222222222';LinkId='11111111-1111-4111-8111-111111111111'}
  function script:Get-ExplorerGraphCollection {
   param($Uri,$ResourcePath)
   if ($ResourcePath -ne '/v1.0/informationProtection/bitlocker/recoveryKeys' -or [Uri]::UnescapeDataString($Uri) -notlike "*deviceId eq '11111111-1111-4111-8111-111111111111'*") { throw 'Metadata request lost the exact device filter.' }
   [pscustomobject]@{id='33333333-3333-4333-8333-333333333333';deviceId='11111111-1111-4111-8111-111111111111';volumeType='fixedDataVolume';createdDateTime='2026-10-30T10:00:00Z'}
  }
  function script:Invoke-MgGraphRequest {
   [CmdletBinding()]param($Method,$Uri,$OutputType,$Headers)
   [void]$script:ResponseFixture.Requests.Add($Uri)
   if ($Method -ne 'GET' -or $OutputType -ne 'PSObject' -or -not $Headers['User-Agent']) { throw 'Unexpected Graph command.' }
   # A metadata-only response cannot be interpreted as a recovered password.
   if ($Uri -cne 'https://graph.microsoft.com/v1.0/informationProtection/bitlocker/recoveryKeys/33333333-3333-4333-8333-333333333333?$select=key') { return [pscustomobject]@{id='33333333-3333-4333-8333-333333333333';deviceId='11111111-1111-4111-8111-111111111111'} }
   $full=[pscustomobject]@{id='33333333-3333-4333-8333-333333333333';deviceId='11111111-1111-4111-8111-111111111111';key=$script:ResponseFixture.Password;volumeType='operatingSystemVolume';createdDateTime='2026-10-29T10:00:00Z'}
   switch ($script:ResponseFixture.Shape) {
    'Projected' { return [pscustomobject]@{key=$script:ResponseFixture.Password} }
    'ProjectedHash' { return @{key=$script:ResponseFixture.Password} }
    'Full' { return $full }
    'Wrapped' { return [pscustomobject]@{value=$full} }
    'WrappedHash' { return @{value=@{key=$script:ResponseFixture.Password}} }
    'WrappedArray' { return [pscustomobject]@{value=@($full)} }
    'Missing' { return [pscustomobject]@{id=$full.id;deviceId=$full.deviceId} }
    'Null' { $full.key=$null;return $full }
    'Empty' { $full.key=' ';return $full }
    'Number' { $full.key=12345;return $full }
    'Array' { $full.key=@($script:ResponseFixture.Password);return $full }
    'Format' { $full.key='SYNTHETIC_PRIVATE_INVALID_VALUE';return $full }
    'Checksum' { $full.key='123456-123456-123456-123456-123456-123456-123456-123456';return $full }
    'ForeignKey' { $full.id='44444444-4444-4444-8444-444444444444';return $full }
    'ForeignDevice' { $full.deviceId='44444444-4444-4444-8444-444444444444';return $full }
    'Multiple' { return [pscustomobject]@{value=@($full,$full)} }
    'NoEntity' { return [pscustomobject]@{value=@()} }
    'NullEntity' { return [pscustomobject]@{value=$null} }
   }
  }
  foreach ($shape in @('Projected','ProjectedHash','Full','Wrapped','WrappedHash','WrappedArray')) {
   $script:ResponseFixture.Shape=$shape;$script:ResponseFixture.Requests.Clear();$trace=New-Object 'Collections.Concurrent.ConcurrentQueue[object]'
   $keys=@(Get-ExplorerBitLockerKeys -Targets @($target) -DiagnosticQueue $trace)
   if ($keys.Count -ne 1 -or $keys[0].Password -cne $script:ResponseFixture.Password -or $keys[0].KeyId -ne '33333333-3333-4333-8333-333333333333' -or $keys[0].Origins[0] -ne ('Intune:'+$target.LinkId) -or $keys[0].Fingerprint.Length -ne 64 -or $script:ResponseFixture.Requests.Count -ne 1 -or $script:ResponseFixture.Requests[0] -notlike '*?$select=key') { throw ('Canonical secret read failed for '+$shape) }
   $volume='operatingSystemVolume';$created='2026-10-29T10:00:00Z'
   if ($shape -in @('Projected','ProjectedHash','WrappedHash')) { $volume='fixedDataVolume';$created='2026-10-30T10:00:00Z' }
   if ($keys[0].Volume -ne $volume -or $keys[0].CreatedAt -ne $created) { throw 'Projected responses lost their previously verified metadata.' }
   $diagnostics=$trace.ToArray() | ConvertTo-Json -Depth 5
   if ($diagnostics -like ('*'+$script:ResponseFixture.Password+'*') -or $diagnostics -notlike '*campo key=True*contenuto=Testo*') { throw 'Response shape diagnostics lost field presence or disclosed the password.' }
  }
  'PASS: the exact documented $select=key request reads bare, projected and wrapped objects/dictionaries, retaining verified metadata, exact key/device binding and fingerprints.'
  foreach ($case in @(@{Shape='Missing';Code='MissingKeyField'},@{Shape='Null';Code='EmptyKeyField'},@{Shape='Empty';Code='EmptyKeyField'},@{Shape='Number';Code='InvalidKeyType'},@{Shape='Array';Code='InvalidKeyType'},@{Shape='Format';Code='InvalidKeyFormat'},@{Shape='Checksum';Code='InvalidPassword'},@{Shape='ForeignKey';Code='ChangedKey'},@{Shape='ForeignDevice';Code='ChangedKey'},@{Shape='Multiple';Code='InvalidKeyResponse'},@{Shape='NoEntity';Code='InvalidKeyResponse'},@{Shape='NullEntity';Code='InvalidKeyResponse'})) {
   $script:ResponseFixture.Shape=$case.Shape;$trace=New-Object 'Collections.Concurrent.ConcurrentQueue[object]';$failure=$null;$keys=@()
   try { $keys=@(Get-ExplorerBitLockerKeys -Targets @($target) -DiagnosticQueue $trace) } catch { $failure=$_ }
   if ($null -eq $failure -or $keys.Count -or $failure.Exception.Data['AssistenteIT.LocalCode'] -ne $case.Code -or $failure.Exception.Data['AssistenteIT.GraphStage'] -ne 'BitLockerResponse') { throw ('Invalid secret response was accepted or misclassified: '+$case.Shape) }
   if (($trace.ToArray() | ConvertTo-Json -Depth 5) -match '000011-000022|SYNTHETIC_PRIVATE_INVALID_VALUE|123456-123456') { throw 'An invalid response leaked its contents into diagnostics.' }
  }
  'PASS: missing/null/empty/non-text/malformed passwords, invalid checksums, foreign identities and ambiguous entities remain blocked with distinct safe error codes.'
 }
}
finally { Remove-Module -ModuleInfo $module -Force }
