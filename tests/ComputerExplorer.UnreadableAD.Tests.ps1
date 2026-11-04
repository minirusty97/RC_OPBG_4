#requires -version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '../ComputerExplorer.Removal.psm1') -Force -PassThru
try {
 & $module {
    param($FixturePath)
    # Reuse the established isolated AD/Graph/GLPI fixture; never execute its test body.
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($FixturePath,[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw $errors[0] }
    foreach ($fn in @($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$true))) { . ([scriptblock]::Create($fn.Extent.Text)) }
    $script:OriginalAdFixture=${function:Get-ADObject}
    function script:Get-ADObject {
        [CmdletBinding()]param([string]$Server,[string]$LDAPFilter,[string]$SearchBase,[string]$SearchScope,[guid]$Identity,[string[]]$Properties)
        foreach ($record in @(& $script:OriginalAdFixture @PSBoundParameters)) {
            if ($script:Fixture.HideMetadata -and $record.DistinguishedName -match '^CN=Recovery,') {
                [pscustomobject]@{ObjectGUID=$null;ObjectClass=$null;Name=$null;DistinguishedName=$record.DistinguishedName;ProtectedFromAccidentalDeletion=$false}
            } else { $record }
        }
    }
    function script:New-UnknownFixture {
        Reset-Fixture;Set-TestAdChildren
        $script:Fixture.HideMetadata=$true;$script:Fixture.LdapMode='';$script:Fixture.Connections=0;$script:Fixture.Disposals=0
        $script:Fixture.Requests=New-Object 'Collections.Generic.List[object]'
    }
    function script:New-RemovalLdapConnection {
        param($Server)
        if ($Server -ne 'dc1.example.invalid') { throw 'Unconfigured DC selected.' }
        $script:Fixture.Connections++
        if ($script:Fixture.LdapMode -eq 'ReplaceOnBind') { $script:Fixture.Ad[0].ObjectGUID=New-TestId 111 }
        $connection=[pscustomobject]@{}
        $connection|Add-Member ScriptMethod SendRequest {
            param($Request)
            if ($Request.GetType().FullName -ne 'System.DirectoryServices.Protocols.DeleteRequest' -or $Request.Controls.Count -ne 0 -or $Request.DistinguishedName -cne $script:Fixture.Children[0].DistinguishedName) { throw 'Unexpected DN or recursive LDAP control.' }
            [void]$script:Fixture.Requests.Add($Request)
            if ($script:Fixture.LdapMode -in @('Denied','NonLeaf','Disconnected')) {
                $code=50;if ($script:Fixture.LdapMode -eq 'NonLeaf') {$code=66};if($script:Fixture.LdapMode -eq 'Disconnected'){$code=81}
                $errorObject=New-Object Exception('Synthetic LDAP failure.')
                $errorObject|Add-Member NoteProperty Response ([pscustomobject]@{ResultCode=$code});throw $errorObject
            }
            if ($script:Fixture.LdapMode -ne 'Unverified') { [void]$script:Fixture.Writes.Add([pscustomobject]@{Source='AD (figlio)';Server='dc1.example.invalid';Id=[string]$script:Fixture.Children[0].ObjectGUID;Name='PC-ONE'}) }
        }
        $connection|Add-Member ScriptMethod Dispose { $script:Fixture.Disposals++ }
        return $connection
    }
    $config=Join-Path ([IO.Path]::GetTempPath()) ('unreadable-ad-'+[guid]::NewGuid().ToString('N')+'.json')
    try {
        @{DomainControllers=@('dc1.example.invalid');Search=@{MinimumCharacters=2}}|ConvertTo-Json -Depth 5|Set-Content $config -Encoding UTF8
        foreach ($consent in @('Missing','WrongComputer')) {
            New-UnknownFixture
            $plan=New-ExplorerRemovalPlan -Names PC-ONE -Sources AD,Entra,Intune -ConfigPath $config
            $unknown=@($plan.Entries[0].Targets|Where-Object Source -eq AD)[0].AdChildren|Where-Object Unreadable
            if ($plan.Entries[0].Error -or @($unknown).Count -ne 1 -or $unknown.Id -or $unknown.ObjectClass) { throw 'Unreadable child became an invalid GUID error or an invented identity.' }
            $names=@();if ($consent -eq 'WrongComputer') {$names=@('PC-TWO')}
            $result=Invoke-ExplorerRemovalPlan -PlanId $plan.PlanId -IncludeAdChildren -ConfirmUnreadableAdChildrenFor $names -Confirm:$false
            if ($result.Failed -ne 1 -or $script:Fixture.Writes.Count -or $script:Fixture.Connections) { throw 'Unreadable child deletion crossed missing/per-computer consent.' }
        }
        'PASS: DN-only child preview remains available without inventing GUID/class; absent or different-computer loss consent prevents every write.'
        New-UnknownFixture
        $plan=New-ExplorerRemovalPlan -Names PC-ONE -Sources AD,Entra,Intune -ConfigPath $config
        $plan.Entries[0].Targets[0].AdChildren[0].DistinguishedName='CN=FORGED,DC=outside,DC=invalid';$plan.Entries[0].Targets[0].AdChildren[0].Unreadable=$false;$plan.Entries[0].Name='FORGED'
        $result=Invoke-ExplorerRemovalPlan -PlanId $plan.PlanId -IncludeAdChildren -ConfirmUnreadableAdChildrenFor PC-ONE -Confirm:$false
        if ($result.Failed -or $result.Deleted -ne 7 -or $script:Fixture.Requests.Count -ne 1 -or $script:Fixture.Disposals -ne 1 -or @($result.Results|Where-Object {$_.Source -eq 'AD (avviso)' -and $_.Error -like '*non sono garantite*'}).Count -ne 1 -or ($script:Fixture.Writes.Source -join ',') -ne 'Intune,AD (figlio),AD (figlio),AD (figlio),AD,Entra,Entra') { throw ('Confirmed DN-only deletion/order or incomplete-backup report failed: '+($result.Results|Out-String)) }
        'PASS: explicit consent permits ordinary single-leaf LDAP deletion, verified absence and parent removal; private identity survives preview edits and incomplete AD coverage is reported.'
        foreach ($mode in @('Denied','NonLeaf','Disconnected','Unverified')) {
            New-UnknownFixture;$script:Fixture.LdapMode=$mode
            $plan=New-ExplorerRemovalPlan -Names PC-ONE -Sources AD,Entra -ConfigPath $config
            $result=Invoke-ExplorerRemovalPlan -PlanId $plan.PlanId -IncludeAdChildren -ConfirmUnreadableAdChildrenFor PC-ONE -Confirm:$false
            if (-not $result.Failed -or @($script:Fixture.Writes|Where-Object {$_.Source -in @('AD','Entra')}).Count -or $script:Fixture.Requests.Count -ne 1 -or $script:Fixture.Disposals -ne 1) { throw ('LDAP failure did not preserve parent/later sources or avoid retries: '+$mode) }
            if ($mode -eq 'Denied' -and @($result.Results|Where-Object Error -like '*permessi di cancellazione insufficienti*').Count -eq 0) {throw 'Deletion denial lost its diagnosis.'}
            if ($mode -eq 'NonLeaf' -and @($result.Results|Where-Object Error -like '*contiene altri oggetti*').Count -eq 0) {throw 'A non-leaf failure attempted an unsafe fallback.'}
        }
        'PASS: denied rights, non-leaf entries, connection errors and unverified absence preserve the parent and later sources; LDAP is not retried or promoted to tree deletion.'
        New-UnknownFixture;$script:Fixture.LdapMode='ReplaceOnBind'
        $plan=New-ExplorerRemovalPlan -Names PC-ONE -Sources AD,Entra -ConfigPath $config
        $result=Invoke-ExplorerRemovalPlan -PlanId $plan.PlanId -IncludeAdChildren -ConfirmUnreadableAdChildrenFor PC-ONE -Confirm:$false
        if (-not $result.Failed -or $script:Fixture.Requests.Count -or @($script:Fixture.Writes|Where-Object {$_.Source -in @('AD','Entra')}).Count -or $script:Fixture.Disposals -ne 1) { throw 'Parent replacement during LDAP binding allowed a DN delete.' }
        'PASS: parent identity is checked again after LDAP binding and a replacement prevents SendRequest.'
        foreach ($mode in @('Protected','NewChild','MetadataNowReadable','DifferentIdentity')) {
            New-UnknownFixture
            $plan=New-ExplorerRemovalPlan -Names PC-ONE -Sources AD,Entra,Intune -ConfigPath $config
            switch ($mode) {
                Protected {$script:Fixture.Ad[0].ProtectedFromAccidentalDeletion=$true}
                NewChild {$script:Fixture.Children+=@([pscustomobject]@{ObjectGUID=(New-TestId 64);ObjectClass='serviceConnectionPoint';DistinguishedName=('CN=New,'+$script:Fixture.Ad[0].DistinguishedName);ProtectedFromAccidentalDeletion=$false})}
                MetadataNowReadable {$script:Fixture.HideMetadata=$false}
                DifferentIdentity {$script:Fixture.Ad[0].ObjectGUID=New-TestId 111}
            }
            $result=Invoke-ExplorerRemovalPlan -PlanId $plan.PlanId -IncludeAdChildren -ConfirmUnreadableAdChildrenFor PC-ONE -Confirm:$false
            if (-not $result.Failed -or $script:Fixture.Writes.Count -or $script:Fixture.Connections) { throw ('Changed/protected object crossed a stale DN plan: '+$mode) }
        }
        'PASS: protected/replaced parent, new descendants and newly readable child metadata invalidate stale consent before any source is changed.'
        New-UnknownFixture
        $plan=New-ExplorerRemovalPlan -Names PC-ONE -Sources AD -ConfigPath $config
        $result=Invoke-ExplorerRemovalPlan -PlanId $plan.PlanId -IncludeAdChildren -ConfirmUnreadableAdChildrenFor PC-ONE -WhatIf
        if ($result.Failed -or $script:Fixture.Writes.Count -or $script:Fixture.Connections) {throw 'WhatIf opened an LDAP connection or wrote.'}
        $script:RemovalReadOnly=$true;$failed=$false
        try { Remove-RemovalUnreadableAdLeaf -Child @($plan.Entries[0].Targets[0].AdChildren|Where-Object Unreadable)[0] -Target $plan.Entries[0].Targets[0] -Confirm:$false } catch {$failed=$true}
        if(-not $failed -or $script:Fixture.Connections){throw 'Direct DN helper bypassed read-only mode.'};$script:RemovalReadOnly=$false
        'PASS: WhatIf and read-only mode never create an LDAP connection or delete an unreadable child.'
    }
    finally { Remove-Item $config -Force -ErrorAction SilentlyContinue }
 } (Join-Path $PSScriptRoot 'ComputerExplorer.Removal.Tests.ps1')
}
finally { Remove-Module -ModuleInfo $module -Force }
