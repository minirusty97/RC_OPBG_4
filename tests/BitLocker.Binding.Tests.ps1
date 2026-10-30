#requires -version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '../BitLocker.Archive.psm1') -Force -PassThru
try {
 & $module {
  $script:Binding=@{Mode='Unique';SerialQuery=$null;NameQuery='';Posts=0}
  function script:Find-GlpiComputer {
   [CmdletBinding()]param($BaseUri,$NameFragment,$SerialNumber,$UserToken,$AppToken,$TimeoutSeconds)
   $script:Binding.SerialQuery=$SerialNumber;$script:Binding.NameQuery=$NameFragment
   if ($script:Binding.Mode -eq 'None') { return @() }
   $row=[pscustomobject]@{GlpiId=901;Name='NOME-GLPI-DIVERSO';SerialNumber='SERIAL-A';EntityId=0;IsDeleted=0}
   if ($script:Binding.Mode -eq 'Duplicate') { $second=$row | Select-Object *;$second.GlpiId=902;return @($row,$second) }
   if ($script:Binding.Mode -eq 'WrongSerial') { $row.SerialNumber='SERIAL-B' }
   if ($script:Binding.Mode -eq 'NameOnly') { $row.Name='PC-INTUNE' }
   return $row
  }
  function script:Get-ExplorerBitLockerKeys { param($Targets) if ($script:Binding.Mode -eq 'KeysDenied') { throw 'Synthetic recovery read denied.' };[pscustomobject]@{KeyId='33333333-3333-4333-8333-333333333333';Fingerprint=('a'*64);Password=(@(1..8 | ForEach-Object {'000011'}) -join '-');Volume='OS';CreatedAt='';Origins=@('Intune:22222222-2222-4222-8222-222222222222')} }
  function script:Open-BlGlpiSession { param($Settings,$UserToken,$AppToken) @{} }
  function script:Close-BlGlpiSession { param($Session) }
  function script:Get-BlGlpiNotes { param($Session,$ComputerId) @() }
  function script:Invoke-BlGlpiRequest {
   param($Session,$Method,$Path,$Body,$Query)
   if ($Method -ne 'GET') { $script:Binding.Posts++;throw 'Binding preview attempted a write.' }
   $name='NOME-GLPI-DIVERSO';if ($script:Binding.Mode -eq 'NameOnly') { $name='PC-INTUNE' }
   [pscustomobject]@{Data=[pscustomobject]@{id=901;name=$name;serial='SERIAL-A';entities_id=0;is_deleted=0}}
  }
  $settings=[pscustomobject]@{Enabled=$true;BaseUri='https://example.invalid/apirest.php';UseAppToken=$false}
  $token=ConvertTo-SecureString synthetic -AsPlainText -Force
  $target=[pscustomobject]@{Source='Intune';SerialNumber='serial-a';LinkId='22222222-2222-4222-8222-222222222222'}
  try {
   $preview=Get-ExplorerBitLockerPreview -Name PC-INTUNE -Targets @($target) -Settings $settings -UserToken $token
   if (-not $preview.ArchiveAvailable -or $preview.Name -ne 'PC-INTUNE' -or $preview.GlpiName -ne 'NOME-GLPI-DIVERSO' -or $preview.MatchBy -ne 'Serial' -or $script:Binding.SerialQuery[0] -ne 'SERIAL-A' -or $script:Binding.NameQuery -or $preview.RequiresMappingConfirmation) { throw 'Intune serial did not select the differently named GLPI asset.' }
   if (($preview | ConvertTo-Json -Depth 6) -match '000011-000011') { throw 'Preview exposes a recovery password.' }
   'PASS: archive binding uses the Intune hardware serial independently of the GLPI asset name, retains both names and exposes metadata only.'
   foreach ($mode in @('None','Duplicate','WrongSerial')) {
    $script:Binding.Mode=$mode
    $preview=Get-ExplorerBitLockerPreview -Name PC-INTUNE -Targets @($target) -Settings $settings -UserToken $token -AllowUnmappedGlpi
    if ($preview.ArchiveAvailable -or $preview.Keys.Count -ne 1 -or $script:Binding.Posts) { throw 'Missing/ambiguous serial binding was silently selected or did not retrieve keys for a copy.' }
    $failed=$false;try { $null=Get-ExplorerBitLockerPreview -Name PC-INTUNE -Targets @($target) -Settings $settings -UserToken $token } catch { $failed=$true }
    if (-not $failed) { throw 'Strict archive accepted a missing/ambiguous serial binding.' }
   }
   $script:Binding.Mode='KeysDenied';$failed=$false
   try { $null=Get-ExplorerBitLockerPreview -Name PC-INTUNE -Targets @($target) -Settings $settings -UserToken $token -AllowUnmappedGlpi } catch { $failed=$true }
   if (-not $failed) { throw 'Loss exception bypassed a key retrieval error.' }
   'PASS: missing/duplicate serial matches can prepare deletion confirmation but strict archiving and key-read failures remain blocked.'
   $script:Binding.Mode='NameOnly';$target.SerialNumber='DEFAULT STRING'
   $preview=Get-ExplorerBitLockerPreview -Name PC-INTUNE -Targets @($target) -Settings $settings -UserToken $token
   if ($preview.MatchBy -ne 'Name' -or -not $preview.RequiresMappingConfirmation -or $script:Binding.NameQuery -ne 'PC-INTUNE' -or $script:Binding.SerialQuery) { throw 'Unusable Intune serial did not fall back to explicitly confirmed name mapping.' }
   'PASS: missing/generic Intune serial falls back to exact name with a separate explicit mapping confirmation.'
  }
  finally { $token.Dispose() }
 }
}
finally { Remove-Module -ModuleInfo $module -Force }
