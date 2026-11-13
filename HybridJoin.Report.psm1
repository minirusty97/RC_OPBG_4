#requires -version 5.1
Set-StrictMode -Version 2.0

$script:SheetNamespace = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
$script:ChartNamespace = 'http://schemas.openxmlformats.org/drawingml/2006/chart'
$script:RelationshipNamespace = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
$script:ReportFields = @(
    'Name', 'HybridState', 'IntuneState', '', 'IdentityState', 'RegisteredCount', 'IntuneSerial',
    'GlpiStatus', 'GlpiDepartment', 'OUName', 'GlpiAssetId', 'Censito', 'GlpiState',
    'ADLastModified', 'EntraLastActivity', 'GlpiLastInventory', 'IntuneReason', 'ADGuid',
    'ADDistinguishedName', 'Anomalies', 'GlpiMatchBy', 'GlpiNames', 'GlpiGroup'
)
$script:ReportHeaders = @(
    'NOME', 'Stato Hybrid', 'Stato Intune', 'Motivi noti e probabili della mancata attestazione',
    'Stato identita', 'Numero registrazioni', 'Numero di serie Intune', 'Stato assegnazione GLPI',
    'Reparto GLPI', 'Nome unita organizzativa', 'ID risorsa GLPI', 'Censito', 'Presenza in GLPI',
    'Ultima modifica AD', 'Ultima attivita Entra', 'Ultimo inventario GLPI', 'Motivo stato Intune',
    'GUID AD', 'Nome distinto AD', 'Anomalie', 'Criterio corrispondenza GLPI', 'Nomi GLPI', 'Gruppo GLPI'
)
$script:DefaultReportGroups = @(
    @{Name='Villa Pamphili'; Aliases=@('villa pamphili','villapamphili')}
    @{Name='S.Onofrio'; Aliases=@('gianicolo','s.onofrio','sant onofrio','sant''onofrio')}
    @{Name='Baldelli'; Aliases=@('baldelli')}
    @{Name='S.Paolo'; Aliases=@('sanpaolo','san paolo','s.paolo')}
    @{Name='Palidoro-Passoscuro'; Aliases=@('palidoro','passoscuro')}
    @{Name='S.Marinella'; Aliases=@('smarinella','s.marinella','santa marinella')}
    @{Name='Laptop'; Aliases=@('laptop')}
)

. (Join-Path $PSScriptRoot 'HybridJoin.Report.Layout.ps1')

function ConvertTo-HybridReportXmlText {
    param([string]$Text)

    return [Security.SecurityElement]::Escape(($Text -replace '[\x00-\x08\x0b\x0c\x0e-\x1f\ufffe\uffff]', ''))
}

function New-HybridReportCell {
    param([string]$Address, $Value, [int]$Style)

    $cell = '<c r="{0}" s="{1}"' -f $Address, $Style
    if ($null -eq $Value -or ($Value -is [string] -and -not $Value.Length)) { return $cell + '/>' }
    if ($Value -is [datetime]) { $Value = $Value.ToOADate() }
    $culture = [Globalization.CultureInfo]::InvariantCulture
    if ($Value -is [double]) { return $cell + '><v>' + $Value.ToString('G17', $culture) + '</v></c>' }
    if ($Value -is [int] -or $Value -is [long]) {
        return $cell + '><v>' + [Convert]::ToString($Value, $culture) + '</v></c>'
    }
    # A text cell preserves identifiers and formula-like source values.
    $text = ConvertTo-HybridReportXmlText (([string]$Value) -replace '_(?=x[0-9a-f]{4}_)', '_x005F_')
    return $cell + ' t="inlineStr"><is><t xml:space="preserve">' + $text + '</t></is></c>'
}

function Write-HybridReportDetail {
    param($Archive, [int]$Number, [object[]]$Rows)

    $rowData = [Text.StringBuilder]::new()
    [void]$rowData.Append('<row r="1" ht="30" customHeight="1">')
    for ($index = 0; $index -lt $script:ReportHeaders.Count; $index++) {
        [void]$rowData.Append((New-HybridReportCell ('{0}1' -f [char](65+$index)) $script:ReportHeaders[$index] 2))
    }
    [void]$rowData.Append('</row>')
    $rowNumber = 2
    if ($Rows.Count -eq 0) { $Rows = @($null) }
    foreach ($record in $Rows) {
        [void]$rowData.Append(('<row r="{0}">' -f $rowNumber))
        for ($index = 0; $index -lt $script:ReportFields.Count; $index++) {
            $field = $script:ReportFields[$index]
            $style = 18
            $value = $null
            if ($field -and $null -ne $record) { $value = $record.$field }
            switch ($index) {
                3 { $style = 16 }
                6 { $style = 17 }
                10 { $style = 17; $value = [string]$value }
                { $_ -in 13,14,15 } { $style = 1 }
                { $_ -in 16,19 } { $style = 15 }
            }
            $address = '{0}{1}' -f [char](65+$index), $rowNumber
            [void]$rowData.Append((New-HybridReportCell $address $value $style))
        }
        [void]$rowData.Append('</row>')
        $rowNumber++
    }
    $last = $rowNumber - 1
    $widths = @(24,26,21,57,23,22,24,25,29,28,19,12,22,23,23,25,70,39,78,70,40,26,22)
    $columns = for ($index = 0; $index -lt $widths.Count; $index++) {
        '<col min="{0}" max="{0}" width="{1}" customWidth="1"/>' -f ($index+1), $widths[$index]
    }
    $sheet = @"
<worksheet xmlns="$script:SheetNamespace" xmlns:r="$script:RelationshipNamespace">
  <dimension ref="A1:W$last"/><sheetViews><sheetView workbookViewId="0">
    <pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/><selection pane="bottomLeft" activeCell="A2" sqref="A2"/>
  </sheetView></sheetViews><sheetFormatPr defaultRowHeight="15"/><cols>$($columns -join '')</cols><sheetData>$rowData</sheetData>
  <conditionalFormatting sqref="A2:W$last">
    <cfRule type="expression" dxfId="0" priority="1" stopIfTrue="1"><formula>AND(`$B2="HYBRID OK",`$C2="OK")</formula></cfRule>
    <cfRule type="expression" dxfId="1" priority="2" stopIfTrue="1"><formula>AND(`$B2="HYBRID OK",`$C2="Da regolarizzare")</formula></cfRule>
    <cfRule type="expression" dxfId="2" priority="3" stopIfTrue="1"><formula>`$B2="ASSENTE DA ENTRA"</formula></cfRule>
    <cfRule type="expression" dxfId="3" priority="4"><formula>LEN(`$A2)&gt;0</formula></cfRule>
  </conditionalFormatting>
  <tableParts count="1"><tablePart r:id="rId1"/></tableParts>
</worksheet>
"@
    $sheetNumber = $Number + 1
    Write-HybridWorkbookPart $Archive "xl/worksheets/sheet$sheetNumber.xml" $sheet
    Write-HybridWorkbookPart $Archive "xl/worksheets/_rels/sheet$sheetNumber.xml.rels" (Get-HybridWorkbookRelationships @("table|../tables/table$Number.xml"))
    $headers = for ($index = 0; $index -lt $script:ReportHeaders.Count; $index++) {
        '<tableColumn id="{0}" name="{1}"/>' -f ($index+1), (ConvertTo-HybridReportXmlText $script:ReportHeaders[$index])
    }
    $table = @"
<table xmlns="$script:SheetNamespace" id="$Number" name="HybridReport$Number" displayName="HybridReport$Number" ref="A1:W$last" totalsRowShown="0">
  <autoFilter ref="A1:W$last"/><tableColumns count="$($script:ReportHeaders.Count)">$($headers -join '')</tableColumns>
  <tableStyleInfo name="TableStyleLight9" showFirstColumn="0" showLastColumn="0" showRowStripes="0" showColumnStripes="0"/>
</table>
"@
    Write-HybridWorkbookPart $Archive "xl/tables/table$Number.xml" $table
}

function Write-HybridReportWorkbook {
    param($Archive, $Groups)

    $styles = Get-HybridReportStyles
    Write-HybridWorkbookPart $Archive 'xl/styles.xml' $styles
    Write-HybridWorkbookPart $Archive '_rels/.rels' (Get-HybridWorkbookRelationships @('officeDocument|xl/workbook.xml'))
    $names = @('Resoconto') + @($Groups | ForEach-Object Name)
    $sheets = [Collections.Generic.List[string]]::new()
    $parts = [Collections.Generic.List[string]]::new()
    $types = [Collections.Generic.List[string]]::new()
    $types.Add('xl/workbook.xml|workbook')
    $types.Add('xl/styles.xml|styles')
    $types.Add('xl/metadata.xml|sheetMetadata')
    for ($index = 0; $index -lt $names.Count; $index++) {
        $number = $index + 1
        $state = ''
        if ($index -eq 8 -and -not $Groups[7].Rows.Count) { $state = ' state="hidden"' }
        $sheets.Add(('<sheet name="{0}" sheetId="{1}" r:id="rId{1}"{2}/>' -f (ConvertTo-HybridReportXmlText $names[$index]),$number,$state))
        $parts.Add("worksheet|worksheets/sheet$number.xml")
        $types.Add("xl/worksheets/sheet$number.xml|worksheet")
    }
    $parts.Add('styles|styles.xml')
    $parts.Add('sheetMetadata|metadata.xml')
    $workbook = @"
<workbook xmlns="$script:SheetNamespace" xmlns:r="$script:RelationshipNamespace">
  <bookViews><workbookView activeTab="0"/></bookViews><sheets>$($sheets -join '')</sheets>
  <definedNames><definedName name="_xlnm.Print_Area" localSheetId="0">Resoconto!`$B`$1:`$N`$203</definedName></definedNames>
  <calcPr calcId="191029" fullCalcOnLoad="1"/>
</workbook>
"@
    Write-HybridWorkbookPart $Archive 'xl/workbook.xml' $workbook
    Write-HybridWorkbookPart $Archive 'xl/_rels/workbook.xml.rels' (Get-HybridWorkbookRelationships $parts.ToArray())

    # Excel dynamic-array metadata for the live reason summary.
    $metadata = @"
<metadata xmlns="$script:SheetNamespace" xmlns:xda="http://schemas.microsoft.com/office/spreadsheetml/2017/dynamicarray">
  <metadataTypes count="1"><metadataType name="XLDAPR" minSupportedVersion="120000" copy="1" pasteAll="1" pasteValues="1" merge="1" splitFirst="1" rowColShift="1" clearFormats="1" clearComments="1" assign="1" coerce="1" cellMeta="1"/></metadataTypes>
  <futureMetadata name="XLDAPR" count="1"><bk><extLst><ext uri="{bdbb8cdc-fa1e-496e-a857-3c3f30c029c3}"><xda:dynamicArrayProperties fDynamic="1" fCollapsed="0"/></ext></extLst></bk></futureMetadata>
  <cellMetadata count="1"><bk><rc t="1" v="0"/></bk></cellMetadata>
</metadata>
"@
    Write-HybridWorkbookPart $Archive 'xl/metadata.xml' $metadata
    $prefix = 'application/vnd.openxmlformats-officedocument.'
    $overrides = foreach ($type in $types) {
        $path, $kind = $type.Split('|', 2)
        $mime = $prefix + 'spreadsheetml.' + $kind + '+xml'
        if ($kind -eq 'workbook') { $mime = $prefix + 'spreadsheetml.sheet.main+xml' }
        '<Override PartName="/{0}" ContentType="{1}"/>' -f $path, $mime
    }
    $overrides += for ($index = 1; $index -le $Groups.Count; $index++) {
        '<Override PartName="/xl/tables/table{0}.xml" ContentType="{1}spreadsheetml.table+xml"/>' -f $index, $prefix
        '<Override PartName="/xl/charts/chart{0}.xml" ContentType="{1}drawingml.chart+xml"/>' -f $index, $prefix
    }
    $content = @"
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/xl/drawings/drawing1.xml" ContentType="$($prefix)drawing+xml"/>$($overrides -join '')
</Types>
"@
    Write-HybridWorkbookPart $Archive '[Content_Types].xml' $content
}

function Get-HybridReportGroupIndex {
    param([string]$DistinguishedName, [string]$OuName)

    $words = [Collections.Generic.List[string]]::new()
    foreach ($rdn in [regex]::Matches($DistinguishedName, '(?:\\.|[^,\\])+')) {
        if ($rdn.Value.Trim() -imatch '^OU=(.+)$') {
            $words.AddRange([string[]]($Matches[1] -split '[-_]+'))
        }
    }
    $words.AddRange([string[]]($OuName -split '[-_;]+'))
    foreach ($word in $words) {
        $key = $word.Trim()
        for ($index = 0; $index -lt $script:DefaultReportGroups.Count; $index++) {
            if ($key -in $script:DefaultReportGroups[$index].Aliases) { return $index }
        }
    }
    return $script:DefaultReportGroups.Count
}

function Get-HybridReportDate {
    param([datetimeoffset]$CapturedAtUtc, [string]$Format = 'dd/MM/yyyy HH:mm')

    $rome = [TimeZoneInfo]::FindSystemTimeZoneById('W. Europe Standard Time')
    return [TimeZoneInfo]::ConvertTime($CapturedAtUtc, $rome).ToString($Format, [Globalization.CultureInfo]::InvariantCulture)
}

function Save-HybridWeeklyReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$Snapshot,
        [Parameter(Mandatory=$true)][string]$Path,
        [switch]$Overwrite
    )

    $ErrorActionPreference = 'Stop'
    $Path = [IO.Path]::GetFullPath($Path)
    if ([IO.Path]::GetExtension($Path) -ine '.xlsx') { throw 'Scegliere un nome di file con estensione .xlsx.' }
    if ([IO.File]::Exists($Path) -and -not $Overwrite) { throw 'Esiste già un resoconto con questo nome.' }
    $temporary = Join-Path ([IO.Path]::GetDirectoryName($Path)) ('.hybrid-' + [guid]::NewGuid().ToString('N') + '.tmp')

    $groups = @(foreach ($name in (@($script:DefaultReportGroups | ForEach-Object { $_.Name }) + 'Altre OU')) {
        [pscustomobject]@{Name=$name; Rows=[Collections.Generic.List[object]]::new(); Counts=[int[]]::new(5)}
    })
    $overall = [int[]]::new(5)
    $toReview = 0
    foreach ($row in $Snapshot.Rows) {
        $group = $groups[(Get-HybridReportGroupIndex $row.ADDistinguishedName $row.OUName)]
        $category = 3
        if ($row.HybridState -eq 'ASSENTE DA ENTRA') { $category = 2 }
        elseif ($row.HybridState -eq 'HYBRID OK' -and $row.IntuneState -eq 'OK') { $category = 0 }
        elseif ($row.HybridState -eq 'HYBRID OK' -and $row.IntuneState -eq 'Da regolarizzare') { $category = 1 }
        if ($row.IntuneState -eq 'Non verificabile') {
            $group.Counts[4]++
            $overall[4]++
        }
        $group.Rows.Add($row)
        $group.Counts[$category]++
        $overall[$category]++
        if ($row.IntuneState -eq 'Da regolarizzare') { $toReview++ }
    }

    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    try {
        $archive = [IO.Compression.ZipFile]::Open($temporary, [IO.Compression.ZipArchiveMode]::Create)
        try {
            Write-HybridReportWorkbook $archive $groups
            Write-HybridReportSummary $archive $groups $overall $toReview $Snapshot.CapturedAtUtc
            for ($index = 0; $index -lt $groups.Count; $index++) {
                Write-HybridReportDetail $archive ($index + 1) ($groups[$index].Rows.ToArray())
            }
        }
        finally { $archive.Dispose() }
        if ($Overwrite -and [IO.File]::Exists($Path)) {
            [IO.File]::Replace($temporary, $Path, [Management.Automation.Language.NullString]::Value)
        }
        else { [IO.File]::Move($temporary, $Path) }
        [pscustomobject]@{Path=$Path; Computers=$Snapshot.Rows.Count}
    }
    finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

Export-ModuleMember -Function Save-HybridWeeklyReport,Get-HybridReportDate
