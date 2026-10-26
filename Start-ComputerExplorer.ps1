#requires -version 5.1
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'computer-explorer.config.local.json'),
    [string]$EnvPath = (Join-Path $PSScriptRoot '.env')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Computer Explorer richiede Windows.' }
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    throw 'Avviare da Windows PowerShell oppure con powershell.exe -STA -File .\Start-ComputerExplorer.ps1.'
}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
Import-Module (Join-Path $PSScriptRoot 'ComputerExplorer.Core.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'BitLocker.Archive.psm1') -ErrorAction Stop
$config = Read-ExplorerConfiguration $ConfigPath
$ConfigPath = (Resolve-Path -LiteralPath $ConfigPath).ProviderPath

function Get-UiSetting {
    param($Object, [string]$Name, $Default)
    if ($null -ne $Object) {
        $property = $Object.PSObject.Properties[$Name]
        if ($null -ne $property) { return $property.Value }
    }
    return $Default
}

function Read-GlpiCredentials {
    param([bool]$UseAppToken)
    $dialog = New-Object Windows.Forms.Form
    $dialog.Icon = $form.Icon
    $dialog.Text = 'Accesso GLPI'; $dialog.Size = New-Object Drawing.Size(490, 240)
    $dialog.StartPosition = 'CenterParent'; $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false; $dialog.MinimizeBox = $false
    $intro = New-Object Windows.Forms.Label
    $intro.Text = 'Token salvati cifrati da Windows per il tuo account su questo PC.'
    $intro.SetBounds(15, 12, 450, 35)
    $userLabel = New-Object Windows.Forms.Label; $userLabel.Text = 'User token'; $userLabel.SetBounds(15, 55, 95, 25)
    $userBox = New-Object Windows.Forms.TextBox; $userBox.SetBounds(115, 52, 340, 25); $userBox.UseSystemPasswordChar = $true
    $appLabel = New-Object Windows.Forms.Label; $appLabel.Text = 'App token'; $appLabel.SetBounds(15, 95, 95, 25)
    $appBox = New-Object Windows.Forms.TextBox; $appBox.SetBounds(115, 92, 340, 25); $appBox.UseSystemPasswordChar = $true
    $appBox.Enabled = $UseAppToken; $appLabel.Enabled = $UseAppToken
    $ok = New-Object Windows.Forms.Button; $ok.Text = 'Salva token'; $ok.SetBounds(255, 145, 95, 30)
    $cancel = New-Object Windows.Forms.Button; $cancel.Text = 'Annulla'; $cancel.SetBounds(360, 145, 95, 30)
    $cancel.DialogResult = 'Cancel'; $dialog.CancelButton = $cancel; $dialog.AcceptButton = $ok
    $ok.Add_Click({
        if ($userBox.Text.Trim().Length -eq 0 -or ($UseAppToken -and $appBox.Text.Trim().Length -eq 0)) {
            [void][Windows.Forms.MessageBox]::Show($dialog, 'Inserire i token richiesti.', 'GLPI', 'OK', 'Information')
            return
        }
        $dialog.DialogResult = 'OK'; $dialog.Close()
    })
    $dialog.Controls.AddRange(@($intro, $userLabel, $userBox, $appLabel, $appBox, $ok, $cancel))
    try {
        if ($dialog.ShowDialog($form) -ne 'OK') { return $null }
        $user = ConvertTo-SecureString -String $userBox.Text.Trim() -AsPlainText -Force
        $app = $null
        if ($UseAppToken) { $app = ConvertTo-SecureString -String $appBox.Text.Trim() -AsPlainText -Force }
        try { Save-ExplorerGlpiCredentials -Path $EnvPath -User $user -App $app }
        catch { $user.Dispose(); if ($null -ne $app) { $app.Dispose() }; throw }
        return [pscustomobject]@{ User = $user; App = $app }
    }
    finally { $userBox.Clear(); $appBox.Clear(); $dialog.Dispose() }
}


function Initialize-ArchiveUiCredentials {
    $settings=Get-UiSetting (Read-ExplorerConfiguration $ConfigPath).Settings 'Glpi' $null
    if (-not [bool](Get-UiSetting $settings 'Enabled' $false)) { throw 'Configurare e abilitare GLPI nelle Impostazioni prima di archiviare o eliminare.' }
    if ($null -eq $script:GlpiCredentials) {
        $useAppToken=[bool](Get-UiSetting $settings 'UseAppToken' $true)
        $script:GlpiCredentials=Read-ExplorerGlpiCredentials -Path $EnvPath -UseAppToken $useAppToken
        if ($null -eq $script:GlpiCredentials) { $script:GlpiCredentials=Read-GlpiCredentials $useAppToken }
        if ($null -eq $script:GlpiCredentials) { return $false }
    }
    return $null -ne $script:GlpiCredentials
}

function Show-ArchivedBitLockerKeys {
    param($Result)
    $dialog=New-Object Windows.Forms.Form; $dialog.Icon=$form.Icon; $dialog.Text='Chiavi BitLocker archiviate su GLPI'
    $live=[bool](Get-UiSetting $Result 'Live' $false)
    if ($live) { $dialog.Text='Ricerca chiavi BitLocker - Intune / AD' }
    $dialog.ClientSize=New-Object Drawing.Size(1050,510); $dialog.StartPosition='CenterParent'
    $panel=New-Object Windows.Forms.TableLayoutPanel; $panel.Dock='Fill'; $panel.RowCount=4; $panel.ColumnCount=1; $panel.Padding=New-Object Windows.Forms.Padding(10)
    [void]$panel.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',80)))
    [void]$panel.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))
    [void]$panel.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',45)))
    [void]$panel.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',40)))
    $information=New-Object Windows.Forms.TextBox;$information.Dock='Fill';$information.Multiline=$true;$information.ReadOnly=$true;$information.ScrollBars='Vertical'
    $information.Text='Archivio GLPI: '+$Result.Records.Count+' chiavi.'
    if ($live) {
        $information.Text=$Result.Name+' - '+$Result.Records.Count+' chiavi trovate.'+[Environment]::NewLine+(@($Result.Sources | ForEach-Object { $_.Name+': '+$_.State+' ('+$_.Count+' chiavi) '+$_.Error }) -join [Environment]::NewLine)
        if ($Result.Records.Count -eq 0) { $information.Text+=[Environment]::NewLine+'Nessuna chiave recuperata. Verificare gli esiti delle fonti e, per i PC gia eliminati, consultare Leggi archivio.' }
    }
    $table=New-Object Windows.Forms.DataGridView; $table.Dock='Fill'; $table.ReadOnly=$true; $table.AllowUserToAddRows=$false; $table.AllowUserToDeleteRows=$false; $table.RowHeadersVisible=$false
    $table.MultiSelect=$false; $table.SelectionMode='FullRowSelect'; $table.AllowUserToResizeRows=$false
    foreach ($column in @(@('Key ID',285),@('Seriale',150),@('Volume',150),@('Origine',270),@('Archiviata',175))) { $i=$table.Columns.Add($column[0],$column[0]); $table.Columns[$i].Width=$column[1] }
    if ($live) { $table.Columns[4].HeaderText='Acquisita' }
    $secret=New-Object Windows.Forms.TextBox; $secret.Dock='Fill'; $secret.ReadOnly=$true; $secret.Font=New-Object Drawing.Font('Consolas',12)
    foreach ($record in $Result.Records) { $i=$table.Rows.Add([object[]]@($record.KeyId,$record.Serial,$record.Volume,($record.Origins -join ', '),$(if ($live) { $record.CreatedAt } else { $record.ArchivedAtUtc }))); $table.Rows[$i].Tag=$record }
    $table.Tag=$secret
    $table.Add_SelectionChanged({param($sender,$eventArgs); $sender.Tag.Clear(); if ($sender.SelectedRows.Count -eq 1 -and $null -ne $sender.SelectedRows[0].Tag) { $sender.Tag.Text=$sender.SelectedRows[0].Tag.Password }})
    $buttons=New-Object Windows.Forms.FlowLayoutPanel; $buttons.Dock='Fill'
    $copy=New-Object Windows.Forms.Button; $copy.Text='Copia chiave'; $copy.Width=125; $copy.Tag=$secret
    $copy.Add_Click({param($sender,$eventArgs); if ($sender.Tag.Text) { try { [Windows.Forms.Clipboard]::SetText($sender.Tag.Text) } catch { [void][Windows.Forms.MessageBox]::Show('Appunti occupati. Riprovare.') } }})
    $close=New-Object Windows.Forms.Button; $close.Text='Chiudi'; $close.Width=100; $close.DialogResult='Cancel'
    $buttons.Controls.AddRange(@($copy,$close)); $panel.Controls.Add($information,0,0); $panel.Controls.Add($table,0,1); $panel.Controls.Add($secret,0,2); $panel.Controls.Add($buttons,0,3)
    $dialog.Controls.Add($panel); $dialog.CancelButton=$close
    try {
        if ($table.Rows.Count) { $table.ClearSelection(); $table.Rows[0].Selected=$true }
        [void]$dialog.ShowDialog($form)
    }
    finally { $secret.Clear(); foreach ($row in $table.Rows) { $row.Tag=$null }; $dialog.Dispose() }
}

function Set-CellPresence {
    param($Cell, [string]$Color)
    $palette = @{
        Verde = [Drawing.Color]::FromArgb(214, 241, 219)
        Giallo = [Drawing.Color]::FromArgb(255, 236, 179)
        Rosso = [Drawing.Color]::FromArgb(251, 216, 216)
        Grigio = [Drawing.Color]::FromArgb(232, 234, 237)
    }
    $Cell.Style.BackColor = $palette[$Color]
    $Cell.Style.SelectionBackColor = $palette[$Color]
    $Cell.Style.ForeColor = [Drawing.Color]::Black
    $Cell.Style.SelectionForeColor = [Drawing.Color]::Black
}

function Update-ExplorerCounters {
    $selected = @($grid.SelectedRows | Where-Object { $null -ne $_.Tag }).Count
    $counterLabel.Text = 'Risultati: {0} | Selezionati: {1}' -f $grid.Rows.Count, $selected
    $complete = $null -ne $script:Latest -and $script:Latest.Complete
    if ($complete) { $complete = @($script:Latest.Sources | Where-Object { $_.State -notin @('OK','Errore','Esclusa') }).Count -eq 0 }
    $conflicts=@($grid.SelectedRows | Where-Object { $null -ne $_.Tag -and $null -ne $_.Tag.PSObject.Properties['SerialConflict'] -and $_.Tag.SerialConflict }).Count
    if ($conflicts -gt 0) { $counterLabel.Text+=' | Conflitti seriale: '+$conflicts }
    $deleteButton.Enabled = $conflicts -eq 0 -and $selected -gt 0 -and $complete -and -not $script:Busy -and -not $script:RemovalNeedsRefresh
    $archiveButton.Enabled=$deleteButton.Enabled
    $readArchiveButton.Enabled=$selected -eq 1 -and $complete -and -not $script:Busy
    $findKeysButton.Enabled=-not $script:Busy -and ($selected -eq 1 -or $nameBox.Text.Trim().Length -ge $config.MinimumCharacters)
}

function Show-RemovalSources {
    param([string[]]$Names,[switch]$ArchiveOnly)
    $dialog = New-Object Windows.Forms.Form
    $dialog.Icon = $form.Icon
    $dialog.Text = 'Elimina computer - origini'; if ($ArchiveOnly) { $dialog.Text='Archivia BitLocker - origini' }; $dialog.Size = New-Object Drawing.Size(640, 430)
    $dialog.MinimumSize = New-Object Drawing.Size(520, 350); $dialog.StartPosition = 'CenterParent'
    $panel = New-Object Windows.Forms.TableLayoutPanel
    $panel.Dock = 'Fill'; $panel.ColumnCount = 1; $panel.RowCount = 4; $panel.Padding = New-Object Windows.Forms.Padding(12)
    [void]$panel.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 45)))
    [void]$panel.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 45)))
    [void]$panel.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
    [void]$panel.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 45)))
    $intro = New-Object Windows.Forms.Label; $intro.Dock = 'Fill'
    $intro.Text = 'Computer selezionati: {0}. Scegliere le origini; segue una verifica degli oggetti prima della conferma.' -f $Names.Count
    $choices = New-Object Windows.Forms.FlowLayoutPanel; $choices.Dock = 'Fill'
    $checks = @()
    foreach ($name in @('AD', 'Entra', 'Intune')) {
        $check = New-Object Windows.Forms.CheckBox; $check.Text = $name; $check.Checked = $true; $check.AutoSize = $true
        $checks += @($check); $choices.Controls.Add($check)
    }
    $glpiLabel = New-Object Windows.Forms.Label; $glpiLabel.Text = 'GLPI: backup nelle Note'; $glpiLabel.AutoSize = $true
    $glpiLabel.Margin = New-Object Windows.Forms.Padding(20, 4, 0, 0); $choices.Controls.Add($glpiLabel)
    $list = New-Object Windows.Forms.ListBox; $list.Dock = 'Fill'
    foreach ($name in $Names) { [void]$list.Items.Add($name) }
    $buttons = New-Object Windows.Forms.FlowLayoutPanel; $buttons.Dock = 'Fill'; $buttons.FlowDirection = 'RightToLeft'
    $cancel = New-Object Windows.Forms.Button; $cancel.Text = 'Annulla'; $cancel.Width = 95; $cancel.DialogResult = 'Cancel'
    $verify = New-Object Windows.Forms.Button; $verify.Text = 'Verifica oggetti'; $verify.Width = 140
    $verify.Add_Click({
        if (@($checks | Where-Object { $_.Checked }).Count -eq 0) {
            [void][Windows.Forms.MessageBox]::Show($dialog, 'Selezionare almeno una origine.', 'Elimina', 'OK', 'Information'); return
        }
        $dialog.DialogResult = 'OK'; $dialog.Close()
    })
    $buttons.Controls.AddRange(@($cancel, $verify))
    $panel.Controls.Add($intro, 0, 0); $panel.Controls.Add($choices, 0, 1); $panel.Controls.Add($list, 0, 2); $panel.Controls.Add($buttons, 0, 3)
    $dialog.Controls.Add($panel); $dialog.AcceptButton = $verify; $dialog.CancelButton = $cancel
    try {
        if ($dialog.ShowDialog($form) -ne 'OK') { return $null }
        return ,@($checks | Where-Object { $_.Checked } | ForEach-Object { $_.Text })
    }
    finally { $dialog.Dispose() }
}

function Show-RemovalPreview {
    param($Plan)
    $dialog = New-Object Windows.Forms.Form
    $dialog.Icon = $form.Icon
    $archiveOnly=[bool](Get-UiSetting $Plan 'ArchiveOnly' $false)
    $dialog.Text = 'Conferma eliminazione - oggetti verificati'; if ($archiveOnly) { $dialog.Text='Conferma archiviazione BitLocker' }; $dialog.Size = New-Object Drawing.Size(1000, 680)
    $dialog.MinimumSize = New-Object Drawing.Size(750, 450); $dialog.StartPosition = 'CenterParent'
    $panel = New-Object Windows.Forms.TableLayoutPanel
    $panel.Dock = 'Fill'; $panel.ColumnCount = 1; $panel.RowCount = 4; $panel.Padding = New-Object Windows.Forms.Padding(10)
    [void]$panel.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 65)))
    [void]$panel.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
    [void]$panel.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 60)))
    [void]$panel.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 45)))
    $intro = New-Object Windows.Forms.Label; $intro.Dock = 'Fill'
    $ready = @($Plan.Entries | Where-Object { [string]::IsNullOrWhiteSpace($_.Error) -and $_.Targets.Count -gt 0 }).Count
    $hasAdChildren = -not $archiveOnly -and @($Plan.Entries | Where-Object { [string]::IsNullOrWhiteSpace($_.Error) } | ForEach-Object { $_.Targets } | Where-Object { $_.Source -eq 'AD' -and $_.AdChildren.Count -gt 0 }).Count -gt 0
    if (-not $hasAdChildren) { $panel.RowStyles[2].Height = 0 }
    $intro.Text = 'Origini: {0}. Computer con oggetti pronti: {1}/{2}. Ordine: Intune, AD, Entra.' -f ($Plan.Sources -join ', '), $ready, $Plan.Entries.Count
    if ($Plan.Sources -contains 'Intune') { $intro.Text += [Environment]::NewLine + 'Intune: eliminare una registrazione Windows avvia anche il ritiro dalla gestione.' }
    $intro.Text += [Environment]::NewLine + 'Prima di eliminare: archivio BitLocker aggiunto alle Note GLPI e riletto dalle Note GLPI. Un errore blocca il computer.'
    if ($archiveOnly) { $intro.Text='Archiviazione delle chiavi in chiaro nelle Note GLPI. Nessun computer verra eliminato. Verificare scheda GLPI, seriale e origini.' }
    $preview = New-Object Windows.Forms.RichTextBox; $preview.Dock = 'Fill'; $preview.ReadOnly = $true
    $preview.WordWrap = $false; $preview.Font = New-Object Drawing.Font('Consolas', 9)
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($entry in $Plan.Entries) {
        [void]$lines.Add($entry.Name)
        if (-not [string]::IsNullOrWhiteSpace($entry.Error)) { [void]$lines.Add('  BLOCCATO: ' + $entry.Error) }
        elseif ($entry.Targets.Count -eq 0) { [void]$lines.Add('  Nessun oggetto presente nelle origini selezionate.') }
        $backup=Get-UiSetting $entry 'Backup' $null
        if ($null -ne $backup) {
            [void]$lines.Add(('  BACKUP GLPI | Computer ID: {0} | Seriale: {1} | Chiavi: {2}' -f $backup.ComputerId,$backup.Serial,$backup.KeyCount))
            foreach ($key in $backup.Keys) { [void]$lines.Add(('    Key ID: {0} | Volume: {1} | Origine: {2}' -f $key.KeyId,$key.Volume,($key.Origins -join ', '))) }
        }
        foreach ($target in $entry.Targets) {
            [void]$lines.Add('  ' + $target.Source + ' | ' + $target.DomainController + ' | ID: ' + $target.Id)
            if ($target.Source -eq 'AD') {
                [void]$lines.Add('    ' + $target.DistinguishedName)
                foreach ($child in $target.AdChildren) {
                    $label = $child.ObjectClass
                    if ($child.ObjectClass -eq 'msFVE-RecoveryInformation') { $label += ' | Recupero BitLocker: queste informazioni verranno eliminate da AD' }
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
    $confirm = New-Object Windows.Forms.Button; $confirm.Name = 'ConfirmRemoval'; $confirm.Text = 'Elimina definitivamente'; $confirm.Width = 185; $confirm.DialogResult = 'OK'; $confirm.Enabled = $ready -gt 0 -and -not $hasAdChildren
    $childConsent = New-Object Windows.Forms.CheckBox; $childConsent.Name = 'AdChildrenConsent'; $childConsent.Dock = 'Fill'; $childConsent.Visible = $hasAdChildren
    $childConsent.Text = 'Autorizzo anche l''eliminazione degli oggetti figli AD elencati. Le eventuali informazioni di recupero BitLocker salvate in AD verranno eliminate.'
    $childConsent.Tag = [pscustomobject]@{ Button = $confirm; Ready = ($ready -gt 0) }
    $childConsent.Add_CheckedChanged({ param($sender, $eventArgs); $sender.Tag.Button.Enabled = $sender.Tag.Ready -and $sender.Checked })
    if ($archiveOnly) { $confirm.Text='Archivia su GLPI' }
    $requiresMapping=@($Plan.Entries | Where-Object { [string]::IsNullOrWhiteSpace($_.Error) -and $null -ne (Get-UiSetting $_ 'Backup' $null) -and $_.Backup.RequiresMappingConfirmation }).Count -gt 0
    if ($requiresMapping) {
        $panel.RowStyles[2].Height=80; $childConsent.Visible=$true; $confirm.Enabled=$false
        $childConsent.Text='Confermo di aver verificato le schede GLPI e i seriali elencati: alcune associazioni sono basate sul nome. Autorizzo il backup e, per l''eliminazione, anche la rimozione degli eventuali figli AD e record BitLocker.'
    }
    $buttons.Controls.AddRange(@($cancel, $confirm))
    $panel.Controls.Add($intro, 0, 0); $panel.Controls.Add($preview, 0, 1); $panel.Controls.Add($childConsent, 0, 2); $panel.Controls.Add($buttons, 0, 3)
    $dialog.Controls.Add($panel); $dialog.AcceptButton = $cancel; $dialog.CancelButton = $cancel
    try {
        if ($dialog.ShowDialog($form) -eq 'OK') { return [pscustomobject]@{ IncludeAdChildren = ($hasAdChildren -and $childConsent.Checked); ConfirmGlpiMapping=($requiresMapping -and $childConsent.Checked) } }
        return $null
    }
    finally { $dialog.Dispose() }
}

function Add-RemovalReportRow {
    param($Result)
    [void]$removalGrid.Rows.Add([object[]]@($Result.Name, $Result.Source, $Result.Destination, $Result.State, $Result.Id, $Result.Error))
}

function Start-RemovalOperation {
    param([ValidateSet('PrepareRemoval','Remove','PrepareArchive','Archive','ReadArchive','ReadKeys')][string]$Operation, [string[]]$Names, [string[]]$Sources, [string]$PlanId, [switch]$IncludeAdChildren, [switch]$ConfirmGlpiMapping, [int]$ComputerId)
    try {
        $script:Operation = $Operation; $script:Stopping = $false
        $script:Queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $script:Pipeline = [PowerShell]::Create(); $script:Pipeline.Runspace = $script:Worker
        if ($Operation -in @('Remove','Archive')) {
            if ($Operation -eq 'Remove') { $script:RemovalNeedsRefresh = $true }
            $script:RemovalCancellation = New-Object Threading.CancellationTokenSource
            $removalGrid.Rows.Clear(); $tabs.SelectedTab = $removalTab
        }
        $workerCode = {
            param($ModulePath, $OperationName, $Names, $Sources, $ConfigFile, $PlanId, $Queue, $Cancellation, $IncludeAdChildren, $Credentials, $ConfirmMapping, $ComputerId)
            $ErrorActionPreference = 'Stop'
            Import-Module $ModulePath -ErrorAction Stop
            if ($OperationName -in @('PrepareRemoval','PrepareArchive')) {
                $arguments=@{Names=$Names;Sources=$Sources;ConfigPath=$ConfigFile;ProgressQueue=$Queue}
                if ($null -ne $Credentials) { $arguments.GlpiCredentials=$Credentials }
                if ($OperationName -eq 'PrepareArchive') { $arguments.ArchiveOnly=$true }
                New-ExplorerRemovalPlan @arguments
            }
            elseif ($OperationName -eq 'ReadKeys') {
                Import-Module (Join-Path (Split-Path $ModulePath -Parent) 'BitLocker.Archive.psm1') -ErrorAction Stop
                Find-ExplorerBitLockerKeys -Name $Names[0] -ConfigPath $ConfigFile -ProgressQueue $Queue
            }
            elseif ($OperationName -eq 'ReadArchive') {
                Import-Module (Join-Path (Split-Path $ModulePath -Parent) 'ComputerExplorer.Core.psm1') -ErrorAction Stop
                Import-Module (Join-Path (Split-Path $ModulePath -Parent) 'BitLocker.Archive.psm1') -ErrorAction Stop
                $settings=(Read-ExplorerConfiguration $ConfigFile).Settings.Glpi
                $records=@(Read-ExplorerBitLockerArchive -ComputerId $ComputerId -Settings $settings -UserToken $Credentials.User -AppToken $Credentials.App)
                [pscustomobject]@{Records=$records}
            }
            else {
                $arguments=@{PlanId=$PlanId;ProgressQueue=$Queue;Cancellation=$Cancellation;IncludeAdChildren=[bool]$IncludeAdChildren;Confirm=$false}
                if ($ConfirmMapping) { $arguments.ConfirmGlpiMapping=$true }
                Invoke-ExplorerRemovalPlan @arguments
            }
        }
        [void]$script:Pipeline.AddScript($workerCode.ToString()).AddArgument((Join-Path $PSScriptRoot 'ComputerExplorer.Removal.psm1')).AddArgument($Operation).AddArgument($Names).AddArgument($Sources).AddArgument($ConfigPath).AddArgument($PlanId).AddArgument($script:Queue).AddArgument($script:RemovalCancellation).AddArgument([bool]$IncludeAdChildren).AddArgument($script:GlpiCredentials).AddArgument([bool]$ConfirmGlpiMapping).AddArgument($ComputerId)
        $script:StartedAt = [datetime]::Now; $script:StageMessage = 'Verifica degli oggetti selezionati...'
        if ($Operation -eq 'Remove') { $script:StageMessage = 'Backup BitLocker, verifica e successiva eliminazione...' }
        elseif ($Operation -eq 'Archive') { $script:StageMessage='Archiviazione BitLocker su GLPI...' }
        elseif ($Operation -eq 'ReadArchive') { $script:StageMessage='Lettura archivio BitLocker da GLPI...' }
        elseif ($Operation -eq 'ReadKeys') { $script:StageMessage='Ricerca chiavi BitLocker: prima Intune, poi AD...' }
        Set-SearchBusy $true
        $script:Invocation = $script:Pipeline.BeginInvoke(); $timer.Start()
    }
    catch {
        if ($null -ne $script:Pipeline -and $null -eq $script:Invocation) { $script:Pipeline.Dispose(); $script:Pipeline = $null }
        if ($null -ne $script:RemovalCancellation) { $script:RemovalCancellation.Dispose(); $script:RemovalCancellation = $null }
        Set-SearchBusy $false
        [void][Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Eliminazione', 'OK', 'Error')
    }
}

function Close-ExplorerGraphLogin {
    if ($null -ne $script:GraphLoginWindow) {
        $script:ClosingGraphLogin=$true
        try { $script:GraphLoginWindow.Close(); $script:GraphLoginWindow.Dispose(); $script:GraphLoginWindow=$null }
        finally { $script:ClosingGraphLogin=$false }
    }
}

function Open-ExplorerGraphBrowser {
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName='https://microsoft.com/devicelogin'; $info.UseShellExecute=$true
    [void][Diagnostics.Process]::Start($info)
}

function Show-ExplorerGraphLogin {
    param($Notice)
    $hasCode=-not [string]::IsNullOrWhiteSpace([string]$Notice.Code)
    if ($null -eq $script:GraphLoginWindow) {
        $dialog=New-Object Windows.Forms.Form; $dialog.Icon=$form.Icon
        $dialog.Text='Accesso Microsoft Graph'; $dialog.ClientSize=New-Object Drawing.Size(620,270)
        $dialog.StartPosition='CenterParent'; $dialog.FormBorderStyle='FixedDialog'; $dialog.MaximizeBox=$false; $dialog.MinimizeBox=$false
        $intro=New-Object Windows.Forms.Label; $intro.Name='GraphIntro'; $intro.SetBounds(18,15,580,60)
        $codeBox=New-Object Windows.Forms.TextBox; $codeBox.Name='GraphCode'; $codeBox.ReadOnly=$true; $codeBox.SetBounds(18,80,350,35)
        $codeBox.Font=New-Object Drawing.Font('Consolas',16)
        $copy=New-Object Windows.Forms.Button; $copy.Name='GraphCopy'; $copy.Text='Copia codice'; $copy.SetBounds(385,80,210,35)
        $copy.Tag=$codeBox
        $copy.Add_Click({ param($sender,$eventArgs); try { if ($sender.Tag.Text) { [Windows.Forms.Clipboard]::SetText($sender.Tag.Text) } } catch { $status.Text='Appunti occupati. Selezionare e copiare il codice.' } })
        $instructions=New-Object Windows.Forms.TextBox; $instructions.Name='GraphInstructions'; $instructions.Multiline=$true; $instructions.ReadOnly=$true
        $instructions.SetBounds(18,125,580,80)
        $open=New-Object Windows.Forms.Button; $open.Name='GraphOpen'; $open.Text='Apri browser'; $open.SetBounds(18,220,190,32)
        $open.Add_Click({ try { Open-ExplorerGraphBrowser } catch { $status.Text='Aprire https://microsoft.com/devicelogin nel browser.' } })
        $cancel=New-Object Windows.Forms.Button; $cancel.Text='Annulla accesso'; $cancel.SetBounds(405,220,190,32)
        $cancel.Add_Click({ Stop-ExplorerSearch; Close-ExplorerGraphLogin })
        $dialog.Controls.AddRange(@($intro,$codeBox,$copy,$instructions,$open,$cancel))
        $dialog.Add_FormClosing({ if (-not $script:ClosingGraphLogin) { Stop-ExplorerSearch } })
        $script:GraphLoginWindow=$dialog
        $dialog.Show($form); $dialog.BringToFront(); [void]$dialog.Activate()
    }
    $dialog=$script:GraphLoginWindow
    $previousCode=$dialog.Controls['GraphCode'].Text
    $dialog.Controls['GraphCode'].Text=[string]$Notice.Code
    $dialog.Controls['GraphCopy'].Enabled=$hasCode; $dialog.Controls['GraphOpen'].Enabled=$hasCode
    $dialog.Controls['GraphInstructions'].Text=[string]$Notice.Message
    if ($hasCode) {
        $dialog.Controls['GraphIntro'].Text='Completa l''accesso nella pagina Microsoft aperta nel browser. Inserisci questo codice quando richiesto:'
        if ($previousCode -ne [string]$Notice.Code) {
            try { Open-ExplorerGraphBrowser } catch { $dialog.Controls['GraphInstructions'].AppendText([Environment]::NewLine+'Aprire manualmente https://microsoft.com/devicelogin.') }
        }
        $script:StageMessage='Completa l''accesso Microsoft Graph nel browser.'
    }
    else {
        $dialog.Controls['GraphIntro'].Text='Completa l''accesso nella finestra Microsoft in apertura. Se viene richiesto un codice dispositivo, comparira qui. Puoi annullare l''operazione.'
        $script:StageMessage=[string]$Notice.Message
    }
}

function Show-SelectedComputer {
    if ($grid.SelectedRows.Count -eq 0 -or $null -eq $grid.SelectedRows[0].Tag) { $details.Clear(); return }
    $computer = $grid.SelectedRows[0].Tag
    $lines = New-Object 'System.Collections.Generic.List[string]'
    [void]$lines.Add($computer.Name)
    [void]$lines.Add('Consultazione per nome completo. Verificare ID e seriali prima di operazioni sul dispositivo.')
    if ($computer.Note.Length -gt 0) { [void]$lines.Add('ATTENZIONE: ' + $computer.Note) }
    [void]$lines.Add(''); [void]$lines.Add('ACTIVE DIRECTORY')
    $adSource = @($script:Latest.Sources | Where-Object { $_.Name -eq 'AD' })[0]
    [void]$lines.Add('DC verificati: ' + $computer.Verificati)
    if ($adSource.DcSources.Count -eq 0) { [void]$lines.Add($adSource.State + ' ' + $adSource.Error) }
    foreach ($dc in $adSource.DcSources) {
        $found = @($computer.ADRecords | Where-Object { $_.DomainController -eq $dc.DomainController })
        if (-not $dc.Verificato) { [void]$lines.Add($dc.DomainController + ' | Non verificabile | ' + $dc.Errore) }
        elseif ($found.Count -eq 0) { [void]$lines.Add($dc.DomainController + ' | Assente per questo nome') }
        foreach ($record in $found) {
            [void]$lines.Add($dc.DomainController + ' | Presente | GUID: ' + $record.ObjectGUID + ' | Abilitato: ' + $record.Enabled)
            [void]$lines.Add('  Percorso: ' + $record.ParentPath)
            [void]$lines.Add('  DN: ' + $record.DistinguishedName)
            [void]$lines.Add('  DNS: ' + $record.DNSHostName + ' | sAMAccountName: ' + $record.SamAccountName)
            [void]$lines.Add('  Ultima modifica: ' + (Format-ExplorerDate $record.LastModified))
        }
    }
    foreach ($section in @(
        @{ Name = 'Entra'; Title = 'ENTRA ID'; Records = $computer.EntraRecords },
        @{ Name = 'Intune'; Title = 'INTUNE (WINDOWS)'; Records = $computer.IntuneRecords },
        @{ Name = 'GLPI'; Title = 'GLPI'; Records = $computer.GlpiRecords }
    )) {
        [void]$lines.Add(''); [void]$lines.Add($section.Title)
        $source = @($script:Latest.Sources | Where-Object { $_.Name -eq $section.Name })[0]
        if ($source.State -ne 'OK') { [void]$lines.Add($source.State + ' ' + $source.Error) }
        elseif ($section.Records.Count -eq 0) { [void]$lines.Add('Nessuna registrazione dello stesso nome nei risultati della ricerca.') }
        foreach ($record in $section.Records) {
            switch ($section.Name) {
                'Entra' { [void]$lines.Add('Ultima attività (approssimativa): ' + (Format-ExplorerDate $record.LastSignIn)) }
                'Intune' { [void]$lines.Add('Ultimo check-in: ' + (Format-ExplorerDate $record.LastSync)) }
                'GLPI' { [void]$lines.Add('Ultimo inventario: ' + (Format-ExplorerDate $record.LastInventory)) }
            }
            [void]$lines.Add(($record | Format-List | Out-String -Width 240).Trim())
            [void]$lines.Add('')
        }
    }
    $details.Text = $lines -join [Environment]::NewLine
}

function Update-ExplorerSourceStatus {
    param([object[]]$Sources)
    foreach ($source in $Sources) {
        if (-not $sourceStatusLabels.Contains($source.Name)) { continue }
        $label=$sourceStatusLabels[$source.Name]
        $name=$source.Name; if ($name -eq 'Entra') { $name='Entra ID' }
        $text='Pronta'; $foreground=[Drawing.Color]::DimGray; $background=[Drawing.Color]::WhiteSmoke
        switch ($source.State) {
            'OK' { $text='Terminata'; $foreground=[Drawing.Color]::DarkGreen; $background=[Drawing.Color]::Honeydew }
            'Errore' { $text='Terminata con errori'; $foreground=[Drawing.Color]::Firebrick; $background=[Drawing.Color]::MistyRose }
            'Esclusa' { $text='Esclusa' }
            'In attesa' {
                $text='In corso'
                $foreground=[Drawing.Color]::DarkGoldenrod; $background=[Drawing.Color]::LightGoldenrodYellow
                if ($source.Name -ne 'AD' -and (Get-UiSetting $source 'Progress' '') -eq 'Accesso Graph') { $text='Accesso Graph' }
            }
            'Interrotta' { $text='Interrotta'; $foreground=[Drawing.Color]::DarkOrange; $background=[Drawing.Color]::OldLace }
        }
        $progress=[string](Get-UiSetting $source 'Progress' '')
        if ($source.Name -eq 'AD' -and $progress) { $text+=' ('+$progress+')' }
        if ($source.Name -in @('Entra','Intune') -and $source.State -eq 'In attesa' -and $progress -and $progress -ne 'Accesso Graph') { $text=$progress }
        $label.Text=$name+': '+$text; $label.ForeColor=$foreground; $label.BackColor=$background
        $information=$label.Text
        $target=[string](Get-UiSetting $source 'CurrentTarget' '')
        if ($target) { $information+=' | DC: '+$target }
        $errorText=[string](Get-UiSetting $source 'Error' '')
        if ($errorText) { $information+=' | '+$errorText }
        $sourceToolTip.SetToolTip($label,$information)
    }
}

function Show-ExplorerSnapshot {
    param($Snapshot)
    $script:CopyCell=$null
    $selectedNames = @($grid.SelectedRows | Where-Object { $null -ne $_.Tag } | ForEach-Object { $_.Tag.Name })
    $script:RenderingGrid = $true
    $script:Latest = $Snapshot
    $grid.SuspendLayout()
    try {
        $grid.Rows.Clear()
        foreach ($computer in $Snapshot.Rows) {
            $index = $grid.Rows.Add([object[]]@($computer.Name, $computer.AD, $computer.ADLastModified,
                $computer.Entra, $computer.EntraLastActivity, $computer.Intune, $computer.IntuneLastCheckIn,
                $computer.GLPI, $computer.GlpiLastInventory, $computer.StatoGLPI, (Get-UiSetting $computer 'Censito' ''),
                (Get-UiSetting $computer 'IntuneSerial' ''), (Get-UiSetting $computer 'GlpiSerial' ''),
                (Get-UiSetting $computer 'SerialCheck' 'Non verificabile'), $computer.PercorsoAD, $computer.Note))
            $row = $grid.Rows[$index]; $row.Tag = $computer
            $row.Cells['Censito'].ToolTipText=[string](Get-UiSetting $computer 'CensitoInfo' '')
            if ((Get-UiSetting $computer 'Censito' '') -eq '✓') {
                $row.Cells['Censito'].Style.ForeColor=[Drawing.Color]::DarkGreen
                $row.Cells['Censito'].Style.SelectionForeColor=[Drawing.Color]::DarkGreen
            }
            Set-CellPresence $row.Cells['SerialCheck'] (Get-UiSetting $computer 'SerialColor' 'Grigio')
            $row.Cells['SerialCheck'].ToolTipText='Confronto dei seriali Intune/GLPI dello stesso nome. AD ed Entra non forniscono qui un seriale hardware. Coerente non certifica identita AD/Entra.' 
            foreach ($name in @('AD', 'Entra', 'Intune', 'GLPI')) {
                $color = $computer.PSObject.Properties[$name + 'Color'].Value
                Set-CellPresence $row.Cells[$name] $color
                $source = @($Snapshot.Sources | Where-Object { $_.Name -eq $name })[0]
                $row.Cells[$name].ToolTipText = $source.State + ' ' + $source.Error
                if ($name -eq 'AD') { $row.Cells[$name].ToolTipText += ' | DC verificati: ' + $computer.Verificati }
            }
        }
        $grid.ClearSelection()
        foreach ($row in $grid.Rows) { if ($selectedNames -contains $row.Tag.Name) { $row.Selected = $true } }
    }
    finally { $grid.ResumeLayout(); $script:RenderingGrid = $false }
    foreach ($name in @('AD', 'ADLastModified', 'Entra', 'EntraLastActivity', 'Intune', 'IntuneLastCheckIn', 'GLPI', 'GlpiLastInventory')) {
        $column = $grid.Columns[$name]
        $column.Width = $column.GetPreferredWidth([Windows.Forms.DataGridViewAutoSizeColumnMode]::AllCells, $true)
    }
    Update-ExplorerCounters
    $sourceGrid.Rows.Clear()
    foreach ($source in $Snapshot.Sources) {
        $date = ''
        if ($null -ne $source.CheckedAtUtc) { $date = ([datetimeoffset]$source.CheckedAtUtc).ToLocalTime().ToString('dd/MM/yyyy HH:mm:ss') }
        $cache = ''
        if ($source.FromCache) { $cache = 'Sì' }
        $count = '?'
        if ($source.State -eq 'OK' -or $source.Name -eq 'AD') { $count = [string]$source.Count }
        [void]$sourceGrid.Rows.Add([object[]]@($source.Name, $source.State, $count, $date, $cache, $source.Error))
    }
    Update-ExplorerSourceStatus -Sources $Snapshot.Sources
    Show-SelectedComputer
    $script:StageMessage = $Snapshot.Message
    $status.Text = '{0} | {1} nomi' -f $Snapshot.Message, $Snapshot.Rows.Count
}

$form = New-Object Windows.Forms.Form
$applicationIcon = New-Object Drawing.Icon((Join-Path $PSScriptRoot 'assets/AssistenteIT.ico'))
$form.Icon = $applicationIcon
$form.Text = 'Computer Explorer - AD / Entra ID / Intune / GLPI'
$form.Size = New-Object Drawing.Size(1440, 850)
$form.MinimumSize = New-Object Drawing.Size(1000, 640)
$form.StartPosition = 'CenterScreen'; $form.Font = New-Object Drawing.Font('Segoe UI', 9)
$layout = New-Object Windows.Forms.TableLayoutPanel
$layout.Dock = 'Fill'; $layout.ColumnCount = 1; $layout.RowCount = 4
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 48)))
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 40)))
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 68)))
$layout.Padding = New-Object Windows.Forms.Padding(8)
$toolbar = New-Object Windows.Forms.FlowLayoutPanel; $toolbar.Dock = 'Fill'; $toolbar.WrapContents = $false
$nameLabel = New-Object Windows.Forms.Label; $nameLabel.Text = 'Parte del nome:'; $nameLabel.AutoSize = $true; $nameLabel.Margin = New-Object Windows.Forms.Padding(4, 9, 4, 0)
$nameBox = New-Object Windows.Forms.TextBox; $nameBox.Width = 250
$searchButton = New-Object Windows.Forms.Button; $searchButton.Text = 'Cerca'; $searchButton.Width = 85
$cancelButton = New-Object Windows.Forms.Button; $cancelButton.Text = 'Interrompi'; $cancelButton.Width = 95; $cancelButton.Enabled = $false
$forceRefresh = New-Object Windows.Forms.CheckBox; $forceRefresh.Text = 'Rileggi cloud'; $forceRefresh.AutoSize = $true; $forceRefresh.Margin = New-Object Windows.Forms.Padding(15, 6, 4, 0)
$tokensButton = New-Object Windows.Forms.Button; $tokensButton.Text = 'Token GLPI'; $tokensButton.Width = 100
$findKeysButton=New-Object Windows.Forms.Button;$findKeysButton.Text='Cerca chiavi';$findKeysButton.Width=110;$findKeysButton.Enabled=$false
$toolbar.Controls.AddRange(@($nameLabel, $nameBox, $searchButton, $cancelButton, $forceRefresh, $tokensButton,$findKeysButton))
$options = New-Object Windows.Forms.FlowLayoutPanel; $options.Dock = 'Fill'; $options.WrapContents = $false
$sourceChecks = [ordered]@{}
$glpiSettings = Get-UiSetting $config.Settings 'Glpi' $null
foreach ($name in @('AD', 'Entra', 'Intune', 'GLPI')) {
    $check = New-Object Windows.Forms.CheckBox; $check.Text = $name; $check.AutoSize = $true; $check.Checked = $true
    if ($name -eq 'GLPI') { $check.Checked = [bool](Get-UiSetting $glpiSettings 'Enabled' $false) }
    $sourceChecks[$name] = $check; $options.Controls.Add($check)
}
$counterLabel = New-Object Windows.Forms.Label; $counterLabel.AutoSize = $true
$counterLabel.Text = 'Risultati: 0 | Selezionati: 0'; $counterLabel.Margin = New-Object Windows.Forms.Padding(20, 5, 12, 0)
$options.Controls.Add($counterLabel)
$deleteButton = New-Object Windows.Forms.Button; $deleteButton.Text = 'Elimina...'; $deleteButton.Width = 100; $deleteButton.Enabled = $false
$archiveButton=New-Object Windows.Forms.Button; $archiveButton.Text='Archivia BitLocker'; $archiveButton.Width=135; $archiveButton.Enabled=$false
$readArchiveButton=New-Object Windows.Forms.Button; $readArchiveButton.Text='Leggi archivio'; $readArchiveButton.Width=115; $readArchiveButton.Enabled=$false
$options.Controls.AddRange(@($deleteButton,$archiveButton,$readArchiveButton))
$splitter = New-Object Windows.Forms.SplitContainer
$splitter.Dock = 'Fill'; $splitter.Orientation = 'Horizontal'
$splitter.Size = New-Object Drawing.Size(1300, 650); $splitter.SplitterDistance = 390
$grid = New-Object Windows.Forms.DataGridView
$grid.Dock = 'Fill'; $grid.ReadOnly = $true; $grid.AllowUserToAddRows = $false; $grid.AllowUserToDeleteRows = $false
$grid.AllowUserToResizeRows = $false
$grid.ClipboardCopyMode = 'EnableAlwaysIncludeHeaderText'
$grid.SelectionMode = 'FullRowSelect'; $grid.MultiSelect = $true; $grid.RowHeadersVisible = $false
$grid.ColumnHeadersDefaultCellStyle.WrapMode = 'False'
$grid.AutoSizeRowsMode = 'None'; $grid.BackgroundColor = [Drawing.Color]::White
foreach ($column in @(
    @('Name', 'Nome computer', 180), @('AD', 'AD', 50), @('ADLastModified', 'Modifica AD', 135),
    @('Entra', 'Entra ID', 60), @('EntraLastActivity', 'Attività Entra', 135),
    @('Intune', 'Intune', 55), @('IntuneLastCheckIn', 'Check-in Intune', 135),
    @('GLPI', 'GLPI', 50), @('GlpiLastInventory', 'Inventario GLPI', 135), @('StatoGLPI', 'Stato GLPI', 185),
    @('Censito', 'Censito', 65), @('IntuneSerial', 'Seriale Intune', 140), @('GlpiSerial', 'Seriale GLPI', 140),
    @('SerialCheck', 'Verifica seriale', 120), @('PercorsoAD', 'Percorso AD', 290), @('Note', 'Segnalazioni', 290)
)) {
    $control = New-Object Windows.Forms.DataGridViewTextBoxColumn
    $control.Name = $column[0]; $control.HeaderText = $column[1]; $control.Width = [int]$column[2]
    $control.SortMode = 'Automatic'
    if ($column[0] -in @('ADLastModified', 'EntraLastActivity', 'IntuneLastCheckIn', 'GlpiLastInventory')) {
        $control.ValueType = [datetime]
        $control.DefaultCellStyle.Format = 'dd/MM/yyyy HH:mm'
        $control.DefaultCellStyle.NullValue = '—'
        $control.ToolTipText = 'Data più recente tra le registrazioni di questo nome. Le singole date sono nel dettaglio.'
    }
    [void]$grid.Columns.Add($control)
}
# Right-click copies a cell without changing the multiple-row selection used by deletion.
$gridCopyMenu=New-Object Windows.Forms.ContextMenuStrip
$copyCellItem=$gridCopyMenu.Items.Add('Copia cella')
$copyRowsItem=$gridCopyMenu.Items.Add('Copia righe selezionate (Ctrl+C)')
$script:CopyCell=$null
$grid.ContextMenuStrip=$gridCopyMenu
$grid.Add_CellMouseDown({
    param($sender,$eventArgs)
    if ($eventArgs.Button -eq [Windows.Forms.MouseButtons]::Right) {
        $script:CopyCell=$null
        if ($eventArgs.RowIndex -ge 0 -and $eventArgs.ColumnIndex -ge 0) { $script:CopyCell=$grid.Rows[$eventArgs.RowIndex].Cells[$eventArgs.ColumnIndex] }
        $copyCellItem.Enabled=$null -ne $script:CopyCell
        $copyRowsItem.Enabled=$grid.SelectedRows.Count -gt 0
    }
})
$copyCellItem.Add_Click({
    if ($null -ne $script:CopyCell) {
        $value=[string]$script:CopyCell.FormattedValue
        if ($value.Length -gt 0) {
            try { [Windows.Forms.Clipboard]::SetText($value) }
            catch { $status.Text="Appunti occupati: riprovare la copia." }
        }
    }
})
$copyRowsItem.Add_Click({
    $content=$grid.GetClipboardContent()
    if ($null -ne $content) {
        try { [Windows.Forms.Clipboard]::SetDataObject($content,$true) }
        catch { $status.Text="Appunti occupati: riprovare la copia." }
    }
})
$grid.Columns['ADLastModified'].ToolTipText += ' Modifica oggetto AD sui DC letti.'
$grid.Columns['EntraLastActivity'].ToolTipText += ' Attività approssimativa comunicata da Entra.'
$grid.Columns['GlpiLastInventory'].ToolTipText += ' Data inventario GLPI; non è la modifica della scheda. Orario del server GLPI.'
$tabs = New-Object Windows.Forms.TabControl; $tabs.Dock = 'Fill'
$detailTab = New-Object Windows.Forms.TabPage; $detailTab.Text = 'Dettaglio del computer'
$sourceTab = New-Object Windows.Forms.TabPage; $sourceTab.Text = 'Stato fonti e orari'
$removalTab = New-Object Windows.Forms.TabPage; $removalTab.Text = 'Esiti eliminazione'
$removalGrid = New-Object Windows.Forms.DataGridView
$removalGrid.Dock = 'Fill'; $removalGrid.ReadOnly = $true; $removalGrid.AllowUserToAddRows = $false
$removalGrid.AllowUserToDeleteRows = $false; $removalGrid.RowHeadersVisible = $false; $removalGrid.BackgroundColor = [Drawing.Color]::White
foreach ($column in @(@('Computer', 190), @('Origine', 75), @('Destinazione / DC', 180), @('Esito', 100), @('Identificativo', 280), @('Errore', 500))) {
    $index = $removalGrid.Columns.Add($column[0], $column[0]); $removalGrid.Columns[$index].Width = [int]$column[1]
}
$removalTab.Controls.Add($removalGrid)
$details = New-Object Windows.Forms.RichTextBox; $details.Dock = 'Fill'; $details.ReadOnly = $true
$details.WordWrap = $false; $details.Font = New-Object Drawing.Font('Consolas', 9)
$sourceGrid = New-Object Windows.Forms.DataGridView
$sourceGrid.Dock = 'Fill'; $sourceGrid.ReadOnly = $true; $sourceGrid.AllowUserToAddRows = $false
$sourceGrid.AllowUserToDeleteRows = $false; $sourceGrid.RowHeadersVisible = $false; $sourceGrid.BackgroundColor = [Drawing.Color]::White
foreach ($column in @(@('Fonte', 90), @('Esito', 100), @('Record', 75), @('Aggiornamento', 170), @('Cache', 65), @('Errore / informazioni', 740))) {
    $index = $sourceGrid.Columns.Add($column[0], $column[0]); $sourceGrid.Columns[$index].Width = [int]$column[1]
}
$detailTab.Controls.Add($details); $sourceTab.Controls.Add($sourceGrid); $tabs.TabPages.AddRange(@($detailTab, $sourceTab, $removalTab))
$splitter.Panel1.Controls.Add($grid); $splitter.Panel2.Controls.Add($tabs)
$footer = New-Object Windows.Forms.TableLayoutPanel; $footer.Dock='Fill'; $footer.ColumnCount=4; $footer.RowCount=2
[void]$footer.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 34)))
[void]$footer.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
$sourceStatusLabels=[ordered]@{}
$sourceToolTip=New-Object Windows.Forms.ToolTip
$columnIndex=0
foreach ($name in @('AD','Entra','Intune','GLPI')) {
    [void]$footer.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 25)))
    $label=New-Object Windows.Forms.Label; $label.Dock='Fill'; $label.AutoEllipsis=$true
    $label.TextAlign='MiddleLeft'; $label.Margin=New-Object Windows.Forms.Padding(3)
    $sourceStatusLabels[$name]=$label; $footer.Controls.Add($label,$columnIndex,0); $columnIndex++
}
Update-ExplorerSourceStatus -Sources @(foreach ($name in $sourceChecks.Keys) {
    $state='Esclusa'; if ($sourceChecks[$name].Checked) { $state='Pronta' }
    [pscustomobject]@{Name=$name;State=$state}
})
$status = New-Object Windows.Forms.Label; $status.Dock = 'Fill'; $status.AutoEllipsis = $true
$status.Text = 'Inserire almeno ' + $config.MinimumCharacters + ' caratteri. Ctrl+clic o Maiusc+clic per selezionare più computer.'
$layout.Controls.Add($toolbar, 0, 0); $layout.Controls.Add($options, 0, 1)
$footer.Controls.Add($status,0,1); $footer.SetColumnSpan($status,4)
$layout.Controls.Add($splitter, 0, 2); $layout.Controls.Add($footer, 0, 3); $form.Controls.Add($layout)
$form.AcceptButton = $searchButton

# Register the visible GUI on its own thread. The SDK follows the hidden
# console's owner chain to this window when it opens the Microsoft broker.
if (-not ('AssistenteIT.GraphLoginBridge' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'Graph.LoginBridge.cs') -ErrorAction Stop }
[AssistenteIT.GraphAuthConsole]::RegisterOwner($form.Handle)

# Un runspace persistente conserva la cache cloud. Nessun controllo WinForms
# viene letto o modificato dal worker: gli aggiornamenti passano nella coda.
$script:Worker = [RunspaceFactory]::CreateRunspace()
$script:Worker.ApartmentState = 'STA'; $script:Worker.ThreadOptions = 'ReuseThread'; $script:Worker.Open()
$script:Pipeline = $null; $script:Invocation = $null; $script:Queue = $null
$script:GraphLoginWindow=$null; $script:ClosingGraphLogin=$false
$script:Latest = $null; $script:GlpiCredentials = $null; $script:CloseRequested = $false
$script:Operation = 'Search'; $script:Busy = $false; $script:RenderingGrid = $false; $script:RemovalNeedsRefresh = $false
$script:RemovalCancellation = $null; $script:LastQuery = ''
$script:Stopping = $false; $script:StageMessage = ''; $script:StartedAt = [datetime]::Now
$timer = New-Object Windows.Forms.Timer; $timer.Interval = 200

function Set-SearchBusy {
    param([bool]$Busy)
    $script:Busy = $Busy
    Update-ExplorerCounters
    $searchButton.Enabled = -not $Busy; $nameBox.Enabled = -not $Busy; $tokensButton.Enabled = -not $Busy
    $forceRefresh.Enabled = -not $Busy; $cancelButton.Enabled = $Busy
    foreach ($check in $sourceChecks.Values) { $check.Enabled = -not $Busy }
}

function Stop-ExplorerSearch {
    if ($null -eq $script:Pipeline -or $script:Stopping) { return }
    $script:Stopping = $true; $cancelButton.Enabled = $false
    if ($script:Operation -in @('Remove','Archive')) {
        $script:RemovalCancellation.Cancel()
        $script:StageMessage = 'Interruzione richiesta: termino il computer corrente...'
    }
    else {
        $script:StageMessage = 'Interruzione della verifica...'
        [void]$script:Pipeline.BeginStop($null, $null)
    }
}

$searchButton.Add_Click({
    try {
        # Rilegge il JSON locale anche dopo una modifica a finestra aperta.
        $config = Read-ExplorerConfiguration $ConfigPath
        if ($nameBox.Text.Trim().Length -lt $config.MinimumCharacters) { throw "Inserire almeno $($config.MinimumCharacters) caratteri." }
        $enabled = @($sourceChecks.Keys | Where-Object { $sourceChecks[$_].Checked })
        if ($enabled.Count -eq 0) { throw 'Selezionare almeno una fonte.' }
        $glpiSettings = Get-UiSetting $config.Settings 'Glpi' $null
        if ($enabled -contains 'GLPI' -and [bool](Get-UiSetting $glpiSettings 'Enabled' $false) -and $null -eq $script:GlpiCredentials) {
            $useAppToken = [bool](Get-UiSetting $glpiSettings 'UseAppToken' $true)
            $script:GlpiCredentials = Read-ExplorerGlpiCredentials -Path $EnvPath -UseAppToken $useAppToken
            if ($null -eq $script:GlpiCredentials) { $script:GlpiCredentials = Read-GlpiCredentials $useAppToken }
            if ($null -eq $script:GlpiCredentials) { return }
        }
        $script:Operation = 'Search'; $script:LastQuery = $nameBox.Text.Trim()
        $script:Latest = $null; $grid.Rows.Clear(); $sourceGrid.Rows.Clear(); $details.Clear(); Update-ExplorerCounters
        $script:Queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $script:Pipeline = [PowerShell]::Create(); $script:Pipeline.Runspace = $script:Worker
        $workerScript = {
            param($ModulePath, $Fragment, $ConfigFile, $Sources, $Credentials, $Refresh, $Queue)
            $ErrorActionPreference = 'Stop'
            Import-Module $ModulePath -ErrorAction Stop
            $arguments = @{ NameFragment = $Fragment; ConfigPath = $ConfigFile; EnabledSources = $Sources; ForceCloudRefresh = $Refresh; ProgressQueue = $Queue }
            if ($null -ne $Credentials) { $arguments.GlpiUserToken = $Credentials.User; $arguments.GlpiAppToken = $Credentials.App }
            Invoke-ComputerExplorerParallelSearch @arguments
        }
        [void]$script:Pipeline.AddScript($workerScript.ToString()).AddArgument((Join-Path $PSScriptRoot 'ComputerExplorer.Parallel.psm1')).AddArgument($nameBox.Text.Trim()).AddArgument($ConfigPath).AddArgument($enabled).AddArgument($script:GlpiCredentials).AddArgument($forceRefresh.Checked).AddArgument($script:Queue)
        $script:Stopping = $false; $script:StartedAt = [datetime]::Now; $script:StageMessage = 'Avvio della ricerca...'
        Update-ExplorerSourceStatus -Sources @(foreach ($name in $sourceChecks.Keys) {
            $state='Esclusa'; if ($enabled -contains $name) { $state='In attesa' }
            [pscustomobject]@{Name=$name;State=$state}
        })
        Set-SearchBusy $true
        $script:Invocation = $script:Pipeline.BeginInvoke(); $timer.Start()
    }
    catch {
        if ($null -ne $script:Pipeline -and $null -eq $script:Invocation) { $script:Pipeline.Dispose(); $script:Pipeline = $null }
        Set-SearchBusy $false
        [void][Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Computer Explorer', 'OK', 'Error')
    }
})
$nameBox.Add_TextChanged({ if ($null -ne $script:Latest -or -not $script:Busy) { Update-ExplorerCounters } })
$findKeysButton.Add_Click({
    try {
        if ($script:Busy) { return }
        $selected=@($grid.SelectedRows | Where-Object { $null -ne $_.Tag })
        if ($selected.Count -gt 1) { throw 'Selezionare un solo dispositivo per cercare le chiavi.' }
        $exactName=$nameBox.Text.Trim()
        if ($selected.Count -eq 1) { $exactName=[string]$selected[0].Tag.Name }
        if ($exactName.Length -lt $config.MinimumCharacters) { throw 'Inserire il nome esatto del computer oppure selezionare una riga.' }
        Start-RemovalOperation -Operation ReadKeys -Names @($exactName)
    }
    catch { [void][Windows.Forms.MessageBox]::Show($form,$_.Exception.Message,'Ricerca chiavi BitLocker','OK','Error') }
})
$tokensButton.Add_Click({
    try {
        $credentials = Read-GlpiCredentials ([bool](Get-UiSetting (Get-UiSetting (Read-ExplorerConfiguration $ConfigPath).Settings 'Glpi' $null) 'UseAppToken' $true))
        if ($null -ne $credentials) {
            if ($null -ne $script:GlpiCredentials) {
                $script:GlpiCredentials.User.Dispose()
                if ($null -ne $script:GlpiCredentials.App) { $script:GlpiCredentials.App.Dispose() }
            }
            $script:GlpiCredentials = $credentials; $status.Text = 'Token GLPI aggiornati e salvati cifrati per questo account Windows.'
        }
    }
    catch { [void][Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'GLPI', 'OK', 'Error') }
})
$deleteButton.Add_Click({
    try {
        $names = @($grid.SelectedRows | Where-Object { $null -ne $_.Tag } | ForEach-Object { $_.Tag.Name } | Sort-Object -Unique)
        if ($names.Count -eq 0 -or $script:Busy -or $script:RemovalNeedsRefresh) { return }
        Update-ExplorerCounters
        if (-not $deleteButton.Enabled) { return }
        $sources = Show-RemovalSources $names
        if ($null -eq $sources -or -not (Initialize-ArchiveUiCredentials)) { return }
        Start-RemovalOperation -Operation 'PrepareRemoval' -Names $names -Sources $sources
    }
    catch { [void][Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Elimina', 'OK', 'Error') }
})

$archiveButton.Add_Click({
    try {
        if ($script:Busy -or -not $archiveButton.Enabled) { return }
        $names=@($grid.SelectedRows | Where-Object { $null -ne $_.Tag } | ForEach-Object { $_.Tag.Name } | Sort-Object -Unique)
        $sources=Show-RemovalSources -Names $names -ArchiveOnly
        if ($null -eq $sources -or -not (Initialize-ArchiveUiCredentials)) { return }
        Start-RemovalOperation -Operation PrepareArchive -Names $names -Sources $sources
    }
    catch { [void][Windows.Forms.MessageBox]::Show($form,$_.Exception.Message,'Archivio BitLocker','OK','Error') }
})
$readArchiveButton.Add_Click({
    try {
        if ($script:Busy -or $grid.SelectedRows.Count -ne 1) { return }
        $records=@($grid.SelectedRows[0].Tag.GlpiRecords | Where-Object { [string]$_.IsDeleted -notin @('1','true') })
        if ($records.Count -ne 1) { throw 'Selezionare un computer con una sola scheda GLPI attiva.' }
        if (-not (Initialize-ArchiveUiCredentials)) { return }
        Start-RemovalOperation -Operation ReadArchive -ComputerId ([int]$records[0].GlpiId)
    }
    catch { [void][Windows.Forms.MessageBox]::Show($form,$_.Exception.Message,'Archivio BitLocker','OK','Error') }
})

$cancelButton.Add_Click({ Stop-ExplorerSearch })
$grid.Add_SelectionChanged({ if (-not $script:RenderingGrid) { Update-ExplorerCounters; if ($null -ne $script:Latest) { Show-SelectedComputer } } })
$timer.Add_Tick({
    try {
        $update = $null; $latestSearchUpdate = $null
        while ($script:Queue.TryDequeue([ref]$update)) {
            $kindProperty=$update.PSObject.Properties['Kind']
            if ($null -ne $kindProperty -and $kindProperty.Value -in @('GraphLoginStarting','GraphLogin')) { Show-ExplorerGraphLogin $update; continue }
            if ($null -ne $kindProperty -and $kindProperty.Value -eq 'GraphLoginComplete') {
                Close-ExplorerGraphLogin
                $errorProperty=$update.PSObject.Properties['Error']
                if ($null -ne $errorProperty -and $errorProperty.Value -and -not $script:Stopping) {
                    [void][Windows.Forms.MessageBox]::Show($form,[string]$errorProperty.Value,'Accesso Microsoft Graph non riuscito','OK','Error')
                }
                continue
            }
            if ($script:Operation -eq 'Search') { $latestSearchUpdate = $update }
            else {
                $script:StageMessage = $update.Message
                if ($null -ne $update.Result) { Add-RemovalReportRow $update.Result }
            }
        }
        if ($null -ne $latestSearchUpdate) { Show-ExplorerSnapshot $latestSearchUpdate }
        if (-not $script:Invocation.IsCompleted) {
            $status.Text = '{0} | {1}s' -f $script:StageMessage, ([int]([datetime]::Now - $script:StartedAt).TotalSeconds)
            return
        }
        $finishedOperation = $script:Operation
        $output = @(); $failed = $false
        try {
            $output = @($script:Pipeline.EndInvoke($script:Invocation))
            if ($script:Pipeline.Streams.Error.Count -gt 0) { throw $script:Pipeline.Streams.Error[0] }
            if ($finishedOperation -eq 'Search') {
                if ($output.Count -ne 1 -or -not $output[0].Complete) { throw 'La ricerca non ha restituito un risultato finale valido. Ripetere la ricerca.' }
                # Il worker può finire durante il ridisegno di un aggiornamento
                # parziale, dopo lo svuotamento della coda di questo tick.
                # EndInvoke restituisce sempre il risultato finale autorevole.
                Show-ExplorerSnapshot $output[0]
                $script:RemovalNeedsRefresh = $false
            }
            if ($script:Pipeline.Streams.Warning.Count -gt 0) { $status.Text += ' | Avviso: ' + $script:Pipeline.Streams.Warning[0].Message }
        }
        catch {
            $failed = $true; $message = $_.Exception.Message
            if ($script:Stopping) { $message = 'Operazione interrotta. Le verifiche ancora in attesa non sono complete.' }
            if ($null -ne $script:Latest -and $finishedOperation -eq 'Search') {
                $script:Latest.Complete = $false
                foreach ($source in $script:Latest.Sources) {
                    if ($source.State -eq 'In attesa') { $source.State = 'Interrotta'; $source.Error = $message }
                }
                Show-ExplorerSnapshot $script:Latest
            }
            if ($null -eq $script:Latest -and $finishedOperation -eq 'Search') {
                Update-ExplorerSourceStatus -Sources @(foreach ($name in $sourceChecks.Keys) {
                    $state='Esclusa'; if ($sourceChecks[$name].Checked) { $state='Interrotta' }
                    [pscustomobject]@{Name=$name;State=$state;Error=$message}
                })
            }
            $status.Text = $message
            if (-not $script:Stopping) { [void][Windows.Forms.MessageBox]::Show($form, $message, 'Computer Explorer', 'OK', 'Error') }
        }
        finally {
            Close-ExplorerGraphLogin
            $timer.Stop(); $script:Pipeline.Dispose(); $script:Pipeline = $null; $script:Invocation = $null
            if ($null -ne $script:RemovalCancellation) { $script:RemovalCancellation.Dispose(); $script:RemovalCancellation = $null }
            Set-SearchBusy $false
        }
        if ($script:CloseRequested) { $form.Close(); return }
        if (-not $failed -and $finishedOperation -in @('PrepareRemoval','PrepareArchive') -and $output.Count -eq 1) {
            $decision = Show-RemovalPreview $output[0]
            if ($null -ne $decision) {
                $operation='Remove'; if ($finishedOperation -eq 'PrepareArchive') { $operation='Archive' }
                Start-RemovalOperation -Operation $operation -PlanId $output[0].PlanId -IncludeAdChildren:$decision.IncludeAdChildren -ConfirmGlpiMapping:$decision.ConfirmGlpiMapping
            }
        }
        elseif ($finishedOperation -eq 'ReadKeys' -and -not $failed -and $output.Count -eq 1) {
            $status.Text='Ricerca chiavi '+$output[0].Name+': '+$output[0].Records.Count+' chiavi. Esiti Intune/AD nella finestra.'
            Show-ArchivedBitLockerKeys $output[0]
        }
        elseif ($finishedOperation -eq 'ReadArchive' -and -not $failed -and $output.Count -eq 1) {
            $status.Text='Archivio GLPI: '+$output[0].Records.Count+' chiavi.'
            Show-ArchivedBitLockerKeys $output[0]
        }
        elseif ($finishedOperation -in @('Remove','Archive')) {
            $tabs.SelectedTab = $removalTab
            if (-not $failed -and $output.Count -eq 1) {
                $status.Text = 'Eliminazione terminata: {0} oggetti eliminati, {1} errori/blocchi. Esiti nella scheda dedicata.' -f $output[0].Deleted, $output[0].Failed
                if ($finishedOperation -eq 'Archive') { $status.Text='Archiviazione terminata: '+$output[0].Archived+' chiavi verificate, '+$output[0].Failed+' errori/blocchi. Nessun computer eliminato.' }
                if ($script:Stopping) { $status.Text = 'Eliminazione interrotta dopo il computer corrente. Consultare gli esiti e ripetere la ricerca.' }
            }
            if ($finishedOperation -eq 'Remove' -and -not $failed -and -not $script:Stopping) {
                $nameBox.Text = $script:LastQuery; $forceRefresh.Checked = $true
                $searchButton.PerformClick()
                $tabs.SelectedTab = $removalTab
            }
        }
        Update-ExplorerCounters
    }
    catch { $status.Text = 'Errore nella visualizzazione: ' + $_.Exception.Message; Stop-ExplorerSearch }
})
$form.Add_FormClosing({
    param($sender, $eventArgs)
    if ($null -ne $script:Pipeline) {
        $eventArgs.Cancel = $true; $script:CloseRequested = $true; Stop-ExplorerSearch
    }
})
try { [void]$form.ShowDialog() }
finally {
    Close-ExplorerGraphLogin
    $timer.Dispose()
    if ($null -ne $script:Pipeline) { $script:Pipeline.Stop(); $script:Pipeline.Dispose() }
    $script:Worker.Close(); $script:Worker.Dispose()
    if ($null -ne $script:GlpiCredentials) {
        $script:GlpiCredentials.User.Dispose()
        if ($null -ne $script:GlpiCredentials.App) { $script:GlpiCredentials.App.Dispose() }
    }
    $gridCopyMenu.Dispose()
    $sourceToolTip.Dispose()
    [AssistenteIT.GraphAuthConsole]::ReleaseOwner()
    $form.Dispose()
    $applicationIcon.Dispose()
}
