#requires -version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $root 'ComputerExplorer.Core.psm1') -Force -PassThru
try {
    $settings=[pscustomobject]@{DomainControllers=@('dc2.example.invalid','srvdc1.example.invalid','dc3.example.invalid','dc4.example.invalid','dc5.example.invalid');Search=[pscustomobject]@{DomainController='';AllDomainControllers=$false}}
    $ordered=@(Get-ExplorerSearchControllers $settings)
    if ($ordered.Count -ne 5 -or $ordered[0] -ne 'srvdc1.example.invalid') { throw 'Legacy settings narrowed the search or lost the default primary DC.' }
    $settings.Search.DomainController='dc3'
    $ordered=@(Get-ExplorerSearchControllers $settings)
    if ($ordered.Count -ne 5 -or $ordered[0] -ne 'dc3.example.invalid') { throw 'Explicit short name did not set the primary while preserving all DCs.' }
    $settings.Search.DomainController='outside.example.invalid';$failed=$false
    try { $null=Get-ExplorerSearchControllers $settings } catch { $failed=$true };if (-not $failed) { throw 'Unconfigured consultation server accepted.' }
    $settings.Search.DomainController='';$settings.DomainControllers=@('dc2.example.invalid','dc3.example.invalid')
    if (@(Get-ExplorerSearchControllers $settings)[0] -ne 'dc2.example.invalid') { throw 'First configured fallback is not deterministic.' }
    $settings.DomainControllers+=@('dc1.example.invalid')
    if (@(Get-ExplorerSearchControllers $settings)[0] -ne 'dc1.example.invalid') { throw 'Short name dc1 did not take priority.' }
    'PASS: ordinary search keeps all configured DCs with a validated primary first, including installations with the legacy single-DC setting.'
    & $module {
        $script:PerfSerialCalls=0;$script:PerfMaxAd=0;$script:PerfOriginalSerials=${function:Get-ExplorerSerials};$script:PerfOriginalHybrid=${function:Get-ExplorerHybridIdentity}
        function script:Get-ExplorerSerials { param([object[]]$Records);$script:PerfSerialCalls++;& $script:PerfOriginalSerials -Records $Records }
        function script:Get-ExplorerHybridIdentity {
            param($Name,$AdRecords,$EntraRecords,$AdComplete,$EntraComplete,$LookupComplete,$SearchController)
            $script:PerfMaxAd=[math]::Max($script:PerfMaxAd,$AdRecords.Count)
            & $script:PerfOriginalHybrid @PSBoundParameters
        }
        $count=80;$sources=[ordered]@{};foreach ($name in @('AD','Entra','Intune','GLPI')) { $sources[$name]=New-ExplorerSource $name 'OK' }
        $sources.AD.DcSources=@([pscustomobject]@{DomainController='dc.example.invalid';Verificato=$true})
        $sources.AD.Records=@(1..$count|ForEach-Object {[pscustomobject]@{Name=('PORT-'+$_);DomainController='dc.example.invalid';ParentPath='Lab';ObjectGUID=('{0:x8}-0000-4000-8000-000000000001' -f $_);LastModified=$null}})
        $sources.Entra.Records=@(1..$count|ForEach-Object {[pscustomobject]@{Name=('PORT-'+$_);ObjectId=('{0:x8}-0000-4000-8000-000000000002' -f $_);DeviceId=('{0:x8}-0000-4000-8000-000000000001' -f $_);TrustType='ServerAd';LastSignIn=$null}})
        $sources.Intune.Records=@(1..$count|ForEach-Object {[pscustomobject]@{Name=('PORT-'+$_);ManagedDeviceId=($_.ToString());AzureADDeviceId=('{0:x8}-0000-4000-8000-000000000001' -f $_);SerialNumber=('SERIAL-'+$_);LastSync=$null}})
        $sources.GLPI.Records=@(1..$count|ForEach-Object {[pscustomobject]@{Name=('RENAMED-'+$_);GlpiId=$_;SerialNumber=('SERIAL-'+$_);State='Synthetic';GroupVerified=$true;GroupName='CENSITO';LastInventory=$null}})
        $rows=@(Merge-ExplorerResults -Sources $sources -DomainControllers @('dc.example.invalid'))
        if ($rows.Count -ne $count -or @($rows|Where-Object {$_.HybridCheck -ne 'Corrisponde' -or $_.GLPI -ne '1'}).Count -or $script:PerfSerialCalls -gt 8*$count -or $script:PerfMaxAd -gt 2) { throw 'Inventory matching repeated global serial/AD scans or lost identity results.' }
        'PASS: synthetic prefix matching keeps serial extraction linear and compares only the primary AD records for the row, preserving renamed GLPI and Hybrid matches.'
    }
}
finally { Remove-Module -ModuleInfo $module -Force }
$module=Import-Module (Join-Path $root 'ComputerExplorer.Parallel.psm1') -Force -PassThru
$configPath=Join-Path ([IO.Path]::GetTempPath()) ('search-dc-'+[guid]::NewGuid().ToString('N')+'.json')
try {
 & $module {
    param($ConfigPath)
    $script:PerfReads=New-Object 'Collections.Concurrent.ConcurrentQueue[string]'
    function script:Get-ExplorerCloudCache { return [hashtable]::Synchronized(@{Reads=$script:PerfReads}) }
    function script:Get-ExplorerReadWorkerScript { return {
        param($Job,$CorePath,$ConfigPath,$Fragment,$Configuration,$Cache)
        $Cache.Reads.Enqueue($Job.DomainController)
        if ($Configuration.Settings.Search.FailPrimary -and $Job.DomainController -eq 'srvdc1.example.invalid') { throw 'Synthetic primary DC unavailable.' }
        [pscustomobject]@{State='OK';Records=@();DcSources=@([pscustomobject]@{DomainController=$Job.DomainController;Verificato=$true});CheckedAtUtc=[datetimeoffset]::UtcNow;FromCache=$false;Error=$null}
    } }
    $config=@{DomainControllers=@('dc2.example.invalid','srvdc1.example.invalid','dc3.example.invalid');Search=@{MinimumCharacters=2;FailPrimary=$false};Glpi=@{Enabled=$false}}
    $config|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $ConfigPath -Encoding UTF8
    $result=Invoke-ComputerExplorerParallelSearch -NameFragment 'PORT-' -ConfigPath $ConfigPath -EnabledSources AD
    if (-not $result.Complete -or ($script:PerfReads.ToArray() -join '|') -ne 'srvdc1.example.invalid|dc2.example.invalid|dc3.example.invalid' -or $result.Sources[0].DcSources.Count -ne 3) { throw 'Parallel coordinator did not consult all DCs with the primary first.' }
    $config.Search.FailPrimary=$true;$config|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $ConfigPath -Encoding UTF8
    $result=Invoke-ComputerExplorerParallelSearch -NameFragment 'PORT-' -ConfigPath $ConfigPath -EnabledSources AD
    if ($script:PerfReads.Count -ne 6 -or $result.Sources[0].State -ne 'Errore' -or $result.Sources[0].DcSources.Count -ne 3 -or
        $result.Sources[0].DcSources[0].Verificato -or @($result.Sources[0].DcSources | Where-Object Verificato).Count -ne 2) { throw 'Primary failure skipped other DCs or fabricated successful reads.' }
    'PASS: the production coordinator reads each configured DC once, including when the primary is unavailable.'
    $script:PerfMerges=0
    function script:Merge-ExplorerResults {param($Sources,$DomainControllers);$script:PerfMerges++;[pscustomobject]@{Name='SYNTHETIC'}}
    $sources=[ordered]@{AD=(New-ParallelSource AD OK)};$queue=New-Object 'Collections.Concurrent.ConcurrentQueue[object]'
    Send-ParallelSnapshot $sources @('dc.example.invalid') 'Data' $queue
    1..12 | ForEach-Object { Send-ParallelSnapshot $sources @('dc.example.invalid') 'Page progress' $queue -ReuseRows }
    if ($script:PerfMerges -ne 1 -or $queue.Count -ne 13) { throw 'Progress-only notifications rebuilt the entire grid.' }
    Send-ParallelSnapshot $sources @('dc.example.invalid') 'New data' $queue
    if ($script:PerfMerges -ne 2) { throw 'A source data change reused stale rows.' }
    'PASS: page progress reuses computed rows; actual source changes rebuild them.'
 } $configPath
}
finally { Remove-Module -ModuleInfo $module -Force;Remove-Item -LiteralPath $configPath -Force -ErrorAction SilentlyContinue }
