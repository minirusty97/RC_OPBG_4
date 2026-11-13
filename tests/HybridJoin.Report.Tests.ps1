#requires -version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'HybridJoin.Report.psm1') -ErrorAction Stop
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Read-ReportPart {
    param($Zip, [string]$Path)
    $stream = $Zip.GetEntry($Path).Open()
    try {
        $xml = New-Object Xml.XmlDocument
        $xml.Load($stream)
        return ,$xml
    }
    finally { $stream.Dispose() }
}

function Get-ReportCell {
    param([xml]$Sheet, [string]$Address)
    return $Sheet.SelectSingleNode("//*[local-name()='c'][@r='$Address']")
}

$columns = [ordered]@{
    Name = '=1+1'; HybridState = 'HYBRID OK'; IntuneState = 'OK'
    IdentityState = 'Corrisponde'; RegisteredCount = 2; IntuneSerial = '00123'
    GlpiStatus = 'Assegnato'; GlpiDepartment = 'Unità di prova'; OUName = 'Lab'
    GlpiAssetId = '00017'; Censito = 'Si'; GlpiState = 'Presente'
    ADLastModified = [datetime]::new(2026,11,13,11,30,0)
    EntraLastActivity = $null; GlpiLastInventory = $null
    IntuneReason = ''; ADGuid = '11111111-1111-4111-8111-111111111111'
    ADDistinguishedName = 'CN=PC\,OU=Gianicolo,OU=Figlia,ou=site-villapamphili,DC=example,DC=invalid'
    Anomalies = ''; GlpiMatchBy = 'Seriale Intune'; GlpiNames = 'PC & TEST'; GlpiGroup = 'CENSITO'
}
$known = [pscustomobject]$columns
$pending = $known | Select-Object *
$pending.Name = 'PC-PENDING'; $pending.IntuneState = 'Da regolarizzare'
$absent = $known | Select-Object *
$absent.Name = 'PC-ABSENT'; $absent.HybridState = 'ASSENTE DA ENTRA'; $absent.IntuneState = 'Da regolarizzare'
$other = $known | Select-Object *
$other.Name = 'PC-OTHER'; $other.HybridState = 'SENZA HYBRID'; $other.IntuneState = 'Da regolarizzare'
$other.ADDistinguishedName = 'CN=PC-OTHER,OU=Test,DC=example,DC=invalid'
$unknown = $known | Select-Object *
$unknown.Name = 'PC-UNKNOWN'; $unknown.IntuneState = 'Non verificabile'
$captured = [datetimeoffset]'2026-11-13T23:30:00+00:00'
$snapshot = [pscustomobject]@{Rows=@($known,$pending,$absent,$other,$unknown); CapturedAtUtc=$captured}

$folder = Join-Path ([IO.Path]::GetTempPath()) ('hybrid-report-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($folder)
try {
    $path = Join-Path $folder 'Resoconto Attestazione Intune.xlsx'
    $saved = Save-HybridWeeklyReport -Snapshot $snapshot -Path $path
    if ($saved.Computers -ne 5 -or (Get-HybridReportDate $captured -Format dd_MM_yy) -ne '14_11_26') {
        throw 'Excel export lost devices or used the host time zone for the report date.'
    }
    $archive = [IO.Compression.ZipFile]::OpenRead($path)
    try {
        if (@($archive.Entries | Where-Object FullName -Match 'connections|queryTable|customXml|externalLink|sharedStrings|printerSettings').Count) {
            throw 'The report still includes source data, a printer or an external data connection.'
        }
        $book = Read-ReportPart $archive 'xl/workbook.xml'
        $sheets = $book.DocumentElement.sheets.ChildNodes
        if (($sheets | ForEach-Object { $_.GetAttribute('name') }) -join '|' -cne 'Resoconto|Villa Pamphili|S.Onofrio|Baldelli|S.Paolo|Palidoro-Passoscuro|S.Marinella|Laptop|Altre OU' -or
            $sheets[8].GetAttribute('state')) { throw 'The exported report lost a detail sheet or omitted the extra OU.' }
        $report = Read-ReportPart $archive 'xl/worksheets/sheet1.xml'
        $counts = @('C6','C7','C8','C9','C10','C14','C31','C52','C162','C178','C179' |
            ForEach-Object { (Get-ReportCell $report $_).v })
        if (($counts -join ',') -ne '1,1,1,2,5,1,4,0,1,0,3' -or
            (Get-ReportCell $report 'D9').v -ne '0.4' -or (Get-ReportCell $report 'B2').is.t.'#text' -notlike '*14/11/2026 00:30') {
            throw ('Wrong overall/per-OU totals, percentages or scan time: ' + ($counts -join ','))
        }
        $chart = Read-ReportPart $archive 'xl/charts/chart1.xml'
        $points = @($chart.GetElementsByTagName('numCache', 'http://schemas.openxmlformats.org/drawingml/2006/chart')[0].pt | ForEach-Object v)
        if (($points -join ',') -ne '1,1,1,2' -or @($archive.Entries | Where-Object FullName -Match '^xl/charts/chart\d+\.xml$').Count -ne 8) {
            throw 'The chart cache or number of charts does not match the summary.'
        }
        $villa = Read-ReportPart $archive 'xl/worksheets/sheet2.xml'
        $table = Read-ReportPart $archive 'xl/tables/table1.xml'
        if ($villa.DocumentElement.dimension.ref -ne 'A1:W5' -or $table.DocumentElement.ref -ne 'A1:W5' -or
            $table.DocumentElement.autoFilter.ref -ne 'A1:W5' -or $villa.DocumentElement.conditionalFormatting.sqref -ne 'A2:W5') {
            throw 'Table, filter or formatting failed to follow the detail rows.'
        }
        if ((Get-ReportCell $villa 'A2').t -ne 'inlineStr' -or (Get-ReportCell $villa 'A2').is.t.'#text' -ne '=1+1' -or
            (Get-ReportCell $villa 'G2').is.t.'#text' -ne '00123' -or (Get-ReportCell $villa 'K2').is.t.'#text' -ne '00017' -or
            (Get-ReportCell $villa 'D2').HasChildNodes -or $null -ne (Get-ReportCell $villa 'O2') -or
            [double](Get-ReportCell $villa 'N2').v -ne $columns.ADLastModified.ToOADate()) {
            throw 'The export lost typed dates, literal identifiers or the blank manual reason.'
        }
        $notes = Get-ReportCell $report 'B182'
        if ($notes.v -ne 'Nessun motivo compilato' -or $notes.f.InnerText -notlike '*HybridReport8[[]Motivi noti*' -or
            (Get-ReportCell $report 'C179').f -notlike '*Da regolarizzare*') {
            throw 'The notes summary cannot include manually entered reasons for all detail sheets.'
        }
    }
    finally { $archive.Dispose() }
    $original = (Get-FileHash -LiteralPath $path).Hash
    $failed = $false
    try { Save-HybridWeeklyReport -Snapshot $snapshot -Path $path } catch { $failed = $true }
    if (-not $failed -or (Get-FileHash -LiteralPath $path).Hash -ne $original) {
        throw 'The export overwrote an existing report without approval.'
    }
    $invalid = $known | Select-Object Name,HybridState,IntuneState,ADDistinguishedName
    $failed = $false
    try { Save-HybridWeeklyReport -Snapshot ([pscustomobject]@{Rows=@($invalid);CapturedAtUtc=$captured}) -Path $path -Overwrite } catch { $failed = $true }
    if (-not $failed -or (Get-FileHash -LiteralPath $path).Hash -ne $original -or @(Get-ChildItem -LiteralPath $folder -Force).Count -ne 1) {
        throw 'A failed export modified the previous report or left a temporary file.'
    }
    $empty = Save-HybridWeeklyReport -Snapshot ([pscustomobject]@{Rows=@();CapturedAtUtc=$captured}) -Path $path -Overwrite
    $archive = [IO.Compression.ZipFile]::OpenRead($path)
    try {
        $book = Read-ReportPart $archive 'xl/workbook.xml'
        $report = Read-ReportPart $archive 'xl/worksheets/sheet1.xml'
        $villa = Read-ReportPart $archive 'xl/worksheets/sheet2.xml'
        if ($empty.Computers -ne 0 -or $book.DocumentElement.sheets.ChildNodes[8].state -ne 'hidden' -or
            (Get-ReportCell $report 'C10').v -ne '0' -or (Get-ReportCell $report 'D10').v -ne '0' -or
            $villa.DocumentElement.dimension.ref -ne 'A1:W2' -or $villa.DocumentElement.sheetData.row[1].HasChildNodes) {
            throw 'An empty scan contained old data, bad totals or an empty extra OU tab.'
        }
    }
    finally { $archive.Dispose() }
    'PASS: Hybrid Excel export creates a standalone workbook, retains exact source values and reconciles detail, summary and charts, including unknown states and empty scans.'
}
finally {
    Remove-Item -LiteralPath $folder -Recurse -Force
    Remove-Module HybridJoin.Report
}
