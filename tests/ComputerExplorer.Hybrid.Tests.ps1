#requires -version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '../ComputerExplorer.Core.psm1') -Force -PassThru
try {
 & $module {
  $id='00112233-4455-6677-8899-aabbccddeeff';$other='11223344-5566-7788-99aa-bbccddeeff00'
  $controllers=@(1..5 | ForEach-Object { 'dc'+$_+'.invalid' })
  $ad=@($controllers | ForEach-Object { [pscustomobject]@{Name='PC-HYBRID';ObjectGUID=$id;DomainController=$_;DistinguishedName='CN=PC-HYBRID,DC=invalid'} })
  $entra=@([pscustomobject]@{Name='PC-HYBRID';ObjectId=$other;DeviceId=$id.ToUpperInvariant();TrustType='ServerAd'},[pscustomobject]@{Name='PC-HYBRID';ObjectId='22222222-2222-4222-8222-222222222222';DeviceId=$other;TrustType='Workplace'})
  $identity=Get-ExplorerHybridIdentity -Name PC-HYBRID -AdRecords $ad -EntraRecords $entra -AdComplete $true -EntraComplete $true
  if ($identity.State -ne 'Corrisponde' -or $identity.RequiresConfirmation -or $identity.Records.Count -ne 2 -or $identity.Records[1].State -ne 'Non applicabile' -or $identity.Records[0].AdMatches.Count -ne 5) { throw 'Hybrid matching confused object ID, DC replicas or a registered namesake.' }
  if (@(Get-ExplorerHybridLookupIds -EntraRecords $entra -AdRecords $ad -Controllers $controllers).Count) { throw 'Already verified GUIDs triggered unnecessary LDAP enrichment.' }
  'PASS: hybrid comparison uses Device ID, normalizes GUIDs, keeps five DC replicas as one identity and excludes only the registered record from comparison.'
  $stale=$entra[0] | Select-Object *;$stale.ObjectId='33333333-3333-4333-8333-333333333333';$stale.DeviceId=$other
  $identity=Get-ExplorerHybridIdentity -Name PC-HYBRID -AdRecords $ad -EntraRecords @($entra[0],$stale,$entra[1]) -AdComplete $true -EntraComplete $true -LookupComplete $true
  if ($identity.State -ne 'Non corrisponde' -or -not $identity.RequiresConfirmation -or $identity.Records[0].State -ne 'Corrisponde' -or @($identity.Records | Where-Object RequiresConfirmation).Count -ne 1) { throw 'A matching hybrid hid a stale hybrid namesake.' }
  $identity=Get-ExplorerHybridIdentity -Name PC-HYBRID -AdRecords $ad -EntraRecords @($stale) -AdComplete $false -EntraComplete $true -LookupComplete $true -LookupError 'DC non verificato.'
  if ($identity.State -ne 'Non verificabile' -or $identity.RequiresConfirmation) { throw 'Unavailable AD was misreported as a proven mismatch.' }
  $identity=Get-ExplorerHybridIdentity -Name PC-HYBRID -EntraRecords @($entra[0]) -AdComplete $true -EntraComplete $true -LookupComplete $true
  if ($identity.State -ne 'Assente in AD' -or $identity.RequiresConfirmation) { throw 'Verified absence was hidden or treated as a mismatch.' }
  foreach ($trust in @('Workplace','AzureAd','')) {
   $record=$entra[0] | Select-Object *;$record.TrustType=$trust
   $identity=Get-ExplorerHybridIdentity -Name PC-HYBRID -AdRecords $ad -EntraRecords @($record) -EntraComplete $true
   $expected='Non applicabile';if (-not $trust) { $expected='Non verificabile' }
   if ($identity.State -ne $expected -or $identity.RequiresConfirmation) { throw 'A non-hybrid or unknown join gained a false GUID comparison.' }
  }
  'PASS: every Entra registration retains its own result; incomplete reads, verified absence, cloud-only joins and unknown join types have distinct outcomes.'
  $renamed=@($ad | ForEach-Object { $copy=$_ | Select-Object *;$copy.Name='PC-RENAMED';$copy.DistinguishedName='CN=PC-RENAMED,DC=invalid';$copy })
  $identity=Get-ExplorerHybridIdentity -Name PC-HYBRID -AllAdRecords $renamed -EntraRecords @($entra[0]) -AdComplete $true -EntraComplete $true -LookupComplete $true
  if ($identity.State -ne 'Corrisponde' -or $identity.Records[0].AdMatches[0].Name -ne 'PC-RENAMED' -or $identity.Records[0].Detail -notlike '*PC-RENAMED*') { throw 'A renamed GUID match was lost.' }
  $foreign=$ad[0] | Select-Object *;$foreign.ObjectGUID=$other
  $identity=Get-ExplorerHybridIdentity -Name PC-HYBRID -AdRecords @($foreign) -AllAdRecords $renamed -EntraRecords @($entra[0]) -AdComplete $true -EntraComplete $true -LookupComplete $true
  if (-not $identity.RequiresConfirmation -or $identity.Records[0].Detail -notlike '*altro nome*') { throw 'A renamed match silently authorized the foreign AD namesake.' }
  'PASS: GUID correlation recognizes renamed AD objects and separately warns when a different AD namesake would be affected.'
  $script:HybridFixture=@{Queries=(New-Object 'Collections.Generic.List[object]');Mode='';Record=$renamed[0]}
  function script:Import-Module { [CmdletBinding()]param($Name) }
  function script:Get-ADComputer {
   [CmdletBinding()]param($Server,$LDAPFilter,$Properties)
   [void]$script:HybridFixture.Queries.Add([pscustomobject]@{Server=$Server;Filter=$LDAPFilter})
   if (@($Properties | Where-Object { $_ -match 'msFVE|password|keypackage' }).Count) { throw 'Hybrid correlation requested BitLocker data.' }
   if ($script:HybridFixture.Mode -eq 'Offline' -and $Server -eq 'dc5.invalid') { throw 'Synthetic unavailable DC.' }
   $record=$script:HybridFixture.Record | Select-Object *
   if ($script:HybridFixture.Mode -eq 'Foreign') { $record.ObjectGUID='99999999-9999-4999-8999-999999999999' }
   return $record
  }
  $lookup=Read-ExplorerHybridAd -DeviceIds @($id) -Controllers $controllers -Name 'PC*(A)'
  if ($lookup.State -ne 'OK' -or $lookup.Records.Count -ne 5 -or $script:HybridFixture.Queries.Count -ne 5 -or $script:HybridFixture.Queries[0].Filter -notlike '*objectGUID=\33\22\11\00\55\44\77\66\88\99\aa\bb\cc\dd\ee\ff*' -or -not $script:HybridFixture.Queries[0].Filter.Contains('(name=PC\2a\28A\29)')) { throw 'GUID enrichment used the wrong AD byte order or an unescaped name.' }
  foreach ($mode in @('Offline','Foreign')) { $script:HybridFixture.Mode=$mode;$lookup=Read-ExplorerHybridAd -DeviceIds @($id) -Controllers $controllers;if ($lookup.State -ne 'Errore' -or -not $lookup.Error) { throw 'An incomplete or foreign LDAP result was accepted.' } }
  $script:HybridFixture.Mode='';$script:HybridFixture.Queries.Clear()
  $ids=@($id)+@(1..40 | ForEach-Object { ([guid]::NewGuid()).ToString() })
  $lookup=Read-ExplorerHybridAd -DeviceIds $ids -Controllers $controllers
  if ($lookup.State -ne 'OK' -or $script:HybridFixture.Queries.Count -ne 10) { throw 'GUID enrichment did not use bounded batches.' }
  'PASS: metadata-only GUID lookup uses escaped AD byte filters, sequential DCs, bounded batches and explicit incomplete-read/foreign-result outcomes.'
 }
}
finally { Remove-Module -ModuleInfo $module -Force }
