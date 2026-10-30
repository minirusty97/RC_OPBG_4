#requires -version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $root 'ComputerExplorer.Removal.psm1') -Force -PassThru
try {
 & $module {
  $script:Loss=@{Mode='';Writes=(New-Object 'Collections.Generic.List[string]');Archives=(New-Object 'Collections.Generic.List[string]');Reads=0}
  function script:Read-ExplorerConfiguration { param($ConfigPath) [pscustomobject]@{GraphAuthentication=$null;Settings=[pscustomobject]@{DomainControllers=@();Glpi=@{Enabled=$true}}} }
  function script:Initialize-RemovalSources { param($Sources,$ProgressQueue,$ArchiveOnly,$GraphAuthentication) }
  function script:Get-RemovalContextKey { param($Sources) 'synthetic-account' }
  function script:Get-RemovalTargets {
   param($Name,$Sources,$Controllers)
   [pscustomobject]@{Name=$Name;Source='Entra';Id='11111111-1111-4111-8111-111111111111';LinkId='22222222-2222-4222-8222-222222222222';DomainController='';DistinguishedName='';SerialNumber='';OperatingSystem=''}
  }
  function script:Read-RemovalTargetById { param($Target) return $Target | Select-Object * }
  function script:Get-ExplorerBitLockerKeys {
   param($Targets)
   $script:Loss.Reads++
   if ($script:Loss.Mode -eq 'ReadError') { throw 'Synthetic key read denied.' }
   $fingerprint='a'*64;if ($script:Loss.Mode -eq 'ChangedKeys') { $fingerprint='b'*64 }
   [pscustomobject]@{KeyId='33333333-3333-4333-8333-333333333333';Fingerprint=$fingerprint;Password=(@(1..8 | ForEach-Object { '000011' }) -join '-');Volume='OS';CreatedAt='';Origins=@('Entra:22222222-2222-4222-8222-222222222222')}
  }
  function script:Get-RemovalBitLockerPreview {
   param($Name,$Targets,$Settings,$Credentials,[switch]$AllowUnmappedGlpi)
   $available=$Name -eq 'PC-UNIQUE'
   if ($script:Loss.Mode -eq 'PreviewError') { throw 'Synthetic unreadable recovery keys.' }
   if (-not $available -and -not $AllowUnmappedGlpi) { throw 'Strict archive requires a unique GLPI asset.' }
   $keys=@(Get-ExplorerBitLockerKeys $Targets | Select-Object KeyId,Fingerprint,Volume,CreatedAt,Origins)
   [pscustomobject]@{ComputerId=$(if($available){901}else{0});Name=$Name;GlpiName=$(if($available){$Name}else{''});Serial='SERIAL-A';EntityId=0;RequiresMappingConfirmation=$false;ArchiveAvailable=$available;GlpiMatchCount=$(if($available){1}else{2});MatchBy='Serial';Warning='Synthetic GLPI duplicates';Keys=$keys}
  }
  function script:Save-RemovalBitLockerBackup { param($Preview,$Targets,$Plan,$ProgressQueue) [void]$script:Loss.Archives.Add($Preview.Name);[pscustomobject]@{Count=$Preview.Keys.Count;Keys=$Preview.Keys} }
  function script:Remove-RemovalTarget { param($Target,$Results,$ProgressQueue) [void]$script:Loss.Writes.Add($Target.Name) }
  function script:Clear-ExplorerCloudCache {}
  function Reset-Loss { $script:Loss.Mode='';$script:Loss.Writes.Clear();$script:Loss.Archives.Clear();$script:Loss.Reads=0 }
  foreach ($consents in @(@(),@('OTHER-PC'))) {
   Reset-Loss;$plan=New-ExplorerRemovalPlan -Names PC-AMBIGUOUS -Sources Entra -ConfigPath synthetic.json
   if ($plan.Entries[0].Error -or $plan.Entries[0].Backup.ArchiveAvailable -or ($plan | ConvertTo-Json -Depth 8) -match '000011-000011') { throw 'GLPI ambiguity is still a hard preview block or exposes passwords.' }
   $result=Invoke-ExplorerRemovalPlan -PlanId $plan.PlanId -ConfirmBitLockerLossFor $consents -Confirm:$false
   if ($result.Deleted -ne 0 -or $result.Failed -ne 1 -or $script:Loss.Writes.Count -or $script:Loss.Archives.Count) { throw 'Missing or unrelated loss consent allowed deletion.' }
  }
  'PASS: GLPI ambiguity produces a warning-only preview with metadata; a missing or foreign per-computer confirmation still prevents every write.'
  Reset-Loss;$plan=New-ExplorerRemovalPlan -Names PC-AMBIGUOUS,PC-UNIQUE -Sources Entra -ConfigPath synthetic.json
  $keys=@(Get-ExplorerRemovalPlanKeys -PlanId $plan.PlanId -Names PC-AMBIGUOUS)
  if ($keys.Count -ne 1 -or -not $keys[0].Password -or $script:Loss.Writes.Count -or $script:Loss.Archives.Count) { throw 'Explicit copy retrieval failed or modified a service.' }
  $text=ConvertTo-ExplorerBitLockerRecoveryText -Records $keys
  if ($text -notlike '*PC-AMBIGUOUS*SERIAL-A*33333333-3333-4333-8333-333333333333*000011-000011*') { throw 'Recovery report lacks hardware/key identity or the printable recovery password.' }
  $result=Invoke-ExplorerRemovalPlan -PlanId $plan.PlanId -ConfirmBitLockerLossFor PC-AMBIGUOUS -Confirm:$false
  if ($result.Deleted -ne 2 -or $script:Loss.Archives.Count -ne 1 -or $script:Loss.Archives[0] -ne 'PC-UNIQUE' -or @($result.Results | Where-Object State -eq 'Senza archivio GLPI').Count -ne 1) { throw 'Explicit override affected a uniquely mapped asset or still blocked the ambiguous asset.' }
  'PASS: explicit key-copy requests do not consume the plan; confirmed unmapped PCs delete without GLPI writes while uniquely mapped PCs retain their verified archive.'
  foreach ($mode in @('PreviewError','ReadError','ChangedKeys')) {
   Reset-Loss
   if ($mode -eq 'PreviewError') { $script:Loss.Mode=$mode }
   $plan=New-ExplorerRemovalPlan -Names PC-AMBIGUOUS -Sources Entra -ConfigPath synthetic.json
   $script:Loss.Mode=$mode
   $result=Invoke-ExplorerRemovalPlan -PlanId $plan.PlanId -ConfirmBitLockerLossFor PC-AMBIGUOUS -Confirm:$false
   if ($result.Deleted -or $script:Loss.Writes.Count -or $script:Loss.Archives.Count) { throw ('Loss consent bypassed another failure: '+$mode) }
  }
  'PASS: loss confirmation does not bypass unreadable keys, failed preview validation or changed recovery-key fingerprints.'
  Reset-Loss;$plan=New-ExplorerRemovalPlan -Names PC-AMBIGUOUS -Sources Entra -ConfigPath synthetic.json
  $result=Invoke-ExplorerRemovalPlan -PlanId $plan.PlanId -ConfirmBitLockerLossFor PC-AMBIGUOUS -WhatIf
  if ($result.WritesAttempted -or $script:Loss.Writes.Count -or $script:Loss.Archives.Count) { throw 'WhatIf performed a write through the loss exception.' }
  $strict=New-ExplorerRemovalPlan -Names PC-AMBIGUOUS -Sources Entra -ConfigPath synthetic.json -ArchiveOnly
  if ([string]::IsNullOrWhiteSpace($strict.Entries[0].Error)) { throw 'Archive-only mode accepted an absent GLPI destination.' }
  'PASS: WhatIf remains read-only and archive-only plans cannot use the deletion exception as a GLPI archive.'
 }
}
finally { Remove-Module -ModuleInfo $module -Force }
