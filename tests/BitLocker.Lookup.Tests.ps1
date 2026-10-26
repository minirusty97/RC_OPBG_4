#requires -version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '../BitLocker.Archive.psm1') -Force -PassThru
try {
    & $module {
        $script:Lookup=@{Calls=(New-Object 'Collections.Generic.List[string]');Mode='Cloud';Reads=(New-Object 'Collections.Generic.List[string]')}
        $device='11111111-1111-4111-8111-111111111111';$managed='22222222-2222-4222-8222-222222222222';$keyId='33333333-3333-4333-8333-333333333333'
        $password=(@(1..8 | ForEach-Object { '000011' }) -join '-')
        $script:Lookup.Password=$password
        function script:Import-Module { [CmdletBinding()]param($Name) if ($Name -notin @('Microsoft.Graph.Authentication','ActiveDirectory')) { throw 'Unexpected dependency.' } }
        function script:Get-ExplorerGraphCollection {
            param($Uri,$ResourcePath)
            [void]$script:Lookup.Calls.Add($ResourcePath)
            if ($ResourcePath -eq '/v1.0/deviceManagement/managedDevices') {
                if ([Uri]::UnescapeDataString($Uri) -notlike "*deviceName eq 'PC-LOOKUP'*") { throw 'Intune lookup was not exact-name.' }
                return [pscustomobject]@{id='22222222-2222-4222-8222-222222222222';deviceName='PC-LOOKUP';azureADDeviceId='11111111-1111-4111-8111-111111111111';operatingSystem='Windows';serialNumber='SERIAL-TEST'}
            }
            if ($ResourcePath -eq '/v1.0/informationProtection/bitlocker/recoveryKeys') {
                if ([Uri]::UnescapeDataString($Uri) -notlike "*deviceId eq '11111111-1111-4111-8111-111111111111'*") { throw 'A managedDeviceId was used instead of azureADDeviceId.' }
                return [pscustomobject]@{id='33333333-3333-4333-8333-333333333333';deviceId='11111111-1111-4111-8111-111111111111'}
            }
            throw 'Unexpected Entra inventory or unrelated endpoint.'
        }
        function script:Invoke-MgGraphRequest {
            [CmdletBinding()]param($Method,$Uri,$OutputType,$Headers)
            if ($Method -ne 'GET' -or $Uri -notlike '*$select=id,deviceId,key*' -or -not $Headers['User-Agent']) { throw 'Secret read not explicit.' }
            [pscustomobject]@{value=[pscustomobject]@{id='33333333-3333-4333-8333-333333333333';deviceId='11111111-1111-4111-8111-111111111111';key=$script:Lookup.Password;volumeType='operatingSystemVolume';createdDateTime='2026-10-26T10:00:00Z'}}
        }
        $records=@(Read-BlKeysBySource -Source Intune -Name PC-LOOKUP)
        if ($records.Count -ne 1 -or $records[0].Password -cne $password -or $records[0].Serial -cne 'SERIAL-TEST' -or $records[0].Origins -notcontains ('Intune:'+$device) -or $script:Lookup.Calls.Count -ne 2) { throw 'Direct Intune lookup failed or required an Entra inventory.' }
        'PASS: live Intune lookup resolves azureADDeviceId, reads and validates the recovery password, and requires no Entra inventory or GLPI.'

        function script:Get-ADComputer {
            [CmdletBinding()]param($Server,$LDAPFilter,$Properties)
            if ($LDAPFilter -ne '(name=PC-LOOKUP)') { throw 'AD query was not exact-name.' }
            [pscustomobject]@{Name='PC-LOOKUP';ObjectGUID='44444444-4444-4444-8444-444444444444';DistinguishedName='CN=PC-LOOKUP,DC=example,DC=invalid';ProtectedFromAccidentalDeletion=$true}
        }
        function script:Get-ADObject {
            [CmdletBinding()]param($Server,$SearchBase,$SearchScope,$LDAPFilter,$Properties,$Identity)
            $record=[pscustomobject]@{ObjectGUID='55555555-5555-4555-8555-555555555555';DistinguishedName='CN=Recovery,CN=PC-LOOKUP,DC=example,DC=invalid';ObjectClass='msFVE-RecoveryInformation';'msFVE-RecoveryGuid'='33333333-3333-4333-8333-333333333333';'msFVE-RecoveryPassword'=$script:Lookup.Password;whenCreated='2026-10-26T10:00:00Z'}
            if (-not $Identity -and $LDAPFilter -ne '(objectClass=msFVE-RecoveryInformation)') { throw 'AD child query was not limited to BitLocker.' }
            return $record
        }
        $ad=@(Read-BlKeysBySource -Source AD -Name PC-LOOKUP -DomainController dc1.example.invalid)
        if ($ad.Count -ne 1 -or $ad[0].Password -cne $password) { throw 'Read-only lookup failed on a protected AD computer.' }
        'PASS: AD fallback reads only BitLocker children and can recover keys from a computer protected against deletion.'

        function script:Read-ExplorerConfiguration { param($ConfigPath) [pscustomobject]@{CloudReadTimeoutSeconds=2;Settings=[pscustomobject]@{DomainControllers=@('dc1.example.invalid','dc2.example.invalid')}} }
        function script:Connect-ExplorerGraph { [CmdletBinding()]param($Sources,[switch]$ForBitLocker,$ProgressQueue,$GraphAuthentication) if ($Sources -ne 'Intune' -or -not $ForBitLocker) { throw 'Wrong key-read consent.' } }
        function script:Read-BlLiveKeySource {
            param($Source,$Name,$DomainController,$TimeoutSeconds)
            [void]$script:Lookup.Reads.Add($Source+':'+$DomainController)
            if ($Source -eq 'Intune' -and $script:Lookup.Mode -eq 'Denied') { throw 'Synthetic access denied.' }
            if ($script:Lookup.Mode -eq 'Empty' -or ($Source -eq 'Intune' -and $script:Lookup.Mode -eq 'Fallback')) { return @() }
            [pscustomobject]@{Name=$Name;KeyId='33333333-3333-4333-8333-333333333333';Password=$script:Lookup.Password;Volume='operatingSystemVolume';Serial='SERIAL-TEST';Origins=@($Source);CreatedAt='';ArchivedAtUtc=''}
        }
        $queue=New-Object 'Collections.Concurrent.ConcurrentQueue[object]'
        $result=Find-ExplorerBitLockerKeys -Name PC-LOOKUP -ConfigPath unused -ProgressQueue $queue
        if ($result.Records.Count -ne 1 -or $script:Lookup.Reads.Count -ne 1 -or $result.Sources[0].Name -ne 'Intune') { throw 'AD was consulted before a successful Intune recovery.' }
        if (($queue.ToArray() | ConvertTo-Json -Depth 5) -like ('*'+$password+'*')) { throw 'A progress event leaked the recovery password.' }
        'PASS: successful live Intune recovery returns immediately and progress contains no recovery passwords.'
        foreach ($mode in @('Fallback','Denied')) {
            $script:Lookup.Mode=$mode;$script:Lookup.Reads.Clear()
            $result=Find-ExplorerBitLockerKeys -Name PC-LOOKUP -ConfigPath unused
            if ($result.Records.Count -ne 1 -or $script:Lookup.Reads.Count -ne 2 -or $script:Lookup.Reads[0] -ne 'Intune:' -or $script:Lookup.Reads[1] -ne 'AD:dc1.example.invalid') { throw 'AD fallback did not follow Intune or queried unnecessary DC replicas.' }
            $expected='OK';if ($mode -eq 'Denied') { $expected='Errore' }
            if ($result.Sources[0].State -ne $expected) { throw 'Intune access denial was incorrectly reported as no keys.' }
        }
        'PASS: empty or unavailable Intune keys fall back to AD while retaining an explicit cloud error when applicable.'
        $script:Lookup.Mode='Empty';$script:Lookup.Reads.Clear()
        $result=Find-ExplorerBitLockerKeys -Name PC-LOOKUP -ConfigPath unused
        if ($result.Records.Count -ne 0 -or $result.Sources.Count -ne 3 -or @($result.Sources | Where-Object State -ne 'OK').Count -ne 0) { throw 'No-key lookup left a source pending or fabricated a key.' }
        'PASS: absent devices or absent recovery keys terminate with zero keys and explicit per-source outcomes.'
    }
}
finally { Remove-Module -ModuleInfo $module -Force -ErrorAction SilentlyContinue }

$module=Import-Module (Join-Path $PSScriptRoot '../BitLocker.Archive.psm1') -Force -PassThru
try {
    & $module {
        function script:Get-BlKeyLookupWorkerScript { return { param($ModulePath,$Source,$Name,$DomainController) Start-Sleep -Seconds 20;throw 'Reader survived its deadline.' } }
        $watch=[Diagnostics.Stopwatch]::StartNew();$timedOut=$false
        try { $null=Read-BlLiveKeySource -Source Intune -Name PC-LOOKUP -TimeoutSeconds 1 } catch { $timedOut=$_.Exception.Message -like '*Tempo massimo*' }
        if (-not $timedOut -or $watch.Elapsed.TotalSeconds -gt 10) { throw 'Live key reader did not stop at its deadline.' }
        function script:Get-BlKeyLookupWorkerScript { return { param($ModulePath,$Source,$Name,$DomainController) [pscustomobject]@{KeyId='33333333-3333-4333-8333-333333333333'} } }
        if (@(Read-BlLiveKeySource -Source Intune -Name PC-LOOKUP -TimeoutSeconds 2).Count -ne 1) { throw 'Lookup could not run after a timed-out reader.' }
        'PASS: live key reads use a bounded asynchronous pipeline and can be repeated after a timeout.'
    }
}
finally { Remove-Module -ModuleInfo $module -Force -ErrorAction SilentlyContinue }
