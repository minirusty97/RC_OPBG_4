#requires -version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $root 'RingManager.Core.psm1') -Force -PassThru
try {
 & $module {
    function script:Ring-TestId {param([int]$N);('{0:x8}-0000-4000-8000-000000000001' -f $N)}
    $script:RingFixture=@{Access=[pscustomobject]@{ReadOnly=$false}}
    function script:Reset-RingFixture {
        $f=$script:RingFixture;$f.Mode='';$f.Access.ReadOnly=$false;$f.CanMove=$false;$f.Writes=New-Object 'Collections.Generic.List[object]'
        $f.Groups=@(1..2 | ForEach-Object { [pscustomobject]@{id=(Ring-TestId $_);displayName=('GROUP-'+$_);groupTypes=@();securityEnabled=$true;mailEnabled=$false;isAssignableToRole=$null;onPremisesSyncEnabled=$null} })
        $f.Devices=@(11..14 | ForEach-Object { [pscustomobject]@{id=(Ring-TestId $_);deviceId=(Ring-TestId ($_+100));displayName=('PC-'+$_);trustType='ServerAd';deviceOwnership='company';isManaged=$true;accountEnabled=$true;operatingSystem='Windows';approximateLastSignInDateTime=$null} })
        $f.Devices[2].accountEnabled=$false;$f.Devices[3].trustType='AzureAd'
        $f.Members=@{};foreach ($device in $f.Devices) { $f.Members[$device.id]=@() };$f.Members[(Ring-TestId 12)]=@((Ring-TestId 2))
    }
    function script:Assert-DmSession {param($Access,$ReadIds,$WriteId);if ($Access.ReadOnly -and $WriteId) { throw 'sola lettura' };if ($script:RingFixture.Mode -eq 'ForeignSession') { return 'foreign-context' };'synthetic-context'}
    function script:Read-DmSettings {param($ConfigPath,$Section);[pscustomobject]@{Config=[pscustomobject]@{};Options=[pscustomobject]@{Groups=@([pscustomobject]@{Id=(Ring-TestId 1);Name='OLD-NAME';Label='Ring1';CanAssign=$true},[pscustomobject]@{Id=(Ring-TestId 2);Name='GROUP-2';Label='Ring2';CanAssign=$script:RingFixture.CanMove})}}}
    function script:Get-DmEntraInventory {param($ProgressQueue);$script:RingFixture.Devices}
    function script:Add-DmInventory {param($Rows,$Config,$Access,$EnvPath,$ProgressQueue,[switch]$IncludeSupplier);if (-not $IncludeSupplier) { throw 'Ring inventory did not request the GLPI supplier.' };[pscustomobject]@{IntuneState='OK';GlpiState='OK';IntuneError='';GlpiError=''}}
    function script:Get-FixtureMembership {
        param($Id,[switch]$Transitive)
        $f=$script:RingFixture;$ids=@($f.Members[$Id])
        if ($Transitive -and $Id -eq (Ring-TestId 12) -and $f.Mode -eq 'Inherited') { $ids+=@((Ring-TestId 2)) }
        if ($Id -eq (Ring-TestId 11) -and $f.Mode -eq 'NewMembership') { $ids+=@((Ring-TestId 2)) }
        @($ids | Sort-Object -Unique | ForEach-Object { @{id=$_} })
    }
    function script:Get-DmGraphItems {
        param($Uri,$ProgressQueue)
        if ($Uri -match '/groups/([^/]+)/transitiveMembers') {
            if ($script:RingFixture.Mode -eq 'MembershipDenied') { throw 'Synthetic membership denial.' }
            $group=$Matches[1]
            foreach ($device in $script:RingFixture.Devices) { $all=@(Get-FixtureMembership $device.id -Transitive | ForEach-Object { $_.id });if ($all -contains $group) { @{id=$device.id} } }
            if ($group -eq (Ring-TestId 2)) { @{id=(Ring-TestId 42)} }
            return
        }
        if ($Uri -match '/devices/([^/]+)/(memberOf|transitiveMemberOf)') { Get-FixtureMembership $Matches[1] -Transitive:($Matches[2] -eq 'transitiveMemberOf');return }
        throw ('Unexpected collection in Ring fixture: '+$Uri)
    }
    function script:Invoke-MgGraphRequest {
        [CmdletBinding()]param($Method,$Uri,$OutputType,$Body,$ContentType)
        $f=$script:RingFixture
        if ($Method -in @('POST','DELETE')) {
            if ($Uri -notmatch '/groups/([^/]+)/members(?:/([^/]+))?/\$ref$') { throw 'A membership mutation omitted literal /$ref or targeted another resource.' }
            $group=$Matches[1];$object=$Matches[2]
            if ($Method -eq 'POST') { $object=(($Body|ConvertFrom-Json).'@odata.id' -split '/')[-1] }
            if ($object -notin @((Ring-TestId 11),(Ring-TestId 12)) -or $group -notin @((Ring-TestId 1),(Ring-TestId 2))) { throw 'A write used a Device ID or unconfigured object.' }
            [void]$f.Writes.Add([pscustomobject]@{Method=$Method;GroupId=$group;ObjectId=$object;Uri=$Uri})
            if ($f.Mode -eq 'PostDenied' -and $Method -eq 'POST') { throw 'Synthetic add denial.' }
            if ($f.Mode -eq 'DeleteDenied' -and $Method -eq 'DELETE') { throw 'Synthetic removal denial.' }
            if ($Method -eq 'POST') { $f.Members[$object]=@(@($f.Members[$object])+@($group)|Sort-Object -Unique) }
            else { $f.Members[$object]=@($f.Members[$object]|Where-Object {$_ -ne $group}) }
            return
        }
        if ($Uri -match '/groups/([^/?]+)\?') {
            $id=$Matches[1];$group=@($f.Groups | Where-Object id -eq $id)[0] | Select-Object *
            if ($f.Mode -eq 'Dynamic') { $group.groupTypes=@('DynamicMembership') }
            if ($f.Mode -eq 'MissingGroup') { throw 'Synthetic group unavailable.' }
            return $group
        }
        if ($Uri -match '/devices/([^/?]+)\?') {
            $id=$Matches[1];$device=@($f.Devices | Where-Object id -eq $id)[0] | Select-Object *
            if ($f.Mode -eq 'Renamed') { $device.displayName='CHANGED' }
            return $device
        }
        if ($Uri -match '/groups/([^/]+)/members/([^/?]+)\?') {
            $group=$Matches[1];$object=$Matches[2]
            if ($f.Mode -eq 'VerifyDenied') { throw 'Synthetic readback denial.' }
            if ($f.Members[$object] -notcontains $group) { throw 'Synthetic membership not found.' }
            return @{id=$object}
        }
        throw ('Unexpected Graph request in Ring fixture: '+$Method+' '+$Uri)
    }
    Reset-RingFixture;$access=$script:RingFixture.Access
    $script:RingFixture.Members[(Ring-TestId 13)]=@((Ring-TestId 2))
    $snapshot=Get-RingManagerSnapshot -ConfigPath synthetic -EnvPath synthetic -GraphAccess $access
    if ($snapshot.Rows.Count -ne 2 -or @($snapshot.Rows | Where-Object Orphan).Count -ne 1 -or @($snapshot.Rows | Where-Object ObjectId -eq (Ring-TestId 12))[0].State -ne 'Assegnato' -or $script:RingFixture.Writes.Count -or -not $snapshot.Groups[0].IsWritable) { throw 'Discovery lost monitored groups, nullable ordinary group metadata, eligibility or read-only behavior.' }
    if ($snapshot.Groups[0].Name -ne 'GROUP-1') { throw 'A pinned group ID was replaced by its old name.' }
    $stats=$snapshot.Statistics
    if ($stats.DeviceTotal -ne 4 -or $stats.EligibleTotal -ne 2 -or $stats.AlreadyAssigned -ne 1 -or $stats.OrphanRemaining -ne 1 -or
        $snapshot.Groups[0].DeviceCount -ne 0 -or $snapshot.Groups[1].DeviceCount -ne 2 -or $snapshot.Groups[1].MemberCount -ne 3) {
        throw 'Ring summary counted a nondevice member or lost eligible and orphan totals.'
    }
    'PASS: Ring summary counts devices per monitored group separately from all transitive objects and reports eligible, assigned and orphan totals.'
    'PASS: Ring discovery pins group IDs, includes monitored-only membership and accepts nullable role metadata on ordinary static security groups.'
    $group=$script:RingFixture.Groups[0]|Select-Object *
    foreach ($kind in @('Role','Dynamic','Synced','Mail','UnknownTypes','NotSecurity')) {
        $test=$group|Select-Object *
        switch ($kind) { Role {$test.isAssignableToRole=$true};Dynamic {$test.groupTypes=@('DynamicMembership')};Synced {$test.onPremisesSyncEnabled=$true};Mail {$test.mailEnabled=$true};UnknownTypes {$test.groupTypes=$null};NotSecurity {$test.securityEnabled=$false} }
        if (-not (Test-RingWritable $test)) { throw ('Unsafe group accepted: '+$kind) }
    }
    'PASS: protected role groups, dynamic/synced/mail groups and incomplete structural metadata remain nonmodifiable.'
    $assignment=@([pscustomobject]@{ObjectId=(Ring-TestId 11);TargetRing='Ring1'})
    $plan=New-RingAssignmentPlan -Assignments $assignment -ConfigPath synthetic -GraphAccess $access
    $plan.Items[0].ObjectId=Ring-TestId 12
    $result=Invoke-RingAssignmentPlan -PlanId $plan.PlanId -GraphAccess $access -Confirm:$false
    if ($result.Assigned -ne 1 -or $script:RingFixture.Writes.Count -ne 1 -or $result.Results[0].ObjectId -ne (Ring-TestId 11)) { throw 'Assignment lost private object binding or readback.' }
    $failed=$false;try { Invoke-RingAssignmentPlan -PlanId $plan.PlanId -GraphAccess $access -Confirm:$false } catch { $failed=$true };if (-not $failed) { throw 'Consumed plan replayed.' }
    'PASS: assignments use the canonical Entra Object ID, resist UI plan edits, verify destination and consume each plan once.'
    foreach ($mode in @('Dynamic','MissingGroup','Renamed','NewMembership','ForeignSession','Expired')) {
        Reset-RingFixture;$null=Get-RingManagerSnapshot -ConfigPath synthetic -EnvPath synthetic -GraphAccess $access
        $plan=New-RingAssignmentPlan -Assignments $assignment -ConfigPath synthetic -GraphAccess $access
        if ($mode -eq 'Expired') { $script:RingPlans[$plan.PlanId].CreatedAt=[datetimeoffset]::UtcNow.AddMinutes(-6) } else { $script:RingFixture.Mode=$mode };$result=$null
        try { $result=Invoke-RingAssignmentPlan -PlanId $plan.PlanId -GraphAccess $access -Confirm:$false } catch { }
        if ($script:RingFixture.Writes.Count -or ($null -ne $result -and $result.Assigned)) { throw ('Stale assignment wrote: '+$mode) }
    }
    'PASS: changed group metadata, names, memberships, sessions and expired plans block stale writes.'
    Reset-RingFixture;$null=Get-RingManagerSnapshot -ConfigPath synthetic -EnvPath synthetic -GraphAccess $access
    $plan=New-RingAssignmentPlan -Assignments $assignment -ConfigPath synthetic -GraphAccess $access
    $result=Invoke-RingAssignmentPlan -PlanId $plan.PlanId -GraphAccess $access -WhatIf
    if ($script:RingFixture.Writes.Count -or $result.Results[0].State -ne 'Simulato') { throw 'WhatIf wrote.' }
    $access.ReadOnly=$true;$failed=$false;try { New-RingAssignmentPlan -Assignments $assignment -ConfigPath synthetic -GraphAccess $access } catch { $failed=$_.Exception.Message -like '*sola lettura*' };if (-not $failed) { throw 'Read-only prepared writes.' }
    Reset-RingFixture;$script:RingFixture.Mode='MembershipDenied';$failed=$false;try { $null=Get-RingManagerSnapshot -ConfigPath synthetic -EnvPath synthetic -GraphAccess $access } catch { $failed=$true };if (-not $failed -or $script:RingRows.Count) { throw 'Unreadable group published false orphans.' }
    'PASS: WhatIf/read-only never write; an unreadable monitored group publishes no candidates.'
    $move=@([pscustomobject]@{ObjectId=(Ring-TestId 12);TargetRing='Ring1'})
    foreach ($kind in @('ReadOnlyOrigin','InheritedOrigin')) {
        Reset-RingFixture
        if ($kind -eq 'InheritedOrigin') { $script:RingFixture.CanMove=$true;$script:RingFixture.Mode='Inherited';$script:RingFixture.Members[(Ring-TestId 12)]=@() }
        $null=Get-RingManagerSnapshot -ConfigPath synthetic -EnvPath synthetic -GraphAccess $access;$failed=$false
        try { $null=New-RingAssignmentPlan -Assignments $move -ConfigPath synthetic -GraphAccess $access } catch { $failed=$true }
        if (-not $failed -or $script:RingFixture.Writes.Count) { throw ('Move accepted '+$kind) }
    }
    'PASS: monitor-only origins and inherited nested membership cannot be removed by a device move.'
    foreach ($mode in @('','PostDenied','VerifyDenied','DeleteDenied')) {
        Reset-RingFixture;$f=$script:RingFixture;$f.CanMove=$true
        # An unconfigured group must never be removed.
        $f.Members[(Ring-TestId 12)]+= @((Ring-TestId 99))
        $null=Get-RingManagerSnapshot -ConfigPath synthetic -EnvPath synthetic -GraphAccess $access
        $plan=New-RingAssignmentPlan -Assignments $move -ConfigPath synthetic -GraphAccess $access
        if ($plan.Items[0].Action -ne 'Sposta' -or $plan.Items[0].RemoveGroups -notlike ('*'+(Ring-TestId 2)+'*')) { throw 'Move preview did not enumerate exact origins.' }
        $plan.Items[0].RemoveGroups='forged';$plan.Items[0].TargetRing='forged';$f.Mode=$mode
        $result=Invoke-RingAssignmentPlan -PlanId $plan.PlanId -GraphAccess $access -Confirm:$false
        if ($f.Members[(Ring-TestId 12)] -notcontains (Ring-TestId 99)) { throw 'Move removed an unconfigured membership.' }
        if ($mode -eq '') {
            if ($result.Moved -ne 1 -or $f.Writes.Count -ne 2 -or $f.Writes[0].Method -ne 'POST' -or $f.Writes[1].Method -ne 'DELETE' -or $f.Writes[1].GroupId -ne (Ring-TestId 2) -or $f.Members[(Ring-TestId 12)] -contains (Ring-TestId 2) -or $result.Results[0].RemoveGroups -eq 'forged') { throw 'Move did not verify destination then remove the private confirmed origin.' }
            $null=Get-RingManagerSnapshot -ConfigPath synthetic -EnvPath synthetic -GraphAccess $access
            $plan=New-RingAssignmentPlan -Assignments $move -ConfigPath synthetic -GraphAccess $access
            $before=$f.Writes.Count;$same=Invoke-RingAssignmentPlan -PlanId $plan.PlanId -GraphAccess $access -Confirm:$false
            if ($same.Results[0].State -ne 'Gia nel Ring' -or $f.Writes.Count -ne $before) { throw 'Already-target membership was not idempotent.' }
        } else {
            if ($result.Failed -ne 1 -or $f.Members[(Ring-TestId 12)] -notcontains (Ring-TestId 2)) { throw ('Failure lost origin membership: '+$mode) }
            if ($mode -in @('PostDenied','VerifyDenied') -and @($f.Writes|Where-Object Method -eq DELETE).Count) { throw 'Origin deleted without verified destination.' }
            if ($mode -eq 'DeleteDenied' -and ($f.Members[(Ring-TestId 12)] -notcontains (Ring-TestId 1) -or $result.Results[0].State -ne 'Parziale: destinazione verificata')) { throw 'Partial move did not retain verified destination and explicit status.' }
        }
    }
    'PASS: moves add and verify destination before exact /$ref removal; add/readback failures preserve origins, partial removal retains destination, other groups stay untouched and repeated target is a no-op.'
 }
}
finally { Remove-Module -ModuleInfo $module -Force }
