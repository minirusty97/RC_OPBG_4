#requires -version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '../ComputerExplorer.Removal.psm1') -Force -PassThru
try {
 & $module {
  $script:HybridRemoval=@{Mode='Mismatch';Writes=(New-Object 'Collections.Generic.List[string]');Fresh=$false}
  function script:Read-ExplorerConfiguration { param($ConfigPath) [pscustomobject]@{GraphAuthentication=$null;Settings=[pscustomobject]@{DomainControllers=@('dc.invalid');Glpi=$null}} }
  function script:Initialize-RemovalSources { param($Sources,$ProgressQueue,[switch]$ArchiveOnly,$GraphAuthentication) }
  function script:Get-RemovalContextKey { param($Sources) 'synthetic|same-context' }
  function script:Get-RemovalTargets {
   param($Name,$Sources,$Controllers)
   if ($Sources -contains 'AD') { [pscustomobject]@{Source='AD';Name=$Name;Id='11111111-1111-4111-8111-111111111111';DomainController='dc.invalid';DistinguishedName=('CN='+$Name+',DC=invalid');LinkId='';SerialNumber='';OperatingSystem='';AdChildren=@()} }
   if ($Sources -contains 'Entra') { [pscustomobject]@{Source='Entra';Name=$Name;Id='22222222-2222-4222-8222-222222222222';DomainController='';DistinguishedName='';LinkId='33333333-3333-4333-8333-333333333333';SerialNumber='';OperatingSystem='';TrustType=$(if ($script:HybridRemoval.Mode -eq 'Registered') {'Workplace'}else{'ServerAd'})} }
  }
  function script:Read-ExplorerHybridAd {
   param($DeviceIds,$Controllers,$Name)
   if ($script:HybridRemoval.Mode -eq 'Offline') { return [pscustomobject]@{State='Errore';Error='DC non verificato.';Records=@()} }
   $id='11111111-1111-4111-8111-111111111111';$recordName=$Name
   if ($script:HybridRemoval.Mode -eq 'Renamed') { $id='33333333-3333-4333-8333-333333333333';$recordName='PC-RENAMED' }
   if ($script:HybridRemoval.Fresh) { $id='44444444-4444-4444-8444-444444444444' }
   [pscustomobject]@{State='OK';Error='';Records=@([pscustomobject]@{Name=$recordName;ObjectGUID=$id;DomainController='dc.invalid';DistinguishedName=('CN='+$recordName+',DC=invalid')})}
  }
  function script:Get-RemovalBitLockerPreview { param($Name,$Targets,$Settings,$Credentials,[switch]$AllowUnmappedGlpi) [pscustomobject]@{ComputerId=900;Name=$Name;Serial='SYNTHETIC';EntityId=0;RequiresMappingConfirmation=$false;Keys=@()} }
  function script:Save-RemovalBitLockerBackup { param($Preview,$Targets,$Plan,$ProgressQueue) [void]$script:HybridRemoval.Writes.Add('Backup');[pscustomobject]@{Count=0;Keys=@()} }
  function script:Read-RemovalTargetById { param($Target) $Target }
  function script:Test-RemovalBitLockerCoverage { param($Target,$Receipt) }
  function script:Remove-RemovalTarget { param($Target,$Results,$ProgressQueue) [void]$script:HybridRemoval.Writes.Add($Target.Source+':'+$Target.Name) }
  function script:Clear-ExplorerCloudCache { }
  foreach ($consent in @(@(),@('PC-OTHER'))) {
   $script:HybridRemoval.Writes.Clear();$preview=New-ExplorerRemovalPlan -Names PC-HYBRID -Sources @('AD','Entra') -ConfigPath synthetic.json
   if ($preview.Entries[0].Error -or -not $preview.Entries[0].HybridIdentity.RequiresConfirmation) { throw 'Mismatch disappeared from preview.' }
   $preview.Entries[0].HybridIdentity.RequiresConfirmation=$false
   $result=Invoke-ExplorerRemovalPlan -PlanId $preview.PlanId -ConfirmHybridMismatchFor $consent -Confirm:$false
   if ($script:HybridRemoval.Writes.Count -ne 0 -or $result.Failed -ne 1 -or $result.Results[0].Error -notlike '*discordanza*') { throw 'Missing/foreign hybrid confirmation authorized a write.' }
  }
  $preview=New-ExplorerRemovalPlan -Names PC-HYBRID -Sources @('AD','Entra') -ConfigPath synthetic.json
  $result=Invoke-ExplorerRemovalPlan -PlanId $preview.PlanId -ConfirmHybridMismatchFor PC-HYBRID -Confirm:$false
  if ($result.Failed -ne 0 -or $script:HybridRemoval.Writes.Count -ne 3 -or $script:HybridRemoval.Writes[0] -ne 'Backup') { throw 'Explicit per-computer hybrid consent did not retain verified backup before deletion.' }
  'PASS: a proven hybrid mismatch requires the exact per-computer confirmation before any archive/deletion write, and accepted consent retains backup ordering.'
  $script:HybridRemoval.Writes.Clear();$preview=New-ExplorerRemovalPlan -Names PC-HYBRID -Sources @('AD','Entra') -ConfigPath synthetic.json
  $script:HybridRemoval.Fresh=$true
  $result=Invoke-ExplorerRemovalPlan -PlanId $preview.PlanId -ConfirmHybridMismatchFor PC-HYBRID -Confirm:$false
  if ($script:HybridRemoval.Writes.Count -ne 0 -or $result.Failed -ne 1 -or $result.Results[0].Error -notlike '*cambiata dopo*') { throw 'A changed AD identity reused old consent.' }
  $script:HybridRemoval.Fresh=$false
  foreach ($mode in @('Registered','Offline')) {
   $script:HybridRemoval.Mode=$mode;$preview=New-ExplorerRemovalPlan -Names PC-HYBRID -Sources @('Entra') -ConfigPath synthetic.json
   if ($preview.Entries[0].HybridIdentity.RequiresConfirmation) { throw 'A registered or unavailable identity was treated as a proven mismatch.' }
  }
  $script:HybridRemoval.Mode='Renamed'
  $preview=New-ExplorerRemovalPlan -Names PC-HYBRID -Sources @('Entra') -ConfigPath synthetic.json
  if ($preview.Entries[0].HybridIdentity.State -ne 'Corrisponde' -or $preview.Entries[0].Targets.Count -ne 1 -or $preview.Entries[0].Targets[0].Source -ne 'Entra') { throw 'A renamed GUID match silently added an AD deletion target.' }
  $script:HybridRemoval.Mode='Mismatch';$script:HybridRemoval.Writes.Clear()
  $preview=New-ExplorerRemovalPlan -Names PC-HYBRID -Sources @('AD','Entra') -ConfigPath synthetic.json -ArchiveOnly
  $result=Invoke-ExplorerRemovalPlan -PlanId $preview.PlanId -Confirm:$false
  if ($result.Failed -ne 0 -or $script:HybridRemoval.Writes.Count -ne 1 -or $script:HybridRemoval.Writes[0] -ne 'Backup') { throw 'An informational mismatch blocked archive-only mode or caused a deletion.' }
  'PASS: changed hybrid identities invalidate consent, unavailable/registered identities remain distinct, renamed matches do not add deletion targets and archive-only remains independent.'
 }
}
finally { Remove-Module -ModuleInfo $module -Force }
