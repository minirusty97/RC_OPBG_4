#requires -version 5.1
[CmdletBinding()]
param([string]$ConfigPath = (Join-Path $PSScriptRoot 'computer-explorer.config.local.json'))

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
    $dialog.Text = 'Accesso GLPI'; $dialog.Size = New-Object Drawing.Size(490, 240)
    $dialog.StartPosition = 'CenterParent'; $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false; $dialog.MinimizeBox = $false
    $intro = New-Object Windows.Forms.Label
    $intro.Text = 'Token usati per questa finestra. Nessun salvataggio su file.'
    $intro.SetBounds(15, 12, 450, 35)
    $userLabel = New-Object Windows.Forms.Label; $userLabel.Text = 'User token'; $userLabel.SetBounds(15, 55, 95, 25)
    $userBox = New-Object Windows.Forms.TextBox; $userBox.SetBounds(115, 52, 340, 25); $userBox.UseSystemPasswordChar = $true
    $appLabel = New-Object Windows.Forms.Label; $appLabel.Text = 'App token'; $appLabel.SetBounds(15, 95, 95, 25)
    $appBox = New-Object Windows.Forms.TextBox; $appBox.SetBounds(115, 92, 340, 25); $appBox.UseSystemPasswordChar = $true
    $appBox.Enabled = $UseAppToken; $appLabel.Enabled = $UseAppToken
    $ok = New-Object Windows.Forms.Button; $ok.Text = 'Usa token'; $ok.SetBounds(255, 145, 95, 30)
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
        return [pscustomobject]@{ User = $user; App = $app }
    }
    finally { $userBox.Clear(); $appBox.Clear(); $dialog.Dispose() }
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

function Show-SelectedComputer {
    if ($grid.SelectedRows.Count -eq 0 -or $null -eq $grid.SelectedRows[0].Tag) { $details.Clear(); return }
    $computer = $grid.SelectedRows[0].Tag
    $lines = New-Object 'System.Collections.Generic.List[string]'
    [void]$lines.Add($computer.Name)
    [void]$lines.Add('Consultazione per nome completo. Verificare ID e seriali prima di operazioni sul dispositivo.')
    if ($computer.Note.Length -gt 0) { [void]$lines.Add('ATTENZIONE: ' + $computer.Note) }
    [void]$lines.Add(''); [void]$lines.Add('ACTIVE DIRECTORY')
    $adSource = @($script:Latest.Sources | Where-Object { $_.Name -eq 'AD' })[0]
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
            [void]$lines.Add(($record | Format-List | Out-String -Width 240).Trim())
            [void]$lines.Add('')
        }
    }
    $details.Text = $lines -join [Environment]::NewLine
}

function Show-ExplorerSnapshot {
    param($Snapshot)
    $selectedName = $null
    if ($grid.SelectedRows.Count -gt 0 -and $null -ne $grid.SelectedRows[0].Tag) { $selectedName = $grid.SelectedRows[0].Tag.Name }
    $script:Latest = $Snapshot
    $grid.SuspendLayout()
    try {
        $grid.Rows.Clear()
        foreach ($computer in $Snapshot.Rows) {
            $index = $grid.Rows.Add([object[]]@($computer.Name, $computer.AD, $computer.Verificati, $computer.Entra, $computer.Intune,
                $computer.GLPI, $computer.StatoGLPI, $computer.PercorsoAD, $computer.Note))
            $row = $grid.Rows[$index]; $row.Tag = $computer
            foreach ($name in @('AD', 'Entra', 'Intune', 'GLPI')) {
                $color = $computer.PSObject.Properties[$name + 'Color'].Value
                Set-CellPresence $row.Cells[$name] $color
                $source = @($Snapshot.Sources | Where-Object { $_.Name -eq $name })[0]
                $row.Cells[$name].ToolTipText = $source.State + ' ' + $source.Error
            }
        }
        $grid.ClearSelection()
        if ($null -ne $selectedName) {
            foreach ($row in $grid.Rows) { if ($row.Tag.Name -eq $selectedName) { $row.Selected = $true; break } }
        }
        if ($grid.SelectedRows.Count -eq 0 -and $grid.Rows.Count -gt 0) { $grid.Rows[0].Selected = $true }
    }
    finally { $grid.ResumeLayout() }
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
    Show-SelectedComputer
    $script:StageMessage = $Snapshot.Message
    $status.Text = '{0} | {1} nomi' -f $Snapshot.Message, $Snapshot.Rows.Count
}

$form = New-Object Windows.Forms.Form
$form.Text = 'Computer Explorer - AD / Entra ID / Intune / GLPI'
$form.Size = New-Object Drawing.Size(1440, 850)
$form.MinimumSize = New-Object Drawing.Size(1000, 640)
$form.StartPosition = 'CenterScreen'; $form.Font = New-Object Drawing.Font('Segoe UI', 9)
$layout = New-Object Windows.Forms.TableLayoutPanel
$layout.Dock = 'Fill'; $layout.ColumnCount = 1; $layout.RowCount = 4
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 48)))
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 40)))
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 35)))
$layout.Padding = New-Object Windows.Forms.Padding(8)
$toolbar = New-Object Windows.Forms.FlowLayoutPanel; $toolbar.Dock = 'Fill'; $toolbar.WrapContents = $false
$nameLabel = New-Object Windows.Forms.Label; $nameLabel.Text = 'Parte del nome:'; $nameLabel.AutoSize = $true; $nameLabel.Margin = New-Object Windows.Forms.Padding(4, 9, 4, 0)
$nameBox = New-Object Windows.Forms.TextBox; $nameBox.Width = 250
$searchButton = New-Object Windows.Forms.Button; $searchButton.Text = 'Cerca'; $searchButton.Width = 85
$cancelButton = New-Object Windows.Forms.Button; $cancelButton.Text = 'Interrompi'; $cancelButton.Width = 95; $cancelButton.Enabled = $false
$forceRefresh = New-Object Windows.Forms.CheckBox; $forceRefresh.Text = 'Rileggi cloud'; $forceRefresh.AutoSize = $true; $forceRefresh.Margin = New-Object Windows.Forms.Padding(15, 6, 4, 0)
$tokensButton = New-Object Windows.Forms.Button; $tokensButton.Text = 'Token GLPI'; $tokensButton.Width = 100
$toolbar.Controls.AddRange(@($nameLabel, $nameBox, $searchButton, $cancelButton, $forceRefresh, $tokensButton))
$options = New-Object Windows.Forms.FlowLayoutPanel; $options.Dock = 'Fill'; $options.WrapContents = $false
$sourceChecks = [ordered]@{}
$glpiSettings = Get-UiSetting $config.Settings 'Glpi' $null
foreach ($name in @('AD', 'Entra', 'Intune', 'GLPI')) {
    $check = New-Object Windows.Forms.CheckBox; $check.Text = $name; $check.AutoSize = $true; $check.Checked = $true
    if ($name -eq 'GLPI') { $check.Checked = [bool](Get-UiSetting $glpiSettings 'Enabled' $false) }
    $sourceChecks[$name] = $check; $options.Controls.Add($check)
}
$legend = New-Object Windows.Forms.Label; $legend.AutoSize = $true
$legend.Text = 'Verde: presenza regolare   Giallo: parziale / duplicati   Rosso: assente   Grigio / ?: non verificato'
$legend.Margin = New-Object Windows.Forms.Padding(16, 5, 0, 0); $options.Controls.Add($legend)
$splitter = New-Object Windows.Forms.SplitContainer
$splitter.Dock = 'Fill'; $splitter.Orientation = 'Horizontal'
$splitter.Size = New-Object Drawing.Size(1300, 650); $splitter.SplitterDistance = 390
$grid = New-Object Windows.Forms.DataGridView
$grid.Dock = 'Fill'; $grid.ReadOnly = $true; $grid.AllowUserToAddRows = $false; $grid.AllowUserToDeleteRows = $false
$grid.SelectionMode = 'FullRowSelect'; $grid.MultiSelect = $false; $grid.RowHeadersVisible = $false
$grid.AutoSizeRowsMode = 'None'; $grid.BackgroundColor = [Drawing.Color]::White
foreach ($column in @(
    @('Name', 'Nome computer', 190), @('AD', 'AD', 60), @('Verificati', 'DC verificati', 90), @('Entra', 'Entra ID', 70),
    @('Intune', 'Intune', 65), @('GLPI', 'GLPI', 60), @('StatoGLPI', 'Stato GLPI', 195),
    @('PercorsoAD', 'Percorso AD', 310), @('Note', 'Segnalazioni', 290)
)) {
    $control = New-Object Windows.Forms.DataGridViewTextBoxColumn
    $control.Name = $column[0]; $control.HeaderText = $column[1]; $control.Width = [int]$column[2]
    $control.SortMode = 'Automatic'; [void]$grid.Columns.Add($control)
}
$tabs = New-Object Windows.Forms.TabControl; $tabs.Dock = 'Fill'
$detailTab = New-Object Windows.Forms.TabPage; $detailTab.Text = 'Dettaglio del computer'
$sourceTab = New-Object Windows.Forms.TabPage; $sourceTab.Text = 'Stato fonti e orari'
$details = New-Object Windows.Forms.RichTextBox; $details.Dock = 'Fill'; $details.ReadOnly = $true
$details.WordWrap = $false; $details.Font = New-Object Drawing.Font('Consolas', 9)
$sourceGrid = New-Object Windows.Forms.DataGridView
$sourceGrid.Dock = 'Fill'; $sourceGrid.ReadOnly = $true; $sourceGrid.AllowUserToAddRows = $false
$sourceGrid.AllowUserToDeleteRows = $false; $sourceGrid.RowHeadersVisible = $false; $sourceGrid.BackgroundColor = [Drawing.Color]::White
foreach ($column in @(@('Fonte', 90), @('Esito', 100), @('Record', 75), @('Aggiornamento', 170), @('Cache', 65), @('Errore / informazioni', 740))) {
    $index = $sourceGrid.Columns.Add($column[0], $column[0]); $sourceGrid.Columns[$index].Width = [int]$column[1]
}
$detailTab.Controls.Add($details); $sourceTab.Controls.Add($sourceGrid); $tabs.TabPages.AddRange(@($detailTab, $sourceTab))
$splitter.Panel1.Controls.Add($grid); $splitter.Panel2.Controls.Add($tabs)
$status = New-Object Windows.Forms.Label; $status.Dock = 'Fill'; $status.AutoEllipsis = $true
$status.Text = 'Inserire almeno ' + $config.MinimumCharacters + ' caratteri. Ricerca di consultazione.'
$layout.Controls.Add($toolbar, 0, 0); $layout.Controls.Add($options, 0, 1)
$layout.Controls.Add($splitter, 0, 2); $layout.Controls.Add($status, 0, 3); $form.Controls.Add($layout)
$form.AcceptButton = $searchButton

# Un runspace persistente conserva la cache cloud. Nessun controllo WinForms
# viene letto o modificato dal worker: gli aggiornamenti passano nella coda.
$script:Worker = [RunspaceFactory]::CreateRunspace()
$script:Worker.ApartmentState = 'STA'; $script:Worker.ThreadOptions = 'ReuseThread'; $script:Worker.Open()
$script:Pipeline = $null; $script:Invocation = $null; $script:Queue = $null
$script:Latest = $null; $script:GlpiCredentials = $null; $script:CloseRequested = $false
$script:Stopping = $false; $script:StageMessage = ''; $script:StartedAt = [datetime]::Now
$timer = New-Object Windows.Forms.Timer; $timer.Interval = 200

function Set-SearchBusy {
    param([bool]$Busy)
    $searchButton.Enabled = -not $Busy; $nameBox.Enabled = -not $Busy; $tokensButton.Enabled = -not $Busy
    $forceRefresh.Enabled = -not $Busy; $cancelButton.Enabled = $Busy
    foreach ($check in $sourceChecks.Values) { $check.Enabled = -not $Busy }
}

function Stop-ExplorerSearch {
    if ($null -eq $script:Pipeline -or $script:Stopping) { return }
    $script:Stopping = $true; $cancelButton.Enabled = $false
    $script:StageMessage = 'Interruzione della ricerca...'
    [void]$script:Pipeline.BeginStop($null, $null)
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
            $script:GlpiCredentials = Read-GlpiCredentials ([bool](Get-UiSetting $glpiSettings 'UseAppToken' $true))
            if ($null -eq $script:GlpiCredentials) { return }
        }
        $grid.Rows.Clear(); $sourceGrid.Rows.Clear(); $details.Clear(); $script:Latest = $null
        $script:Queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $script:Pipeline = [PowerShell]::Create(); $script:Pipeline.Runspace = $script:Worker
        $workerScript = {
            param($ModulePath, $Fragment, $ConfigFile, $Sources, $Credentials, $Refresh, $Queue)
            $ErrorActionPreference = 'Stop'
            Import-Module $ModulePath -ErrorAction Stop
            $arguments = @{ NameFragment = $Fragment; ConfigPath = $ConfigFile; EnabledSources = $Sources; ForceCloudRefresh = $Refresh; ProgressQueue = $Queue }
            if ($null -ne $Credentials) { $arguments.GlpiUserToken = $Credentials.User; $arguments.GlpiAppToken = $Credentials.App }
            Invoke-ComputerExplorerSearch @arguments
        }
        [void]$script:Pipeline.AddScript($workerScript.ToString()).AddArgument((Join-Path $PSScriptRoot 'ComputerExplorer.Core.psm1')).AddArgument($nameBox.Text.Trim()).AddArgument($ConfigPath).AddArgument($enabled).AddArgument($script:GlpiCredentials).AddArgument($forceRefresh.Checked).AddArgument($script:Queue)
        $script:Stopping = $false; $script:StartedAt = [datetime]::Now; $script:StageMessage = 'Avvio della ricerca...'
        Set-SearchBusy $true
        $script:Invocation = $script:Pipeline.BeginInvoke(); $timer.Start()
    }
    catch {
        if ($null -ne $script:Pipeline -and $null -eq $script:Invocation) { $script:Pipeline.Dispose(); $script:Pipeline = $null }
        Set-SearchBusy $false
        [void][Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Computer Explorer', 'OK', 'Error')
    }
})
$tokensButton.Add_Click({
    try {
        $credentials = Read-GlpiCredentials ([bool](Get-UiSetting (Get-UiSetting (Read-ExplorerConfiguration $ConfigPath).Settings 'Glpi' $null) 'UseAppToken' $true))
        if ($null -ne $credentials) {
            if ($null -ne $script:GlpiCredentials) {
                $script:GlpiCredentials.User.Dispose()
                if ($null -ne $script:GlpiCredentials.App) { $script:GlpiCredentials.App.Dispose() }
            }
            $script:GlpiCredentials = $credentials; $status.Text = 'Token GLPI aggiornati per questa finestra.'
        }
    }
    catch { [void][Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'GLPI', 'OK', 'Error') }
})
$cancelButton.Add_Click({ Stop-ExplorerSearch })
$grid.Add_SelectionChanged({ if ($null -ne $script:Latest) { Show-SelectedComputer } })
$timer.Add_Tick({
    try {
        $update = $null
        while ($script:Queue.TryDequeue([ref]$update)) { Show-ExplorerSnapshot $update }
        if (-not $script:Invocation.IsCompleted) {
            $elapsed = [int]([datetime]::Now - $script:StartedAt).TotalSeconds
            $status.Text = '{0} | {1}s' -f $script:StageMessage, $elapsed
            return
        }
        try {
            $null = $script:Pipeline.EndInvoke($script:Invocation)
            if ($script:Pipeline.Streams.Error.Count -gt 0) { throw $script:Pipeline.Streams.Error[0] }
            if ($script:Pipeline.Streams.Warning.Count -gt 0) { $status.Text += ' | Avviso: ' + $script:Pipeline.Streams.Warning[0].Message }
        }
        catch {
            $message = $_.Exception.Message
            if ($script:Stopping) { $message = 'Ricerca interrotta. Le fonti ancora in attesa non sono state verificate.' }
            if ($null -ne $script:Latest) {
                foreach ($source in $script:Latest.Sources) {
                    if ($source.State -eq 'In attesa') { $source.State = 'Interrotta'; $source.Error = $message }
                }
                Show-ExplorerSnapshot $script:Latest
            }
            $status.Text = $message
            if (-not $script:Stopping) { [void][Windows.Forms.MessageBox]::Show($form, $message, 'Ricerca', 'OK', 'Error') }
        }
        finally {
            $timer.Stop(); $script:Pipeline.Dispose(); $script:Pipeline = $null; $script:Invocation = $null
            Set-SearchBusy $false
        }
        if ($script:CloseRequested) { $form.Close() }
    }
    catch {
        $status.Text = 'Errore nella visualizzazione: ' + $_.Exception.Message
        Stop-ExplorerSearch
    }
})
$form.Add_FormClosing({
    param($sender, $eventArgs)
    if ($null -ne $script:Pipeline) {
        $eventArgs.Cancel = $true; $script:CloseRequested = $true; Stop-ExplorerSearch
    }
})
try { [void]$form.ShowDialog() }
finally {
    $timer.Dispose()
    if ($null -ne $script:Pipeline) { $script:Pipeline.Stop(); $script:Pipeline.Dispose() }
    $script:Worker.Close(); $script:Worker.Dispose()
    if ($null -ne $script:GlpiCredentials) {
        $script:GlpiCredentials.User.Dispose()
        if ($null -ne $script:GlpiCredentials.App) { $script:GlpiCredentials.App.Dispose() }
    }
    $form.Dispose()
}
