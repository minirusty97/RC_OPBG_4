#requires -version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $root 'DeviceModules.Core.psm1') -Force -PassThru
try {
 & $module {
    $script:DmFixture=@{Mode='';Calls=0;Finds=(New-Object 'Collections.Generic.List[object]')}
    $access=[pscustomobject]@{CanOpen=$true;ReadOnly=$false;TenantId='11111111-1111-4111-8111-111111111111';ClientId='22222222-2222-4222-8222-222222222222';Account='synthetic@example.invalid';Permissions=@([pscustomobject]@{Id='entra-read';Available=$true},[pscustomobject]@{Id='intune-read';Available=$true},[pscustomobject]@{Id='groups-write';Available=$true})}
    $script:DmFixture.Access=$access
    function script:Get-MgContext { [CmdletBinding()]param();$a=$script:DmFixture.Access;[pscustomobject]@{AuthType='Delegated';Environment='Global';TenantId=$a.TenantId;ClientId=$a.ClientId;Account=$(if ($script:DmFixture.Mode -eq 'Foreign') {'foreign@example.invalid'} else {$a.Account});Scopes=@('Device.Read.All','GroupMember.ReadWrite.All')} }
    $context=Assert-DmSession $access -WriteId groups-write
    if ($context -notlike '*Device.Read.All,GroupMember.ReadWrite.All') { throw 'Session signature lost individual scopes.' }
    foreach ($mode in @('ReadOnly','Foreign')) {
        $script:DmFixture.Mode=$mode;$access.ReadOnly=$mode -eq 'ReadOnly';$failed=$false
        try { [void](Assert-DmSession $access -WriteId groups-write) } catch { $failed=$true }
        if (-not $failed) { throw 'A read-only or foreign session crossed the write boundary.' }
    }
    $access.ReadOnly=$false;$script:DmFixture.Mode=''
    'PASS: new modules bind operations to the wrapper account, client, tenant and delegated context; read-only writes stop before any request.'
    function script:Invoke-MgGraphRequest {
        [CmdletBinding()]param($Method,$Uri,$Headers,$OutputType)
        if ($Method -ne 'GET') { throw 'Read operation attempted a write.' }
        $script:DmFixture.Calls++
        $id='33333333-3333-4333-8333-333333333333'
        if ($script:DmFixture.Mode -eq 'Malformed') { return @{} }
        if ($script:DmFixture.Mode -eq 'ForeignPage') { return @{value=@();'@odata.nextLink'='https://example.invalid/leak'} }
        if ($script:DmFixture.Mode -eq 'Loop') { return @{value=@();'@odata.nextLink'=$Uri} }
        if ($Uri -notlike '*skiptoken*') { return @{value=@(@{id=$id;displayName='FIRST'});'@odata.nextLink'='https://graph.microsoft.com/v1.0/devices?$skiptoken=next'} }
        @{value=@(@{id='44444444-4444-4444-8444-444444444444';displayName='SECOND'})}
    }
    $items=@(Get-DmGraphItems -Uri 'https://graph.microsoft.com/v1.0/devices?$top=1')
    if ($items.Count -ne 2 -or $script:DmFixture.Calls -ne 2) { throw 'Complete Graph pages were not collected.' }
    foreach ($mode in @('Malformed','ForeignPage','Loop')) {
        $script:DmFixture.Mode=$mode;$failed=$false;$items=@()
        try { $items=@(Get-DmGraphItems -Uri 'https://graph.microsoft.com/v1.0/devices?$top=1') } catch { $failed=$true }
        if (-not $failed -or $items.Count) { throw 'Incomplete or unsafe Graph pagination published rows.' }
    }
    'PASS: inventory collection accepts dictionary responses and complete pagination, rejects malformed/foreign/repeated pages and never publishes partial rows.'
    function script:Get-DmGraphItems {
        param($Uri,$ProgressQueue)
        if ($script:DmFixture.Mode -eq 'IntuneDenied') { throw 'Synthetic Intune denial.' }
        @(@{id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';azureADDeviceId='33333333-3333-4333-8333-333333333333';operatingSystem='Windows';serialNumber='REAL-SERIAL';deviceName='RENAMED'},@{id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';azureADDeviceId='44444444-4444-4444-8444-444444444444';operatingSystem='Windows';serialNumber='OTHER-SERIAL';deviceName='SAME-NAME'})
    }
    function script:Read-ExplorerGlpiCredentials {param($Path,$UseAppToken);[pscustomobject]@{User=(ConvertTo-SecureString synthetic -AsPlainText -Force);App=(ConvertTo-SecureString synthetic -AsPlainText -Force)} }
    function script:Find-GlpiComputer {
        param($BaseUri,$UserToken,$AppToken,$PageSize,$TimeoutSeconds,$SerialNumber,$ExactName)
        [void]$script:DmFixture.Finds.Add(@{Serials=$SerialNumber;Names=$ExactName})
        if ($SerialNumber) { return @([pscustomobject]@{GlpiId=10;Name='GLPI-OTHER-NAME';SerialNumber='REAL-SERIAL';State='Assegnato';GroupPath='CENSITO';GroupName='CENSITO';GroupVerified=$true}) }
        @([pscustomobject]@{GlpiId=20;Name='SAME-NAME';SerialNumber='WRONG-FOR-FIRST';State='Ritirato';GroupPath='';GroupName='';GroupVerified=$true})
    }
    $rows=@([pscustomobject]@{Name='SAME-NAME';DeviceIds=@('33333333-3333-4333-8333-333333333333')},[pscustomobject]@{Name='SAME-NAME';DeviceIds=@('55555555-5555-4555-8555-555555555555')})
    $config=[pscustomobject]@{Settings=[pscustomobject]@{Glpi=[pscustomobject]@{Enabled=$true;BaseUri='https://example.invalid/apirest.php';UseAppToken=$true}}}
    $script:DmFixture.Mode=''
    $sources=Add-DmInventory -Rows $rows -Config $config -Access $access -EnvPath synthetic
    if ($rows[0].GlpiIds -ne '10' -or $rows[0].GlpiNames -ne 'GLPI-OTHER-NAME' -or $rows[0].IntuneSerial -ne 'REAL-SERIAL' -or $rows[0].Censito -ne 'Si' -or $rows[1].GlpiIds -ne '20' -or $rows[1].IntuneRecords.Count -ne 0 -or $script:DmFixture.Finds.Count -ne 2) { throw 'Serial-first inventory attached an unrelated namesake or lost exact-name fallback.' }
    'PASS: both modules correlate Intune by Entra Device ID, prefer the verified serial over GLPI namesakes, keep renamed GLPI assets and use exact-name batches only when no serial is available.'
    $script:DmFixture.Mode='IntuneDenied'
    $sources=Add-DmInventory -Rows @() -Config $config -Access $access -EnvPath synthetic
    if ($sources.IntuneState -ne 'Errore') { throw 'Intune denial became an empty successful inventory.' }
    if ((ConvertTo-DmCsvValue '=HYPERLINK("x")') -notlike "'=*") { throw 'CSV formula injection was not escaped.' }
    'PASS: source failures remain explicit and spreadsheet formulas are escaped in exported reports.'
 }
}
finally { Remove-Module -ModuleInfo $module -Force }
