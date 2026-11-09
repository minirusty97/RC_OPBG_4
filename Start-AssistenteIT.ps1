#requires -version 5.1
[CmdletBinding()]
param([string]$DataRoot, [string]$SmokeTestOutput)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Avviare la suite su Windows con powershell.exe -STA.' }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
. (Join-Path $PSScriptRoot 'AssistenteIT/Hub.UI.ps1')
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
    $searchSettings=Get-DmValue $settings 'Search'
    $searchPage=New-Object Windows.Forms.TabPage;$searchPage.Text='Ricerca computer'
    [void]$settingsTabs.TabPages.Add($searchPage)
    $searchDcLabel=New-Object Windows.Forms.Label;$searchDcLabel.Text='DC principale (uno dei DC configurati in GLPI / AD)';$searchDcLabel.SetBounds(18,18,560,30)
    $searchDc=New-Object Windows.Forms.TextBox;$searchDc.Name='ExplorerSearchDc';$searchDc.Text=[string](Get-DmValue $searchSettings 'DomainController' '');$searchDc.SetBounds(18,55,560,25)
    $searchHint=New-Object Windows.Forms.Label;$searchHint.Text='La ricerca consulta tutti i DC configurati. Il DC principale viene interrogato per primo e fornisce i dati per il confronto dei GUID Hybrid. Lasciare vuoto per scegliere automaticamente dc1 o srvdc1, oppure il primo DC dell''elenco.';$searchHint.SetBounds(18,100,560,110)
    $searchPage.Controls.AddRange(@($searchDcLabel,$searchDc,$searchHint))
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
    $groupHint=New-Object Windows.Forms.Label;$groupHint.Text='Scegliere i gruppi da controllare e quelli modificabili (inserimenti e rimozioni confermate). I gruppi scelti vengono salvati per ID. Nessun gruppo e preselezionato; includi solo quelli che vuoi controllare.';$groupHint.SetBounds(18,18,560,65)
    $chooseGroups=New-Object Windows.Forms.Button;$chooseGroups.Name='ChooseRingGroups';$chooseGroups.Text='Seleziona gruppi da Entra';$chooseGroups.SetBounds(18,94,270,34)
    $selectedGroups=New-Object Windows.Forms.TextBox;$selectedGroups.Name='SelectedRingGroups';$selectedGroups.Multiline=$true;$selectedGroups.ReadOnly=$true;$selectedGroups.ScrollBars='Vertical';$selectedGroups.SetBounds(18,145,560,300)
    $showSelectedGroups={ $selectedGroups.Text=(@($ringSelection.Groups | ForEach-Object { $mode='solo controllo';if ($_.CanAssign) { $mode='controllo e modifica' };$_.Label+' | '+$_.Name+' | '+$mode }) -join [Environment]::NewLine) }
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
            Save-AssistenteITSettings -SearchSettings ([pscustomobject]@{DomainController=$searchDc.Text;AllDomainControllers=$true}) -HybridJoinSettings ([pscustomobject]@{AdServer=$hybridServer.Text;SearchScope=[string]$scopeBox.SelectedItem;TargetOus=@($ouBox.Lines | Where-Object { $_.Trim() })}) -RingManagerSettings ([pscustomobject]@{Groups=@($ringSelection.Groups)}) -GraphAuthentication $graphAuthentication -Paths $paths -DomainControllers $dcBox.Lines -GlpiBaseUri $urlBox.Text -GlpiEnabled $glpiCheck.Checked -UseAppToken $appCheck.Checked -UserToken $userBox.Text -AppToken $appBox.Text
            $dialog.DialogResult='OK'; $dialog.Close()
        }
        catch { [void][Windows.Forms.MessageBox]::Show($dialog, $_.Exception.Message, 'Impostazioni', 'OK', 'Error') }
    })
    $generalPage.Controls.AddRange(@($dcLabel,$dcBox,$glpiCheck,$urlLabel,$urlBox,$appCheck,$userLabel,$userBox,$appLabel,$appBox,$hint))
    $dialog.Controls.AddRange(@($settingsTabs,$save,$cancel))
    try {
        $saved=$dialog.ShowDialog($form) -eq 'OK'
        if ($saved) { $status.Text='Impostazioni salvate.' }
        return $saved
    }
    finally { $userBox.Clear(); $appBox.Clear(); $dialog.Dispose() }
}

$script:UpdateWorker=$null; $script:UpdatePipeline=$null; $script:UpdateInvocation=$null
$script:UpdateInfo=$null; $script:DownloadedUpdate=$null; $script:UpdateOperation=''
$script:UpdateQueue=New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$script:ModuleTasks=New-Object 'System.Collections.Generic.List[object]'
$script:Access=$null
$script:AccessTask=$null
$script:AccessChecking=$false
$script:GlpiTask=$null
$script:GlpiRecheck=$false
$accessItems=[ordered]@{Microsoft='Microsoft'; 'entra-read'='Entra ID'; 'intune-read'='Intune'; 'groups-read'='Gruppi Entra'}
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
        $state='Error'
        $label.Text='Accesso richiesto'
        $detail='Premi Accesso per abilitare il modulo.'
        if ($script:AccessChecking) {
            $state='Pending'; $label.Text='Verifica in corso'; $detail=$label.Text
        }
        elseif ($verified.CanOpen) {
            $state='Ready'; $label.Text='Sola lettura'; $detail=$label.Text
            if ($verified.AccessMode -eq 'ReadWrite') {
                $label.Text='Lettura e scrittura'
                $detail='Ambiti di scrittura concessi. Il servizio verifica i diritti durante l''operazione.'
            }
        }
        elseif ($null -ne $script:Access) {
            $label.Text='Non disponibile'; $detail=$verified.Reason
        }
        $label.ForeColor=$hubColors[$state]
        $hubToolTip.SetToolTip($label,$detail)
    }
}

function Set-AssistenteITAccessStatus {
    param($Access,[string]$Detail,[switch]$Checking)
    $script:AccessChecking=[bool]$Checking
    $script:Access=$null
    $reads=@()
    if ($null -ne $Access) { $reads=@($Access.Permissions | Where-Object Id -in @('entra-read','intune-read','groups-read')) }
    $rejected=@($reads | Where-Object { $_.PSObject.Properties['SessionRejected'] -and $_.SessionRejected }).Count -gt 0
    if ($Checking) {
        Set-AssistenteITHubStatus Microsoft Pending 'Verifica in corso' $Detail
    }
    elseif (-not $rejected -and @($reads | Where-Object OperationVerified).Count -gt 0) {
        $script:Access=$Access
        Set-AssistenteITHubStatus Microsoft Ready $Access.Account ('Accesso verificato per '+$Access.Account+'.')
    }
    else {
        if ($rejected) { $Detail='La sessione è scaduta o Microsoft richiede un intervento. Premi Accesso.' }
        elseif ($null -ne $Access) { $Detail='Nessuna lettura Graph è stata convalidata. Premi Accesso per riprovare.' }
        Set-AssistenteITHubStatus Microsoft Error 'Accesso richiesto' $Detail
    }
    foreach ($id in @('entra-read','intune-read','groups-read')) {
        $read=$reads | Where-Object Id -eq $id | Select-Object -First 1
        if ($Checking) { Set-AssistenteITHubStatus $id Pending 'In verifica' }
        elseif ($null -eq $read) { Set-AssistenteITHubStatus $id Pending 'In attesa di accesso' }
        elseif (-not $read.OperationVerified) { Set-AssistenteITHubStatus $id Error $read.CheckStatus $read.Detail }
        elseif ($rejected) { Set-AssistenteITHubStatus $id Pending 'Sessione da rinnovare' }
        elseif ($id -eq 'groups-read' -and $Access.GroupError) {
            Set-AssistenteITHubStatus $id Pending 'Appartenenze da verificare' 'Lettura gruppi riuscita. La verifica delle appartenenze dell''account è incompleta.'
        }
        else { Set-AssistenteITHubStatus $id Ready 'Lettura verificata' $read.Detail }
    }
    Update-AssistenteITModuleAvailability
}

function Start-AssistenteITSavedAccessCheck {
    if ($null -ne $script:AccessTask) { return }
    if (-not $prerequisites.GraphAvailable) {
        Set-AssistenteITAccessStatus $null 'Microsoft Graph non disponibile.'
        return
    }
    if (-not [IO.File]::Exists($paths.GraphSessionPath)) {
        Set-AssistenteITAccessStatus $null 'Premi Accesso per collegare l''account Microsoft.'
        return
    }

    $pipeline=[PowerShell]::Create()
    try {
        $worker={
            param($Root,$Definition,$Config,$SessionPath,$WindowHandle)
            $ErrorActionPreference='Stop'
            Import-Module (Join-Path $Root 'AssistenteIT/AssistenteIT.Core.psm1') -ErrorAction Stop
            Initialize-AssistenteITModuleAccess -Module $Definition -ConfigPath $Config -SessionPath $SessionPath -WindowHandle $WindowHandle
        }
        $definition=Get-AssistenteITAccessDefinition -Modules $manifest.Modules
        [void]$pipeline.AddScript($worker.ToString()).AddArgument($PSScriptRoot).AddArgument($definition).AddArgument($paths.ConfigPath).AddArgument($paths.GraphSessionPath).AddArgument($form.Handle)
        $invocation=$pipeline.BeginInvoke()
        $script:AccessTask=@{Pipeline=$pipeline;Invocation=$invocation;Stop=$null;Deadline=[datetime]::UtcNow.AddSeconds(45)}
        Set-AssistenteITAccessStatus $null 'Ripristino silenzioso dell''account Microsoft salvato.' -Checking
        $accessButton.Enabled=$false
        $settingsButton.Enabled=$false
        $accessTimer.Start()
    }
    catch {
        $pipeline.Dispose()
        $script:AccessTask=$null
        Set-AssistenteITAccessStatus $null 'Verifica della sessione non riuscita. Usa Accesso.'
    }
}

function Start-AssistenteITGlpiCheck {
    Set-AssistenteITHubStatus GLPI Pending 'In verifica'
    if ($null -ne $script:GlpiTask) { $script:GlpiRecheck=$true; return }
    $pipeline=[PowerShell]::Create()
    try {
        [void]$pipeline.AddScript({
            param($Core,$Config,$EnvPath)
            $ErrorActionPreference='Stop'
            Import-Module $Core -ErrorAction Stop
            Get-AssistenteITGlpiStatus -ConfigPath $Config -EnvPath $EnvPath
        }.ToString()).AddArgument((Join-Path $PSScriptRoot 'AssistenteIT/AssistenteIT.Core.psm1')).AddArgument($paths.ConfigPath).AddArgument($paths.EnvPath)
        $script:GlpiTask=@{Pipeline=$pipeline;Invocation=$pipeline.BeginInvoke()}
        $glpiTimer.Start()
    }
    catch {
        $pipeline.Dispose()
        $script:GlpiTask=$null
        Set-AssistenteITHubStatus GLPI Error 'Non disponibile' 'Impossibile avviare la verifica di GLPI.'
    }
}

function Install-AssistenteITDownloadedUpdate {
    if ($null -eq $script:DownloadedUpdate) { return }
    if ((Get-AssistenteITOpenModules) -gt 0) {
        $status.Text='Aggiornamento scaricato. Chiudi i moduli aperti e premi Installa.'
        $installUpdateButton.Text='Installa'
        [void][Windows.Forms.MessageBox]::Show($form,$status.Text,'Aggiornamento Assistente IT','OK','Information')
        return
    }
    try { Start-AssistenteITUpdateOperation Install }
    catch {
        $status.Text=$_.Exception.Message
        [void][Windows.Forms.MessageBox]::Show($form,$status.Text,'Aggiornamento Assistente IT','OK','Error')
    }
}

function Start-AssistenteITUpdateOperation {
    param([ValidateSet('Check','Download','Install')][string]$Operation)
    if ($null -ne $script:UpdatePipeline) { return }
    $script:UpdateOperation=$Operation
    $releaseButton.Enabled=$false; $installUpdateButton.Enabled=$false
    if ($Operation -eq 'Check') {
        Set-AssistenteITHubStatus Repository Pending 'In verifica'
        Set-AssistenteITHubStatus Update Pending 'In verifica'
        $script:DownloadedUpdate=$null; $script:UpdateInfo=$null; $installUpdateButton.Visible=$false
    }
    elseif ($Operation -eq 'Download') {
        Set-AssistenteITHubStatus Update Pending ('Download v'+$script:UpdateInfo.Version)
    }
    else {
        Set-AssistenteITHubStatus Update Pending 'Installazione in corso'
        $form.Enabled=$false
    }
    try {
        if ($null -eq $script:UpdateWorker) {
            $worker=[RunspaceFactory]::CreateRunspace()
            try {
                $worker.ApartmentState='STA'; $worker.ThreadOptions='ReuseThread'; $worker.Open()
                $script:UpdateWorker=$worker
            }
            catch { $worker.Dispose(); throw }
        }
        $script:UpdatePipeline=[PowerShell]::Create(); $script:UpdatePipeline.Runspace=$script:UpdateWorker
        $code={
            param($Module,$Operation,$Version,$Update,$Directory,$Queue,$Downloaded,$InstallRoot)
            $ErrorActionPreference='Stop'
            Import-Module $Module -ErrorAction Stop
            switch ($Operation) {
                'Check' { Get-AssistenteITUpdateStatus -CurrentVersion $Version }
                'Download' { Save-AssistenteITUpdate -Update $Update -CacheDirectory $Directory -ProgressQueue $Queue }
                'Install' {
                    Start-AssistenteITUpdateHandoff -PlanPath $Downloaded.PlanPath -InstallRoot $InstallRoot
                    $true
                }
            }
        }
        [void]$script:UpdatePipeline.AddScript($code.ToString()).AddArgument((Join-Path $PSScriptRoot 'AssistenteIT/AssistenteIT.Update.psm1')).AddArgument($Operation).AddArgument($manifest.Version).AddArgument($script:UpdateInfo).AddArgument((Join-Path $paths.DataRoot 'Updates')).AddArgument($script:UpdateQueue).AddArgument($script:DownloadedUpdate).AddArgument($PSScriptRoot)
        $script:UpdateInvocation=$script:UpdatePipeline.BeginInvoke(); $updateTimer.Start()
    }
    catch {
        if ($null -ne $script:UpdatePipeline) { $script:UpdatePipeline.Dispose() }
        $script:UpdatePipeline=$null; $script:UpdateInvocation=$null
        $form.Enabled=$true; $releaseButton.Enabled=$true
        $installUpdateButton.Enabled=$null -ne $script:UpdateInfo -and $script:UpdateInfo.Available
        Set-AssistenteITHubStatus Update Error 'Operazione non riuscita'
        if ($Operation -eq 'Check') { Set-AssistenteITHubStatus Repository Error 'Nessuna connessione' 'Verifica GitHub non avviata.' }
        throw
    }
}

$form = New-Object Windows.Forms.Form
$applicationIcon = New-Object Drawing.Icon((Join-Path $PSScriptRoot 'assets/AssistenteIT.ico'))
$form.Icon=$applicationIcon
$form.Text='{0} - {1}' -f $manifest.Product,$manifest.Version
$form.Size=New-Object Drawing.Size(960,700)
$form.MinimumSize=New-Object Drawing.Size(780,560)
$form.StartPosition='CenterScreen'
$form.Font=New-Object Drawing.Font('Segoe UI',10)
$form.BackColor=$hubColors.Canvas
$form.ForeColor=$hubColors.Ink

$layout=New-Object Windows.Forms.TableLayoutPanel
$layout.Dock='Fill'
$layout.Padding=New-Object Windows.Forms.Padding(20,14,20,10)
$layout.ColumnCount=1
[void]$layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100)))
$layout.RowCount=5
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',68)))
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',153)))
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',44)))
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',25)))

$header=New-Object Windows.Forms.TableLayoutPanel
$header.Dock='Fill'
$header.ColumnCount=2; $header.RowCount=2
[void]$header.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100)))
[void]$header.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',140)))
[void]$header.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',37)))
[void]$header.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',22)))
$title=New-AssistenteITHubLabel $manifest.Product
$title.Font=$hubTitleFont
$subtitle=New-AssistenteITHubLabel 'Moduli operativi' $hubColors.Muted
$versionLabel=New-AssistenteITHubLabel ('Versione '+$manifest.Version) $hubColors.Muted
$versionLabel.TextAlign='MiddleRight'
$header.Controls.Add($title,0,0)
$header.Controls.Add($subtitle,0,1)
$header.Controls.Add($versionLabel,1,0)

$modulePanel=New-Object Windows.Forms.FlowLayoutPanel
$modulePanel.Dock='Fill'; $modulePanel.AutoScroll=$true
$modulePanel.FlowDirection='TopDown'; $modulePanel.WrapContents=$false
$modulePanel.Margin=New-Object Windows.Forms.Padding(3,0,3,8)
$modulePanel.Add_SizeChanged({
    $width=[Math]::Max(500,$modulePanel.ClientSize.Width-20)
    foreach ($card in $modulePanel.Controls) { $card.Width=$width }
})
foreach ($module in $manifest.Modules) {
    $card=New-Object Windows.Forms.TableLayoutPanel
    $card.Name='ModuleCard-'+$module.Id
    $card.Size=New-Object Drawing.Size(870,68)
    $card.Margin=New-Object Windows.Forms.Padding(0,0,0,7)
    $card.Padding=New-Object Windows.Forms.Padding(12,5,12,5)
    $card.BackColor=$hubColors.Surface
    $card.ColumnCount=3; $card.RowCount=2
    [void]$card.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100)))
    [void]$card.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',166)))
    [void]$card.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',119)))
    [void]$card.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',51)))
    [void]$card.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',49)))
    $name=New-AssistenteITHubLabel $module.Name
    $name.Font=$hubBold
    $description=New-AssistenteITHubLabel $module.Description $hubColors.Muted
    $hubToolTip.SetToolTip($description,$module.Description)
    $accessLabel=New-AssistenteITHubLabel ''
    $accessLabel.Name='ModuleAccess-'+$module.Id
    $accessLabel.TextAlign='MiddleRight'
    $accessLabel.Margin=New-Object Windows.Forms.Padding(4,0,13,0)
    $open=New-AssistenteITHubButton 'Apri modulo' 119
    $open.Name='OpenModule-'+$module.Id
    $open.Dock='Fill'
    $open.Margin=New-Object Windows.Forms.Padding(0,11,0,11)
    $open.Tag=$module.Id; $open.Enabled=$false
    $script:ModuleButtons[$module.Id]=$open
    $script:ModuleAccessLabels[$module.Id]=$accessLabel
    $open.Add_Click({
        param($sender, $eventArgs)
        try {
            $task=Start-AssistenteITModule -InstallRoot $PSScriptRoot -ModuleId ([string]$sender.Tag) -Paths $paths -Access $script:Access
            [void]$script:ModuleTasks.Add($task)
            $accessButton.Enabled=$false; $settingsButton.Enabled=$false
        }
        catch { [void][Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Avvio modulo', 'OK', 'Error') }
    })
    $card.Controls.Add($name,0,0)
    $card.Controls.Add($description,0,1)
    $card.Controls.Add($accessLabel,1,0); $card.SetRowSpan($accessLabel,2)
    $card.Controls.Add($open,2,0); $card.SetRowSpan($open,2)
    $modulePanel.Controls.Add($card)
}

$toolbar=New-Object Windows.Forms.FlowLayoutPanel
$toolbar.Dock='Fill'; $toolbar.WrapContents=$false
$accessButton=New-AssistenteITHubButton 'Accesso' 100 -Primary
$accessButton.Name='SignIn'
$settingsButton=New-AssistenteITHubButton 'Impostazioni' 110
$dataButton=New-AssistenteITHubButton 'Cartella dati' 112
$releaseButton=New-AssistenteITHubButton 'Cerca aggiornamenti' 166
$releaseButton.Name='CheckUpdates'
$installUpdateButton=New-AssistenteITHubButton 'Installa aggiornamento' 174 -Primary
$installUpdateButton.Visible=$false
$accessButton.Add_Click({
    if ((Get-AssistenteITOpenModules) -gt 0) { $status.Text='Chiudi i moduli prima di cambiare accesso.';return }
    if ($null -ne $script:AccessTask) { return }
    Set-AssistenteITAccessStatus $null 'Accesso Microsoft avviato dal pulsante Accesso.' -Checking
    try {
        . (Join-Path $PSScriptRoot 'AssistenteIT/Graph.Access.ps1')
        $definition=Get-AssistenteITAccessDefinition -Modules $manifest.Modules
        $verified=Show-AssistenteITModuleAccess -InstallRoot $PSScriptRoot -Module $definition -ConfigPath $paths.ConfigPath -VerifyOnly -Owner $form
        Set-AssistenteITAccessStatus $verified 'Accesso da completare. Seleziona Accesso.'
        if ($null -ne $script:Access) {
            $saved=$false
            try { $saved=Save-AssistenteITGraphSession -Path $paths.GraphSessionPath -Access $verified } catch { }
            if (-not $saved) {
                try { [IO.File]::Delete($paths.GraphSessionPath) } catch { }
                Set-AssistenteITHubStatus Microsoft Pending $verified.Account 'Accesso verificato per questa apertura. Il riferimento della sessione non è stato salvato.'
            }
        }
    }
    catch { Set-AssistenteITAccessStatus $null 'Accesso non riuscito. Seleziona Accesso per riprovare.' }
})
$settingsButton.Add_Click({
    try {
        $before=[IO.File]::ReadAllText($paths.ConfigPath)
        if (Show-AssistenteITSettings) {
            Start-AssistenteITGlpiCheck
            if ($before -cne [IO.File]::ReadAllText($paths.ConfigPath)) { Start-AssistenteITSavedAccessCheck }
        }
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
$statusPanel=New-Object Windows.Forms.TableLayoutPanel
$statusPanel.Name='HubStatus'
$statusPanel.Dock='Fill'; $statusPanel.ColumnCount=2; $statusPanel.RowCount=1
[void]$statusPanel.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',48)))
[void]$statusPanel.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',52)))
$accessPanel=New-AssistenteITStatusSection GraphSessionPanel 'Stato accesso' $accessItems
$components=New-AssistenteITStatusSection ComponentsPanel 'Componenti' ([ordered]@{
    GraphSdk='SDK Graph'; ActiveDirectory='RSAT AD'; GLPI='GLPI'; Repository='Repository GitHub'; Update='Aggiornamento'
})
$statusPanel.Controls.Add($accessPanel,0,0)
$statusPanel.Controls.Add($components,1,0)
foreach ($item in @(@{Id='GraphSdk';Available=$prerequisites.GraphAvailable},@{Id='ActiveDirectory';Available=$prerequisites.ActiveDirectoryAvailable})) {
    if ($item.Available) { Set-AssistenteITHubStatus $item.Id Ready 'Disponibile' }
    else { Set-AssistenteITHubStatus $item.Id Error 'Componente mancante' }
}
$status=New-AssistenteITHubLabel '' $hubColors.Muted
$status.Name='HubMessage'
$layout.Controls.Add($header,0,0)
$layout.Controls.Add($modulePanel,0,1)
$layout.Controls.Add($statusPanel,0,2)
$layout.Controls.Add($toolbar,0,3)
$layout.Controls.Add($status,0,4)
$form.Controls.Add($layout)
Initialize-AssistenteITWindowIdentity -InstallRoot $PSScriptRoot -Window $form
Set-AssistenteITAccessStatus $null 'Verifica automatica all''apertura.' -Checking
$accessTimer=New-Object Windows.Forms.Timer;$accessTimer.Interval=100
$accessTimer.Add_Tick({
    $task=$script:AccessTask
    if ($null -eq $task) { return }
    if (-not $task.Invocation.IsCompleted) {
        if ($null -eq $task.Stop -and [datetime]::UtcNow -gt $task.Deadline) {
            Set-AssistenteITAccessStatus $null 'Tempo di verifica scaduto. Premi Accesso per riprovare.'
            $task.Stop=$task.Pipeline.BeginStop($null,$null)
        }
        return
    }
    $accessTimer.Stop()
    $script:AccessTask=$null
    $result=$null
    $message='Sessione non convalidata. Seleziona Accesso.'
    try {
        if ($null -ne $task.Stop) { $task.Pipeline.EndStop($task.Stop) }
        $output=@($task.Pipeline.EndInvoke($task.Invocation))
        if ($task.Pipeline.Streams.Error.Count -gt 0 -or $output.Count -gt 1) { throw 'Verifica sessione incompleta.' }
        if ($output.Count -eq 1 -and $null -eq $task.Stop) { $result=$output[0] }
    }
    catch { $message='Verifica della sessione non riuscita. Usa Accesso.' }
    finally { $task.Pipeline.Dispose() }
    Set-AssistenteITAccessStatus $result $message
})
$glpiTimer=New-Object Windows.Forms.Timer
$glpiTimer.Interval=200
$glpiTimer.Add_Tick({
    $task=$script:GlpiTask
    if ($null -eq $task -or -not $task.Invocation.IsCompleted) { return }
    $glpiTimer.Stop()
    $script:GlpiTask=$null
    $report=$null
    try {
        $output=@($task.Pipeline.EndInvoke($task.Invocation))
        if ($output.Count -eq 1 -and $task.Pipeline.Streams.Error.Count -eq 0) { $report=$output[0] }
    }
    catch { }
    finally { $task.Pipeline.Dispose() }
    if ($script:GlpiRecheck) {
        $script:GlpiRecheck=$false
        Start-AssistenteITGlpiCheck
        return
    }
    if ($null -eq $report) { Set-AssistenteITHubStatus GLPI Error 'Non disponibile' 'Verifica GLPI non completata.' }
    elseif ($report.State -eq 'Ready') { Set-AssistenteITHubStatus GLPI Ready ('Configurato · '+$report.Account) }
    elseif ($report.State -eq 'NotConfigured') { Set-AssistenteITHubStatus GLPI Pending 'Non configurato' $report.Detail }
    else { Set-AssistenteITHubStatus GLPI Error 'Non disponibile' $report.Detail }
})
$moduleTimer=New-Object Windows.Forms.Timer;$moduleTimer.Interval=300
$moduleTimer.Add_Tick({ $idle=(Get-AssistenteITOpenModules) -eq 0 -and $null -eq $script:AccessTask;$accessButton.Enabled=$idle;$settingsButton.Enabled=$idle });$moduleTimer.Start()
$form.Add_FormClosing({
    param($sender,$eventArgs)
    if ($script:UpdateOperation -eq 'Install' -and $null -ne $script:UpdateInvocation) { $eventArgs.Cancel=$true;return }
    if ((Get-AssistenteITOpenModules) -gt 0) { $eventArgs.Cancel=$true;$status.Text='Chiudi i moduli aperti prima di uscire da Assistente IT.' }
})
$updateTimer=New-Object Windows.Forms.Timer; $updateTimer.Interval=250
$updateTimer.Add_Tick({
    $progress=$null
    while ($script:UpdateQueue.TryDequeue([ref]$progress)) {
        $status.Text='Download aggiornamento: {0:N1} MB' -f ($progress.Bytes/1MB)
    }
    if ($null -eq $script:UpdateInvocation -or -not $script:UpdateInvocation.IsCompleted) { return }
    $operation=$script:UpdateOperation; $success=$false; $installError=''
    try {
        $output=@($script:UpdatePipeline.EndInvoke($script:UpdateInvocation))
        if ($script:UpdatePipeline.Streams.Error.Count -gt 0) { throw $script:UpdatePipeline.Streams.Error[0] }
        if ($output.Count -ne 1) { throw 'Risposta aggiornamento incompleta.' }
        if ($operation -eq 'Check') {
            $report=$output[0]
            switch ($report.RepositoryState) {
                'Available' { Set-AssistenteITHubStatus Repository Ready 'Disponibile' $report.RepositoryDetail }
                'Closed' { Set-AssistenteITHubStatus Repository Error 'Chiusa' $report.RepositoryDetail }
                default { Set-AssistenteITHubStatus Repository Error 'Nessuna connessione' $report.RepositoryDetail }
            }
            $script:UpdateInfo=$report.Update
            $installUpdateButton.Visible=$null -ne $script:UpdateInfo -and $script:UpdateInfo.Available
            $installUpdateButton.Text='Installa aggiornamento'
            if ($null -eq $script:UpdateInfo) {
                Set-AssistenteITHubStatus Update Error 'Verifica non riuscita' $report.UpdateDetail
            }
            elseif ($script:UpdateInfo.Available) {
                Set-AssistenteITHubStatus Update Pending ('Disponibile v'+$script:UpdateInfo.Version)
            }
            else {
                Set-AssistenteITHubStatus Update Ready ('Aggiornata · v'+$manifest.Version) ('Assistente IT è aggiornato (versione '+$manifest.Version+').')
            }
        }
        elseif ($operation -eq 'Download') { $script:DownloadedUpdate=$output[0]; $installUpdateButton.Text='Installa'; $status.Text='Download verificato. Preparazione installazione...' }
        $success=$true
    }
    catch {
        Set-AssistenteITHubStatus Update Error 'Operazione non riuscita' $_.Exception.Message
        if ($operation -eq 'Check') { Set-AssistenteITHubStatus Repository Error 'Nessuna connessione' 'Verifica GitHub non completata.' }
        $status.Text='Aggiornamento — '+$_.Exception.Message
        if ($operation -eq 'Install') { $installError=$_.Exception.Message }
    }
    finally {
        $updateTimer.Stop(); $script:UpdatePipeline.Dispose(); $script:UpdatePipeline=$null; $script:UpdateInvocation=$null
        if ($operation -eq 'Install') { $form.Enabled=$true }
        $releaseButton.Enabled=$true; $installUpdateButton.Enabled=$null -ne $script:UpdateInfo -and $script:UpdateInfo.Available
    }
    if ($installError) { [void][Windows.Forms.MessageBox]::Show($form,$installError,'Aggiornamento Assistente IT','OK','Error') }
    elseif ($success -and $operation -eq 'Download') { Install-AssistenteITDownloadedUpdate }
    elseif ($success -and $operation -eq 'Install') { $form.Close() }
})
$form.Add_Shown({
    if (-not $SmokeTestOutput) {
        Start-AssistenteITSavedAccessCheck
        Start-AssistenteITGlpiCheck
        try { Start-AssistenteITUpdateOperation Check } catch { $status.Text=$_.Exception.Message; $releaseButton.Enabled=$true }
    }
})
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
    $accessTimer.Stop();$accessTimer.Dispose()
    if ($null -ne $script:AccessTask) {
        $script:AccessTask.Pipeline.Stop()
        $script:AccessTask.Pipeline.Dispose()
    }
    $glpiTimer.Stop();$glpiTimer.Dispose()
    if ($null -ne $script:GlpiTask) { $script:GlpiTask.Pipeline.Stop(); $script:GlpiTask.Pipeline.Dispose() }
    $moduleTimer.Stop();$moduleTimer.Dispose()
    $form.Dispose(); $applicationIcon.Dispose(); $activity.Dispose()
    $hubToolTip.Dispose(); $hubBold.Dispose(); $hubTitleFont.Dispose()
}
