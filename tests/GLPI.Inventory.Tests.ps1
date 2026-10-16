#requires -version 5.1
[CmdletBinding()]
param(
    [string]$ModulePath = (Join-Path $PSScriptRoot '../GLPI.Inventory.psm1')
)

$ErrorActionPreference = 'Stop'
$module = Import-Module $ModulePath -Force -PassThru -ErrorAction Stop
try {
    & $module {
        $cases = @(
            @{ Name='single-result array'; Json='{"data":[{"1":"PORT-301","2":301}]}'; Ids=@(301) },
            @{ Name='multiple-result array'; Json='{"data":[{"1":"PORT-301","2":301},{"1":"PORT-302","2":302}]}'; Ids=@(301,302) },
            @{ Name='single row object'; Json='{"data":{"1":"PORT-301","2":301}}'; Ids=@(301) },
            @{ Name='indexed numeric columns'; Json='{"data":{"301":{"1":"PORT-301","2":301}}}'; Ids=@(301) },
            @{ Name='indexed row without ID column'; Json='{"data":{"301":{"1":"PORT-301"}}}'; Ids=@(301) },
            @{ Name='UID column names'; Json='{"data":[{"Computer.name":"PORT-301","Computer.id":301}]}'; Ids=@(301) },
            @{ Name='indexed UID columns'; Json='{"data":{"301":{"Computer.name":"PORT-301","Computer.id":301}}}'; Ids=@(301) },
            @{ Name='row ID equals column option'; Json='{"data":{"2":{"1":"PORT-2","2":2}}}'; Ids=@(2) },
            @{ Name='zero-result array'; Json='{"data":[]}'; Ids=@() },
            @{ Name='zero-result map'; Json='{"data":{}}'; Ids=@() }
        )
        foreach ($case in $cases) {
            $page = $case.Json | ConvertFrom-Json
            $data = Get-GlpiValue $page 'data'
            $records = @(ConvertTo-GlpiSearchRecords -Data $data -IdOption '2' -NameOption '1')
            $ids = @($records | ForEach-Object { Resolve-GlpiComputerId -Row $_.Values -IdOption '2' -IndexedId $_.IndexedId })
            if (($ids -join ',') -ne ($case.Ids -join ',')) { throw "IDs incorrect: $($case.Name)" }
            "PASS: $($case.Name)."
        }
        $dictionary = @{ data = @(@{ '1'='PORT-301'; '2'=301 }) }
        $array = Get-GlpiValue $dictionary 'data'
        if (-not ($array -is [Array]) -or $array.Count -ne 1) { throw 'Dictionary array was flattened.' }
        $row = @(ConvertTo-GlpiSearchRecords -Data $array -IdOption '2' -NameOption '1')[0]
        if ((Resolve-GlpiComputerId -Row $row.Values -IdOption '2' -IndexedId $row.IndexedId) -ne 301) { throw 'Dictionary row ID.' }
        'PASS: dictionary property access preserves arrays.'
        $conflict = $false
        try { Resolve-GlpiComputerId -Row ([pscustomobject]@{ '2'=301 }) -IdOption '2' -IndexedId '302' | Out-Null }
        catch { $conflict = $_.Exception.Message -like '*diverso*' }
        if (-not $conflict) { throw 'Conflicting IDs were not rejected.' }
        'PASS: conflicting row IDs rejected.'

        # Stub REST nello stesso scope del modulo: nessuna richiesta al GLPI reale.
        function script:Invoke-RestMethod {
            [CmdletBinding()]
            param([string]$Method, [string]$Uri, [hashtable]$Headers, [string]$ContentType, [int]$TimeoutSec)
            if ($Method -ne 'GET') { throw 'Unexpected write operation.' }
            $parsed = [Uri]$Uri
            [void]$script:RequestPaths.Add($parsed.AbsolutePath)
            switch -Regex ($parsed.AbsolutePath) {
                '/initSession$' { return [pscustomobject]@{session_token='synthetic-session'} }
                '/killSession$' { return [pscustomobject]@{success=$true} }
                '/listSearchOptions/Computer$' {
                    return ('{"common":"Characteristics","1":{"table":"glpi_computers","field":"name"},"2":{"table":"glpi_computers","field":"id"}}' | ConvertFrom-Json)
                }
                '/search/Computer$' {
                    $query = @{}
                    foreach ($part in $parsed.Query.TrimStart('?').Split('&')) {
                        $pair = $part.Split('=')
                        $query[[Uri]::UnescapeDataString($pair[0])] = [Uri]::UnescapeDataString($pair[1])
                    }
                    foreach ($key in @('giveItems','uid_cols','is_deleted')) {
                        if ($query[$key] -ne '0') { throw "Boolean not serialized as 0: $key" }
                    }
                    if ($query['withindexes'] -ne '1') { throw 'Missing indexed search request.' }
                    if ($query['criteria[0][value]'] -ne 'PORT-') { throw 'Name fragment not correctly encoded.' }
                    switch ($script:FixtureKind) {
                        'ArraySingle' { return ('{"totalcount":1,"data":[{"1":"PORT-301","2":301}]}' | ConvertFrom-Json) }
                        'UIDSingle' { return ('{"totalcount":1,"data":[{"Computer.name":"PORT-301","Computer.id":301}]}' | ConvertFrom-Json) }
                        'IndexedNoColumn' { return ('{"totalcount":1,"data":{"301":{"1":"PORT-301"}}}' | ConvertFrom-Json) }
                        'NoResults' { return ('{"totalcount":0,"data":[]}' | ConvertFrom-Json) }
                        default {
                            $offset = [int]($query['range'].Split('-')[0])
                            if ($script:FixtureKind -eq 'PageFailure' -and $offset -gt 0) { throw 'Synthetic second-page failure.' }
                            $id = 301 + $offset
                            $payload = @{totalcount=2; data=@{([string]$id)=@{ '1'="PORT-$id"; '2'=$id }}}
                            return ($payload | ConvertTo-Json -Depth 6 | ConvertFrom-Json)
                        }
                    }
                }
                '/Computer/([0-9]+)$' {
                    $id = [int]$Matches[1]
                    return [pscustomobject]@{id=$id;name="PORT-$id";groups_id=7;groups_id_tech=8;states_id=9;serial="TEST-$id";otherserial="INV-$id";entities_id=0;is_deleted=0;date_mod='2026-10-15 10:00:00';last_inventory_update='2026-10-14 08:20:00'}
                }
                '/Group/7$' {
                    if ($script:FixtureKind -eq 'GroupFailure') { throw 'Synthetic group permission failure.' }
                    return [pscustomobject]@{id=7;name='CENSITO';completename='Inventario > CENSITO'}
                }
                '/State/9$' { return [pscustomobject]@{ id=9; name='Assegnato noleggio' } }
                default { throw 'Unexpected mocked endpoint.' }
            }
        }

        $userToken = ConvertTo-SecureString 'synthetic-user-token' -AsPlainText -Force
        $appToken = ConvertTo-SecureString 'synthetic-app-token' -AsPlainText -Force
        foreach ($mode in @('ArraySingle','UIDSingle','IndexedNoColumn','NoResults','Paging')) {
            $script:FixtureKind = $mode
            $script:RequestPaths = New-Object 'System.Collections.Generic.List[string]'
            $rows = @(Find-GlpiComputer -BaseUri 'https://example.invalid/apirest.php' -NameFragment 'PORT-' -UserToken $userToken -AppToken $appToken -PageSize 1)
            $expected = 1
            if ($mode -eq 'Paging') { $expected=2 }
            if ($mode -eq 'NoResults') { $expected=0 }
            if ($rows.Count -ne $expected) { throw "Result count incorrect: $mode" }
            foreach ($row in $rows) {
                if (-not $row.GroupVerified -or $row.GroupName -ne 'CENSITO' -or $row.GroupId -ne 7) { throw 'Assigned group not resolved independently of technical group.' }
                if ($row.State -ne 'Assegnato noleggio' -or $row.GlpiId -le 0) { throw 'Invalid parsed inventory.' }
                if ($row.LastInventory -ne '2026-10-14 08:20:00' -or $row.LastModified -ne '2026-10-15 10:00:00') { throw 'GLPI inventory date confused with asset modification date.' }
            }
            if (@($script:RequestPaths | Where-Object { $_ -like '*/killSession' }).Count -ne 1) { throw 'Session not closed.' }
            if ($expected -gt 0 -and @($script:RequestPaths | Where-Object { $_ -like '*/State/9' }).Count -ne 1) { throw 'State lookup not cached.' }
            if ($expected -gt 0 -and @($script:RequestPaths | Where-Object { $_ -like '*/Group/7' }).Count -ne 1) { throw 'Group lookup not cached.' }
            "PASS: full connector / mocked REST: $mode."
        }
        $script:FixtureKind='GroupFailure'
        $script:RequestPaths=New-Object 'System.Collections.Generic.List[string]'
        $groupFailure=@(Find-GlpiComputer -BaseUri 'https://example.invalid/apirest.php' -NameFragment 'PORT-' -UserToken $userToken -PageSize 1)
        if ($groupFailure.Count -ne 2 -or @($groupFailure | Where-Object { $_.GroupVerified -or $_.GroupError -ne 'Synthetic group permission failure.' }).Count -gt 0) { throw 'Unreadable groups lost assets or became a confirmed group.' }
        if (@($script:RequestPaths | Where-Object { $_ -like '*/killSession' }).Count -ne 1) { throw 'Group error leaked session.' }
        'PASS: an unreadable group preserves inventory, exposes uncertainty and closes the session.'
        $script:FixtureKind='PageFailure' 
        $script:RequestPaths=New-Object 'System.Collections.Generic.List[string]'
        $out=@()
        $failed=$false
        try { $out=@(Find-GlpiComputer -BaseUri 'https://example.invalid/apirest.php' -NameFragment 'PORT-' -UserToken $userToken -AppToken $appToken -PageSize 1) }
        catch { $failed=$_.Exception.Message -eq 'Synthetic second-page failure.' }
        if (-not $failed -or $out.Count -ne 0) { throw 'Incomplete-page results escaped.' }
        if (@($script:RequestPaths | Where-Object { $_ -like '*/killSession' }).Count -ne 1) { throw 'Session left open after failure.' }
        'PASS: partial page failure returns no incomplete inventory and closes the session.'
    }

}
finally {
    Remove-Module -ModuleInfo $module -Force -ErrorAction SilentlyContinue
}
