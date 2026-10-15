#requires -version 5.1
[CmdletBinding()]
param([string]$UiPath = (Join-Path $PSScriptRoot '../Start-ComputerExplorer.ps1'))
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { Write-Host 'SKIP: WinForms smoke test requires Windows.'; return }
$sourcePath = (Resolve-Path -LiteralPath $UiPath).ProviderPath
$root = Split-Path $sourcePath -Parent
$text = [IO.File]::ReadAllText($sourcePath, [Text.Encoding]::UTF8)
$marker = 'try { [void]$form.ShowDialog() }'
$position = $text.IndexOf($marker, [StringComparison]::Ordinal)
if ($position -lt 0) { throw 'UI entry point not found.' }
$probePath = Join-Path $root ('ui-smoke-' + [guid]::NewGuid().ToString('N') + '.local.ps1')
$probe = @'
try {
    $form.CreateControl()
    $form.PerformLayout()
    if (-not $grid.MultiSelect -or $grid.SelectionMode -ne 'FullRowSelect') { throw 'Grid is not configured for multiple complete rows.' }
    if (@($options.Controls | Where-Object { $_.Text -like 'Verde:*' }).Count -gt 0) { throw 'Old legend still displayed.' }
    $rows = @(1..2 | ForEach-Object {
        [pscustomobject]@{
            Name = ('PC-UI-' + $_); AD = '5/5'; ADColor = 'Verde'; Verificati = '5/5'
            Entra = '12'; EntraColor = 'Giallo'; Intune = '1'; IntuneColor = 'Verde'; GLPI = '1'; GLPIColor = 'Verde'
            ADLastModified = [datetime]'2026-10-15T10:05:00'; EntraLastActivity = [datetime]'2026-10-14T23:50:00'
            IntuneLastCheckIn = [datetime]'2026-10-15T09:30:00'; GlpiLastInventory = [datetime]'2026-10-15T08:00:00'
            StatoGLPI = 'Assegnato'; PercorsoAD = 'example.invalid/Lab'; Note = ''
            ADRecords = @(); EntraRecords = @(); IntuneRecords = @(); GlpiRecords = @()
        }
    })
    $snapshot = [pscustomobject]@{
        Rows = $rows; Message = 'Synthetic UI test'; Complete = $true
        Sources = @(@('AD', 'Entra', 'Intune', 'GLPI') | ForEach-Object {
            [pscustomobject]@{ Name=$_; State='OK'; Count=2; CheckedAtUtc=[datetimeoffset]::UtcNow; FromCache=$false; Error=$null; DcSources=@() }
        })
    }
    Show-ExplorerSnapshot $snapshot
    if ($counterLabel.Text -ne 'Risultati: 2 | Selezionati: 0' -or $deleteButton.Enabled) { throw 'Initial result/selection counters or delete state incorrect.' }
    $grid.SelectAll()
    if ($counterLabel.Text -ne 'Risultati: 2 | Selezionati: 2' -or -not $deleteButton.Enabled) { throw 'Multi-selection counter or delete state incorrect.' }
    Show-ExplorerSnapshot $snapshot
    if ($grid.SelectedRows.Count -ne 2) { throw 'Selection not retained after snapshot update.' }
    'PASS: native WinForms counters, multiple selection and removal button state.'
    foreach ($name in @('AD', 'ADLastModified', 'Entra', 'EntraLastActivity', 'Intune', 'IntuneLastCheckIn', 'GLPI', 'GlpiLastInventory')) {
        $column = $grid.Columns[$name]
        $preferred = $column.GetPreferredWidth([Windows.Forms.DataGridViewAutoSizeColumnMode]::AllCells, $true)
        if ($column.Width -ne $preferred) { throw ('Column does not fit formatted cells and header: ' + $name) }
    }
    'PASS: all eight source/date columns fit native formatted content and headers.'
    Set-SearchBusy $true
    if ($deleteButton.Enabled) { throw 'Delete button active during background query.' }
    Set-SearchBusy $false
    $script:RemovalNeedsRefresh = $true
    Update-ExplorerCounters
    if ($deleteButton.Enabled) { throw 'Delete button active on invalidated results.' }
    $grid.ClearSelection(); Update-ExplorerCounters
    if ($counterLabel.Text -ne 'Risultati: 2 | Selezionati: 0') { throw 'Cleared selection counter incorrect.' }
    'PASS: busy/stale views cannot start another deletion.'
}
finally {
    $timer.Dispose()
    $script:Worker.Close(); $script:Worker.Dispose()
    $form.Dispose()
}
'@
try {
    [IO.File]::WriteAllText($probePath, ($text.Substring(0, $position) + $probe), (New-Object Text.UTF8Encoding($true)))
    & $probePath -ConfigPath (Join-Path $root 'computer-explorer.config.example.json')
}
finally { Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue }
