#requires -version 5.1
[CmdletBinding()]
param([string]$ModulePath = (Join-Path $PSScriptRoot '../ComputerExplorer.Core.psm1'))
$ErrorActionPreference = 'Stop'
$module = Import-Module $ModulePath -Force -PassThru
try {
    & $module {
        $script:Fixture = @{ Mode = 'Normal'; Calls = (New-Object 'System.Collections.Generic.List[string]'); Logins = @() }
        $script:Context = [pscustomobject]@{ TenantId = 'tenant-a'; ClientId = 'client-a'; Account = 'test@example.invalid'; AuthType = 'Delegated'; Environment = 'Global';
            Scopes = @('Directory.AccessAsUser.All', 'DeviceManagementManagedDevices.ReadWrite.All') }
        function script:Get-MgContext { [CmdletBinding()]param() return $script:Context }
        function script:Connect-MgGraph {
            [CmdletBinding()]param([string[]]$Scopes, [string]$ContextScope, [switch]$NoWelcome, [string]$TenantId, [string]$ClientId)
            $script:Fixture.Logins += @([pscustomobject]@{Scopes=$Scopes;TenantId=$TenantId;ClientId=$ClientId})
        }
        function script:Import-Module {
            [CmdletBinding()]param([string]$Name)
            if ($Name -ne 'Microsoft.Graph.Authentication') { throw "Unexpected import: $Name" }
        }
        function script:Invoke-MgGraphRequest {
            [CmdletBinding()]param([string]$Method, [string]$Uri, [string]$OutputType)
            if ($Method -ne 'GET') { throw 'Unexpected write.' }
            [void]$script:Fixture.Calls.Add($Uri)
            $id1 = '11111111-1111-4111-8111-111111111111'
            $id2 = '22222222-2222-4222-8222-222222222222'
            $id3 = '33333333-3333-4333-8333-333333333333'
            if ($Uri -like '*managedDevices*') {
                return [pscustomobject]@{value=@(
                    [pscustomobject]@{id=$id1;deviceName='PA-PORT-001';operatingSystem='Windows';azureADDeviceId=$id3;serialNumber='SERIAL-1';lastSyncDateTime='2026-10-15T07:30:00Z'},
                    [pscustomobject]@{id=$id2;deviceName='PORT-ANDROID';operatingSystem='Android'}
                )}
            }
            $record = [pscustomobject]@{id=$id1;displayName='PA-PORT-001';deviceId=$id3;operatingSystem='Windows';approximateLastSignInDateTime='2026-10-14T12:00:00Z'}
            if ($script:Fixture.Mode -eq 'Empty') { return [pscustomobject]@{value=@()} }
            if ($script:Fixture.Mode -eq 'Malformed') { return [pscustomobject]@{value=$record} }
            if ($script:Fixture.Mode -eq 'InvalidId') { $record.id='invalid'; return [pscustomobject]@{value=@($record)} }
            if ($Uri -like '*skiptoken*') {
                if ($script:Fixture.Mode -eq 'Failure') { throw 'Synthetic second-page failure.' }
                if ($script:Fixture.Mode -eq 'Conflict') { $record.displayName='DIFFERENT' }
                $second = [pscustomobject]@{id=$id2;displayName='port-001';deviceId=$id2}
                return [pscustomobject]@{value=@($record,$second)}
            }
            $next = 'https://graph.microsoft.com/v1.0/devices?$skiptoken=two'
            if ($script:Fixture.Mode -eq 'ForeignHost') { $next='https://example.invalid/v1.0/devices?page=two' }
            if ($script:Fixture.Mode -eq 'ForeignResource') { $next='https://graph.microsoft.com/v1.0/users?page=two' }
            if ($script:Fixture.Mode -eq 'Loop') { $next=$Uri }
            return [pscustomobject]@{value=@($record);'@odata.nextLink'=$next}
        }

        Connect-ExplorerGraph -Sources Entra,Intune
        if ($script:Fixture.Logins.Count -ne 0) { throw 'Existing broad scopes not reused.' }
        'PASS: existing broad Graph permissions reused.'
        $script:Context.Scopes=@('Directory.Read.All')
        Connect-ExplorerGraph -Sources Entra,Intune
        $login=$script:Fixture.Logins[0]
        if ($login.Scopes -notcontains 'Directory.Read.All' -or $login.Scopes -notcontains 'DeviceManagementManagedDevices.ReadWrite.All' -or
            $login.TenantId -ne 'tenant-a' -or $login.ClientId -ne 'client-a') { throw 'Missing Intune scope or login identity lost.' }
        'PASS: Intune consent retains existing scopes, tenant and client.'
        $script:Context.Scopes=@('Directory.AccessAsUser.All','DeviceManagementManagedDevices.ReadWrite.All')
        $script:Context.AuthType='AppOnly'
        Connect-ExplorerGraph -Sources Entra,Intune
        if ($script:Fixture.Logins.Count -ne 1) { throw 'Application authentication replaced.' }
        'PASS: existing app-only session retained.'
        $script:Context.AuthType='Delegated'

        $first=Get-ExplorerCloudInventory -Source Entra
        if ($first.Records.Count -ne 2 -or $first.FromCache -or $script:Fixture.Calls.Count -ne 2) { throw 'Pages not fully collected or duplicate not removed.' }
        'PASS: Graph pagination, distinct IDs and optional nextLink.'
        $cached=Get-ExplorerCloudInventory -Source Entra
        if (-not $cached.FromCache -or $script:Fixture.Calls.Count -ne 2 -or $cached.CheckedAtUtc -ne $first.CheckedAtUtc) { throw 'Cache timestamp or reuse incorrect.' }
        'PASS: complete cache reused with original timestamp.'
        $script:Context.TenantId='tenant-b'
        $other=Get-ExplorerCloudInventory -Source Entra
        if ($other.FromCache -or $script:Fixture.Calls.Count -ne 4) { throw 'Cache leaked between tenants.' }
        $script:Context.Account='other@example.invalid'
        $other=Get-ExplorerCloudInventory -Source Entra
        if ($other.FromCache -or $script:Fixture.Calls.Count -ne 6) { throw 'Cache leaked between accounts.' }
        'PASS: cloud cache isolated by tenant and account.'
        $windows=Get-ExplorerCloudInventory -Source Intune
        if ($windows.Records.Count -ne 1 -or $windows.Records[0].ManagedDeviceId -ne '11111111-1111-4111-8111-111111111111' -or
            $windows.Records[0].AzureADDeviceId -ne '33333333-3333-4333-8333-333333333333') { throw 'Intune platform or ID mapping incorrect.' }
        'PASS: Intune Windows filter and distinct managedDeviceId / DeviceId.'
        if (@($first.Records | Where-Object { $_.Name -eq 'PA-PORT-001' })[0].LastSignIn -ne '2026-10-14T12:00:00Z' -or
            $windows.Records[0].LastSync -ne '2026-10-15T07:30:00Z') { throw 'Cloud activity / check-in timestamps lost.' }
        'PASS: Entra activity and Intune check-in fields retained.'

        foreach ($mode in @('Failure','ForeignHost','ForeignResource','Loop','Malformed','InvalidId','Conflict')) {
            $script:Fixture.Mode=$mode
            $out=@(); $rejected=$false
            try { $out=@(Get-ExplorerCloudInventory -Source Entra -ForceRefresh) }
            catch { $rejected=$true }
            if (-not $rejected -or $out.Count -ne 0) { throw "Incomplete or invalid inventory emitted: $mode" }
            "PASS: incomplete/invalid Graph response rejected / $mode."
        }
        $script:Fixture.Mode='Empty'
        $empty=Get-ExplorerCloudInventory -Source Entra -ForceRefresh
        if ($empty.Records.Count -ne 0 -or $empty.FromCache) { throw 'Empty completed collection incorrect.' }
        'PASS: empty successful cloud inventory.'
        $script:Fixture.Mode='Normal'
        $forced=Get-ExplorerCloudInventory -Source Entra -ForceRefresh
        if ($forced.Records.Count -ne 2 -or $forced.FromCache) { throw 'Failed refresh cache was reused.' }
        'PASS: refresh failure cannot be represented by stale success.'
        $cacheKey=@($script:CloudCache.Keys | Where-Object { $_ -like '*|Entra' -and $_ -like 'tenant-b*' -and $_ -like '*other@example.invalid*' })[0]
        $script:CloudCache[$cacheKey].CheckedAtUtc=[datetimeoffset]::UtcNow.AddMinutes(-6)
        if ((Get-ExplorerCloudInventory -Source Entra).FromCache) { throw 'Expired cache not refreshed.' }
        'PASS: expired cloud cache reread.'

        $sources=[ordered]@{}
        foreach ($name in @('AD','Entra','Intune','GLPI')) { $sources[$name]=New-ExplorerSource $name 'OK' }
        $controllers=@(1..5 | ForEach-Object { "dc$_.example.invalid" })
        $sources.AD.DcSources=@($controllers | ForEach-Object { [pscustomobject]@{DomainController=$_;Verificato=$true} })
        $sources.AD.Records=@($controllers | ForEach-Object { [pscustomobject]@{Name='PORT-001';DomainController=$_;ObjectGUID='ad-id';ParentPath='example.invalid/Laptops'} })
        $sources.Entra.Records=@(
            [pscustomobject]@{Name='port-001';ObjectId='entra-1';DeviceId='device-1'},
            [pscustomobject]@{Name='PORT-001';ObjectId='entra-2';DeviceId='device-2'},
            [pscustomobject]@{Name='CLOUD-ONLY';ObjectId='entra-3';DeviceId='device-3'}
        )
        $sources.Intune.Records=@([pscustomobject]@{Name='PORT-001';ManagedDeviceId='intune-1';AzureADDeviceId='device-1';SerialNumber='SERIAL-A'})
        $sources.GLPI.Records=@(
            [pscustomobject]@{Name='PORT-001';GlpiId=1;State='Assegnato';SerialNumber='SERIAL-A'},
            [pscustomobject]@{Name='PORT-001';GlpiId=2;State='Dismesso';SerialNumber='SERIAL-B'},
            [pscustomobject]@{Name='PORT-001 (999)';GlpiId=3;State='Assegnato';SerialNumber='SERIAL-C'}
        )
        $rows=@(Merge-ExplorerResults $sources $controllers)
        $row=@($rows | Where-Object { $_.Name -eq 'PORT-001' })[0]
        $only=@($rows | Where-Object { $_.Name -eq 'CLOUD-ONLY' })[0]
        if ($rows.Count -ne 3 -or $row.AD -ne '5/5' -or $row.ADColor -ne 'Verde' -or $row.Entra -ne '2' -or $row.EntraColor -ne 'Giallo' -or
            $row.IntuneColor -ne 'Verde' -or $row.GLPI -ne '2' -or $row.GLPIColor -ne 'Giallo' -or $row.GlpiRecords.Count -ne 2 -or
            $row.StatoGLPI -notlike '*Dismesso*' -or $row.Note -notlike '*Seriali diversi*' -or $only.ADColor -ne 'Rosso' -or $only.IntuneColor -ne 'Rosso') {
            throw 'Unified presence, duplicate records, aliases or ambiguity incorrect.'
        }
        'PASS: four-source union, exact case-insensitive names, duplicates, raw states and serial conflict.'
        foreach ($record in $sources.AD.Records) { $record | Add-Member NoteProperty LastModified ([datetime]'2026-10-13T18:00:00') }
        $sources.AD.Records[4].LastModified=[datetime]'2026-10-15T09:00:00'
        $sources.Entra.Records[0] | Add-Member NoteProperty LastSignIn '2026-10-14T23:30:00+02:00'
        $sources.Entra.Records[1] | Add-Member NoteProperty LastSignIn '2026-10-14T22:00:00Z'
        $sources.Intune.Records[0] | Add-Member NoteProperty LastSync '2026-10-15T07:30:00Z'
        $sources.GLPI.Records[0] | Add-Member NoteProperty LastInventory '2026-09-30 08:00:00'
        $sources.GLPI.Records[1] | Add-Member NoteProperty LastInventory '2026-10-01 09:10:00'
        $dated=@(Merge-ExplorerResults $sources $controllers | Where-Object { $_.Name -eq 'PORT-001' })[0]
        if ($dated.ADLastModified -ne [datetime]'2026-10-15T09:00:00' -or
            $dated.EntraLastActivity -ne ([datetimeoffset]'2026-10-14T22:00:00Z').LocalDateTime -or
            $dated.IntuneLastCheckIn -ne ([datetimeoffset]'2026-10-15T07:30:00Z').LocalDateTime -or
            $dated.GlpiLastInventory -ne [datetime]'2026-10-01T09:10:00' -or $dated.EntraLastActivity -isnot [datetime]) { throw 'Latest per-source dates or timezone conversion incorrect.' }
        if ($dated.ADRecords[0].LastModified -eq $dated.ADRecords[4].LastModified -or $dated.GlpiRecords[0].LastInventory -eq $dated.GlpiRecords[1].LastInventory) { throw 'Individual record dates replaced by aggregated dates.' }
        'PASS: latest date per source compares timestamps and preserves individual dates.'
        $unavailable=@(Merge-ExplorerResults $sources $controllers | Where-Object { $_.Name -eq 'CLOUD-ONLY' })[0]
        if ($null -ne $unavailable.ADLastModified -or $null -ne $unavailable.EntraLastActivity -or $null -ne $unavailable.IntuneLastCheckIn -or $null -ne $unavailable.GlpiLastInventory) { throw 'Date fabricated for an empty or undated source.' }
        foreach ($value in @($null, '', 'invalid', '0000-00-00 00:00:00', '0001-01-01T00:00:00Z', [datetime]::MinValue)) {
            if ($null -ne (ConvertTo-ExplorerDate $value) -or (Format-ExplorerDate $value) -ne '—') { throw 'Missing or sentinel date rendered as a real date.' }
        }
        'PASS: missing, invalid and sentinel dates remain unavailable.'
        if ((Format-ExplorerDate '2026-10-15 09:05:00') -ne '15/10/2026 09:05') { throw 'GLPI wall time or Italian display format incorrect.' }
        $typed=[datetimeoffset]'2026-10-14T22:00:00Z'
        if ((ConvertTo-ExplorerDate $typed) -ne $typed.LocalDateTime -or
            (ConvertTo-ExplorerDate $typed.UtcDateTime) -ne $typed.LocalDateTime) { throw 'Typed API dates not converted consistently.' }
        'PASS: Italian date format, GLPI server time and typed UTC/offset dates.'
        $sources.AD.Records=@($sources.AD.Records | Select-Object -First 2)
        $partial=@(Merge-ExplorerResults $sources $controllers | Where-Object { $_.Name -eq 'PORT-001' })[0]
        if ($partial.AD -ne '2/5' -or $partial.ADColor -ne 'Giallo') { throw 'Partial AD presence incorrect.' }
        $sources.AD.DcSources[4].Verificato=$false; $sources.AD.State='Errore'; $sources.Entra.State='Errore'
        $unknown=@(Merge-ExplorerResults $sources $controllers | Where-Object { $_.Name -eq 'PORT-001' })[0]
        if ($unknown.ADColor -ne 'Grigio' -or $unknown.Verificati -ne '4/5' -or $unknown.Entra -ne '?' -or $unknown.EntraColor -ne 'Grigio') {
            throw 'Unavailable source shown as absent or verified.'
        }
        'PASS: partial AD and unavailable-source colors preserve known counts.'
        $sources.AD.Records[1].ObjectGUID='other-guid'; $sources.AD.Records[1].ParentPath='example.invalid/Other'
        $sources.Entra.State='OK'; $sources.Intune.Records[0].AzureADDeviceId='unmatched-device'
        $conflicts=@(Merge-ExplorerResults $sources $controllers | Where-Object { $_.Name -eq 'PORT-001' })[0]
        if ($conflicts.Note -notlike '*GUID AD diversi*' -or $conflicts.Note -notlike '*Percorsi AD diversi*' -or $conflicts.Note -notlike '*DeviceId Intune*') { throw 'Identity/path conflict not exposed.' }
        'PASS: AD identity / OU and Entra-Intune DeviceId conflicts exposed.'

        $path=Join-Path ([IO.Path]::GetTempPath()) ('explorer-' + [guid]::NewGuid().ToString('N') + '.json')
        try {
            @{DomainControllers=$controllers;Search=@{MinimumCharacters=2;CloudCacheMinutes=5};Glpi=@{Enabled=$false}} | ConvertTo-Json -Depth 4 | Set-Content $path -Encoding UTF8
            $queue=New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
            $search=Invoke-ComputerExplorerSearch -NameFragment 'PoRt-' -ConfigPath $path -EnabledSources Entra,Intune -ProgressQueue $queue
            if ($search.Rows.Count -ne 2 -or $queue.Count -lt 4 -or -not $search.Complete) { throw 'Background snapshots or contains search incorrect.' }
            $contains=@($search.Rows | Where-Object { $_.Name -eq 'PA-PORT-001' })[0]
            if ($contains.ADColor -ne 'Grigio' -or $contains.Entra -ne '1' -or $contains.Intune -ne '1' -or $contains.GLPI -ne '?') { throw 'Contains result or excluded source incorrect.' }
            'PASS: orchestration emits immutable snapshots and finds a fragment in the middle of the name.'
            $rejected=$false
            try { Invoke-ComputerExplorerSearch -NameFragment 'P' -ConfigPath $path -EnabledSources Entra | Out-Null }
            catch { $rejected=$true }
            if (-not $rejected) { throw 'Too-short fragment accepted.' }
            'PASS: minimum fragment length enforced before requests.'
        }
        finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    }
}
finally { Remove-Module -ModuleInfo $module -Force -ErrorAction SilentlyContinue }

# Stesso canale di lavoro della UI: runspace persistente e coda concorrente.
$runspace=[RunspaceFactory]::CreateRunspace(); $runspace.Open()
$pipeline=[PowerShell]::Create(); $pipeline.Runspace=$runspace
try {
    $configFile=Join-Path (Split-Path $ModulePath -Parent) 'computer-explorer.config.example.json'
    $queue=New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    [void]$pipeline.AddScript({param($ModuleFile,$ConfigFile,$Queue)
        Import-Module $ModuleFile -ErrorAction Stop
        Invoke-ComputerExplorerSearch -NameFragment 'PORT-' -ConfigPath $ConfigFile -EnabledSources @('GLPI') -ProgressQueue $Queue
    }.ToString()).AddArgument((Resolve-Path $ModulePath).ProviderPath).AddArgument((Resolve-Path $configFile).ProviderPath).AddArgument($queue)
    $operation=$pipeline.BeginInvoke()
    $result=$pipeline.EndInvoke($operation)
    if ($pipeline.HadErrors -or $result.Count -ne 1 -or -not $result[0].Complete -or $queue.Count -lt 3) { throw 'Runspace / queue delivery failed.' }
    'PASS: native background runspace and concurrent queue.'
    $pipeline.Dispose(); $pipeline=[PowerShell]::Create(); $pipeline.Runspace=$runspace
    $ready=New-Object Threading.ManualResetEvent($false)
    try {
        [void]$pipeline.AddScript({param($Ready) [void]$Ready.Set(); Start-Sleep -Seconds 10; throw 'Cancellation did not stop the worker.'}.ToString()).AddArgument($ready)
        $operation=$pipeline.BeginInvoke()
        if (-not $ready.WaitOne(2000)) { throw 'Worker failed to start.' }
        $stop=$pipeline.BeginStop($null,$null)
        $pipeline.EndStop($stop)
        $stopped=$false
        try { $null=$pipeline.EndInvoke($operation) }
        catch { $stopped=$_.Exception.ToString() -like '*PipelineStopped*' }
        if (-not $stopped) { throw 'Asynchronous cancellation not confirmed.' }
        $pipeline.Dispose(); $pipeline=[PowerShell]::Create(); $pipeline.Runspace=$runspace
        [void]$pipeline.AddScript("'ready-again'")
        $again=$pipeline.Invoke()
        if ($again.Count -ne 1 -or $again[0] -ne 'ready-again') { throw 'Runspace cannot be reused after cancellation.' }
        'PASS: asynchronous cancellation and runspace reuse.'
    }
    finally { $ready.Dispose() }
}
finally { $pipeline.Dispose(); $runspace.Close(); $runspace.Dispose() }
