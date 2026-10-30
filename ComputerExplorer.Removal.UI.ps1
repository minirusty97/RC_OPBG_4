#requires -version 5.1
function Show-AssistenteITRemovalPreview {
    param($Plan,$Owner)
    $form=$Owner
    $dialog = New-Object Windows.Forms.Form
    $dialog.Icon = $form.Icon
    $archiveOnly=[bool](Get-UiSetting $Plan 'ArchiveOnly' $false)
    $dialog.Text = 'Conferma eliminazione - oggetti verificati'; if ($archiveOnly) { $dialog.Text='Conferma archiviazione BitLocker' }; $dialog.Size = New-Object Drawing.Size(1000, 680)
    $dialog.MinimumSize = New-Object Drawing.Size(750, 450); $dialog.StartPosition = 'CenterParent';$dialog.Font=$form.Font
    $panel = New-Object Windows.Forms.TableLayoutPanel
    $panel.Dock = 'Fill'; $panel.ColumnCount = 1; $panel.RowCount = 5; $panel.Padding = New-Object Windows.Forms.Padding(10)
    [void]$panel.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 65)))
    [void]$panel.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
    [void]$panel.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 60)))
    [void]$panel.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 0)))
    [void]$panel.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 45)))
    $intro = New-Object Windows.Forms.Label; $intro.Dock = 'Fill'
    $ready = @($Plan.Entries | Where-Object { [string]::IsNullOrWhiteSpace($_.Error) -and $_.Targets.Count -gt 0 }).Count
    $hasAdChildren = -not $archiveOnly -and @($Plan.Entries | Where-Object { [string]::IsNullOrWhiteSpace($_.Error) } | ForEach-Object { $_.Targets } | Where-Object { $_.Source -eq 'AD' -and $_.AdChildren.Count -gt 0 }).Count -gt 0
    if (-not $hasAdChildren) { $panel.RowStyles[2].Height = 0 }
    $intro.Text = 'Origini: {0}. Computer con oggetti pronti: {1}/{2}. Ordine: Intune, AD, Entra.' -f ($Plan.Sources -join ', '), $ready, $Plan.Entries.Count
    if ($Plan.Sources -contains 'Intune') { $intro.Text += [Environment]::NewLine + 'Intune: eliminare una registrazione Windows avvia anche il ritiro dalla gestione.' }
    $intro.Text += [Environment]::NewLine + 'Prima di eliminare: archivio BitLocker aggiunto alle Note GLPI e riletto dalle Note GLPI. Un errore blocca il computer.'
    if ($archiveOnly) { $intro.Text='Archiviazione delle chiavi in chiaro nelle Note GLPI. Nessun computer verra eliminato. Origini: '+($Plan.Sources -join ', ')+'. Verificare scheda GLPI, seriale e origini.' }
    $unmapped=@($Plan.Entries | Where-Object { [string]::IsNullOrWhiteSpace($_.Error) -and $_.Targets.Count -gt 0 -and $null -ne (Get-UiSetting $_ 'Backup' $null) -and -not [bool](Get-UiSetting $_.Backup 'ArchiveAvailable' $true) })
    if ($unmapped.Count) {
        $panel.RowStyles[0].Height=95
        $intro.Text='Origini: '+($Plan.Sources -join ', ')+'. PC pronti: '+$ready+'/'+$Plan.Entries.Count+'.'+[Environment]::NewLine+'Per '+$unmapped.Count+' PC manca una scheda GLPI univoca: seguono download/stampa e conferma separata. Gli altri PC mantengono il backup GLPI.'
        if ($Plan.Sources -contains 'Intune') { $intro.Text+=[Environment]::NewLine+'Intune: eliminare la registrazione Windows avvia anche il ritiro dalla gestione.' }
    }
    $preview = New-Object Windows.Forms.RichTextBox; $preview.Dock = 'Fill'; $preview.ReadOnly = $true
    $preview.WordWrap = $false; $preview.Font = New-Object Drawing.Font('Consolas', 9)
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($entry in $Plan.Entries) {
        [void]$lines.Add($entry.Name)
        if (-not [string]::IsNullOrWhiteSpace($entry.Error)) { [void]$lines.Add('  BLOCCATO: ' + $entry.Error) }
        elseif ($entry.Targets.Count -eq 0) { [void]$lines.Add('  Nessun oggetto presente nelle origini selezionate.') }
        $identity=Get-UiSetting $entry 'HybridIdentity' $null
        if ($null -ne $identity) {
            [void]$lines.Add('  IDENTITA AD/ENTRA | '+$identity.State)
            foreach ($check in $identity.Records) {
                [void]$lines.Add('    '+$check.TrustType+' | Device ID: '+$check.DeviceId+' | '+$check.State+' | '+$check.Detail)
                foreach ($match in $check.AdMatches) { [void]$lines.Add('      AD: '+$match.Name+' | GUID: '+$match.ObjectGUID+' | DC: '+$match.DomainController) }
            }
        }
        $backup=Get-UiSetting $entry 'Backup' $null
        if ($null -ne $backup) {
            if (-not [bool](Get-UiSetting $backup 'ArchiveAvailable' $true)) { [void]$lines.Add('  AVVISO: '+$backup.Warning+' Chiavi da conservare: '+$backup.KeyCount) }
            else {
            [void]$lines.Add(('  BACKUP GLPI | Computer ID: {0} | Seriale: {1} | Chiavi: {2}' -f $backup.ComputerId,$backup.Serial,$backup.KeyCount))
            if ((Get-UiSetting $backup 'MatchBy' 'Name') -eq 'Serial') { [void]$lines.Add('  Associazione per seriale Intune | Nome GLPI: '+$backup.GlpiName) }
            }
            foreach ($key in $backup.Keys) { [void]$lines.Add(('    Key ID: {0} | Volume: {1} | Origine: {2}' -f $key.KeyId,$key.Volume,($key.Origins -join ', '))) }
        }
        foreach ($target in $entry.Targets) {
            [void]$lines.Add('  ' + $target.Source + ' | ' + $target.DomainController + ' | ID: ' + $target.Id)
            if ($target.Source -eq 'AD') {
                [void]$lines.Add('    ' + $target.DistinguishedName)
                if ($archiveOnly) { [void]$lines.Add('    Oggetti di recupero BitLocker visibili: '+@($target.AdChildren | Where-Object ObjectClass -eq 'msFVE-RecoveryInformation').Count+'. Zero oggetti visibili non esclude restrizioni di lettura AD.') }
                foreach ($child in $target.AdChildren) {
                    $label = $child.ObjectClass
                    if ($child.ObjectClass -eq 'msFVE-RecoveryInformation') { if ($archiveOnly) { $label+=' | Recupero BitLocker: sola lettura per archivio' } else { $label += ' | Recupero BitLocker: queste informazioni verranno eliminate da AD' } }
                    [void]$lines.Add('    FIGLIO AD | ' + $label + ' | ID: ' + $child.Id)
                    [void]$lines.Add('      ' + $child.DistinguishedName)
                }
            }
            elseif ($target.Source -eq 'Intune') { [void]$lines.Add('    Windows | Seriale: ' + $target.SerialNumber + ' | DeviceId Entra: ' + $target.LinkId) }
            else { [void]$lines.Add('    DeviceId: ' + $target.LinkId) }
        }
        [void]$lines.Add('')
    }
    $preview.Text = $lines -join [Environment]::NewLine
    $buttons = New-Object Windows.Forms.FlowLayoutPanel; $buttons.Dock = 'Fill'; $buttons.FlowDirection = 'RightToLeft'
    $cancel = New-Object Windows.Forms.Button; $cancel.Text = 'Annulla'; $cancel.Width = 100; $cancel.DialogResult = 'Cancel'
    $confirm = New-Object Windows.Forms.Button; $confirm.Name = 'ConfirmRemoval'; $confirm.Text = 'Elimina definitivamente'; $confirm.Width = 185; $confirm.Enabled = $ready -gt 0 -and -not $hasAdChildren
    $childConsent = New-Object Windows.Forms.CheckBox; $childConsent.Name = 'AdChildrenConsent'; $childConsent.Dock = 'Fill'; $childConsent.Visible = $hasAdChildren
    $childConsent.Text = 'Autorizzo anche l''eliminazione degli oggetti figli AD elencati. Le eventuali informazioni di recupero BitLocker salvate in AD verranno eliminate.'

    if ($archiveOnly) { $confirm.Text='Archivia su GLPI' }
    $requiresMapping=@($Plan.Entries | Where-Object { [string]::IsNullOrWhiteSpace($_.Error) -and $null -ne (Get-UiSetting $_ 'Backup' $null) -and $_.Backup.RequiresMappingConfirmation }).Count -gt 0
    if ($requiresMapping) {
        $panel.RowStyles[2].Height=80; $childConsent.Visible=$true; $confirm.Enabled=$false
        $childConsent.Text='Confermo di aver verificato le schede GLPI e i seriali elencati: alcune associazioni sono basate sul nome. Autorizzo il backup e, per l''eliminazione, anche la rimozione degli eventuali figli AD e record BitLocker.'
    }
    $hybridEntries=@($Plan.Entries | Where-Object { -not $_.Error -and $null -ne (Get-UiSetting $_ 'HybridIdentity' $null) -and $_.HybridIdentity.RequiresConfirmation })
    $requiresHybrid=-not $archiveOnly -and $hybridEntries.Count -gt 0
    $hybridConsent=New-Object Windows.Forms.CheckBox;$hybridConsent.Name='HybridIdentityConsent';$hybridConsent.Dock='Fill';$hybridConsent.Visible=$requiresHybrid
    $hybridConsent.Text='Confermo di aver verificato la discordanza tra GUID AD e Device ID Entra hybrid per: '+(@($hybridEntries | ForEach-Object { $_.Name }) -join ', ')+'. Autorizzo l''eliminazione degli oggetti elencati.'
    if ($requiresHybrid) { $panel.RowStyles[3].Height=70;$confirm.Enabled=$false }
    $consentState=[pscustomobject]@{Button=$confirm;Ready=($ready -gt 0);Child=$childConsent;Hybrid=$hybridConsent;RequiresChild=($hasAdChildren -or $requiresMapping);RequiresHybrid=$requiresHybrid}
    $childConsent.Tag=$consentState;$hybridConsent.Tag=$consentState
    $consentChanged={param($sender,$eventArgs);$gate=$sender.Tag;$gate.Button.Enabled=$gate.Ready -and (-not $gate.RequiresChild -or $gate.Child.Checked) -and (-not $gate.RequiresHybrid -or $gate.Hybrid.Checked)}
    $childConsent.Add_CheckedChanged($consentChanged);$hybridConsent.Add_CheckedChanged($consentChanged)
    $previewDecision=@{LossNames=@()}

    $confirm.Add_Click({
        if ($unmapped.Count -gt 0) {
            $loss=Show-ExplorerBitLockerLossConfirmation -Plan $Plan -Entries $unmapped -Owner $dialog
            if ($null -eq $loss) { return }
            $previewDecision.LossNames=$loss.Names
        }
        $dialog.DialogResult='OK';$dialog.Close()
    })
    $buttons.Controls.AddRange(@($cancel, $confirm))
    $panel.Controls.Add($intro, 0, 0); $panel.Controls.Add($preview, 0, 1); $panel.Controls.Add($childConsent, 0, 2); $panel.Controls.Add($hybridConsent, 0, 3); $panel.Controls.Add($buttons, 0, 4)
    $dialog.Controls.Add($panel); $dialog.AcceptButton = $cancel; $dialog.CancelButton = $cancel
    try {
        if ($dialog.ShowDialog($form) -eq 'OK') { return [pscustomobject]@{ IncludeAdChildren = ($hasAdChildren -and $childConsent.Checked); ConfirmGlpiMapping=($requiresMapping -and $childConsent.Checked);ConfirmBitLockerLossFor=[string[]]$previewDecision.LossNames;ConfirmHybridMismatchFor=[string[]]@($hybridEntries | Where-Object { $requiresHybrid -and $hybridConsent.Checked } | ForEach-Object { $_.Name }) } }
        return $null
    }
    finally { $dialog.Dispose() }
}

