#requires -version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $root 'ComputerExplorer.Core.psm1') -Force -PassThru
try {
    $settings=[pscustomobject]@{DomainControllers=@('dc2.example.invalid','srvdc1.example.invalid','dc3.example.invalid','dc4.example.invalid','dc5.example.invalid');Search=[pscustomobject]@{DomainController='';AllDomainControllers=$false}}
    if (@(Get-ExplorerSearchControllers $settings).Count -ne 1 -or (Get-ExplorerSearchControllers $settings) -ne 'srvdc1.example.invalid') { throw 'Default reads did not choose configured srvDC1.' }
    $settings.Search.DomainController='dc3'
    if ((Get-ExplorerSearchControllers $settings) -ne 'dc3.example.invalid') { throw 'Explicit short name did not resolve to the configured DC.' }
    $settings.Search.AllDomainControllers=$true
    if (@(Get-ExplorerSearchControllers $settings).Count -ne 5) { throw 'All-DC diagnostic lost controllers.' }
    $settings.Search.AllDomainControllers=$false;$settings.Search.DomainController='outside.example.invalid';$failed=$false
    try { $null=Get-ExplorerSearchControllers $settings } catch { $failed=$true };if (-not $failed) { throw 'Unconfigured consultation server accepted.' }
    $settings.Search.DomainController='';$settings.DomainControllers=@('dc2.example.invalid','dc3.example.invalid')
    if ((Get-ExplorerSearchControllers $settings) -ne 'dc2.example.invalid') { throw 'First configured fallback is not deterministic.' }
    'PASS: ordinary search selects one configured srvDC1, explicit DCs are validated, missing srvDC1 falls back to the first configured DC and all-DC diagnostics remain available.'
    & $module {
        $script:PerfSerialCalls=0;$script:PerfMaxAd=0;$script:PerfOriginalSerials=${function:Get-ExplorerSerials};$script:PerfOriginalHybrid=${function:Get-ExplorerHybridIdentity}
        function script:Get-ExplorerSerials { param([object[]]$Records);$script:PerfSerialCalls++;& $script:PerfOriginalSerials -Records $Records }
        function script:Get-ExplorerHybridIdentity {
            param($Name,$AdRecords,$EntraRecords,$AllAdRecords,$AdComplete,$EntraComplete,$LookupComplete,$LookupError)
            $script:PerfMaxAd=[math]::Max($script:PerfMaxAd,$AllAdRecords.Count)
            & $script:PerfOriginalHybrid @PSBoundParameters
        }
        $count=80;$sources=[ordered]@{};foreach ($name in @('AD','Entra','Intune','GLPI')) { $sources[$name]=New-ExplorerSource $name 'OK' }
        $sources.AD.DcSources=@([pscustomobject]@{Verificato=$true})
        $sources.AD.Records=@(1..$count|ForEach-Object {[pscustomobject]@{Name=('PORT-'+$_);DomainController='dc.example.invalid';ParentPath='Lab';ObjectGUID=('{0:x8}-0000-4000-8000-000000000001' -f $_);LastModified=$null}})
        $sources.Entra.Records=@(1..$count|ForEach-Object {[pscustomobject]@{Name=('PORT-'+$_);ObjectId=('{0:x8}-0000-4000-8000-000000000002' -f $_);DeviceId=('{0:x8}-0000-4000-8000-000000000001' -f $_);TrustType='ServerAd';LastSignIn=$null}})
        $sources.Intune.Records=@(1..$count|ForEach-Object {[pscustomobject]@{Name=('PORT-'+$_);ManagedDeviceId=($_.ToString());AzureADDeviceId=('{0:x8}-0000-4000-8000-000000000001' -f $_);SerialNumber=('SERIAL-'+$_);LastSync=$null}})
        $sources.GLPI.Records=@(1..$count|ForEach-Object {[pscustomobject]@{Name=('RENAMED-'+$_);GlpiId=$_;SerialNumber=('SERIAL-'+$_);State='Synthetic';GroupVerified=$true;GroupName='CENSITO';LastInventory=$null}})
        $rows=@(Merge-ExplorerResults -Sources $sources -DomainControllers @('dc.example.invalid'))
        if ($rows.Count -ne $count -or @($rows|Where-Object {$_.HybridCheck -ne 'Corrisponde' -or $_.GLPI -ne '1'}).Count -or $script:PerfSerialCalls -gt 8*$count -or $script:PerfMaxAd -gt 2) { throw 'Inventory matching repeated global serial/AD scans or lost identity results.' }
        'PASS: synthetic prefix matching keeps serial extraction linear and passes only relevant AD identities to each row, while preserving renamed GLPI and Hybrid matches.'
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
        if ($Configuration.Settings.Search.FailPrimary) { throw 'Synthetic primary DC unavailable.' }
        [pscustomobject]@{State='OK';Records=@();DcSources=@([pscustomobject]@{DomainController=$Job.DomainController;Verificato=$true});CheckedAtUtc=[datetimeoffset]::UtcNow;FromCache=$false;Error=$null}
    } }
    $config=@{DomainControllers=@('dc2.example.invalid','srvdc1.example.invalid','dc3.example.invalid');Search=@{MinimumCharacters=2;FailPrimary=$false};Glpi=@{Enabled=$false}}
    $config|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $ConfigPath -Encoding UTF8
    $result=Invoke-ComputerExplorerParallelSearch -NameFragment 'PORT-' -ConfigPath $ConfigPath -EnabledSources AD
    if (-not $result.Complete -or $script:PerfReads.Count -ne 1 -or $script:PerfReads.ToArray()[0] -ne 'srvdc1.example.invalid' -or $result.Sources[0].DcSources.Count -ne 1) { throw 'Parallel coordinator ignored the one-DC selection.' }
    $config.Search.FailPrimary=$true;$config|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $ConfigPath -Encoding UTF8
    $result=Invoke-ComputerExplorerParallelSearch -NameFragment 'PORT-' -ConfigPath $ConfigPath -EnabledSources AD
    if ($script:PerfReads.Count -ne 2 -or $result.Sources[0].State -ne 'Errore' -or $result.Sources[0].DcSources.Count -ne 1 -or $result.Sources[0].DcSources[0].Verificato) { throw 'Primary failure fabricated successful reads or silently retried all DCs.' }
    'PASS: the production parallel coordinator issues one AD read and reports an unavailable primary explicitly without claiming that the other DCs were checked.'
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
