#requires -version 5.1
[CmdletBinding()]
param([string]$DataRoot, [string]$SmokeTestOutput)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Avviare la suite su Windows con powershell.exe -STA.' }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
Import-Module (Join-Path $PSScriptRoot 'Suite/Suite.Core.psm1') -ErrorAction Stop
Enable-ITSuiteDependencies $PSScriptRoot
$manifest = Read-ITSuiteManifest $PSScriptRoot
$paths = Initialize-ITSuite -InstallRoot $PSScriptRoot -DataRoot $DataRoot
$prerequisites = Get-ITSuitePrerequisites
$activity = Open-ITSuiteActivity

function Show-ITSuiteSettings {
    $settings = Get-Content -LiteralPath $paths.ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = 'Impostazioni - OPBG IT Suite'; $dialog.ClientSize = New-Object Drawing.Size(630, 520)
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
    $hint = New-Object Windows.Forms.Label; $hint.Text='Lascia vuoti i token per conservare quelli salvati. I token restano nel .env personale su questo PC.'; $hint.SetBounds(18, 393, 590, 42)
    $save = New-Object Windows.Forms.Button; $save.Text='Salva'; $save.SetBounds(388, 463, 105, 32)
    $cancel = New-Object Windows.Forms.Button; $cancel.Text='Annulla'; $cancel.DialogResult='Cancel'; $cancel.SetBounds(503, 463, 105, 32)
    $dialog.AcceptButton=$save; $dialog.CancelButton=$cancel
    $save.Add_Click({
        try {
            Save-ITSuiteSettings -Paths $paths -DomainControllers $dcBox.Lines -GlpiBaseUri $urlBox.Text -GlpiEnabled $glpiCheck.Checked -UseAppToken $appCheck.Checked -UserToken $userBox.Text -AppToken $appBox.Text
            $dialog.DialogResult='OK'; $dialog.Close()
        }
        catch { [void][Windows.Forms.MessageBox]::Show($dialog, $_.Exception.Message, 'Impostazioni', 'OK', 'Error') }
    })
    $dialog.Controls.AddRange(@($dcLabel,$dcBox,$glpiCheck,$urlLabel,$urlBox,$appCheck,$userLabel,$userBox,$appLabel,$appBox,$hint,$save,$cancel))
    try {
        if ($dialog.ShowDialog($form) -eq 'OK') { $status.Text='Impostazioni salvate. Saranno usate alla prossima apertura del modulo.' }
    }
    finally { $userBox.Clear(); $appBox.Clear(); $dialog.Dispose() }
}

$form = New-Object Windows.Forms.Form
$form.Text = '{0} - {1}' -f $manifest.Product, $manifest.Version
$form.Size = New-Object Drawing.Size(790, 550); $form.MinimumSize=New-Object Drawing.Size(660, 440)
$form.StartPosition='CenterScreen'; $form.Font=New-Object Drawing.Font('Segoe UI', 10)
$layout = New-Object Windows.Forms.TableLayoutPanel
$layout.Dock='Fill'; $layout.Padding=New-Object Windows.Forms.Padding(20); $layout.ColumnCount=1; $layout.RowCount=4
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 75)))
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 48)))
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 58)))
$heading = New-Object Windows.Forms.Label; $heading.Dock='Fill'
$heading.Text = "OPBG IT Suite`r`nScegli il modulo da aprire. Configura GLPI e i DC da Impostazioni."
$heading.Font = New-Object Drawing.Font('Segoe UI', 12)
$modulePanel = New-Object Windows.Forms.FlowLayoutPanel; $modulePanel.Dock='Fill'; $modulePanel.AutoScroll=$true; $modulePanel.FlowDirection='TopDown'; $modulePanel.WrapContents=$false
foreach ($module in $manifest.Modules) {
    $card = New-Object Windows.Forms.GroupBox; $card.Text=$module.Name; $card.Size=New-Object Drawing.Size(685, 123)
    $description = New-Object Windows.Forms.Label; $description.Text=$module.Description; $description.SetBounds(18, 30, 485, 67)
    $open = New-Object Windows.Forms.Button; $open.Text='Apri modulo'; $open.SetBounds(530, 43, 132, 35); $open.Tag=$module.Id
    $open.Add_Click({
        param($sender, $eventArgs)
        try {
            $info = Get-ITSuiteModuleStartInfo -InstallRoot $PSScriptRoot -ModuleId ([string]$sender.Tag) -Paths $paths
            [void][Diagnostics.Process]::Start($info)
        }
        catch { [void][Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Avvio modulo', 'OK', 'Error') }
    })
    $card.Controls.AddRange(@($description,$open)); $modulePanel.Controls.Add($card)
}
$toolbar = New-Object Windows.Forms.FlowLayoutPanel; $toolbar.Dock='Fill'; $toolbar.WrapContents=$false
$settingsButton = New-Object Windows.Forms.Button; $settingsButton.Text='Impostazioni'; $settingsButton.Size=New-Object Drawing.Size(135, 34)
$dataButton = New-Object Windows.Forms.Button; $dataButton.Text='Cartella dati'; $dataButton.Size=New-Object Drawing.Size(135, 34)
$releaseButton = New-Object Windows.Forms.Button; $releaseButton.Text='Release su GitHub'; $releaseButton.Size=New-Object Drawing.Size(165, 34)
$settingsButton.Add_Click({ try { Show-ITSuiteSettings } catch { [void][Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Impostazioni', 'OK', 'Error') } })
$dataButton.Add_Click({ [void][Diagnostics.Process]::Start('explorer.exe', ('"' + $paths.DataRoot + '"')) })
$releaseButton.Add_Click({ $info=New-Object Diagnostics.ProcessStartInfo; $info.FileName=$manifest.ReleasesUrl; $info.UseShellExecute=$true; [void][Diagnostics.Process]::Start($info) })
$toolbar.Controls.AddRange(@($settingsButton,$dataButton,$releaseButton))
$status = New-Object Windows.Forms.Label; $status.Dock='Fill'
$graphText='disponibile'; if (-not $prerequisites.GraphAvailable) { $graphText='mancante' }
$adText='disponibile'; if (-not $prerequisites.ActiveDirectoryAvailable) { $adText='RSAT mancante (AD non disponibile)' }
$status.Text = 'Graph: {0} | ActiveDirectory: {1}' -f $graphText, $adText
$layout.Controls.Add($heading,0,0); $layout.Controls.Add($modulePanel,0,1); $layout.Controls.Add($toolbar,0,2); $layout.Controls.Add($status,0,3)
$form.Controls.Add($layout)
try {
    if ($SmokeTestOutput) {
        $form.CreateControl(); $form.PerformLayout()
        [pscustomobject]@{Product=$manifest.Product;Version=$manifest.Version;ModuleCount=$modulePanel.Controls.Count;GraphAvailable=$prerequisites.GraphAvailable;DataRoot=$paths.DataRoot;ConfigPath=$paths.ConfigPath;EnvPath=$paths.EnvPath} | ConvertTo-Json | Set-Content -LiteralPath $SmokeTestOutput -Encoding UTF8
    }
    else { [void]$form.ShowDialog() }
}
finally { $form.Dispose(); $activity.Dispose() }
