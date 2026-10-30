#requires -version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '../GLPI.Inventory.psm1') -Force -PassThru
try {
 & $module {
  $script:SerialFixture=@{Mode='Normal';Opens=0;Closes=0;Searches=(New-Object 'Collections.Generic.List[object]')}
  function script:Invoke-GlpiRead {
   param($Session,$Path,$Query=@{})
   switch -Regex ($Path) {
    '^initSession$' { $script:SerialFixture.Opens++;return @{session_token='synthetic'} }
    '^killSession$' { $script:SerialFixture.Closes++;return @{} }
    '^listSearchOptions/Computer$' { return ('{"10":{"table":"glpi_computers","field":"id"},"12":{"table":"glpi_computers","field":"name"},"77":{"table":"glpi_computers","field":"serial"}}' | ConvertFrom-Json) }
    '^search/Computer$' {
     [void]$script:SerialFixture.Searches.Add($Query.Clone())
     if ($script:SerialFixture.Mode -eq 'Batches') { return @{totalcount=0;data=@()} }
     if ($Query['criteria[0][field]'] -ne '77' -or $Query['criteria[0][searchtype]'] -ne 'contains' -or $Query['criteria[0][value]'] -ne '^S_01&+$') { throw 'Serial search is not anchored to the dynamically resolved serial field.' }
     if ($script:SerialFixture.Mode -eq 'Duplicate') { return @{totalcount=2;data=@(@{'10'=1;'12'='NOME-DIVERSO'},@{'10'=2;'12'='ALTRO-NOME'})} }
     return @{totalcount=2;data=@(@{'10'=1;'12'='NOME-DIVERSO'},@{'10'=3;'12'='SERIALE-PARZIALE'})}
    }
    '^Computer/([0-9]+)$' {
     $id=[int]$Matches[1];$serial='S_01&+';if ($id -eq 3) { $serial='S_01&+-ALTRO' }
     return @{id=$id;name=('NOME-DIVERSO-'+$id);serial=$serial;groups_id=0;states_id=0;otherserial='';entities_id=0;is_deleted=0}
    }
    default { throw 'Unexpected endpoint in serial fixture.' }
   }
  }
  $token=ConvertTo-SecureString 'synthetic-token' -AsPlainText -Force
  try {
   $rows=@(Find-GlpiComputer -BaseUri https://example.invalid/apirest.php -SerialNumber ' s_01&+ ' -UserToken $token)
   if ($rows.Count -ne 1 -or $rows[0].GlpiId -ne 1 -or $rows[0].Name -ne 'NOME-DIVERSO-1') { throw 'Exact serial lookup required a matching name or accepted a partial serial.' }
   'PASS: GLPI searches the dynamically resolved serial field with anchored string criteria and validates exact normalized detail serials, preserving the actual different GLPI name.'
   $script:SerialFixture.Mode='Duplicate'
   $rows=@(Find-GlpiComputer -BaseUri https://example.invalid/apirest.php -SerialNumber 'S_01&+' -UserToken $token)
   if ($rows.Count -ne 2) { throw 'Separate assets with the same serial were collapsed into a false unique match.' }
   'PASS: multiple GLPI asset IDs with the same hardware serial remain explicit duplicates.'
   $script:SerialFixture.Mode='Batches';$script:SerialFixture.Searches.Clear();$script:SerialFixture.Opens=0;$script:SerialFixture.Closes=0
   $serials=@(1..21 | ForEach-Object { 'SERIAL-'+$_ })
   $rows=@(Find-GlpiComputer -BaseUri https://example.invalid/apirest.php -SerialNumber $serials -UserToken $token)
   if ($rows.Count -ne 0 -or $script:SerialFixture.Opens -ne 1 -or $script:SerialFixture.Closes -ne 1 -or $script:SerialFixture.Searches.Count -ne 2 -or $script:SerialFixture.Searches[0]['criteria[1][link]'] -ne 'OR') { throw 'Bulk serial lookup did not batch criteria within one session.' }
   'PASS: serial enrichment uses bounded OR batches in one GLPI session, retaining normal pagination and cleanup.'
   $script:SerialFixture.Searches.Clear()
   $rows=@(Find-GlpiComputer -BaseUri https://example.invalid/apirest.php -ExactName @('PC-ONE','PC-TWO') -UserToken $token)
   $query=$script:SerialFixture.Searches[0]
   if ($query['criteria[0][field]'] -ne '12' -or $query['criteria[0][value]'] -ne '^PC-ONE$' -or $query['criteria[1][value]'] -ne '^PC-TWO$' -or $query['criteria[1][link]'] -ne 'OR') { throw 'Exact-name batches did not use the resolved name field and anchored criteria.' }
   'PASS: module GLPI enrichment batches exact names through the resolved name field, preserving one-session pagination behavior.'

  }
  finally { $token.Dispose() }
 }
}
finally { Remove-Module -ModuleInfo $module -Force }
