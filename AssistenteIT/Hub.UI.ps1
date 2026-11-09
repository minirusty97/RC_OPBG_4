#requires -version 5.1

$hubColors=@{
    Canvas=[Drawing.ColorTranslator]::FromHtml('#F0F4F9')
    Surface=[Drawing.Color]::White
    Ink=[Drawing.ColorTranslator]::FromHtml('#142A43')
    Muted=[Drawing.ColorTranslator]::FromHtml('#50647B')
    Action=[Drawing.ColorTranslator]::FromHtml('#D6E6FA')
    ActionHover=[Drawing.ColorTranslator]::FromHtml('#C4DBF6')
    DisabledFill=[Drawing.ColorTranslator]::FromHtml('#EEF0F3')
    DisabledInk=[Drawing.ColorTranslator]::FromHtml('#69788A')
    Accent=[Drawing.ColorTranslator]::FromHtml('#2059A2')
    AccentHover=[Drawing.ColorTranslator]::FromHtml('#174A8A')
    Ready=[Drawing.ColorTranslator]::FromHtml('#16704F')
    Pending=[Drawing.ColorTranslator]::FromHtml('#905A0D')
    Error=[Drawing.ColorTranslator]::FromHtml('#AD3548')
}
$script:StatusRows=@{}
$hubBold=New-Object Drawing.Font('Segoe UI',10,[Drawing.FontStyle]::Bold)
$hubTitleFont=New-Object Drawing.Font('Segoe UI',21,[Drawing.FontStyle]::Bold)
$hubToolTip=New-Object Windows.Forms.ToolTip
$hubToolTip.ShowAlways=$true
$hubToolTip.AutoPopDelay=12000

function New-AssistenteITHubLabel {
    param([string]$Text,[Drawing.Color]$Color=$hubColors.Ink)
    $label=New-Object Windows.Forms.Label
    $label.Text=$Text
    $label.ForeColor=$Color
    $label.Dock='Fill'
    $label.TextAlign='MiddleLeft'
    $label.AutoEllipsis=$true
    $label.Margin=New-Object Windows.Forms.Padding(0)
    return $label
}

function Set-AssistenteITHubCorners {
    param([Windows.Forms.Control]$Control,[int]$Radius)
    $resize = {
        param($sender,$eventArgs)
        $diameter = [Math]::Min(2 * $Radius, [Math]::Min($sender.Width, $sender.Height))
        if ($diameter -lt 2) { return }
        $right = $sender.Width - $diameter
        $bottom = $sender.Height - $diameter
        $path = New-Object Drawing.Drawing2D.GraphicsPath
        try {
            $path.AddArc(0, 0, $diameter, $diameter, 180, 90)
            $path.AddArc($right, 0, $diameter, $diameter, 270, 90)
            $path.AddArc($right, $bottom, $diameter, $diameter, 0, 90)
            $path.AddArc(0, $bottom, $diameter, $diameter, 90, 90)
            $path.CloseFigure()
            $sender.Region = New-Object Drawing.Region($path)
        }
        finally { $path.Dispose() }
    }.GetNewClosure()
    $Control.Add_SizeChanged($resize)
    & $resize $Control ([EventArgs]::Empty)
}

function New-AssistenteITHubButton {
    param([string]$Text,[int]$Width,[switch]$Primary)
    $button=New-Object Windows.Forms.Button
    $button.Text=$Text
    $button.Size=New-Object Drawing.Size($Width,32)
    $button.Margin=New-Object Windows.Forms.Padding(0,4,8,0)
    $button.FlatStyle='Flat'
    $button.UseVisualStyleBackColor=$false
    $button.FlatAppearance.BorderSize=0
    $enabledFill=$hubColors.Action
    $enabledInk=$hubColors.Ink
    $button.FlatAppearance.MouseOverBackColor=$hubColors.ActionHover
    if ($Primary) {
        $enabledFill=$hubColors.Accent
        $enabledInk=[Drawing.Color]::White
        $button.FlatAppearance.MouseOverBackColor=$hubColors.AccentHover
    }
    $disabledFill=$hubColors.DisabledFill
    $disabledInk=$hubColors.DisabledInk
    $style = {
        param($sender,$eventArgs)
        if ($sender.Enabled) {
            $sender.BackColor=$enabledFill
            $sender.ForeColor=$enabledInk
        }
        else {
            $sender.BackColor=$disabledFill
            $sender.ForeColor=$disabledInk
        }
    }.GetNewClosure()
    $button.Add_EnabledChanged($style)
    & $style $button ([EventArgs]::Empty)
    Set-AssistenteITHubCorners $button 8
    return $button
}

function New-AssistenteITStatusSection {
    param([string]$Name,[string]$Title,[System.Collections.IDictionary]$Items)
    $section=New-Object Windows.Forms.TableLayoutPanel
    $section.Name=$Name
    $section.Text=$Title
    $section.AccessibleName=$Title
    $section.Dock='Fill'
    $section.BackColor=$hubColors.Surface
    $section.Padding=New-Object Windows.Forms.Padding(12,4,12,5)
    $section.ColumnCount=3
    $section.RowCount=$Items.Count+2
    [void]$section.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',18)))
    [void]$section.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',116)))
    [void]$section.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100)))
    [void]$section.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',26)))
    $heading=New-AssistenteITHubLabel $Title
    $heading.Font=$hubBold
    $section.Controls.Add($heading,0,0)
    $section.SetColumnSpan($heading,3)
    $row=1
    foreach ($id in $Items.Keys) {
        [void]$section.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',22)))
        $dot=New-AssistenteITHubLabel '●' $hubColors.Pending
        $dot.Name='StatusDot-'+$id
        $label=New-AssistenteITHubLabel $Items[$id] $hubColors.Muted
        $value=New-AssistenteITHubLabel 'In attesa' $hubColors.Pending
        $value.Name='StatusValue-'+$id
        $section.Controls.Add($dot,0,$row)
        $section.Controls.Add($label,1,$row)
        $section.Controls.Add($value,2,$row)
        $script:StatusRows[$id]=[pscustomobject]@{Dot=$dot;Value=$value;State='Pending'}
        $row++
    }
    [void]$section.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))
    Set-AssistenteITHubCorners $section 11
    return $section
}

function Set-AssistenteITHubStatus {
    param([string]$Id,[ValidateSet('Ready','Pending','Error')][string]$State,[string]$Text,[string]$Detail)
    $row=$script:StatusRows[$Id]
    $row.State=$State
    $row.Dot.ForeColor=$hubColors[$State]
    $row.Value.ForeColor=$hubColors[$State]
    $row.Value.Text=$Text
    if (-not $Detail) { $Detail=$Text }
    $hubToolTip.SetToolTip($row.Dot,$Detail)
    $hubToolTip.SetToolTip($row.Value,$Detail)
}
