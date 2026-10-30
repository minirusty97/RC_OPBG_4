#requires -version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '../BitLocker.Archive.psm1') -Force -PassThru
try {
 & $module {
  $password='000011-000022-000033-000044-000055-000066-000077-000088'
  $record=[pscustomobject]@{SchemaVersion=2;ComputerId=901;Name='PC-TEST';Serial='SERIAL-TEST';KeyId='33333333-3333-4333-8333-333333333333';Password=$password;Volume='operatingSystemVolume';CreatedAt='2026-10-01T10:00:00Z';ArchivedAtUtc='2026-10-30T10:00:00Z';Origins=@('Intune:11111111-1111-4111-8111-111111111111','AD:11111111-1111-4111-8111-111111111111')}
  $text=ConvertTo-BlPlainNote $record
  if ($text -notlike ('*Computer: PC-TEST*Seriale: SERIAL-TEST*ID chiave: '+$record.KeyId+'*Chiave di recupero: '+$password+'*') -or $text -match '<p>|<pre>|&quot;|"SchemaVersion"') { throw 'Native GLPI note is not readable plain text.' }
  $read=Read-BlNote ([pscustomobject]@{content=$text}) 901
  if ($read.SchemaVersion -ne 2 -or $read.Password -cne $password -or $read.KeyId -ne $record.KeyId -or $read.Origins.Count -ne 2 -or $read.Serial -cne $record.Serial) { throw 'Readable note lost recovery data.' }
  $record.Name="PC%26&A<test>`r`nID chiave: fake";$record.Serial='SERIAL%20&copy;'
  $read=Read-BlNote ([pscustomobject]@{content=[Net.WebUtility]::HtmlEncode((ConvertTo-BlPlainNote $record))}) 901
  if ($read.Name -cne $record.Name -or $read.Serial -cne $record.Serial) { throw 'Line delimiters, percent signs or literal HTML entities changed archived identity.' }
  $legacy=$record | Select-Object *;$legacy.SchemaVersion=1
  $old='<p>Archivio</p><pre>[AIT-BITLOCKER-V1]'+[Environment]::NewLine+[Net.WebUtility]::HtmlEncode(($legacy | ConvertTo-Json -Depth 5))+'</pre>'
  $read=Read-BlNote ([pscustomobject]@{content=$old}) 901
  if ($read.SchemaVersion -ne 1 -or $read.Password -cne $password -or $read.Name -cne $record.Name) { throw 'Existing HTML/JSON notes stopped being readable.' }
  foreach ($bad in @($text.Replace('Computer GLPI: 901','Computer GLPI: 902'),($text+[Environment]::NewLine+'ID chiave: '+$record.KeyId),$text.Replace('Chiave di recupero:','Campo diverso:'))) {
   $failed=$false;try { $null=Read-BlNote ([pscustomobject]@{content=$bad}) 901 } catch { $failed=$true }
   if (-not $failed) { throw 'Foreign, duplicated or incomplete readable note was accepted.' }
  }
  'PASS: native notes are plain readable text, retain special characters losslessly, read existing V1 HTML/JSON and reject foreign, duplicate or missing fields.'
 }
}
finally { Remove-Module -ModuleInfo $module -Force }
