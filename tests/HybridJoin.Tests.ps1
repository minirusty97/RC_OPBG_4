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
    $hybrid.deviceId=$ad.ObjectGUID
    $otherAd=$ad | Select-Object *
    $otherAd.Name='PC-OTHER';$otherAd.ObjectGUID='77777777-7777-4777-8777-777777777777'
    $otherHybrid=$hybrid | Select-Object *
    $otherHybrid.id='88888888-8888-4888-8888-888888888888';$otherHybrid.deviceId='ffffffff-ffff-4fff-8fff-ffffffffffff';$otherHybrid.displayName=$otherAd.Name
    $secondRegistered=$registered | Select-Object *
    $secondRegistered.id='99999999-9999-4999-8999-999999999999';$secondRegistered.deviceId='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';$secondRegistered.displayName=$otherAd.Name
    $intune=[pscustomobject]@{id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';azureADDeviceId=$ad.ObjectGUID;serialNumber='SERIAL-VERIFIED'}
    $falseIntune=[pscustomobject]@{id='cccccccc-cccc-4ccc-8ccc-cccccccccccc';azureADDeviceId=$registered.deviceId;serialNumber='SERIAL-WORKPLACE'}
    $wrongIntune=[pscustomobject]@{id='dddddddd-dddd-4ddd-8ddd-dddddddddddd';azureADDeviceId=$otherHybrid.deviceId;serialNumber='SERIAL-WRONG'}
    $script:HybridSnapshotFixture=@{
        Mode=''; IntuneState='OK'; Ad=$ad; Other=$otherAd; AdServer=''; ExpectedServer='dc1.example.invalid'
        Devices=@($hybrid,$registered,$otherHybrid,$secondRegistered)
        Intune=@($intune,$falseIntune,$wrongIntune)
    }
    function script:Assert-DmSession {param($Access,$ReadIds,$WriteId);if ($WriteId -and $Access.ReadOnly) { throw 'sola lettura' };'synthetic-context'}
    function script:Read-DmSettings {
        param($ConfigPath,$Section)
        [pscustomobject]@{
            Config=[pscustomobject]@{CloudReadTimeoutSeconds=90;Settings=[pscustomobject]@{DomainControllers=@('dc2.example.invalid','dc1.example.invalid','dc3.example.invalid')}}
            Options=[pscustomobject]@{AdServer=$script:HybridSnapshotFixture.AdServer;SearchScope='Subtree';TargetOus=@('OU=Lab','OU=Child,OU=Lab','OU=Empty')}
        }
    }
    function script:Get-HybridReadSources {
        param($Controller,$Query,$Access,$Queue,$CloudTimeoutSeconds)
        $fixture=$script:HybridSnapshotFixture
        if ($Controller -ne $fixture.ExpectedServer -or $Query.SearchScope -ne 'Subtree') { throw 'Configured DC or search scope changed.' }
        if ($fixture.Mode -eq 'OuDenied') { throw 'Synthetic OU denial.' }
        $found=@($fixture.Ad,$fixture.Other | Select-Object * -ExcludeProperty HostKey,OUName,OUDistinguishedName)
        $data=[pscustomobject]@{Ous=@(
            [pscustomobject]@{Name='Lab';DistinguishedName='OU=Lab,DC=example,DC=invalid';Computers=$found}
            [pscustomobject]@{Name='Child';DistinguishedName='OU=Child,OU=Lab,DC=example,DC=invalid';Computers=@($fixture.Ad | Select-Object * -ExcludeProperty HostKey,OUName,OUDistinguishedName)}
            [pscustomobject]@{Name='Empty';DistinguishedName='OU=Empty,DC=example,DC=invalid';Computers=@()}
        )}
        [pscustomobject]@{AD=$data;AdSeconds=1;Entra=$fixture.Devices;Intune=[pscustomobject]@{Records=$fixture.Intune;State=$fixture.IntuneState;Error=''}}
    }
    $access=[pscustomobject]@{ReadOnly=$false}
    $snapshot=Get-HybridJoinSnapshot -ConfigPath synthetic -EnvPath synthetic -GraphAccess $access
    $known=$snapshot.Rows | Where-Object Name -eq $ad.Name
    $other=$snapshot.Rows | Where-Object Name -eq $otherAd.Name
    if ($snapshot.Rows.Count -ne 2 -or $known.EntraCount -ne 2 -or $known.IdentityState -ne 'Corrisponde' -or
        $known.IntuneSerial -ne 'SERIAL-VERIFIED' -or $known.IntuneState -ne 'OK' -or -not $known.PSObject.Properties['GlpiDepartment'] -or
        $other.IdentityState -ne 'Non corrisponde' -or $other.IntuneSerial -or $other.IntuneState -ne 'Da regolarizzare' -or
        $snapshot.Sources.AdServer -ne 'dc1.example.invalid') {
        throw 'The OU inventory lost the verified identity or included Workplace or mismatched serials.'
    }
    $lab=$snapshot.OuStatistics | Where-Object Name -eq 'Lab'
    $child=$snapshot.OuStatistics | Where-Object Name -eq 'Child'
    $empty=$snapshot.OuStatistics | Where-Object Name -eq 'Empty'
    if ($lab.Count -ne 2 -or $lab.IntuneOk -ne 1 -or $lab.IntuneUnknown -ne 0 -or $child.Count -ne 1 -or $child.IntuneOk -ne 1 -or
        $empty.Count -ne 0 -or $snapshot.Statistics.Computers -ne 2 -or $snapshot.Statistics.IntuneOk -ne 1 -or
        $snapshot.Statistics.RegisteredComputers -ne 2 -or $known.OUName -ne 'Child; Lab') {
        throw 'Per-OU and general counters failed to handle overlap, a wrong-GUID device, or an empty OU.'
    }
    'PASS: Hybrid counts unique AD devices globally and per OU, uses a single DC and correlates the correct Windows Intune record.'
    $script:HybridSnapshotFixture.AdServer='dc2.example.invalid'
    $script:HybridSnapshotFixture.ExpectedServer='dc2.example.invalid'
    $snapshot=Get-HybridJoinSnapshot -ConfigPath synthetic -EnvPath synthetic -GraphAccess $access
    if ($snapshot.Sources.AdServer -ne 'dc2.example.invalid') { throw 'Explicit Hybrid DC did not override the default.' }
    $duplicateIntune=$intune | Select-Object *
    $duplicateIntune.id='eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'
    $script:HybridSnapshotFixture.Intune+=@($duplicateIntune)
    $snapshot=Get-HybridJoinSnapshot -ConfigPath synthetic -EnvPath synthetic -GraphAccess $access
    if ($snapshot.Statistics.IntuneOk -ne 0 -or ($snapshot.Rows | Where-Object Name -eq $ad.Name).IntuneReason -notlike '*Più record*') { throw 'Duplicate Intune records were counted as verified.' }
    $script:HybridSnapshotFixture.IntuneState='Errore'
    $snapshot=Get-HybridJoinSnapshot -ConfigPath synthetic -EnvPath synthetic -GraphAccess $access
    if ($snapshot.Statistics.IntuneUnknown -ne 2 -or $snapshot.Statistics.IntuneOk -ne 0) { throw 'Intune source errors produced false missing enrollments.' }
    'PASS: duplicate Intune records stay unresolved, and an unavailable Intune source reports unverified counts.'
    function script:Get-DmGraphItems {param($Uri);if ($Uri -like '*registeredUsers*') { throw 'Synthetic user relationship denial.' };@(@{id='66666666-6666-4666-8666-666666666666'})}
    $result=Get-HybridCleanupCandidates -GraphAccess $access
    if ($result.Candidates.Count -ne 2 -or $result.Candidates.ObjectId -notcontains $registered.id -or $result.Candidates.ObjectId -notcontains $secondRegistered.id -or
        $result.Candidates[0].Users -notlike '*Utente non risolto*' -or $result.Candidates[0].UserNotes -notlike '*registeredUsers*') {
        throw 'Cleanup failed to include all snapshot Workplace candidates or concealed unresolved users.'
    }
    $failed=$false
    try { New-HybridCleanupPlan -ObjectIds @($hybrid.id) -ConfigPath synthetic -EnvPath synthetic -GraphAccess $access } catch { $failed=$_.Exception.Message -like '*selezione verificata*' }
    if (-not $failed) { throw 'A UI-supplied Object ID outside the Workplace candidates prepared a plan.' }
    $access.ReadOnly=$true
    $failed=$false
    try { New-HybridCleanupPlan -ObjectIds @($registered.id) -ConfigPath synthetic -EnvPath synthetic -GraphAccess $access } catch { $failed=$_.Exception.Message -like '*sola lettura*' }
    if (-not $failed) { throw 'Read-only Hybrid mode prepared a write plan.' }
    'PASS: cleanup verifies all Workplace registrations from the private snapshot, while a write plan requires verified Object IDs and write access.'
    $script:HybridSnapshotFixture.Mode='OuDenied'
    $failed=$false
    try { $null=Get-HybridJoinSnapshot -ConfigPath synthetic -EnvPath synthetic -GraphAccess $access } catch { $failed=$_.Exception.Message -like '*Synthetic OU denial*' }
    if (-not $failed -or $script:HybridRows.Count -or $script:HybridCandidates.Count) { throw 'An unreadable OU published a false empty or stale comparison.' }
    'PASS: failure to read an OU on the configured DC clears the candidate state and fails the scan explicitly.'

 }
}
finally { Remove-Module -ModuleInfo $module -Force }
