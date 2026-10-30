#requires -version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $root 'HybridJoin.Core.psm1') -Force -PassThru
try {
 & $module {
    $ad=[pscustomobject]@{Name='PC-SYNTHETIC';HostKey='PC-SYNTHETIC';ObjectGUID='11111111-1111-4111-8111-111111111111';DNSHostName='PC-SYNTHETIC.example.invalid';OUName='Lab';OUDistinguishedName='OU=Lab,DC=example,DC=invalid';DistinguishedName='CN=PC-SYNTHETIC,OU=Lab,DC=example,DC=invalid';Enabled=$true;OperatingSystem='Windows';OperatingSystemVersion='';LastLogonDate=$null;PasswordLastSet=$null}
    $hybrid=[pscustomobject]@{id='22222222-2222-4222-8222-222222222222';deviceId=$ad.ObjectGUID;displayName='RENAMED';trustType='ServerAd';deviceOwnership='company';isManaged=$true;accountEnabled=$true}
    $registered=[pscustomobject]@{id='33333333-3333-4333-8333-333333333333';deviceId='44444444-4444-4444-8444-444444444444';displayName=$ad.Name;trustType='Workplace';deviceOwnership='personal';isManaged=$false;accountEnabled=$true}
    $row=New-HybridComparison $ad @($hybrid,$registered)
    if ($row.IdentityState -ne 'Corrisponde' -or $row.RegisteredCount -ne 1 -or $row.HybridState -ne 'HYBRID OK') { throw 'A registered Device ID interfered with hybrid GUID comparison.' }
    $hybrid.deviceId='55555555-5555-4555-8555-555555555555'
    $row=New-HybridComparison $ad @($hybrid)
    if ($row.IdentityState -ne 'Non corrisponde' -or $row.Severity -ne 'Error') { throw 'A namesake with the wrong GUID was reported as healthy.' }
    $row=New-HybridComparison $ad @($registered)
    if ($row.IdentityState -ne 'Non applicabile' -or $row.HybridCount -ne 0) { throw 'Workplace was treated as an AD GUID identity.' }
    'PASS: Hybrid Join compares AD ObjectGUID with ServerAd Device ID, identifies mismatches and ignores GUID comparison for Workplace.'
    $script:HybridSnapshotFixture=@{Mode='';Ad=$ad;Devices=@($hybrid,$registered);Server=''}
    function script:Assert-DmSession {param($Access,$ReadIds,$WriteId);'synthetic-context'}
    function script:Import-Module { [CmdletBinding()]param($Name) if ($Name -ne 'ActiveDirectory') { throw 'Unexpected module import in snapshot.' } }
    function script:Read-DmSettings {param($ConfigPath,$Section);[pscustomobject]@{Config=[pscustomobject]@{Settings=[pscustomobject]@{DomainControllers=@('dc.example.invalid')}};Options=[pscustomobject]@{AdServer='';SearchScope='Subtree';TargetOus=@('OU=Lab','OU=Child,OU=Lab')}}}
    function script:Get-ADDomain { [CmdletBinding()]param($Server);$script:HybridSnapshotFixture.Server=$Server;[pscustomobject]@{DistinguishedName='DC=example,DC=invalid'} }
    function script:Get-ADOrganizationalUnit { [CmdletBinding()]param($Server,$Identity);if ($script:HybridSnapshotFixture.Mode -eq 'OuDenied') { throw 'Synthetic OU denial.' };[pscustomobject]@{Name='Lab';DistinguishedName=$Identity} }
    function script:Get-ADComputer { [CmdletBinding()]param($Server,$Filter,$SearchBase,$SearchScope,$Properties);$script:HybridSnapshotFixture.Ad }
    function script:Get-DmEntraInventory {param($ProgressQueue);$script:HybridSnapshotFixture.Devices}
    function script:Add-DmInventory {param($Rows,$Config,$Access,$EnvPath,$ProgressQueue);[pscustomobject]@{IntuneState='OK';GlpiState='OK';IntuneError='';GlpiError=''}}
    $hybrid.deviceId=$ad.ObjectGUID
    $snapshot=Get-HybridJoinSnapshot -ConfigPath synthetic -EnvPath synthetic -GraphAccess ([pscustomobject]@{})
    if ($snapshot.Rows.Count -ne 1 -or $snapshot.Rows[0].EntraCount -ne 2 -or $snapshot.Rows[0].IdentityState -ne 'Corrisponde' -or $script:HybridSnapshotFixture.Server -ne 'dc.example.invalid') { throw 'OU snapshot duplicated overlapping objects or lost renamed GUID-matched Hybrid registrations.' }
    $script:HybridSnapshotFixture.Mode='OuDenied';$failed=$false;try { $null=Get-HybridJoinSnapshot -ConfigPath synthetic -EnvPath synthetic -GraphAccess ([pscustomobject]@{}) } catch { $failed=$true }
    if (-not $failed -or $script:HybridRows.Count) { throw 'An unreadable OU published a false empty or stale comparison.' }
    'PASS: the OU snapshot uses the configured DC, deduplicates overlapping OU objects by GUID, finds renamed Hybrid registrations by GUID and clears candidate state on AD read failure.'
    $script:HybridContext='synthetic-context';$script:HybridRows=@{}
    $hybrid.deviceId=$ad.ObjectGUID
    $row=New-HybridComparison $ad @($hybrid,$registered);$script:HybridRows[$row.Key]=$row
    function script:Assert-DmSession {param($Access,$ReadIds,$WriteId);if ($WriteId -and $Access.ReadOnly) { throw 'sola lettura' };'synthetic-context'}
    function script:Get-DmGraphItems {param($Uri);if ($Uri -like '*registeredUsers*') { throw 'Synthetic user relationship denial.' };@(@{id='66666666-6666-4666-8666-666666666666'})}
    $access=[pscustomobject]@{ReadOnly=$false}
    $result=Get-HybridCleanupCandidates -RowKeys @($row.Key) -GraphAccess $access
    if ($result.Candidates.Count -ne 1 -or $result.Candidates[0].ObjectId -ne $registered.id -or $result.Candidates[0].Users -notlike '*Utente non risolto*' -or $result.Candidates[0].UserNotes -notlike '*registeredUsers*') { throw 'Cleanup candidates expanded to hybrid objects or concealed unavailable user information.' }
    $failed=$false;try { Get-HybridCleanupCandidates -RowKeys unknown -GraphAccess $access } catch { $failed=$true };if (-not $failed) { throw 'Unknown UI rows could invent cleanup candidates.' }
    $access.ReadOnly=$true;$failed=$false;try { New-HybridCleanupPlan -ObjectIds @($registered.id) -ConfigPath synthetic -EnvPath synthetic -GraphAccess $access } catch { $failed=$_.Exception.Message -like '*sola lettura*' };if (-not $failed) { throw 'Read-only Hybrid mode prepared a write plan.' }
    'PASS: Registered cleanup exposes only private-snapshot Workplace candidates, retains unresolved-user warnings and blocks read-only preparation before credentials or writes.'
 }
}
finally { Remove-Module -ModuleInfo $module -Force }
