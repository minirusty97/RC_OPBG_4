#requires -version 5.1
[CmdletBinding()]
param([string]$DataRoot, [string]$SmokeTestOutput)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Avviare la suite su Windows con powershell.exe -STA.' }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
Import-Module (Join-Path $PSScriptRoot 'AssistenteIT/AssistenteIT.Core.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'AssistenteIT/AssistenteIT.Update.psm1') -ErrorAction Stop
Enable-AssistenteITDependencies $PSScriptRoot
$manifest = Read-AssistenteITManifest $PSScriptRoot
$activity = Open-AssistenteITActivity
$paths = Initialize-AssistenteIT -InstallRoot $PSScriptRoot -DataRoot $DataRoot
Initialize-AssistenteITWindowIdentity -InstallRoot $PSScriptRoot
$prerequisites = Get-AssistenteITPrerequisites

function Show-AssistenteITSettings {
    $settings = Get-Content -LiteralPath $paths.ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $dialog = New-Object Windows.Forms.Form
    $dialog.Icon = $form.Icon
    $dialog.Text = 'Impostazioni - ' + $manifest.Product; $dialog.ClientSize = New-Object Drawing.Size(630, 590)
    $dialog.StartPosition = 'CenterParent'; $dialog.FormBorderStyle='FixedDialog'; $dialog.MaximizeBox=$false; $dialog.MinimizeBox=$false
    $dialog.Font = $form.Font
    $dcLabel = New-Object Windows.Forms.Label; $dcLabel.Text='Domain Controller, uno per riga'; $dcLabel.SetBounds(18, 16, 580, 24)
    $dcBox = New-Object Windows.Forms.TextBox; $dcBox.Multiline=$true; $dcBox.ScrollBars='Vertical'; $dcBox.SetBounds(18, 44, 590, 105)
    $dcBox.Lines = [string[]]@($settings.DomainControllers)
    $glpiCheck = New-Object Windows.Forms.CheckBox; $glpiCheck.Text='Abilita GLPI'; $glpiCheck.Checked=[bool]$settings.Glpi.Enabled; $glpiCheck.SetBounds(18, 163, 180, 25)
    $urlLabel = New-Object Windows.Forms.Label; $urlLabel.Text='URL API GLPI (esempio: https://server/glpi/apirest.php)'; $urlLabel.SetBounds(18, 198, 590, 24)
    $urlBox = New-Object Windows.Forms.TextBox; $urlBox.Text=[string]$settings.Glpi.BaseUri; $urlBox.SetBounds(18, 225, 590, 25)
    $appCheck = New-Object Windows.Forms.CheckBox; $appCheck.Text='Usa App token'; $appCheck.Checked=[bool]$settings.Glpi.UseAppToken; $appCheck.SetBounds(18, 263, 220, 25)
    $userLabel = New-Object Windows.Forms.Label; $userLabel.Text='User token GLPI'; $userLabel.SetBounds(18, 306, 145, 24)
    $userBox = New-Object Windows.Forms.TextBox; $userBox.UseSystemPasswordChar=$true; $userBox.SetBounds(170, 303, 438, 25)
    $appLabel = New-Object Windows.Forms.Label; $appLabel.Text='App token GLPI'; $appLabel.SetBounds(18, 348, 145, 24)
    $appBox = New-Object Windows.Forms.TextBox; $appBox.UseSystemPasswordChar=$true; $appBox.SetBounds(170, 345, 438, 25)
    $hint = New-Object Windows.Forms.Label; $hint.Text='Lascia vuoti i token per conservare quelli salvati. I token sono cifrati da Windows per il tuo account su questo PC.'; $hint.SetBounds(18, 393, 590, 42)
    $graphProperty=$settings.PSObject.Properties['Graph']
    $graphSettings=$null;if ($null -ne $graphProperty) { $graphSettings=$graphProperty.Value }
    # Let old certificate configurations be edited without authenticating as
    # another identity. The operator must explicitly select and save a user mode.
    $removedCertificate=$false
    if ($null -ne $graphSettings) {
        $oldMode=$graphSettings.PSObject.Properties['AuthenticationMode']
        if ($null -ne $oldMode -and $oldMode.Value -eq 'Certificate') {
            $removedCertificate=$true
            $graphSettings=$graphSettings | Select-Object AuthenticationMode,TenantId,ClientId
            $graphSettings.AuthenticationMode='Interactive'
        }
    }
    $graph=ConvertTo-ExplorerGraphAuthentication $graphSettings
    $settingsTabs=New-Object Windows.Forms.TabControl;$settingsTabs.SetBounds(4,10,622,515)
    $generalPage=New-Object Windows.Forms.TabPage;$generalPage.Text='GLPI / AD'
    $graphPage=New-Object Windows.Forms.TabPage;$graphPage.Text='Microsoft Graph'
    $settingsTabs.TabPages.AddRange(@($generalPage,$graphPage))
    $modeLabel=New-Object Windows.Forms.Label;$modeLabel.Text='Autenticazione Microsoft Graph';$modeLabel.SetBounds(18,18,550,24)
    $modeBox=New-Object Windows.Forms.ComboBox;$modeBox.Name='GraphAuthenticationMode';$modeBox.DropDownStyle='DropDownList';$modeBox.SetBounds(18,44,550,25)
    [void]$modeBox.Items.Add('Accesso utente (app Microsoft)');[void]$modeBox.Items.Add('Accesso delegato (app dedicata)')
    $modeBox.SelectedIndex=0;if ($graph.AuthenticationMode -eq 'Delegated') { $modeBox.SelectedIndex=1 }
    $tenantLabel=New-Object Windows.Forms.Label;$tenantLabel.Text='Directory (Tenant) ID';$tenantLabel.SetBounds(18,88,550,24)
    $tenantBox=New-Object Windows.Forms.TextBox;$tenantBox.Name='GraphTenantId';$tenantBox.Text=$graph.TenantId;$tenantBox.SetBounds(18,112,550,25)
    $clientLabel=New-Object Windows.Forms.Label;$clientLabel.Text='Application (Client) ID';$clientLabel.SetBounds(18,150,550,24)
    $clientBox=New-Object Windows.Forms.TextBox;$clientBox.Name='GraphClientId';$clientBox.Text=$graph.ClientId;$clientBox.SetBounds(18,174,550,25)
    $graphHint=New-Object Windows.Forms.Label;$graphHint.Name='GraphAuthenticationHint';$graphHint.SetBounds(18,220,550,100)
    $updateGraphMode={
        $tenantBox.Enabled=$modeBox.SelectedIndex -eq 1;$clientBox.Enabled=$tenantBox.Enabled
        if ($modeBox.SelectedIndex -eq 1) {
            $graphHint.Text='Ogni tecnico accede con il proprio account Microsoft. Inserire Tenant ID e Client ID dell''app dedicata, autorizzata con permessi Delegati. Le operazioni dipendono dai ruoli del tecnico su Entra e Intune.'
        }
        else {
            $graphHint.Text='Accesso utente tramite l''app Microsoft Graph PowerShell e la cache personale Microsoft. Per usare l''app aziendale selezionare Accesso delegato (app dedicata). Tenant ID e Client ID qui non vengono utilizzati.'
        }
        if ($removedCertificate) { $graphHint.Text='La modalita con certificato e stata rimossa. Selezionare e salvare un accesso utente. '+$graphHint.Text }
    }
    $modeBox.Add_SelectedIndexChanged($updateGraphMode);& $updateGraphMode
    $restrictionsHint=New-Object Windows.Forms.Label;$restrictionsHint.Name='GraphRestrictionsHint';$restrictionsHint.Text='Il wrapper verifica accesso e permessi prima di aprire ogni modulo. Con l''app dedicata vengono usati i consensi gia concessi; nessuna funzione richiede nuovi permessi durante l''uso.';$restrictionsHint.SetBounds(18,340,550,70)
    $graphPage.Controls.AddRange(@($modeLabel,$modeBox,$tenantLabel,$tenantBox,$clientLabel,$clientBox,$graphHint,$restrictionsHint))
    Import-Module (Join-Path $PSScriptRoot 'DeviceModules.Core.psm1') -ErrorAction Stop
    $hybridSettings=(Read-DmSettings $paths.ConfigPath HybridJoin -SettingsOnly).Options
    $ringSettings=(Read-DmSettings $paths.ConfigPath RingManager -SettingsOnly).Options
    $hybridPage=New-Object Windows.Forms.TabPage;$hybridPage.Text='Hybrid Join'
    $ringPage=New-Object Windows.Forms.TabPage;$ringPage.Text='Ring Intune'
    $settingsTabs.TabPages.AddRange(@($hybridPage,$ringPage))
    $hybridServerLabel=New-Object Windows.Forms.Label;$hybridServerLabel.Text='Server AD (vuoto: primo DC configurato)';$hybridServerLabel.SetBounds(18,18,560,24)
    $hybridServer=New-Object Windows.Forms.TextBox;$hybridServer.Name='HybridAdServer';$hybridServer.Text=[string]$hybridSettings.AdServer;$hybridServer.SetBounds(18,44,560,25)
    $scopeLabel=New-Object Windows.Forms.Label;$scopeLabel.Text='Profondita ricerca OU';$scopeLabel.SetBounds(18,84,560,24)
    $scopeBox=New-Object Windows.Forms.ComboBox;$scopeBox.Name='HybridSearchScope';$scopeBox.DropDownStyle='DropDownList';$scopeBox.SetBounds(18,110,560,25)
    [void]$scopeBox.Items.AddRange(@('Subtree','OneLevel','Base'));$scopeBox.SelectedItem=[string]$hybridSettings.SearchScope
    $ouLabel=New-Object Windows.Forms.Label;$ouLabel.Text='OU, una per riga (DN relativo al dominio oppure completo)';$ouLabel.SetBounds(18,151,325,24)
    $ouBox=New-Object Windows.Forms.TextBox;$ouBox.Name='HybridTargetOus';$ouBox.Multiline=$true;$ouBox.ScrollBars='Vertical';$ouBox.SetBounds(18,178,560,230);$ouBox.Lines=[string[]]$hybridSettings.TargetOus
    $hybridHint=New-Object Windows.Forms.Label;$hybridHint.Text='La lettura AD usa l''account Windows corrente. Le registrazioni Hybrid sono confrontate anche tramite GUID; la pulizia seleziona solo Workplace.';$hybridHint.SetBounds(18,423,560,52)
    $importOus=New-Object Windows.Forms.Button;$importOus.Name='ImportHybridOus';$importOus.Text='Importa OU dallo script';$importOus.SetBounds(360,145,218,30)
    $importOus.Add_Click({
        $openScript=New-Object Windows.Forms.OpenFileDialog;$openScript.Filter='Script PowerShell (*.ps1)|*.ps1';$openScript.Title='Seleziona lo script Hybrid Join originale'
        try { if ($openScript.ShowDialog($dialog) -eq 'OK') { $imported=Read-DmHybridScriptDefaults -Path $openScript.FileName;$ouBox.Lines=[string[]]$imported.TargetOus;if ($imported.AdServer) { $hybridServer.Text=$imported.AdServer } } }
        catch { [void][Windows.Forms.MessageBox]::Show($dialog,$_.Exception.Message,'Importazione OU','OK','Error') }
        finally { $openScript.Dispose() }
    })
    $hybridPage.Controls.AddRange(@($hybridServerLabel,$hybridServer,$scopeLabel,$scopeBox,$ouLabel,$ouBox,$importOus,$hybridHint))
    . (Join-Path $PSScriptRoot 'AssistenteIT/GroupPicker.UI.ps1')
    $ringSelection=@{Groups=@($ringSettings.Groups)}
    $groupHint=New-Object Windows.Forms.Label;$groupHint.Text='Scegliere i gruppi da controllare e quelli utilizzabili come destinazione. I gruppi scelti vengono salvati per ID. Nessun gruppo e preselezionato; includi solo quelli che vuoi controllare.';$groupHint.SetBounds(18,18,560,65)
    $chooseGroups=New-Object Windows.Forms.Button;$chooseGroups.Name='ChooseRingGroups';$chooseGroups.Text='Seleziona gruppi da Entra';$chooseGroups.SetBounds(18,94,270,34)
    $selectedGroups=New-Object Windows.Forms.TextBox;$selectedGroups.Name='SelectedRingGroups';$selectedGroups.Multiline=$true;$selectedGroups.ReadOnly=$true;$selectedGroups.ScrollBars='Vertical';$selectedGroups.SetBounds(18,145,560,300)
    $showSelectedGroups={ $selectedGroups.Text=(@($ringSelection.Groups | ForEach-Object { $mode='solo controllo';if ($_.CanAssign) { $mode='controllo e destinazione' };$_.Label+' | '+$_.Name+' | '+$mode }) -join [Environment]::NewLine) }
    & $showSelectedGroups
    $chooseGroups.Add_Click({
        $entry=@($manifest.Modules | Where-Object Id -eq 'ring-manager')[0]
        $verified=Get-AssistenteITModuleAccess -Module $entry -Access $script:Access
        $picked=Show-AssistenteITGroupPicker -Configured $ringSelection.Groups -Access $verified -Owner $dialog -InstallRoot $PSScriptRoot
        if ($null -ne $picked) { $ringSelection.Groups=@($picked);& $showSelectedGroups }
    })
    $ringPage.Controls.AddRange(@($groupHint,$chooseGroups,$selectedGroups))
    $save = New-Object Windows.Forms.Button; $save.Name='SaveSettings';$save.Text='Salva'; $save.SetBounds(388, 540, 105, 32)
    $cancel = New-Object Windows.Forms.Button; $cancel.Text='Annulla'; $cancel.DialogResult='Cancel'; $cancel.SetBounds(503, 540, 105, 32)
    $dialog.AcceptButton=$save; $dialog.CancelButton=$cancel
    $save.Add_Click({
        try {
            $mode='Interactive';if ($modeBox.SelectedIndex -eq 1) { $mode='Delegated' }
            $graphAuthentication=[pscustomobject]@{AuthenticationMode=$mode;TenantId=$tenantBox.Text;ClientId=$clientBox.Text}
            Save-AssistenteITSettings -HybridJoinSettings ([pscustomobject]@{AdServer=$hybridServer.Text;SearchScope=[string]$scopeBox.SelectedItem;TargetOus=@($ouBox.Lines | Where-Object { $_.Trim() })}) -RingManagerSettings ([pscustomobject]@{Groups=@($ringSelection.Groups)}) -GraphAuthentication $graphAuthentication -Paths $paths -DomainControllers $dcBox.Lines -GlpiBaseUri $urlBox.Text -GlpiEnabled $glpiCheck.Checked -UseAppToken $appCheck.Checked -UserToken $userBox.Text -AppToken $appBox.Text
            $dialog.DialogResult='OK'; $dialog.Close()
        }
        catch { [void][Windows.Forms.MessageBox]::Show($dialog, $_.Exception.Message, 'Impostazioni', 'OK', 'Error') }
    })
    $generalPage.Controls.AddRange(@($dcLabel,$dcBox,$glpiCheck,$urlLabel,$urlBox,$appCheck,$userLabel,$userBox,$appLabel,$appBox,$hint))
    $dialog.Controls.AddRange(@($settingsTabs,$save,$cancel))
    try {
        if ($dialog.ShowDialog($form) -eq 'OK') { $status.Text='Impostazioni salvate. Saranno usate alla prossima apertura del modulo.' }
    }
    finally { $userBox.Clear(); $appBox.Clear(); $dialog.Dispose() }
}

$script:UpdateWorker=$null; $script:UpdatePipeline=$null; $script:UpdateInvocation=$null
$script:UpdateInfo=$null; $script:DownloadedUpdate=$null; $script:UpdateOperation=''
$script:UpdateQueue=New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$script:ModuleTasks=New-Object 'System.Collections.Generic.List[object]'
$script:Access=$null
$script:ModuleButtons=@{}
$script:ModuleAccessLabels=@{}

function Get-AssistenteITOpenModules {
    $running=0
    foreach ($task in @($script:ModuleTasks.ToArray())) {
        if ($task.Invocation.IsCompleted) {
            [void]$script:ModuleTasks.Remove($task)
            try { $null=$task.Pipeline.EndInvoke($task.Invocation);if ($task.Pipeline.Streams.Error.Count) { throw $task.Pipeline.Streams.Error[0] } }
            catch { $status.Text='Modulo '+$task.ModuleId+': '+$_.Exception.Message }
            finally { $task.Pipeline.Dispose();$task.Runspace.Close();$task.Runspace.Dispose() }
        }
        else { $running++ }
    }
    return $running
}

function Update-AssistenteITModuleAvailability {
    foreach ($entry in $manifest.Modules) {
        $verified=Get-AssistenteITModuleAccess -Module $entry -Access $script:Access
        $script:ModuleButtons[$entry.Id].Enabled=$verified.CanOpen
        $label=$script:ModuleAccessLabels[$entry.Id]
        $label.Text='Eseguire Accesso per abilitare il modulo';$label.ForeColor=[Drawing.Color]::DimGray
        if ($null -ne $script:Access -and -not $verified.CanOpen) { $label.Text=$verified.Reason;$label.ForeColor=[Drawing.Color]::DarkOrange }
        elseif ($verified.CanOpen) {
            $label.Text='Sola lettura';$label.ForeColor=[Drawing.Color]::SteelBlue
            if ($verified.AccessMode -eq 'ReadWrite') { $label.Text='Lettura e scrittura (ambiti concessi)';$label.ForeColor=[Drawing.Color]::DarkGreen }
        }
    }
}

function Install-AssistenteITDownloadedUpdate {
    if ($null -eq $script:DownloadedUpdate) { return }
    if ((Get-AssistenteITOpenModules) -gt 0) {
        $status.Text='Aggiornamento scaricato. Chiudi i moduli aperti e premi Installa.'
        $installUpdateButton.Text='Installa'; return
    }
    try {
        Start-AssistenteITUpdateHandoff -PlanPath $script:DownloadedUpdate.PlanPath -InstallRoot $PSScriptRoot
        $form.Close()
    }
    catch { $status.Text=$_.Exception.Message; $installUpdateButton.Enabled=$true }
}

function Start-AssistenteITUpdateOperation {
    param([ValidateSet('Check','Download')][string]$Operation)
    if ($null -ne $script:UpdatePipeline) { return }
    $script:UpdateOperation=$Operation
    $releaseButton.Enabled=$false; $installUpdateButton.Enabled=$false
    if ($Operation -eq 'Check') { $status.Text='Controllo aggiornamenti su GitHub...'; $script:DownloadedUpdate=$null; $script:UpdateInfo=$null; $installUpdateButton.Visible=$false }
    else { $status.Text='Download aggiornamento '+$script:UpdateInfo.Version+'...' }
    if ($null -eq $script:UpdateWorker) {
        $script:UpdateWorker=[RunspaceFactory]::CreateRunspace(); $script:UpdateWorker.ApartmentState='STA'
        $script:UpdateWorker.ThreadOptions='ReuseThread'; $script:UpdateWorker.Open()
    }
    $script:UpdatePipeline=[PowerShell]::Create(); $script:UpdatePipeline.Runspace=$script:UpdateWorker
    $code={
        param($Module,$Operation,$Version,$Update,$Directory,$Queue)
        $ErrorActionPreference='Stop'
        Import-Module $Module -ErrorAction Stop
        if ($Operation -eq 'Check') { Get-AssistenteITUpdate -CurrentVersion $Version }
        else { Save-AssistenteITUpdate -Update $Update -CacheDirectory $Directory -ProgressQueue $Queue }
    }
    [void]$script:UpdatePipeline.AddScript($code.ToString()).AddArgument((Join-Path $PSScriptRoot 'AssistenteIT/AssistenteIT.Update.psm1')).AddArgument($Operation).AddArgument($manifest.Version).AddArgument($script:UpdateInfo).AddArgument((Join-Path $paths.DataRoot 'Updates')).AddArgument($script:UpdateQueue)
    $script:UpdateInvocation=$script:UpdatePipeline.BeginInvoke(); $updateTimer.Start()
}

$form = New-Object Windows.Forms.Form
$applicationIcon = New-Object Drawing.Icon((Join-Path $PSScriptRoot 'assets/AssistenteIT.ico'))
$form.Icon = $applicationIcon
$form.Text = '{0} - {1}' -f $manifest.Product, $manifest.Version
$form.Size = New-Object Drawing.Size(940, 850); $form.MinimumSize=New-Object Drawing.Size(800, 600)
$form.StartPosition='CenterScreen'; $form.Font=New-Object Drawing.Font('Segoe UI', 10)
$layout = New-Object Windows.Forms.TableLayoutPanel
$layout.Dock='Fill'; $layout.Padding=New-Object Windows.Forms.Padding(20); $layout.ColumnCount=1; $layout.RowCount=5
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 75)))
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 52)))
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 95)))
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 60)))
$heading = New-Object Windows.Forms.Label; $heading.Dock='Fill'
$heading.Text = $manifest.Product + "`r`nEsegui Accesso dalla barra in basso, poi scegli un modulo abilitato."
$heading.Font = New-Object Drawing.Font('Segoe UI', 12)
$modulePanel = New-Object Windows.Forms.FlowLayoutPanel; $modulePanel.Dock='Fill'; $modulePanel.AutoScroll=$true; $modulePanel.FlowDirection='TopDown'; $modulePanel.WrapContents=$false
$modulePanel.Add_SizeChanged({ foreach ($card in $modulePanel.Controls) { $card.Width=[Math]::Max(500,$modulePanel.ClientSize.Width-26);foreach ($control in $card.Controls) { if ($control -is [Windows.Forms.Button]) { $control.Left=$card.Width-167 } else { $control.Width=$card.Width-205 } } } })
foreach ($module in $manifest.Modules) {
    $card = New-Object Windows.Forms.GroupBox; $card.Text=$module.Name; $card.Size=New-Object Drawing.Size(785, 136)
    $description = New-Object Windows.Forms.Label; $description.Text=$module.Description; $description.SetBounds(18, 29, 555, 44)
    $accessLabel=New-Object Windows.Forms.Label;$accessLabel.Name='ModuleAccess-'+$module.Id;$accessLabel.SetBounds(18,82,555,34)
    $open = New-Object Windows.Forms.Button; $open.Name='OpenModule-'+$module.Id;$open.Text='Apri modulo'; $open.SetBounds(618, 48, 145, 36); $open.Tag=$module.Id;$open.Enabled=$false
    $script:ModuleButtons[$module.Id]=$open;$script:ModuleAccessLabels[$module.Id]=$accessLabel
    $open.Add_Click({
        param($sender, $eventArgs)
        try {
            $task=Start-AssistenteITModule -InstallRoot $PSScriptRoot -ModuleId ([string]$sender.Tag) -Paths $paths -Access $script:Access
            [void]$script:ModuleTasks.Add($task)
            $accessButton.Enabled=$false;$settingsButton.Enabled=$false
        }
        catch { [void][Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Avvio modulo', 'OK', 'Error') }
    })
    $card.Controls.AddRange(@($description,$accessLabel,$open)); $modulePanel.Controls.Add($card)
}
$toolbar = New-Object Windows.Forms.FlowLayoutPanel; $toolbar.Dock='Fill'; $toolbar.WrapContents=$true
$accessButton=New-Object Windows.Forms.Button;$accessButton.Name='SignIn';$accessButton.Text='Accesso';$accessButton.Size=New-Object Drawing.Size(105,34)
$settingsButton = New-Object Windows.Forms.Button; $settingsButton.Text='Impostazioni'; $settingsButton.Size=New-Object Drawing.Size(115, 34)
$dataButton = New-Object Windows.Forms.Button; $dataButton.Text='Cartella dati'; $dataButton.Size=New-Object Drawing.Size(120, 34)
$releaseButton = New-Object Windows.Forms.Button; $releaseButton.Name='CheckUpdates';$releaseButton.Text='Cerca aggiornamenti'; $releaseButton.Size=New-Object Drawing.Size(180, 34)
$installUpdateButton=New-Object Windows.Forms.Button; $installUpdateButton.Text='Installa aggiornamento'; $installUpdateButton.Size=New-Object Drawing.Size(180,34); $installUpdateButton.Visible=$false
$accessButton.Add_Click({
    if ((Get-AssistenteITOpenModules) -gt 0) { $status.Text='Chiudi i moduli prima di cambiare accesso.';return }
    $script:Access=$null;Update-AssistenteITModuleAvailability
    try {
        . (Join-Path $PSScriptRoot 'AssistenteIT/Graph.Access.ps1')
        $definition=Get-AssistenteITAccessDefinition -Modules $manifest.Modules
        $script:Access=Show-AssistenteITModuleAccess -InstallRoot $PSScriptRoot -Module $definition -ConfigPath $paths.ConfigPath -VerifyOnly -Owner $form
        if ($null -ne $script:Access) { $status.Text='Accesso verificato: '+$script:Access.Account+'. Moduli abilitati secondo i permessi disponibili.' }
        else { $status.Text='Accesso non completato. I moduli restano disabilitati.' }
    }
    catch { $status.Text='Accesso non riuscito: '+$_.Exception.Message }
    finally { Update-AssistenteITModuleAvailability }
})
$settingsButton.Add_Click({
    try {
        $before=[IO.File]::ReadAllText($paths.ConfigPath)
        Show-AssistenteITSettings
        if ($before -cne [IO.File]::ReadAllText($paths.ConfigPath)) { $script:Access=$null;Update-AssistenteITModuleAvailability;$status.Text='Impostazioni salvate. Eseguire nuovamente Accesso.' }
    }
    catch { [void][Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Impostazioni', 'OK', 'Error') }
})
$dataButton.Add_Click({ [void][Diagnostics.Process]::Start('explorer.exe', ('"' + $paths.DataRoot + '"')) })
$releaseButton.Add_Click({ try { Start-AssistenteITUpdateOperation Check } catch { $status.Text=$_.Exception.Message; $releaseButton.Enabled=$true } })
$installUpdateButton.Add_Click({
    if ($null -ne $script:DownloadedUpdate) { Install-AssistenteITDownloadedUpdate; return }
    if ($null -eq $script:UpdateInfo -or -not $script:UpdateInfo.Available) { return }
    $notes=[string]$script:UpdateInfo.Notes
    if ($notes.Length -gt 1400) { $notes=$notes.Substring(0,1400)+'...' }
    $message='Versione installata: '+$manifest.Version+[Environment]::NewLine+'Nuova versione: '+$script:UpdateInfo.Version+[Environment]::NewLine+[Environment]::NewLine+$notes+[Environment]::NewLine+[Environment]::NewLine+'Scaricare e installare? La finestra si chiudera per completare l''aggiornamento; i moduli aperti devono essere chiusi prima dell''installazione.'
    if ([Windows.Forms.MessageBox]::Show($form,$message,'Aggiorna Assistente IT','YesNo','Question') -eq 'Yes') {
        try { Start-AssistenteITUpdateOperation Download } catch { $status.Text=$_.Exception.Message; $releaseButton.Enabled=$true; $installUpdateButton.Enabled=$true }
    }
})
$toolbar.Controls.AddRange(@($accessButton,$settingsButton,$dataButton,$releaseButton,$installUpdateButton))
$components = New-Object Windows.Forms.GroupBox; $components.Text='Componenti aggiuntivi'; $components.Dock='Fill'
$componentRows=New-Object Windows.Forms.TableLayoutPanel
$componentRows.Dock='Fill'; $componentRows.Padding=New-Object Windows.Forms.Padding(10,3,10,6)
$componentRows.ColumnCount=1; $componentRows.RowCount=2
[void]$componentRows.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',50)))
[void]$componentRows.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',50)))
$graphStatus=New-Object Windows.Forms.Label; $graphStatus.Dock='Fill'; $graphStatus.TextAlign='MiddleLeft'
$graphStatus.Text='Microsoft Graph: disponibile'; $graphStatus.ForeColor=[Drawing.Color]::DarkGreen
if (-not $prerequisites.GraphAvailable) { $graphStatus.Text='Microsoft Graph: componente mancante'; $graphStatus.ForeColor=[Drawing.Color]::DarkOrange }
$adStatus=New-Object Windows.Forms.Label; $adStatus.Dock='Fill'; $adStatus.TextAlign='MiddleLeft'
$adStatus.Text='Active Directory (RSAT): disponibile'; $adStatus.ForeColor=[Drawing.Color]::DarkGreen
if (-not $prerequisites.ActiveDirectoryAvailable) { $adStatus.Text='Active Directory (RSAT): componente mancante'; $adStatus.ForeColor=[Drawing.Color]::DarkOrange }
$componentRows.Controls.Add($graphStatus,0,0); $componentRows.Controls.Add($adStatus,0,1)
$components.Controls.Add($componentRows)
$status = New-Object Windows.Forms.Label; $status.Dock='Fill'; $status.Padding=New-Object Windows.Forms.Padding(0,8,0,0)
$status.Text='Aggiornamenti: in attesa del controllo.'
$layout.Controls.Add($heading,0,0); $layout.Controls.Add($modulePanel,0,1); $layout.Controls.Add($toolbar,0,2)
$layout.Controls.Add($components,0,3); $layout.Controls.Add($status,0,4)
$form.Controls.Add($layout)
Initialize-AssistenteITWindowIdentity -InstallRoot $PSScriptRoot -Window $form
Update-AssistenteITModuleAvailability
$moduleTimer=New-Object Windows.Forms.Timer;$moduleTimer.Interval=300
$moduleTimer.Add_Tick({ $running=Get-AssistenteITOpenModules;$accessButton.Enabled=$running -eq 0;$settingsButton.Enabled=$running -eq 0 });$moduleTimer.Start()
$form.Add_FormClosing({param($sender,$eventArgs) if ((Get-AssistenteITOpenModules) -gt 0) { $eventArgs.Cancel=$true;$status.Text='Chiudi i moduli aperti prima di uscire da Assistente IT.' } })
$updateTimer=New-Object Windows.Forms.Timer; $updateTimer.Interval=250
$updateTimer.Add_Tick({
    $progress=$null
    while ($script:UpdateQueue.TryDequeue([ref]$progress)) {
        $status.Text='Download aggiornamento: {0:N1} MB' -f ($progress.Bytes/1MB)
    }
    if ($null -eq $script:UpdateInvocation -or -not $script:UpdateInvocation.IsCompleted) { return }
    $operation=$script:UpdateOperation; $success=$false
    try {
        $output=@($script:UpdatePipeline.EndInvoke($script:UpdateInvocation))
        if ($script:UpdatePipeline.Streams.Error.Count -gt 0) { throw $script:UpdatePipeline.Streams.Error[0] }
        if ($output.Count -ne 1) { throw 'Risposta aggiornamento incompleta.' }
        if ($operation -eq 'Check') {
            $script:UpdateInfo=$output[0]; $installUpdateButton.Visible=$script:UpdateInfo.Available
            $installUpdateButton.Text='Installa aggiornamento'
            if ($script:UpdateInfo.Available) { $status.Text='Disponibile Assistente IT '+$script:UpdateInfo.Version+'. Premi Installa aggiornamento per installare.' }
            else { $status.Text='Assistente IT è aggiornato (versione '+$manifest.Version+').' }
        }
        else { $script:DownloadedUpdate=$output[0]; $installUpdateButton.Text='Installa'; $status.Text='Download verificato. Preparazione installazione...' }
        $success=$true
    }
    catch { $status.Text='Aggiornamento: '+$_.Exception.Message }
    finally {
        $updateTimer.Stop(); $script:UpdatePipeline.Dispose(); $script:UpdatePipeline=$null; $script:UpdateInvocation=$null
        $releaseButton.Enabled=$true; $installUpdateButton.Enabled=$null -ne $script:UpdateInfo -and $script:UpdateInfo.Available
    }
    if ($success -and $operation -eq 'Download') { Install-AssistenteITDownloadedUpdate }
})
$form.Add_Shown({ if (-not $SmokeTestOutput) { try { Start-AssistenteITUpdateOperation Check } catch { $status.Text=$_.Exception.Message; $releaseButton.Enabled=$true } } })
try {
    if ($SmokeTestOutput) {
        $form.CreateControl(); $form.PerformLayout()
        [pscustomobject]@{Product=$manifest.Product;Version=$manifest.Version;WindowTitle=$form.Text;ModuleCount=$modulePanel.Controls.Count;GraphAvailable=$prerequisites.GraphAvailable;LoginButton=$accessButton.Text;UpdateButton=$releaseButton.Text;ModulesEnabled=@($script:ModuleButtons.Values | Where-Object Enabled).Count;AppUserModelId=[AssistenteIT.WindowIdentity]::CurrentId();DataRoot=$paths.DataRoot;ConfigPath=$paths.ConfigPath;EnvPath=$paths.EnvPath} | ConvertTo-Json | Set-Content -LiteralPath $SmokeTestOutput -Encoding UTF8
    }
    else { [void]$form.ShowDialog() }
}
finally {
    $updateTimer.Stop(); $updateTimer.Dispose()
    if ($null -ne $script:UpdatePipeline) { $script:UpdatePipeline.Stop(); $script:UpdatePipeline.Dispose() }
    if ($null -ne $script:UpdateWorker) { $script:UpdateWorker.Close(); $script:UpdateWorker.Dispose() }
    $moduleTimer.Stop();$moduleTimer.Dispose()
    $form.Dispose(); $applicationIcon.Dispose(); $activity.Dispose()
}
