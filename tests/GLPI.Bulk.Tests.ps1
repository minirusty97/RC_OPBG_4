#requires -version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '../GLPI.Inventory.psm1') -Force -PassThru
try {
 & $module {
    $script:BulkFixture=@{Mode='';Batch=0;Single=0;Dropdown=0;Supplier=0;ScopeChanges=0;AllEntities=$false;Closed=0;Sizes=(New-Object 'Collections.Generic.List[int]')}
    function script:Invoke-RestMethod {
        [CmdletBinding()]param($Method,$Uri,$Headers,$ContentType,$TimeoutSec,$Body)
        $f=$script:BulkFixture;$parsed=[uri]$Uri;$q=@{}
        if ($parsed.AbsolutePath -like '*/changeActiveEntities') {
            if ($Method -ne 'POST' -or $Body -cne '{"is_recursive":true}' -or $Headers['Session-Token'] -ne 'synthetic') { throw 'GLPI 10.0.11 requires an authenticated session update with the entity ID omitted.' }
            $f.ScopeChanges++
            if ($f.Mode -eq 'ScopeDenied') { return $false }
            $f.AllEntities=$true
            return $true
        }
        if ($Method -ne 'GET') { throw 'Inventory attempted an asset write.' }
        foreach ($part in $parsed.Query.TrimStart('?').Split('&')) { if (-not $part) { continue };$pair=$part.Split('=',2);$q[[uri]::UnescapeDataString($pair[0])]=[uri]::UnescapeDataString($pair[1]) }
        if ($parsed.AbsolutePath -like '*/initSession') { $f.AllEntities=$false;return @{session_token='synthetic'} }
        if ($parsed.AbsolutePath -like '*/killSession') { $f.Closed++;return @{} }
        if ($parsed.AbsolutePath -like '*/listSearchOptions/Computer') { return ('{"1":{"table":"glpi_computers","field":"name"},"2":{"table":"glpi_computers","field":"id"},"5":{"table":"glpi_computers","field":"serial"}}'|ConvertFrom-Json) }
        if ($parsed.AbsolutePath -like '*/search/Computer') {
            $ids=@(1..45)
            if ($f.Mode -eq 'EntityVisibility' -and -not $f.AllEntities) { $ids=@(1..44) }
            if ($q['criteria[0][value]'] -ne 'PORT-') {
                $wanted=@();for ($i=0;$q.ContainsKey('criteria['+$i+'][value]');$i++) { $wanted+=@($q['criteria['+$i+'][value]'].Trim('^','$')) }
                $prefix='PORT-'
                if ($q['criteria[0][field]'] -eq '5') { $prefix='S-' }
                # GLPI 10 follows insertion order after parsing the query string.
                # Exercise the order [1, 0], with the missing link defaulting to AND.
                if ($f.Mode -eq 'ReorderedCriteria' -and $wanted.Count -eq 2 -and $q['criteria[0][link]'] -ne 'OR') {
                    $ids=@($ids | Where-Object { ($prefix+$_) -eq $wanted[1] -and ($prefix+$_) -eq $wanted[0] })
                }
                else { $ids=@($ids | Where-Object { $wanted -contains ($prefix+$_) }) }
            }
            $range=$q.range.Split('-');$start=[int]$range[0];$end=[int]$range[1]
            $page=@();if ($start -lt $ids.Count) { $page=@($ids[$start..([math]::Min($end,$ids.Count-1))]|ForEach-Object { @{ '1'=('PORT-'+$_);'2'=$_ } }) }
            return @{totalcount=$ids.Count;data=$page}
        }
        if ($parsed.AbsolutePath -like '*/getMultipleItems') {
            $f.Batch++;$ids=@();for ($i=0;$q.ContainsKey('items['+$i+'][items_id]');$i++) {
                if ($q['items['+$i+'][itemtype]'] -ne 'Computer') { throw 'Bulk endpoint requested another item type.' }
                $ids+=@([int]$q['items['+$i+'][items_id]'])
            }
            if ($q.get_hateoas -ne '0' -or $q.expand_dropdowns -ne '0' -or -not $ids.Count -or $ids.Count -gt 20) { throw 'Unbounded or expanded bulk read.' }
            [void]$f.Sizes.Add($ids.Count)
            if ($q.ContainsKey('with_infocoms') -and ($f.Mode -ne 'Supplier' -or $q.with_infocoms -ne '1')) { throw 'Unexpected administrative-data read.' }
            $rows=@($ids | Sort-Object -Descending | ForEach-Object { New-BulkComputer $_ -WithInfo:($q['with_infocoms'] -eq '1') })
            switch ($f.Mode) { Missing {$rows=@($rows|Select-Object -Skip 1)};Foreign {$rows[0].id=999};Duplicate {if($rows.Count -gt 1){$rows[0].id=$rows[1].id}} }
            return ,$rows
        }
        if ($parsed.AbsolutePath -match '/Computer/([0-9]+)$') { $f.Single++;return (New-BulkComputer ([int]$Matches[1])) }
        if ($parsed.AbsolutePath -like '*/State/9') { $f.Dropdown++;return @{id=9;name='Synthetic state'} }
        if ($parsed.AbsolutePath -like '*/Group/7') { $f.Dropdown++;return @{id=7;name='CENSITO';completename='CENSITO'} }
        if ($parsed.AbsolutePath -like '*/Supplier/7') { $f.Supplier++;return @{id=7;name='Synthetic department'} }
        if ($parsed.AbsolutePath -like '*/Supplier/8') { $f.Supplier++;throw 'Synthetic supplier read denial.' }
        throw ('Unexpected mock endpoint: '+$parsed.AbsolutePath)
    }
    function script:New-BulkComputer {
        param([int]$Id,[switch]$WithInfo)
        $computer=[pscustomobject]@{id=$Id;name=('PORT-'+$Id);serial=('S-'+$Id);groups_id=7;states_id=9;is_deleted=0;entities_id=0;otherserial='';date_mod='2026-01-01';last_inventory_update='2026-01-01'}
        if ($WithInfo) {
            $info=@{suppliers_id=7}
            switch ($Id) {
                1 { $computer.otherserial='00017' }
                3 { $info=@() }
                4 { $info=@('ERROR_RIGHT_MISSING','Synthetic management read denial.') }
                5 { $info=@{suppliers_id=8} }
                6 { $info=@{suppliers_id=0} }
            }
            $computer | Add-Member NoteProperty _infocoms $info
        }
        $computer
    }
    $user=ConvertTo-SecureString synthetic -AsPlainText -Force;$other=ConvertTo-SecureString other-synthetic -AsPlainText -Force
    try {
        $cache=[hashtable]::Synchronized(@{});$queue=New-Object 'Collections.Concurrent.ConcurrentQueue[object]'
        $args=@{BaseUri='https://example.invalid/apirest.php';UserToken=$user;PageSize=100;BulkRead=$true;LookupCache=$cache;ProgressQueue=$queue}
        $rows=@(Find-GlpiComputer @args -NameFragment 'PORT-')
        if ($rows.Count -ne 45 -or $script:BulkFixture.Batch -ne 3 -or $script:BulkFixture.Single -ne 0 -or $script:BulkFixture.Dropdown -ne 2 -or ($script:BulkFixture.Sizes -join ',') -ne '20,20,5' -or $queue.Count -ne 1) { throw 'Bulk inventory did not replace 45 individual reads with 3 bounded calls.' }
        $notice=$null;[void]$queue.TryDequeue([ref]$notice);if (-not $notice.Message -or -not $notice.Progress -or $notice.Source -ne 'GLPI') { throw 'Progress cannot be consumed by both UI coordinators.' }
        $serials=@(1..45|ForEach-Object {'S-'+$_});$rows=@(Find-GlpiComputer @args -SerialNumber $serials)
        if ($rows.Count -ne 45 -or $script:BulkFixture.Batch -ne 3 -or $script:BulkFixture.Dropdown -ne 2) { throw 'Serial enrichment reread already fetched assets or dropdowns.' }
        'PASS: 45 inventory assets use 3 bulk detail GETs and serial enrichment adds zero detail/dropdown GETs, with progress for both module UIs.'
        $fresh=@(Find-GlpiComputer -BaseUri $args.BaseUri -UserToken $user -NameFragment 'PORT-')
        if ($fresh.Count -ne 45 -or $script:BulkFixture.Single -ne 45) { throw 'Default fresh reads for destructive/archive callers were changed to cached inventory.' }
        $before=$script:BulkFixture.Batch;$args.UserToken=$other;$rows=@(Find-GlpiComputer @args -ExactName 'PORT-1')
        if ($rows.Count -ne 1 -or $script:BulkFixture.Batch -ne $before+1) { throw 'Inventory cache crossed credential boundaries.' }
        'PASS: fresh default reads bypass the inventory cache; different credentials cannot reuse its records.'
        $script:BulkFixture.Mode='Supplier';$before=$script:BulkFixture.Batch
        $supplied=@(Find-GlpiComputer @args -SerialNumber @('S-1','S-2','S-3','S-4','S-5','S-6') -IncludeSupplier)
        $byName=@(Find-GlpiComputer @args -ExactName @('PORT-1','PORT-7') -IncludeSupplier)
        if ($supplied.Count -ne 6 -or $byName.Count -ne 2 -or $script:BulkFixture.Batch -ne $before+2 -or $script:BulkFixture.Supplier -ne 2 -or
            $supplied[0].SupplierName -ne 'Synthetic department' -or $supplied[0].InventoryNumber -cne '00017' -or $byName[1].SupplierName -ne $supplied[0].SupplierName -or
            $supplied[2].SupplierName -or $supplied[2].SupplierError -or $supplied[2].InventoryNumber -or $supplied[3].SupplierName -or -not $supplied[3].SupplierError -or
            -not $supplied[4].SupplierError -or $supplied[5].SupplierName -or $supplied[5].SupplierError) { throw 'Supplier enrichment leaked across caches, hid assets or confused blank and inaccessible administrative fields.' }
        'PASS: the optional supplier uses bounded detail reads and one GET per supplier across serial and name lookups, preserves inventory numbers, and keeps denied assets visible.'
        $script:BulkFixture.Mode='ReorderedCriteria'
        $bySerial=@(Find-GlpiComputer @args -SerialNumber @('S-1','S-2'))
        $byName=@(Find-GlpiComputer @args -ExactName @('PORT-3','PORT-4'))
        if ((@($bySerial | ForEach-Object GlpiId) -join ',') -ne '1,2' -or (@($byName | ForEach-Object GlpiId) -join ',') -ne '3,4') {
            throw 'Reordered criteria hid existing GLPI computers during serial and exact-name lookup.'
        }
        'PASS: reversed GLPI query criteria preserve both serial matches and both exact-name matches.'
        $script:BulkFixture.Mode='EntityVisibility'
        $defaultEntity=@(Find-GlpiComputer @args -ExactName 'PORT-45')
        $allEntities=@(Find-GlpiComputer @args -ExactName 'PORT-45' -AllProfileEntities)
        if ($defaultEntity.Count -ne 0 -or $allEntities.Count -ne 1 -or $allEntities[0].GlpiId -ne 45 -or $script:BulkFixture.ScopeChanges -ne 1) { throw 'An existing asset outside the default entity was not visible in the authorized inventory.' }
        $script:BulkFixture.Mode='ScopeDenied';$closed=$script:BulkFixture.Closed;$failed=$false
        try { $null=Find-GlpiComputer @args -SerialNumber 'S-45' -AllProfileEntities } catch { $failed=$_.Exception.Message -like '*profilo GLPI*' }
        if (-not $failed -or $script:BulkFixture.Closed -ne $closed+1) { throw 'The connector hid an unconfirmed entity scope as absence or leaked its session.' }
        'PASS: inventory finds an authorized computer outside the default entity. A rejected entity selection fails explicitly and closes the API session.'
        foreach ($mode in @('Missing','Foreign','Duplicate')) {
            $script:BulkFixture.Mode=$mode;$args.LookupCache=@{};$out=@();$failed=$false
            try { $out=@(Find-GlpiComputer @args -NameFragment 'PORT-') } catch { $failed=$true }
            if (-not $failed -or $out.Count) { throw ('Invalid multi-item response published partial inventory: '+$mode) }
        }
        'PASS: missing, foreign and duplicate bulk IDs fail explicitly without publishing incomplete inventory.'
    }
    finally { $user.Dispose();$other.Dispose() }
 }
}
finally { Remove-Module -ModuleInfo $module -Force }
