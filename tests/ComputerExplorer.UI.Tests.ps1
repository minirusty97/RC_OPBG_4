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
    $script:LoginBrowserOpens=0; $script:LoginCodeSeen=''
    function Open-ExplorerGraphBrowser {
        $script:LoginBrowserOpens++
        if (-not [object]::ReferenceEquals($script:WaitingLoginWindow,$script:GraphLoginWindow)) { throw "Login recreated the waiting window when its code arrived." }
        $script:LoginCodeSeen=@($script:GraphLoginWindow.Controls | Where-Object { $_ -is [Windows.Forms.TextBox] -and $_.Text -eq 'ABCD12345' }).Count
        @($script:GraphLoginWindow.Controls | Where-Object { $_.Text -eq 'Copia codice' })[0].PerformClick()
    }
    $form.CreateControl()
    $form.PerformLayout()
    if (-not $grid.MultiSelect -or $grid.SelectionMode -ne 'FullRowSelect') { throw 'Grid is not configured for multiple complete rows.' }
    if (@($options.Controls | Where-Object { $_.Text -like 'Verde:*' }).Count -gt 0) { throw 'Old legend still displayed.' }
    $rows = @(1..2 | ForEach-Object {
        [pscustomobject]@{
            Censito='✓'; CensitoInfo='Gruppo: CENSITO'; IntuneSerial='ABC'; GlpiSerial='ABC'; SerialCheck='Coerente'; SerialColor='Verde'; SerialConflict=$false
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
    if ($grid.AllowUserToResizeRows -or $grid.AutoSizeRowsMode -ne 'None') { throw 'Result row heights can still change.' }
    $script:CopyCell=$grid.Rows[0].Cells['Name']; $copyCellItem.PerformClick()
    if ([Windows.Forms.Clipboard]::GetText() -ne 'PC-UI-1') { throw 'Cell copy did not use displayed text.' }
    $copyRowsItem.PerformClick()
    $copied=[Windows.Forms.Clipboard]::GetText()
    if ($copied -notlike '*Nome computer*' -or $copied -notlike '*PC-UI-1*' -or $copied -notlike '*PC-UI-2*' -or $grid.SelectedRows.Count -ne 2) { throw 'Row copy changed selection or omitted headers/rows.' }
    if ($grid.Rows[0].Cells['Censito'].Value -ne '✓' -or $grid.Rows[0].Cells['Censito'].Style.ForeColor -ne [Drawing.Color]::DarkGreen) { throw 'Census check is missing or not green.' }
    'PASS: fixed row heights, green census and clipboard cell/row copying preserve multi-selection.'
    $rows[0].SerialConflict=$true; $rows[0].SerialCheck='Conflitto'; $rows[0].SerialColor='Rosso'
    Show-ExplorerSnapshot $snapshot
    if ($deleteButton.Enabled -or $counterLabel.Text -notlike '*Conflitti seriale: 1*') { throw 'Conflicting selected hardware can be deleted.' }
    $rows[0].SerialConflict=$false; $rows[0].SerialCheck='Coerente'; $rows[0].SerialColor='Verde'
    Show-ExplorerSnapshot $snapshot
    if (-not $deleteButton.Enabled) { throw 'Nonconflicting results remain blocked.' }
    'PASS: selected serial conflicts block deletion and normal selections remain actionable.'
    if ($sourceStatusLabels.Count -ne 4) { throw 'Four persistent source statuses are missing.' }
    foreach ($name in @('AD','Entra','Intune','GLPI')) {
        if ($sourceStatusLabels[$name].BackColor -ne [Drawing.Color]::Honeydew -or $sourceStatusLabels[$name].Text -notlike '*Terminata*') { throw ('Successful source did not turn green: '+$name) }
    }
    'PASS: all four successful sources show a separate green completed indicator in the footer.'
    foreach ($name in @('AD', 'ADLastModified', 'Entra', 'EntraLastActivity', 'Intune', 'IntuneLastCheckIn', 'GLPI', 'GlpiLastInventory')) {
        $column = $grid.Columns[$name]
        $preferred = $column.GetPreferredWidth([Windows.Forms.DataGridViewAutoSizeColumnMode]::AllCells, $true)
        if ($column.Width -ne $preferred) { throw ('Column does not fit formatted cells and header: {0}; width={1}, preferred={2}' -f $name, $column.Width, $preferred) }
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

    Show-ExplorerGraphLogin ([pscustomobject]@{Kind='GraphLoginStarting';Code='';Message='Richiesta del codice in corso...'})
    $script:WaitingLoginWindow=$script:GraphLoginWindow
    if (-not $script:WaitingLoginWindow.Visible -or $script:LoginBrowserOpens -ne 0 -or $script:WaitingLoginWindow.Controls['GraphCopy'].Enabled -or $script:WaitingLoginWindow.Controls['GraphOpen'].Enabled) { throw 'Login window was hidden while Microsoft was preparing the code.' }
    'PASS: Graph login is visible before the Microsoft code is received, with copy/browser disabled until ready.'

    # The final result is returned by the real worker but absent from the
    # progress queue, as when completion races with a partial redraw.
    $grid.SelectAll()
    $script:Queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $script:Queue.Enqueue([pscustomobject]@{Rows=$rows;Message='In corso: GLPI';Complete=$false;Sources=$snapshot.Sources})
    $script:Queue.Enqueue([pscustomobject]@{Kind='GraphLogin';Code='ABCD12345';Message='Use https://microsoft.com/devicelogin with code ABCD12345.'})
    $snapshot.Message = 'Ricerca completata'
    $script:Pipeline = [PowerShell]::Create(); $script:Pipeline.Runspace = $script:Worker
    [void]$script:Pipeline.AddScript({param($FinalSnapshot) return $FinalSnapshot}.ToString()).AddArgument($snapshot)
    Set-SearchBusy $true
    $script:Invocation = $script:Pipeline.BeginInvoke()
    if (-not $script:Invocation.AsyncWaitHandle.WaitOne(5000)) { throw 'Native UI completion worker did not finish.' }
    $tickMethod = $timer.GetType().GetMethod('OnTick', [Reflection.BindingFlags]'Instance, NonPublic')
    [void]$tickMethod.Invoke($timer, [object[]]@([EventArgs]::Empty))
    if (-not $script:Latest.Complete -or $script:Busy -or $script:RemovalNeedsRefresh -or -not $deleteButton.Enabled) { throw 'Native timer left a finished search blocked.' }
    if ($counterLabel.Text -ne 'Risultati: 2 | Selezionati: 2' -or $status.Text -notlike 'Ricerca completata*') { throw 'Native completion lost selection or final status.' }
    'PASS: native timer applies the returned final snapshot and enables deletion of selected rows.'
    if ($script:LoginBrowserOpens -ne 1 -or $script:LoginCodeSeen -ne 1 -or $null -ne $script:GraphLoginWindow -or [Windows.Forms.Clipboard]::GetText() -ne 'ABCD12345') { throw 'Device login was hidden, not copyable, duplicated or left open after completion.' }
    'PASS: the real UI timer shows a copyable Graph code, requests the external browser and closes the login window on completion.'


    function Test-RemovalConsentDialog {
        param([bool]$HasChildren,[bool]$Accept,[bool]$Mapping=$false,[bool]$ArchiveOnly=$false)
        $script:RemovalDialogHasChildren=$HasChildren; $script:RemovalDialogAccept=$Accept; $script:RemovalDialogMapping=$Mapping; $script:RemovalDialogArchiveOnly=$ArchiveOnly; $script:RemovalDialogError=''
        $script:RemovalDialogSeen=$false
        $script:RemovalDialogTimer=New-Object Windows.Forms.Timer
        $script:RemovalDialogTimer.Interval=50
        $script:RemovalDialogTimer.Add_Tick({
            $window=@([Windows.Forms.Application]::OpenForms | Where-Object { $_.Text -in @('Conferma eliminazione - oggetti verificati','Conferma archiviazione BitLocker') -and $_.Visible } | Select-Object -First 1)
            if ($window.Count -eq 0) { return }
            $dialog=$window[0]; $script:RemovalDialogSeen=$true
            try {
                $layout=@($dialog.Controls | Where-Object { $_ -is [Windows.Forms.TableLayoutPanel] })[0]
                $consent=@($dialog.Controls.Find('AdChildrenConsent',$true))[0]
                $confirm=@($dialog.Controls.Find('ConfirmRemoval',$true))[0]
                $preview=@($layout.Controls | Where-Object { $_ -is [Windows.Forms.RichTextBox] })[0]
                if ($null -eq $consent -or $null -eq $confirm -or $null -eq $preview) { throw 'Visible removal preview has incomplete controls.' }
                if ($script:RemovalDialogHasChildren -or $script:RemovalDialogMapping) {
                    if (-not $consent.Visible -or $consent.Checked -or $confirm.Enabled -or ($script:RemovalDialogHasChildren -and ($preview.Text -notlike '*msFVE-RecoveryInformation*' -or $preview.Text -notlike '*Recupero BitLocker*' -or $preview.Text -notlike '*ID: child-guid*'))) { throw 'Child metadata, warning or unchecked consent state missing.' }
                    $consent.Checked=$true
                    if (-not $confirm.Enabled) { throw 'Child consent did not enable deletion.' }
                    $consent.Checked=$false
                    if ($confirm.Enabled) { throw 'Removing child consent left deletion enabled.' }
                    $consent.Checked=$script:RemovalDialogAccept
                }
                elseif ($consent.Visible -or -not $confirm.Enabled) { throw 'Leaf computer unexpectedly requires child consent.' }
                if ($script:RemovalDialogMapping -and $preview.Text -notlike '*BACKUP GLPI*') { throw 'GLPI backup mapping is absent from the native preview.' }
                if ($script:RemovalDialogArchiveOnly -and $confirm.Text -ne 'Archivia su GLPI') { throw 'Archive-only preview still offers a deletion action.' }
                if ($script:RemovalDialogAccept) { $confirm.PerformClick() }
                else { $dialog.DialogResult='Cancel' }
            }
            catch { $script:RemovalDialogError=$_.Exception.Message; $dialog.DialogResult='Cancel' }
            finally { $script:RemovalDialogTimer.Stop() }
        })
        $children=@()
        if ($HasChildren) { $children=@([pscustomobject]@{Id='child-guid';DistinguishedName='CN=Recovery,CN=PC-UI,OU=Lab,DC=example,DC=invalid';ObjectClass='msFVE-RecoveryInformation'}) }
        $plan=[pscustomobject]@{PlanId='synthetic';Sources=@('AD');Entries=@([pscustomobject]@{Name='PC-UI';Error='';Targets=@([pscustomobject]@{Source='AD';DomainController='dc.example.invalid';Id='computer-guid';DistinguishedName='CN=PC-UI,OU=Lab,DC=example,DC=invalid';AdChildren=$children})})}
        $plan | Add-Member -NotePropertyName ArchiveOnly -NotePropertyValue $ArchiveOnly
        if ($Mapping -or $ArchiveOnly) { $plan.Entries[0] | Add-Member -NotePropertyName Backup -NotePropertyValue ([pscustomobject]@{ComputerId=901;Serial='SERIAL-UI';KeyCount=1;RequiresMappingConfirmation=$Mapping;Keys=@([pscustomobject]@{KeyId='recovery-guid';Volume='OS';Origins=@('AD:synthetic')})}) }
        try {
            $script:RemovalDialogTimer.Start()
            $decision=Show-RemovalPreview $plan
            if (-not $script:RemovalDialogSeen -or $script:RemovalDialogError) { throw ('Removal dialog verification failed: '+$script:RemovalDialogError) }
            if ($Accept) {
                if ($null -eq $decision -or $decision.IncludeAdChildren -ne $HasChildren -or $decision.ConfirmGlpiMapping -ne $Mapping) { throw 'Removal dialog returned incorrect explicit child consent.' }
            }
            elseif ($null -ne $decision) { throw 'Cancelled preview returned an accepted removal decision.' }
        }
        finally { $script:RemovalDialogTimer.Stop(); $script:RemovalDialogTimer.Dispose() }
    }
    Test-RemovalConsentDialog -HasChildren $true -Accept $false
    Test-RemovalConsentDialog -HasChildren $true -Accept $true
    Test-RemovalConsentDialog -HasChildren $false -Accept $true
    'PASS: native removal preview lists BitLocker child metadata, requires an unchecked explicit consent, supports revocation/cancel and leaves leaf-only confirmation unchanged.'
    Test-RemovalConsentDialog -HasChildren $true -Accept $true -Mapping $true
    Test-RemovalConsentDialog -HasChildren $false -Accept $true -Mapping $true -ArchiveOnly $true
    Test-RemovalConsentDialog -HasChildren $false -Accept $false -Mapping $true -ArchiveOnly $true
    if ($archiveButton.Text -ne 'Archivia BitLocker' -or $readArchiveButton.Text -ne 'Leggi archivio') { throw 'Native archive controls missing.' }
    'PASS: native GLPI mapping requires explicit consent in both deletion and archive-only modes; archive-only confirmation never offers deletion.'

    $snapshot.Complete=$false
    $snapshot.Sources[0].State='In attesa'
    $snapshot.Sources[0] | Add-Member -NotePropertyName Progress -NotePropertyValue '1/5 DC'
    $snapshot.Sources[0] | Add-Member -NotePropertyName CurrentTarget -NotePropertyValue 'dc2.example.invalid'
    $snapshot.Sources[2].State='In attesa'
    $snapshot.Sources[3].State='Errore'; $snapshot.Sources[3].Error='Synthetic GLPI failure'
    Show-ExplorerSnapshot $snapshot
    if ($deleteButton.Enabled -or $sourceStatusLabels.AD.Text -notlike '*1/5 DC*' -or $sourceStatusLabels.AD.BackColor -ne [Drawing.Color]::LightGoldenrodYellow -or $sourceStatusLabels.Entra.BackColor -ne [Drawing.Color]::Honeydew -or $sourceStatusLabels.GLPI.BackColor -ne [Drawing.Color]::MistyRose -or $sourceToolTip.GetToolTip($sourceStatusLabels.AD) -notlike '*dc2.example.invalid*') { throw 'Independent progress, colors, AD target or busy deletion guard failed.' }
    'PASS: one source can be green and another red while AD progress stays visible and deletion remains disabled.'

    $snapshot.Complete=$true; $snapshot.Message='Ricerca completata con errori'
    $snapshot.Sources[0].State='OK'; $snapshot.Sources[0].Progress='5/5 DC'; $snapshot.Sources[0].CurrentTarget=''
    $snapshot.Sources[2].State='OK'
    $script:Queue=New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $script:Pipeline=[PowerShell]::Create(); $script:Pipeline.Runspace=$script:Worker
    [void]$script:Pipeline.AddScript({param($FinalSnapshot) return $FinalSnapshot}.ToString()).AddArgument($snapshot)
    Set-SearchBusy $true
    $script:Invocation=$script:Pipeline.BeginInvoke()
    if (-not $script:Invocation.AsyncWaitHandle.WaitOne(5000)) { throw 'Mixed-error completion worker timed out.' }
    [void]$tickMethod.Invoke($timer, [object[]]@([EventArgs]::Empty))
    if ($script:Busy -or -not $deleteButton.Enabled -or $script:RemovalNeedsRefresh -or $sourceStatusLabels.AD.BackColor -ne [Drawing.Color]::Honeydew -or $sourceStatusLabels.GLPI.BackColor -ne [Drawing.Color]::MistyRose) { throw 'A terminal source error kept completed results blocked or cleared source colors.' }
    'PASS: the real timer releases selected results when every source terminates, including a source with errors.'

    $snapshot.Rows=@();$snapshot.Message='Ricerca completata. Nessun dispositivo trovato.'
    foreach ($source in $snapshot.Sources) { $source.State='OK';$source.Count=0;$source.Error=$null;$source.Progress='' }
    $script:Queue=New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $script:Pipeline=[PowerShell]::Create();$script:Pipeline.Runspace=$script:Worker
    [void]$script:Pipeline.AddScript({param($FinalSnapshot) return $FinalSnapshot}.ToString()).AddArgument($snapshot)
    Set-SearchBusy $true
    $script:Invocation=$script:Pipeline.BeginInvoke()
    if (-not $script:Invocation.AsyncWaitHandle.WaitOne(5000)) { throw 'Zero-result native UI fixture timed out.' }
    [void]$tickMethod.Invoke($timer,[object[]]@([EventArgs]::Empty))
    if ($script:Busy -or $grid.Rows.Count -ne 0 -or $counterLabel.Text -ne 'Risultati: 0 | Selezionati: 0' -or -not $searchButton.Enabled -or $cancelButton.Enabled -or $deleteButton.Enabled -or $archiveButton.Enabled -or $readArchiveButton.Enabled -or @($sourceStatusLabels.Values | Where-Object { $_.BackColor -ne [Drawing.Color]::Honeydew }).Count -gt 0) { throw 'A completed zero-result search left the native UI pending or actionable.' }
    'PASS: a zero-result search clears the native grid, completes every source and releases the search controls.'
    Update-ExplorerSourceStatus @([pscustomobject]@{Name='Entra';State='In attesa';Progress='Pagina 2, 999 record letti';Error=$null})
    if ($sourceStatusLabels.Entra.Text -notlike '*Pagina 2, 999*' -or $sourceStatusLabels.Entra.BackColor -ne [Drawing.Color]::LightGoldenrodYellow) { throw 'Cloud page progress is missing from the native footer.' }
    'PASS: the native footer identifies the active cloud page and record count.'


}
finally {
    Close-ExplorerGraphLogin
    $timer.Dispose()
    if ($null -ne $script:Pipeline) { $script:Pipeline.Stop(); $script:Pipeline.Dispose() }
    $script:Worker.Close(); $script:Worker.Dispose()
    $gridCopyMenu.Dispose()
    $sourceToolTip.Dispose()
    $form.Dispose()
    $applicationIcon.Dispose()
}
'@
try {
    [IO.File]::WriteAllText($probePath, ($text.Substring(0, $position) + $probe), (New-Object Text.UTF8Encoding($true)))
    & $probePath -ConfigPath (Join-Path $root 'computer-explorer.config.example.json')
}
finally { Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue }
