#requires -version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$temp=Join-Path ([IO.Path]::GetTempPath()) ('hybrid-sources-'+[guid]::NewGuid().ToString('N'))
$modules=Join-Path $temp 'modules'
$adModule=Join-Path $modules 'ActiveDirectory'
$graphModule=Join-Path $modules 'Microsoft.Graph.Authentication'
[void][IO.Directory]::CreateDirectory($adModule)
[void][IO.Directory]::CreateDirectory($graphModule)
$originalPath=$env:PSModulePath
$originalFixture=$env:ASSISTENTEIT_HYBRID_FIXTURE
$pipeline=$null
try {
    $env:ASSISTENTEIT_HYBRID_FIXTURE=$temp
    $env:PSModulePath=$modules+[IO.Path]::PathSeparator+$originalPath
    @'
function Get-ADDomain {
    [CmdletBinding()]param($Server)
    $root=$env:ASSISTENTEIT_HYBRID_FIXTURE
    if ($Server -ne 'dc1.example.invalid') { throw 'The scan queried a second DC.' }
    $marker=Join-Path $root ($Server+'.ready')
    if ([IO.File]::Exists($marker)) { throw 'The scan repeated the AD read.' }
    [IO.File]::WriteAllText($marker,[string]$PID)
    $deadline=[datetime]::UtcNow.AddSeconds(18)
    while (@(Get-ChildItem $root -Filter '*.ready').Count -lt 3) {
        if ([datetime]::UtcNow -ge $deadline) { throw 'AD, Entra and Intune did not overlap.' }
        Start-Sleep -Milliseconds 40
    }
    [pscustomobject]@{DistinguishedName='DC=example,DC=invalid'}
}
function Get-ADOrganizationalUnit {
    [CmdletBinding()]param($Server,$Identity)
    if ($Identity -notin @('OU=Lab,DC=example,DC=invalid','OU=Postazioni,OU=Lab,DC=example,DC=invalid')) { throw 'Unexpected OU DN.' }
    [pscustomobject]@{Name=$Identity.Split(',')[0].Substring(3);DistinguishedName=$Identity}
}
function Get-ADComputer {
    [CmdletBinding()]param($Server,$Filter,$SearchBase,$SearchScope,$Properties)
    if ($Filter -ne '*' -or $SearchScope -ne 'Subtree' -or $Properties -notcontains 'ObjectGUID' -or $Properties -notcontains 'Modified') { throw 'Unexpected AD query.' }
    [pscustomobject]@{
        Name='PC-TEST';ObjectGUID='11111111-1111-4111-8111-111111111111';Enabled=$true
        DistinguishedName='CN=PC-TEST,OU=Postazioni,OU=Lab,DC=example,DC=invalid'
        DNSHostName='pc-test.example.invalid';OperatingSystem='Windows';OperatingSystemVersion=''
        LastLogonDate=$null;PasswordLastSet=$null;Modified=[datetime]::new(2026,10,30,11,43,0)
    }
}
'@ | Set-Content -LiteralPath (Join-Path $adModule 'ActiveDirectory.psm1') -Encoding UTF8

    @'
function Get-MgContext {
    [CmdletBinding()]param()
    [pscustomobject]@{
        TenantId='22222222-2222-4222-8222-222222222222';ClientId='33333333-3333-4333-8333-333333333333'
        Account='tester@example.invalid';AuthType='Delegated';Environment='Global';Scopes=@('Device.Read.All','DeviceManagementManagedDevices.Read.All')
    }
}
function Invoke-MgGraphRequest {
    [CmdletBinding()]param($Method,$Uri,$Headers,$OutputType)
    if ($Method -ne 'GET') { throw 'The snapshot attempted a write.' }
    $root=$env:ASSISTENTEIT_HYBRID_FIXTURE
    if ($Uri -like '*/deviceManagement/managedDevices?*') {
        $source='intune'
        $items=@([pscustomobject]@{
            id='44444444-4444-4444-8444-444444444444';azureADDeviceId='11111111-1111-4111-8111-111111111111'
            deviceName='PC-TEST';serialNumber='FIXTURE-SERIAL';operatingSystem='Windows'
        })
    }
    elseif ($Uri -like '*/devices?*') {
        $source='entra'
        if ($Uri -notmatch 'approximateLastSignInDateTime') { throw 'Entra activity was not requested in the inventory read.' }
        $items=@(
            [pscustomobject]@{
                id='55555555-5555-4555-8555-555555555555';deviceId='11111111-1111-4111-8111-111111111111'
                displayName='PC-RENAMED';trustType='ServerAd';isManaged=$true;accountEnabled=$true;deviceOwnership='company'
                approximateLastSignInDateTime='2026-10-29T11:22:00Z'
            }
            [pscustomobject]@{
                id='66666666-6666-4666-8666-666666666666';deviceId='77777777-7777-4777-8777-777777777777'
                displayName='PC-TEST';trustType='Workplace';isManaged=$false;accountEnabled=$true;deviceOwnership='personal'
                approximateLastSignInDateTime='2026-11-01T12:14:00+01:00'
            }
        )
    }
    else { throw 'Unexpected Graph request.' }
    [IO.File]::WriteAllText((Join-Path $root ($source+'.ready')),$source)
    $deadline=[datetime]::UtcNow.AddSeconds(18)
    while (@(Get-ChildItem $root -Filter '*.ready').Count -lt 3) {
        if ([datetime]::UtcNow -ge $deadline) { throw 'The Graph reads did not overlap AD.' }
        Start-Sleep -Milliseconds 40
    }
    [pscustomobject]@{value=$items}
}
'@ | Set-Content -LiteralPath (Join-Path $graphModule 'Microsoft.Graph.Authentication.psm1') -Encoding UTF8

    $configPath=Join-Path $temp 'config.json'
    $config=Get-Content -LiteralPath (Join-Path $root 'computer-explorer.config.example.json') -Raw | ConvertFrom-Json
    $config.HybridJoin.TargetOus=@('OU=Lab','OU=Postazioni,OU=Lab,DC=example,DC=invalid')
    $config.Glpi.Enabled=$true
    $config.Glpi.BaseUri='https://glpi.example.invalid/apirest.php'
    $config | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $configPath -Encoding UTF8
    $access=[pscustomobject]@{
        CanOpen=$true;ReadOnly=$true;TenantId='22222222-2222-4222-8222-222222222222'
        ClientId='33333333-3333-4333-8333-333333333333';Account='tester@example.invalid'
        Permissions=@([pscustomobject]@{Id='entra-read';Available=$true},[pscustomobject]@{Id='intune-read';Available=$true})
    }
    $pipeline=[PowerShell]::Create()
    [void]$pipeline.AddScript({
        param($Root,$ConfigPath,$Access)
        $ErrorActionPreference='Stop'
        Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
        $hybrid = Import-Module (Join-Path $Root 'HybridJoin.Core.psm1') -PassThru -ErrorAction Stop
        & $hybrid {
            & (Get-Command Add-DmInventory).Module {
                function script:Read-ExplorerGlpiCredentials {
                    param($Path,$UseAppToken)
                    [pscustomobject]@{User=(ConvertTo-SecureString synthetic -AsPlainText -Force);App=$null}
                }
                function script:Find-GlpiComputer {
                    param($BaseUri,$UserToken,$AppToken,$PageSize,$TimeoutSeconds,$SerialNumber,$ExactName,$BulkRead,$AllProfileEntities,$LookupCache,$ProgressQueue,$IncludeSupplier)
                    if ($SerialNumber -ne 'FIXTURE-SERIAL') { throw 'Expected the associated GLPI card by serial.' }
                    [pscustomobject]@{
                        GlpiId=12;Name='PC-GLPI';SerialNumber='FIXTURE-SERIAL';State='Assegnato'
                        GroupPath='';GroupName='';GroupVerified=$true;LastModified='2026-11-02 09:45:00';LastInventory='2026-11-02 07:30:00'
                    }
                }
            }
        }
        Get-HybridJoinSnapshot -ConfigPath $ConfigPath -GraphAccess $Access
    }.ToString()).AddArgument($root).AddArgument($configPath).AddArgument($access)
    $invocation=$pipeline.BeginInvoke()
    if (-not $invocation.AsyncWaitHandle.WaitOne(45000)) { throw 'Hybrid snapshot timed out.' }
    $snapshot=$pipeline.EndInvoke($invocation)[0]
    $workerIds=@(Get-ChildItem $temp -Filter 'dc*.ready' | ForEach-Object { [int](Get-Content $_.FullName -Raw) })
    if ($workerIds.Count -ne 1 -or $workerIds -contains $PID -or $snapshot.Sources.AdServer -ne 'dc1.example.invalid' -or
        $snapshot.Rows.Count -ne 1 -or $snapshot.Rows[0].IntuneSerial -ne 'FIXTURE-SERIAL' -or
        $snapshot.OuStatistics.Count -ne 2 -or $snapshot.Statistics.IntuneOk -ne 1) {
        throw 'Single isolated DC read, parallel cloud reads or result merge failed.'
    }
    'PASS: the OU scan reads a single DC in an isolated process while Entra and Intune run concurrently.'
    $row = $snapshot.Rows[0]
    $expectedEntra = [datetimeoffset]::Parse('2026-11-01T12:14:00+01:00').LocalDateTime
    if ($row.ADLastModified -ne [datetime]::new(2026,10,30,11,43,0) -or $row.EntraLastActivity -ne $expectedEntra -or
        $snapshot.Sources.GlpiState -ne 'OK' -or $row.GlpiLastModified -ne [datetime]::new(2026,11,2,9,45,0)) {
        throw 'The snapshot lost the DC modification date, most recent Entra activity, or GLPI card modification date.'
    }
    'PASS: the snapshot carries AD modification, the latest Entra activity, and the GLPI card update as dates.'

}
finally {
    if ($null -ne $pipeline) { $pipeline.Dispose() }
    $env:PSModulePath=$originalPath
    $env:ASSISTENTEIT_HYBRID_FIXTURE=$originalFixture
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
