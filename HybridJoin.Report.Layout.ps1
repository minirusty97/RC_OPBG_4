function Write-HybridWorkbookPart {
    param($Archive, [string]$Name, [string]$Content)

    $writer = [IO.StreamWriter]::new($Archive.CreateEntry($Name).Open(), [Text.UTF8Encoding]::new($false))
    try { $writer.Write($Content) }
    finally { $writer.Dispose() }
}

function Get-HybridWorkbookRelationships {
    param([string[]]$Parts)

    $body = for ($index = 0; $index -lt $Parts.Count; $index++) {
        $type, $target = $Parts[$index].Split('|', 2)
        '<Relationship Id="rId{0}" Type="{1}/{2}" Target="{3}"/>' -f ($index + 1), $script:RelationshipNamespace, $type, $target
    }
    return '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' + ($body -join '') + '</Relationships>'
}

function Get-HybridReportStyles {
    return @'
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <numFmts count="2"><numFmt numFmtId="164" formatCode="0.0%"/><numFmt numFmtId="165" formatCode="dd/mm/yyyy hh:mm"/></numFmts>
  <fonts count="5">
    <font><sz val="11"/><color rgb="FF172B3A"/><name val="Calibri"/></font>
    <font><b/><sz val="19"/><color rgb="FF172B3A"/><name val="Calibri"/></font>
    <font><b/><sz val="12"/><color rgb="FF172B3A"/><name val="Calibri"/></font>
    <font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Calibri"/></font>
    <font><sz val="10"/><color rgb="FF425D70"/><name val="Calibri"/></font>
  </fonts>
  <fills count="7">
    <fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FF156082"/><bgColor indexed="64"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFC1F0C8"/><bgColor indexed="64"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFFFFF99"/><bgColor indexed="64"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFFF9999"/><bgColor indexed="64"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFD9E2F3"/><bgColor indexed="64"/></patternFill></fill>
  </fills>
  <borders count="4">
    <border><left/><right/><top/><bottom/><diagonal/></border>
    <border>
      <left style="thin"><color rgb="FF657A88"/></left><right style="thin"><color rgb="FF657A88"/></right>
      <top style="thin"><color rgb="FF657A88"/></top><bottom style="thin"><color rgb="FF657A88"/></bottom><diagonal/>
    </border>
    <border>
      <left style="thin"><color rgb="FFA5C2D0"/></left><right style="thin"><color rgb="FFA5C2D0"/></right>
      <top style="thin"><color rgb="FF435D70"/></top><bottom style="medium"><color rgb="FF435D70"/></bottom><diagonal/>
    </border>
    <border>
      <left style="thin"><color rgb="FF657A88"/></left><right style="thin"><color rgb="FF657A88"/></right>
      <top style="medium"><color rgb="FF435D70"/></top><bottom style="thin"><color rgb="FF657A88"/></bottom><diagonal/>
    </border>
  </borders>
  <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
  <cellXfs count="21">
    <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
    <xf numFmtId="165" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyNumberFormat="1"/>
    <xf numFmtId="0" fontId="3" fillId="2" borderId="2" xfId="0" applyBorder="1" applyFont="1" applyFill="1" applyAlignment="1"><alignment vertical="center" wrapText="1"/></xf>
    <xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>
    <xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1"/>
    <xf numFmtId="0" fontId="4" fillId="0" borderId="0" xfId="0" applyFont="1"/>
    <xf numFmtId="0" fontId="0" fillId="3" borderId="1" xfId="0" applyBorder="1" applyFill="1"/>
    <xf numFmtId="0" fontId="0" fillId="4" borderId="1" xfId="0" applyBorder="1" applyFill="1"/>
    <xf numFmtId="0" fontId="0" fillId="5" borderId="1" xfId="0" applyBorder="1" applyFill="1"/>
    <xf numFmtId="0" fontId="0" fillId="6" borderId="1" xfId="0" applyBorder="1" applyFill="1"/>
    <xf numFmtId="164" fontId="0" fillId="3" borderId="1" xfId="0" applyBorder="1" applyNumberFormat="1" applyFill="1"/>
    <xf numFmtId="164" fontId="0" fillId="4" borderId="1" xfId="0" applyBorder="1" applyNumberFormat="1" applyFill="1"/>
    <xf numFmtId="164" fontId="0" fillId="5" borderId="1" xfId="0" applyBorder="1" applyNumberFormat="1" applyFill="1"/>
    <xf numFmtId="164" fontId="0" fillId="6" borderId="1" xfId="0" applyBorder="1" applyNumberFormat="1" applyFill="1"/>
    <xf numFmtId="164" fontId="2" fillId="0" borderId="3" xfId="0" applyBorder="1" applyNumberFormat="1" applyFont="1"/>
    <xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>
    <xf numFmtId="49" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyNumberFormat="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>
    <xf numFmtId="49" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyNumberFormat="1"/>
    <xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1"/>
    <xf numFmtId="0" fontId="2" fillId="0" borderId="3" xfId="0" applyBorder="1" applyFont="1"/>
    <xf numFmtId="0" fontId="2" fillId="0" borderId="1" xfId="0" applyBorder="1" applyFont="1"/>
  </cellXfs>
  <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
  <dxfs count="5">
    <dxf><fill><patternFill><bgColor rgb="FFC1F0C8"/></patternFill></fill></dxf>
    <dxf><fill><patternFill><bgColor rgb="FFFFFF99"/></patternFill></fill></dxf>
    <dxf><fill><patternFill><bgColor rgb="FFFF9999"/></patternFill></fill></dxf>
    <dxf><fill><patternFill><bgColor rgb="FFD9E2F3"/></patternFill></fill></dxf>
    <dxf><border>
      <left style="thin"><color rgb="FF657A88"/></left><right style="thin"><color rgb="FF657A88"/></right>
      <top style="thin"><color rgb="FF657A88"/></top><bottom style="thin"><color rgb="FF657A88"/></bottom>
    </border></dxf>
  </dxfs>
  <tableStyles count="0" defaultTableStyle="TableStyleLight9" defaultPivotStyle="PivotStyleLight16"/>
</styleSheet>
'@
}

function Write-HybridReportChart {
    param($Archive, [int]$Index, [string]$Title, [string[]]$Labels, [int[]]$Counts)

    $first = 6 + 21 * $Index
    $last = $first + $Labels.Count - 1
    $number = $Index + 1
    $category = for ($i = 0; $i -lt $Labels.Count; $i++) {
        '<c:pt idx="{0}"><c:v>{1}</c:v></c:pt>' -f $i, (ConvertTo-HybridReportXmlText $Labels[$i])
    }
    $values = for ($i = 0; $i -lt $Labels.Count; $i++) {
        '<c:pt idx="{0}"><c:v>{1}</c:v></c:pt>' -f $i, $Counts[$i]
    }
    $colors = @('C1F0C8', 'FFFF99', 'FF9999', 'D9E2F3')
    $points = for ($i = 0; $i -lt $Labels.Count; $i++) {
        '<c:dPt><c:idx val="{0}"/><c:spPr><a:solidFill><a:srgbClr val="{1}"/></a:solidFill></c:spPr></c:dPt>' -f $i, $colors[$i]
    }
    $categoryRef = 'Resoconto!$B0:$B1' -f $first, $last
    $valueRef = 'Resoconto!$C0:$C1' -f $first, $last
    $name = ConvertTo-HybridReportXmlText ($Title + ' - stato attestazione')
    $count = $Labels.Count
    $chart = @"
<c:chartSpace xmlns:c="$script:ChartNamespace" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
  <c:lang val="it-IT"/><c:chart>
    <c:title><c:tx><c:rich><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang="it-IT"/><a:t>$name</a:t></a:r></a:p></c:rich></c:tx><c:overlay val="0"/></c:title>
    <c:view3D><c:rotX val="35"/><c:rotY val="0"/><c:rAngAx val="0"/><c:perspective val="30"/></c:view3D>
    <c:plotArea><c:layout/><c:pie3DChart><c:varyColors val="1"/><c:ser>
      <c:idx val="0"/><c:order val="0"/><c:tx><c:v>Dispositivi</c:v></c:tx>$($points -join '')
      <c:cat><c:strRef><c:f>$categoryRef</c:f><c:strCache><c:ptCount val="$count"/>$($category -join '')</c:strCache></c:strRef></c:cat>
      <c:val><c:numRef><c:f>$valueRef</c:f><c:numCache><c:formatCode>0</c:formatCode><c:ptCount val="$count"/>$($values -join '')</c:numCache></c:numRef></c:val>
    </c:ser><c:dLbls><c:dLblPos val="bestFit"/><c:showLegendKey val="0"/><c:showVal val="0"/><c:showCatName val="0"/><c:showSerName val="0"/><c:showPercent val="1"/></c:dLbls></c:pie3DChart></c:plotArea>
    <c:legend><c:legendPos val="b"/><c:overlay val="0"/></c:legend><c:plotVisOnly val="1"/><c:dispBlanksAs val="gap"/>
  </c:chart>
</c:chartSpace>
"@
    Write-HybridWorkbookPart $Archive ("xl/charts/chart$number.xml") $chart
    $top = 3 + 21 * $Index
    $bottom = $top + 19
    return @"
<xdr:twoCellAnchor>
  <xdr:from><xdr:col>6</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>$top</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:from>
  <xdr:to><xdr:col>14</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>$bottom</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:to>
  <xdr:graphicFrame><xdr:nvGraphicFramePr><xdr:cNvPr id="$number" name="Grafico $number"/><xdr:cNvGraphicFramePr/></xdr:nvGraphicFramePr>
    <xdr:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/></xdr:xfrm>
    <a:graphic><a:graphicData uri="$script:ChartNamespace"><c:chart r:id="rId$number"/></a:graphicData></a:graphic>
  </xdr:graphicFrame><xdr:clientData/>
</xdr:twoCellAnchor>
"@
}

function Write-HybridReportSummary {
    param($Archive, $Groups, [int[]]$Overall, [int]$ToReview, [datetimeoffset]$CapturedAtUtc)

    $labels = @('Hybrid OK / Intune OK', 'Hybrid OK / Intune da regolarizzare', 'Assente da Entra', 'Altri esiti Hybrid / Intune')
    $rows = [Text.StringBuilder]::new()
    $drawings = [Collections.Generic.List[string]]::new()
    $chartParts = [Collections.Generic.List[string]]::new()
    $merges = [Collections.Generic.List[string]]::new()
    $merges.Add('B1:N1'); $merges.Add('B2:N2'); $merges.Add('B174:N174'); $merges.Add('B175:N176')
    $title = New-HybridReportCell 'B1' 'Resoconto attestazione dispositivi' 3
    $date = New-HybridReportCell 'B2' ('Rilevazione del ' + (Get-HybridReportDate $CapturedAtUtc)) 5
    [void]$rows.Append('<row r="1" ht="30" customHeight="1">'+$title+'</row><row r="2">'+$date+'</row>')
    for ($index = 0; $index -lt 8; $index++) {
        $start = 4 + 21 * $index
        $name = 'TUTTI'
        $counts = $Overall
        if ($index) { $name = $Groups[$index - 1].Name; $counts = $Groups[$index - 1].Counts }
        $total = $counts[0] + $counts[1] + $counts[2] + $counts[3]
        $merges.Add(('B{0}:D{0}' -f $start))
        $caption = New-HybridReportCell ('B' + $start) $name 4
        [void]$rows.Append(('<row r="{0}" ht="20" customHeight="1">{1}</row>' -f $start, $caption))
        $header = $start + 1
        $cells = (New-HybridReportCell "B$header" 'Stato' 2) + (New-HybridReportCell "C$header" 'Dispositivi' 2) + (New-HybridReportCell "D$header" 'Quota' 2)
        [void]$rows.Append(('<row r="{0}">{1}</row>' -f $header, $cells))
        for ($category = 0; $category -lt $labels.Count; $category++) {
            $line = $start + 2 + $category
            $quota = 0.0
            if ($total) { $quota = $counts[$category] / $total }
            $cells = (New-HybridReportCell "B$line" $labels[$category] (6 + $category)) +
                (New-HybridReportCell "C$line" $counts[$category] (6 + $category)) +
                (New-HybridReportCell "D$line" $quota (10 + $category))
            [void]$rows.Append(('<row r="{0}">{1}</row>' -f $line, $cells))
        }
        $line = $start + 6
        $cells = (New-HybridReportCell "B$line" 'Totale' 19) + (New-HybridReportCell "C$line" $total 19) +
            (New-HybridReportCell "D$line" ([int]($total -gt 0)) 14)
        [void]$rows.Append(('<row r="{0}">{1}</row>' -f $line, $cells))
        if ($counts[4]) {
            $line = $start + 10
            $cells = (New-HybridReportCell "B$line" 'Di cui Intune non verificabile' 5) + (New-HybridReportCell "C$line" $counts[4] 0)
            [void]$rows.Append(('<row r="{0}">{1}</row>' -f $line, $cells))
        }
        $drawings.Add((Write-HybridReportChart $Archive $index $name $labels $counts))
        $chartParts.Add(('chart|../charts/chart{0}.xml' -f ($index + 1)))
    }
    if ($Groups[7].Rows.Count) {
        $cells = (New-HybridReportCell 'B162' 'Di cui in altre OU' 5) + (New-HybridReportCell 'C162' $Groups[7].Rows.Count 0)
        [void]$rows.Append('<row r="162">'+$cells+'</row>')
    }

    $tableNames = @(1..$Groups.Count | ForEach-Object { 'HybridReport' + $_ })
    $names = @($tableNames | ForEach-Object { $_ + '[NOME]' })
    $notes = @($tableNames | ForEach-Object { $_ + '[' + $script:ReportHeaders[3] + ']' })
    $counts = for ($index = 0; $index -lt $tableNames.Count; $index++) {
        'COUNTIFS({0},"<>",{1},"<>")' -f $names[$index], $notes[$index]
    }
    $missing = for ($index = 0; $index -lt $tableNames.Count; $index++) {
        'COUNTIFS({0},"<>",{1}[Stato Intune],"Da regolarizzare",{2},"")' -f $names[$index], $tableNames[$index], $notes[$index]
    }
    $reasonFormula = '_xlfn.LET(_xlpm.m,_xlfn.VSTACK(' + ($notes -join ',') + '),_xlpm.n,_xlfn.VSTACK(' + ($names -join ',') + '),' +
        'IF(SUM((_xlpm.m<>"")*(_xlpm.n<>"")*(_xlpm.m<>0))=0,"Nessun motivo compilato",' +
        '_xlfn.LET(_xlpm.v,_xlfn._xlws.FILTER(_xlpm.m,(_xlpm.m<>"")*(_xlpm.n<>"")*(_xlpm.m<>0)),' +
        '_xlpm.u,_xlfn.UNIQUE(_xlpm.v),_xlpm.c,_xlfn.MAP(_xlpm.u,_xlfn.LAMBDA(_xlpm.x,SUM(--(_xlpm.v=_xlpm.x)))),' +
        '_xlfn.SORTBY(_xlfn.HSTACK(_xlpm.u,_xlpm.c),_xlpm.c,-1,_xlpm.u,1))))'
    $title = New-HybridReportCell 'B174' 'Resoconto dei motivi noti e probabili' 4
    $caption = New-HybridReportCell 'B175' 'Le ipotesi sono motivi probabili e vanno confermate.' 5
    $withReason = New-HybridReportCell 'B178' 'PC con motivo compilato' 20
    $withoutReason = New-HybridReportCell 'B179' 'PC da regolarizzare senza motivo' 20
    $header = (New-HybridReportCell 'B181' 'Motivo noto o probabile' 2) + (New-HybridReportCell 'C181' 'Numero di PC' 2)
    $withFormula = ConvertTo-HybridReportXmlText ('SUM(' + ($counts -join ',') + ')')
    $withoutFormula = ConvertTo-HybridReportXmlText ('SUM(' + ($missing -join ',') + ')')
    $reasonFormula = ConvertTo-HybridReportXmlText $reasonFormula
    # One device can contribute at most one distinct reason to the spilled table.
    $deviceCount = $Overall[0] + $Overall[1] + $Overall[2] + $Overall[3]
    $lastReasonRow = [Math]::Min(1048576, [Math]::Max(203, 181 + $deviceCount))
    [void]$rows.Append(@"
<row r="174" ht="22" customHeight="1">$title</row>
<row r="175">$caption</row>
<row r="178">$withReason<c r="C178" s="18"><f>$withFormula</f><v>0</v></c></row>
<row r="179">$withoutReason<c r="C179" s="18"><f>$withoutFormula</f><v>$ToReview</v></c></row>
<row r="181">$header</row>
<row r="182"><c r="B182" s="15" cm="1" t="str"><f t="array" ref="B182">$reasonFormula</f><v>Nessun motivo compilato</v></c><c r="C182" s="18"/></row>
"@)
    $mergeCells = ($merges | ForEach-Object { '<mergeCell ref="' + $_ + '"/>' }) -join ''
    $sheet = @"
<worksheet xmlns="$script:SheetNamespace" xmlns:r="$script:RelationshipNamespace">
  <sheetPr><pageSetUpPr fitToPage="1"/></sheetPr><dimension ref="A1:N203"/>
  <sheetViews><sheetView showGridLines="0" tabSelected="1" workbookViewId="0"/></sheetViews><sheetFormatPr defaultRowHeight="15"/>
  <cols><col min="1" max="1" width="4" customWidth="1"/><col min="2" max="2" width="71" customWidth="1"/><col min="3" max="4" width="13" customWidth="1"/><col min="5" max="6" width="3.4" customWidth="1"/><col min="7" max="14" width="12.4" customWidth="1"/></cols>
  <sheetData>$rows</sheetData><mergeCells count="$($merges.Count)">$mergeCells</mergeCells>
  <conditionalFormatting sqref="B182:C$lastReasonRow">
    <cfRule type="expression" dxfId="4" priority="1"><formula>LEN(`$B182)&gt;0</formula></cfRule>
  </conditionalFormatting>
  <pageMargins left="0.25" right="0.25" top="0.4" bottom="0.4" header="0.2" footer="0.2"/>
  <pageSetup paperSize="9" orientation="landscape" fitToWidth="1" fitToHeight="0"/>
  <drawing r:id="rId1"/>
</worksheet>
"@
    Write-HybridWorkbookPart $Archive 'xl/worksheets/sheet1.xml' $sheet
    Write-HybridWorkbookPart $Archive 'xl/worksheets/_rels/sheet1.xml.rels' (Get-HybridWorkbookRelationships @('drawing|../drawings/drawing1.xml'))
    $drawing = @"
<xdr:wsDr xmlns:xdr="http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:c="$script:ChartNamespace" xmlns:r="$script:RelationshipNamespace">$($drawings -join '')</xdr:wsDr>
"@
    Write-HybridWorkbookPart $Archive 'xl/drawings/drawing1.xml' $drawing
    Write-HybridWorkbookPart $Archive 'xl/drawings/_rels/drawing1.xml.rels' (Get-HybridWorkbookRelationships $chartParts.ToArray())
}
