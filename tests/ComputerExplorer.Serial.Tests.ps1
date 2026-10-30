#requires -version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '../ComputerExplorer.Core.psm1') -Force -PassThru
try {
 & $module {
  $sources=[ordered]@{};foreach ($name in @('AD','Entra','Intune','GLPI')) { $sources[$name]=New-ExplorerSource $name 'OK' }
  $sources.Intune.Records=@([pscustomobject]@{Name='PC-INTUNE';ManagedDeviceId='managed';AzureADDeviceId='device';SerialNumber='SERIAL-A'})
  $sources.GLPI.Records=@([pscustomobject]@{Name='NOME-GLPI-DIVERSO';GlpiId=1;SerialNumber='serial-a';State='Assegnato'},[pscustomobject]@{Name='PC-INTUNE';GlpiId=2;SerialNumber='SERIAL-B';State='Vecchio'})
  $rows=@(Merge-ExplorerResults -Sources $sources -DomainControllers @())
  if ($rows.Count -ne 1 -or $rows[0].Name -ne 'PC-INTUNE' -or $rows[0].GLPI -ne '1' -or $rows[0].GlpiRecords[0].Name -ne 'NOME-GLPI-DIVERSO' -or $rows[0].SerialConflict -or $rows[0].DeletionIdentityConflict -or $rows[0].Note -notlike '*seriale Intune*' -or $rows[0].Note -notlike '*omonime escluse*') { throw 'The grid did not prefer serial identity over a homonymous foreign asset.' }
  'PASS: Intune serial joins a differently named GLPI asset to the correct row and excludes a homonymous foreign serial without altering stored GLPI names.'
  $sources.Intune.Records+=@([pscustomobject]@{Name='PC-INTUNE';ManagedDeviceId='other';AzureADDeviceId='other-device';SerialNumber='SERIAL-B'})
  $rows=@(Merge-ExplorerResults -Sources $sources -DomainControllers @())
  if (-not $rows[0].DeletionIdentityConflict) { throw 'Different Intune hardware identities were silently accepted.' }
  'PASS: conflicting Intune hardware identities retain a distinct deletion block.'
  $sources.Intune.Records=@();$sources.GLPI.Records=@([pscustomobject]@{Name='PC-NO-INTUNE';GlpiId=1;SerialNumber='A';State='A'},[pscustomobject]@{Name='PC-NO-INTUNE';GlpiId=2;SerialNumber='B';State='B'})
  $rows=@(Merge-ExplorerResults -Sources $sources -DomainControllers @())
  if ($rows[0].DeletionIdentityConflict -or $rows[0].GLPI -ne '2') { throw 'GLPI ambiguity alone still imposes an unconditionally blocked deletion.' }
  'PASS: absent Intune serials keep name lookup, while GLPI-only ambiguity can proceed to the explicit loss confirmation.'
  function script:Import-Module { [CmdletBinding()]param($Name) }
  $script:SerialQuery=$null
  function script:Find-GlpiComputer { [CmdletBinding()]param($BaseUri,$NameFragment,$SerialNumber,$UserToken,$PageSize,$TimeoutSeconds) $script:SerialQuery=@{Name=$NameFragment;Serial=$SerialNumber};@() }
  $configuration=[pscustomobject]@{Settings=[pscustomobject]@{Glpi=[pscustomobject]@{Enabled=$true;BaseUri='https://example.invalid/apirest.php';UseAppToken=$false}}}
  $token=ConvertTo-SecureString 'synthetic' -AsPlainText -Force
  try {
   $source=Read-ExplorerSource -Source GLPI -NameFragment 'PC-' -Configuration $configuration -GlpiUserToken $token -IntuneDevices @([pscustomobject]@{SerialNumber='serial-a'})
   if ($source.State -ne 'OK' -or $script:SerialQuery.Name -or $script:SerialQuery.Serial.Count -ne 1 -or $script:SerialQuery.Serial[0] -ne 'SERIAL-A') { throw 'GLPI reader failed to forward normalized Intune serials without a name restriction.' }
   $source=Read-ExplorerSource -Source GLPI -NameFragment 'PC-' -Configuration $configuration -GlpiUserToken $token -IntuneDevices @([pscustomobject]@{SerialNumber='DEFAULT STRING'})
   if ($source.State -ne 'OK' -or $script:SerialQuery.Name -ne 'PC-' -or $script:SerialQuery.Serial) { throw 'Invalid firmware placeholders did not fall back to name lookup.' }
  }
  finally { $token.Dispose() }
  'PASS: GLPI reader forwards Intune serials and falls back to name only when no meaningful serial is available.'
 }
}
finally { Remove-Module -ModuleInfo $module -Force }
