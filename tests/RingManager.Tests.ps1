#requires -version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $root 'RingManager.Core.psm1') -Force -PassThru
try {
 & $module {
    function script:Ring-TestId {param([int]$N);('{0:x8}-0000-4000-8000-000000000001' -f $N)}
    $script:RingFixture=@{Mode='';Posts=0;Contexts=0;Access=[pscustomobject]@{ReadOnly=$false};Groups=@();Devices=@()}
    function script:Reset-RingFixture {
        $script:RingFixture.Mode='';$script:RingFixture.Posts=0;$script:RingFixture.Access.ReadOnly=$false
        $script:RingFixture.Groups=@(1..2 | ForEach-Object { [pscustomobject]@{id=(Ring-TestId $_);displayName=('GROUP-'+$_);groupTypes=@();securityEnabled=$true;mailEnabled=$false;isAssignableToRole=$false;onPremisesSyncEnabled=$null} })
        $script:RingFixture.Devices=@(11..14 | ForEach-Object { [pscustomobject]@{id=(Ring-TestId $_);deviceId=(Ring-TestId ($_+100));displayName=('PC-'+$_);trustType='ServerAd';deviceOwnership='company';isManaged=$true;accountEnabled=$true;operatingSystem='Windows';approximateLastSignInDateTime=$null} })
        $script:RingFixture.Devices[2].accountEnabled=$false;$script:RingFixture.Devices[3].trustType='AzureAd'
    }
    function script:Assert-DmSession {param($Access,$ReadIds,$WriteId);if ($Access.ReadOnly -and $WriteId) { throw 'sola lettura' };if ($script:RingFixture.Mode -eq 'ForeignSession') { return 'foreign-context' };'synthetic-context'}
    function script:Read-DmSettings {param($ConfigPath,$Section);[pscustomobject]@{Config=[pscustomobject]@{};Options=[pscustomobject]@{Groups=@([pscustomobject]@{Id=(Ring-TestId 1);Name='OLD-NAME';Label='Ring1';CanAssign=$true},[pscustomobject]@{Id=(Ring-TestId 2);Name='GROUP-2';Label='Ring2';CanAssign=$false})}}}
    function script:Get-DmEntraInventory {param($ProgressQueue);$script:RingFixture.Devices}
    function script:Add-DmInventory {param($Rows,$Config,$Access,$EnvPath,$ProgressQueue);[pscustomobject]@{IntuneState='OK';GlpiState='OK';IntuneError='';GlpiError=''}}
    function script:Get-DmGraphItems {
        param($Uri,$ProgressQueue)
        if ($Uri -match '/groups/([^/]+)/transitiveMembers') {
            if ($script:RingFixture.Mode -eq 'MembershipDenied') { throw 'Synthetic membership denial.' }
            if ($Matches[1] -eq (Ring-TestId 2)) { return @(@{id=(Ring-TestId 12)}) };return @()
        }
        if ($Uri -like '*/transitiveMemberOf*') { if ($script:RingFixture.Mode -eq 'NewMembership') { return @(@{id=(Ring-TestId 2)}) };return @() }
        throw ('Unexpected collection in Ring fixture: '+$Uri)
    }
    function script:Invoke-MgGraphRequest {
        [CmdletBinding()]param($Method,$Uri,$OutputType,$Body,$ContentType)
        if ($Method -eq 'POST') {
            if ($Uri -notmatch '/groups/00000001-0000-4000-8000-000000000001/members/\$ref$' -or (($Body | ConvertFrom-Json).'@odata.id') -notmatch '/devices/0000000b-0000-4000-8000-000000000001$') { throw 'Assignment used a Device ID or an unselected group.' }
            $script:RingFixture.Posts++;return
        }
        if ($Uri -match '/groups/([^/?]+)\?') {
            $group=@($script:RingFixture.Groups | Where-Object id -eq $Matches[1])[0] | Select-Object *
            if ($script:RingFixture.Mode -eq 'Dynamic') { $group.groupTypes=@('DynamicMembership') }
            if ($script:RingFixture.Mode -eq 'MissingGroup') { throw 'Synthetic group unavailable.' }
            return $group
        }
        if ($Uri -match '/devices/([^/?]+)\?') {
            $device=@($script:RingFixture.Devices | Where-Object id -eq $Matches[1])[0] | Select-Object *
            if ($script:RingFixture.Mode -eq 'Renamed') { $device.displayName='CHANGED' }
            return $device
        }
        if ($Uri -match '/groups/[^/]+/members/([^/?]+)\?') { if ($script:RingFixture.Mode -eq 'VerifyDenied') { throw 'Synthetic readback denial.' };return @{id=$Matches[1]} }
        throw ('Unexpected Graph request in Ring fixture: '+$Method+' '+$Uri)
    }
    Reset-RingFixture
    $access=$script:RingFixture.Access
    $snapshot=Get-RingManagerSnapshot -ConfigPath synthetic -EnvPath synthetic -GraphAccess $access
    if ($snapshot.Rows.Count -ne 2 -or @($snapshot.Rows | Where-Object Orphan).Count -ne 1 -or @($snapshot.Rows | Where-Object ObjectId -eq (Ring-TestId 12))[0].State -ne 'Assegnato' -or $script:RingFixture.Posts) { throw 'Orphan discovery ignored monitored-only groups, admitted non-Windows/non-Hybrid/disabled devices or wrote memberships.' }
    if ($snapshot.Groups[0].Name -notcontains 'GROUP-1' -and @($snapshot.Groups | Where-Object Name -eq 'GROUP-1').Count -ne 1) { throw 'A pinned group ID was replaced by the old display name.' }
    'PASS: Ring discovery uses selected group Object IDs, tolerates group renames, checks monitored-only memberships and limits candidates to enabled Windows Hybrid Corporate MDM devices.'
    $assignment=@([pscustomobject]@{ObjectId=(Ring-TestId 11);TargetRing='Ring1'})
    $plan=New-RingAssignmentPlan -Assignments $assignment -ConfigPath synthetic -GraphAccess $access
    $plan.Items[0].ObjectId=Ring-TestId 12
    $result=Invoke-RingAssignmentPlan -PlanId $plan.PlanId -GraphAccess $access -Confirm:$false
    if ($result.Assigned -ne 1 -or $script:RingFixture.Posts -ne 1 -or $result.Results[0].ObjectId -ne (Ring-TestId 11)) { throw 'Assignment lost its canonical object binding or lacked readback.' }
    $failed=$false;try { Invoke-RingAssignmentPlan -PlanId $plan.PlanId -GraphAccess $access -Confirm:$false } catch { $failed=$true };if (-not $failed) { throw 'A consumed plan could be replayed.' }
    'PASS: confirmed Ring assignments use the exact Entra Object ID, preserve private plans against UI edits, verify membership after POST and consume each plan once.'
    foreach ($mode in @('Dynamic','MissingGroup','Renamed','NewMembership','ForeignSession')) {
        Reset-RingFixture;$null=Get-RingManagerSnapshot -ConfigPath synthetic -EnvPath synthetic -GraphAccess $access
        $plan=New-RingAssignmentPlan -Assignments $assignment -ConfigPath synthetic -GraphAccess $access
        $script:RingFixture.Mode=$mode;$result=$null
        try { $result=Invoke-RingAssignmentPlan -PlanId $plan.PlanId -GraphAccess $access -Confirm:$false } catch { }
        if ($script:RingFixture.Posts -ne 0 -or ($null -ne $result -and $result.Assigned -ne 0)) { throw ('Stale assignment wrote after: '+$mode) }
    }
    'PASS: dynamic/missing groups, renamed devices, new memberships in any selected Ring and changed sessions block stale assignments before POST.'
    Reset-RingFixture;$null=Get-RingManagerSnapshot -ConfigPath synthetic -EnvPath synthetic -GraphAccess $access
    $plan=New-RingAssignmentPlan -Assignments $assignment -ConfigPath synthetic -GraphAccess $access
    $result=Invoke-RingAssignmentPlan -PlanId $plan.PlanId -GraphAccess $access -WhatIf
    if ($script:RingFixture.Posts -ne 0 -or $result.Results[0].State -ne 'Simulato') { throw 'WhatIf modified a membership.' }
    $access.ReadOnly=$true;$failed=$false;try { New-RingAssignmentPlan -Assignments $assignment -ConfigPath synthetic -GraphAccess $access } catch { $failed=$_.Exception.Message -like '*sola lettura*' };if (-not $failed) { throw 'Read-only Ring mode prepared assignments.' }
    Reset-RingFixture;$script:RingFixture.Mode='MembershipDenied';$failed=$false;try { $null=Get-RingManagerSnapshot -ConfigPath synthetic -EnvPath synthetic -GraphAccess $access } catch { $failed=$true };if (-not $failed -or $script:RingRows.Count) { throw 'Incomplete group reads published false orphans.' }
    'PASS: WhatIf and read-only guards prevent writes; an unreadable monitored group clears candidate state instead of publishing false orphans.'
 }
}
finally { Remove-Module -ModuleInfo $module -Force }
