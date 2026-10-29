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
    $save = New-Object Windows.Forms.Button; $save.Name='SaveSettings';$save.Text='Salva'; $save.SetBounds(388, 540, 105, 32)
    $cancel = New-Object Windows.Forms.Button; $cancel.Text='Annulla'; $cancel.DialogResult='Cancel'; $cancel.SetBounds(503, 540, 105, 32)
    $dialog.AcceptButton=$save; $dialog.CancelButton=$cancel
    $save.Add_Click({
        try {
            $mode='Interactive';if ($modeBox.SelectedIndex -eq 1) { $mode='Delegated' }
            $graphAuthentication=[pscustomobject]@{AuthenticationMode=$mode;TenantId=$tenantBox.Text;ClientId=$clientBox.Text}
            Save-AssistenteITSettings -GraphAuthentication $graphAuthentication -Paths $paths -DomainControllers $dcBox.Lines -GlpiBaseUri $urlBox.Text -GlpiEnabled $glpiCheck.Checked -UseAppToken $appCheck.Checked -UserToken $userBox.Text -AppToken $appBox.Text
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
$script:ModuleProcesses=New-Object 'System.Collections.Generic.List[object]'

function Get-AssistenteITOpenModules {
    $running=0
    foreach ($process in @($script:ModuleProcesses.ToArray())) {
        if ($process.HasExited) { $process.Dispose(); [void]$script:ModuleProcesses.Remove($process) }
        else { $running++ }
    }
    return $running
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
$form.Size = New-Object Drawing.Size(790, 650); $form.MinimumSize=New-Object Drawing.Size(660, 535)
$form.StartPosition='CenterScreen'; $form.Font=New-Object Drawing.Font('Segoe UI', 10)
$layout = New-Object Windows.Forms.TableLayoutPanel
$layout.Dock='Fill'; $layout.Padding=New-Object Windows.Forms.Padding(20); $layout.ColumnCount=1; $layout.RowCount=5
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 75)))
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 48)))
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 95)))
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 60)))
$heading = New-Object Windows.Forms.Label; $heading.Dock='Fill'
$heading.Text = $manifest.Product + "`r`nScegli il modulo: accesso e verifica dei permessi precedono l''apertura. Configura le connessioni da Impostazioni."
$heading.Font = New-Object Drawing.Font('Segoe UI', 12)
$modulePanel = New-Object Windows.Forms.FlowLayoutPanel; $modulePanel.Dock='Fill'; $modulePanel.AutoScroll=$true; $modulePanel.FlowDirection='TopDown'; $modulePanel.WrapContents=$false
foreach ($module in $manifest.Modules) {
    $card = New-Object Windows.Forms.GroupBox; $card.Text=$module.Name; $card.Size=New-Object Drawing.Size(685, 123)
    $description = New-Object Windows.Forms.Label; $description.Text=$module.Description; $description.SetBounds(18, 30, 485, 67)
    $open = New-Object Windows.Forms.Button; $open.Text='Accesso e apri'; $open.SetBounds(530, 43, 132, 35); $open.Tag=$module.Id
    $open.Add_Click({
        param($sender, $eventArgs)
        try {
            $info = Get-AssistenteITModuleStartInfo -InstallRoot $PSScriptRoot -ModuleId ([string]$sender.Tag) -Paths $paths
            [void]$script:ModuleProcesses.Add([Diagnostics.Process]::Start($info))
        }
        catch { [void][Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Avvio modulo', 'OK', 'Error') }
    })
    $card.Controls.AddRange(@($description,$open)); $modulePanel.Controls.Add($card)
}
$toolbar = New-Object Windows.Forms.FlowLayoutPanel; $toolbar.Dock='Fill'; $toolbar.WrapContents=$false
$settingsButton = New-Object Windows.Forms.Button; $settingsButton.Text='Impostazioni'; $settingsButton.Size=New-Object Drawing.Size(135, 34)
$dataButton = New-Object Windows.Forms.Button; $dataButton.Text='Cartella dati'; $dataButton.Size=New-Object Drawing.Size(135, 34)
$releaseButton = New-Object Windows.Forms.Button; $releaseButton.Text='Aggiornamenti'; $releaseButton.Size=New-Object Drawing.Size(160, 34)
$installUpdateButton=New-Object Windows.Forms.Button; $installUpdateButton.Text='Aggiorna'; $installUpdateButton.Size=New-Object Drawing.Size(105,34); $installUpdateButton.Visible=$false
$settingsButton.Add_Click({ try { Show-AssistenteITSettings } catch { [void][Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Impostazioni', 'OK', 'Error') } })
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
$toolbar.Controls.AddRange(@($settingsButton,$dataButton,$releaseButton,$installUpdateButton))
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
            $installUpdateButton.Text='Aggiorna'
            if ($script:UpdateInfo.Available) { $status.Text='Disponibile Assistente IT '+$script:UpdateInfo.Version+'. Premi Aggiorna per installare.' }
            else { $status.Text='Assistente IT e aggiornato (versione '+$manifest.Version+').' }
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
        [pscustomobject]@{Product=$manifest.Product;Version=$manifest.Version;WindowTitle=$form.Text;ModuleCount=$modulePanel.Controls.Count;GraphAvailable=$prerequisites.GraphAvailable;DataRoot=$paths.DataRoot;ConfigPath=$paths.ConfigPath;EnvPath=$paths.EnvPath} | ConvertTo-Json | Set-Content -LiteralPath $SmokeTestOutput -Encoding UTF8
    }
    else { [void]$form.ShowDialog() }
}
finally {
    $updateTimer.Stop(); $updateTimer.Dispose()
    if ($null -ne $script:UpdatePipeline) { $script:UpdatePipeline.Stop(); $script:UpdatePipeline.Dispose() }
    if ($null -ne $script:UpdateWorker) { $script:UpdateWorker.Close(); $script:UpdateWorker.Dispose() }
    foreach ($process in $script:ModuleProcesses) { $process.Dispose() }
    $form.Dispose(); $applicationIcon.Dispose(); $activity.Dispose()
}
