#requires -version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $root 'AssistenteIT/AssistenteIT.Core.psm1') -Force -PassThru
$manifest=Read-AssistenteITManifest $root
$entry=$manifest.Modules[0]
$definition=Get-AssistenteITAccessDefinition $manifest.Modules
if ($definition.GraphPermissions.Count -ne 5 -or $definition.NeedsGroupMembership) { throw 'Common login definition duplicated scopes or required unconfigured group discovery.' }
$permissions=@($entry.GraphPermissions | ForEach-Object { [pscustomobject]@{Id=$_.Id;Name=$_.Name;Available=($_.Id -notmatch '-remove$');Detail='Synthetic'} })
$access=[pscustomobject]@{Account='synthetic@example.invalid';ClientId='22222222-2222-4222-8222-222222222222';TenantId='11111111-1111-4111-8111-111111111111';Permissions=$permissions;GroupIds=@();GroupMembershipVerified=$false}
if ((Get-AssistenteITModuleAccess $entry $null).CanOpen) { throw 'Module opened before login.' }
$mode=Get-AssistenteITModuleAccess $entry $access
if (-not $mode.CanOpen -or -not $mode.ReadOnly -or $mode.AccessMode -ne 'ReadOnly') { throw 'Read scopes did not enable a read-only module.' }
$permissions | Where-Object Id -eq 'intune-remove' | ForEach-Object { $_.Available=$true }
if ((Get-AssistenteITModuleAccess $entry $access).AccessMode -ne 'ReadWrite') { throw 'Verified write permission did not enable the module write mode.' }
'PASS: modules remain disabled before login; verified read and write requirements independently select read-only or read/write access.'
$grouped=$entry | Select-Object *
$grouped | Add-Member NoteProperty ReadGroupIds @('33333333-3333-4333-8333-333333333333')
$grouped | Add-Member NoteProperty WriteGroupIds @('44444444-4444-4444-8444-444444444444')
if (-not (Get-AssistenteITAccessDefinition @($grouped)).NeedsGroupMembership) { throw 'Configured colleague groups did not request group verification.' }
$access.GroupMembershipVerified=$true;$access.GroupIds=$grouped.ReadGroupIds
if ((Get-AssistenteITModuleAccess $grouped $access).AccessMode -ne 'ReadOnly') { throw 'Read-group colleague received write access from shared app scopes.' }
$access.GroupIds=$grouped.WriteGroupIds
if ((Get-AssistenteITModuleAccess $grouped $access).AccessMode -ne 'ReadWrite') { throw 'Write-group colleague was not enabled with available scopes.' }
$access.GroupIds=@()
if ((Get-AssistenteITModuleAccess $grouped $access).CanOpen) { throw 'An unassigned colleague could open a group-restricted module.' }
$access.GroupIds=$grouped.WriteGroupIds;$access.GroupMembershipVerified=$false
if ((Get-AssistenteITModuleAccess $grouped $access).CanOpen) { throw 'Unverified memberships were accepted.' }
'PASS: optional Entra groups separate colleagues with identical app scopes into read-only/write/no-access modes and fail closed when group verification is unavailable.'
$access.GroupMembershipVerified=$true
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('hub-readonly-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
try {
 $config=Join-Path $fixture 'config.json'
 @{Graph=@{AuthenticationMode='Delegated';TenantId=$access.TenantId;ClientId=$access.ClientId}} | ConvertTo-Json -Depth 4 | Set-Content $config -Encoding UTF8
 & $module {
  param($Definition,$Config,$Group)
  $script:GroupFixture=@{Context=$null;Requests=0;Mode=''}
  function script:Import-Module { [CmdletBinding()]param($Name) }
  function script:Get-MgContext { [CmdletBinding()]param() return $script:GroupFixture.Context }
  function script:Disconnect-MgGraph { [CmdletBinding()]param() $script:GroupFixture.Context=$null }
  function script:Connect-MgGraph { [CmdletBinding()]param($Scopes,$TenantId,$ClientId,$Environment,$ContextScope,[switch]$NoWelcome)
   $script:GroupFixture.Context=[pscustomobject]@{AuthType='Delegated';Environment='Global';ContextScope='CurrentUser';TenantId=$TenantId;ClientId=$ClientId;Account='synthetic@example.invalid';Scopes=@('Device.Read.All','DeviceManagementManagedDevices.ReadWrite.All','BitlockerKey.Read.All','User.Read')}
  }
  function script:Invoke-MgGraphRequest { [CmdletBinding()]param($Method,$Uri,$OutputType,$Headers)
   if ($Method -ne 'GET') { throw 'Group verification attempted a write.' }
   if ($Uri -like '*transitiveMemberOf*') {
    $script:GroupFixture.Requests++
    if ($script:GroupFixture.Mode -eq 'Denied') { throw 'Synthetic membership denial.' }
    if ($script:GroupFixture.Mode -eq 'BadPage') { return [pscustomobject]@{value=@();'@odata.nextLink'='https://example.invalid/leak'} }
    return [pscustomobject]@{value=@([pscustomobject]@{id=$Group;'@odata.type'='#microsoft.graph.group'})}
   }
   [pscustomobject]@{value=@()}
  }
  $report=Initialize-AssistenteITModuleAccess -Module $Definition -ConfigPath $Config
  if (-not $report.GroupMembershipVerified -or $report.GroupIds.Count -ne 1 -or $report.GroupIds[0] -ne $Group -or $script:GroupFixture.Requests -ne 1) { throw 'Own group memberships were not verified during the common login.' }
  foreach ($case in @('Denied','BadPage')) {
   $script:GroupFixture.Mode=$case
   $report=Initialize-AssistenteITModuleAccess -Module $Definition -ConfigPath $Config
   if ($report.GroupMembershipVerified -or $report.GroupIds.Count -ne 0 -or -not $report.GroupError) { throw 'Failed or unsafe group lookup retained colleague access.' }
  }
 } (Get-AssistenteITAccessDefinition @($grouped)) $config $grouped.ReadGroupIds[0]
 'PASS: optional group discovery reads only the signed-in user memberships and rejects failed or foreign pagination without retaining access.'
}
finally { Remove-Item $fixture -Recurse -Force;Remove-Module -ModuleInfo $module -Force }
$removal=Import-Module (Join-Path $root 'ComputerExplorer.Removal.psm1') -Force -PassThru
try {
 & $removal {
  $script:ReadOnlyBoundaryCalls=0
  function script:Read-ExplorerConfiguration { param($ConfigPath) $script:ReadOnlyBoundaryCalls++;throw 'Should stop before source or credential access.' }
  Set-ExplorerRemovalReadOnly -ReadOnly
  foreach ($operation in @('Prepare','Invoke','Direct')) {
   $rejected=$false
   try {
    if ($operation -eq 'Prepare') { $null=New-ExplorerRemovalPlan -Names PC-TEST -Sources AD -ConfigPath 'synthetic.json' }
    elseif ($operation -eq 'Invoke') { $null=Invoke-ExplorerRemovalPlan -PlanId 'synthetic' -Confirm:$false }
    else { Remove-RemovalTarget -Target ([pscustomobject]@{Source='AD'}) }
   }
   catch { $rejected=$_.Exception.Message -like '*sola lettura*' }
   if (-not $rejected -or $script:ReadOnlyBoundaryCalls -ne 0) { throw 'Read-only mode reached a write or credential boundary.' }
  }
 }
 'PASS: read-only mode blocks deletion and archive planning, execution and direct removal before any source/credential access.'
}
finally { Remove-Module -ModuleInfo $removal -Force }
