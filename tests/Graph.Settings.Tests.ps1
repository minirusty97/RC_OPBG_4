#requires -version 5.1
$ErrorActionPreference='Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { Write-Host 'SKIP: Graph settings UI requires Windows.';return }
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'AssistenteIT/AssistenteIT.Core.psm1') -Force
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('graph-settings-'+[guid]::NewGuid().ToString('N'))
$paths=Initialize-AssistenteIT -InstallRoot $root -DataRoot $temporary
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Start-AssistenteIT.ps1'),[ref]$tokens,[ref]$errors)
$definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Show-AssistenteITSettings'},$true)
Set-Item Function:Show-AssistenteITSettings $definition.Body.GetScriptBlock()
$manifest=[pscustomobject]@{Product='Assistente IT certificate test'}
$status=[pscustomobject]@{Text=''}
$form=New-Object Windows.Forms.Form;$form.Icon=[Drawing.SystemIcons]::Application;$form.Font=New-Object Drawing.Font('Segoe UI',9)
$timer=New-Object Windows.Forms.Timer;$timer.Interval=60
$script:SettingsSeen=$false;$script:SettingsError=''
$timer.Add_Tick({
    $windows=@([Windows.Forms.Application]::OpenForms | Where-Object Text -eq 'Impostazioni - Assistente IT certificate test')
    if ($windows.Count -eq 0) { return }
    $timer.Stop();$dialog=$windows[0];$script:SettingsSeen=$true
    try {
        $mode=$dialog.Controls.Find('GraphAuthenticationMode',$true)[0]
        if ($mode.SelectedIndex -ne 0) { throw 'New settings do not default to interactive login.' }
        $dialog.Controls.Find('GraphTenantId',$true)[0].Text='11111111-1111-4111-8111-111111111111'
        $dialog.Controls.Find('GraphClientId',$true)[0].Text='22222222-2222-4222-8222-222222222222'
        $dialog.Controls.Find('GraphCertificateThumbprint',$true)[0].Text=('ab '*20)
        $dialog.Controls.Find('GraphCertificateStore',$true)[0].SelectedIndex=1
        $mode.SelectedIndex=1
        $dialog.Controls.Find('SaveSettings',$true)[0].PerformClick()
    }
    catch { $script:SettingsError=$_.Exception.Message;$dialog.Close() }
})
try {
    $form.Show();$timer.Start();Show-AssistenteITSettings
    if (-not $script:SettingsSeen -or $script:SettingsError) { throw ('Certificate settings UI failed: '+$script:SettingsError) }
    $saved=Get-Content $paths.ConfigPath -Raw | ConvertFrom-Json
    if ($saved.Graph.AuthenticationMode -ne 'Certificate' -or $saved.Graph.TenantId -ne '11111111-1111-4111-8111-111111111111' -or $saved.Graph.ClientId -ne '22222222-2222-4222-8222-222222222222' -or $saved.Graph.CertificateThumbprint -cne ('AB'*20) -or $saved.Graph.CertificateStore -ne 'LocalMachine' -or $saved.DomainControllers.Count -ne 5) { throw 'Native settings did not persist the certificate identity or changed existing connection settings.' }
    'PASS: native Graph settings select and save tenant, client, thumbprint and certificate store without importing a private key.'
    Save-AssistenteITSettings -Paths $paths -DomainControllers $saved.DomainControllers -GlpiEnabled $false
    $again=Get-Content $paths.ConfigPath -Raw | ConvertFrom-Json
    if ($again.Graph.CertificateThumbprint -cne $saved.Graph.CertificateThumbprint -or $again.Graph.AuthenticationMode -ne 'Certificate') { throw 'Saving unrelated settings erased certificate configuration.' }
    $before=[IO.File]::ReadAllBytes($paths.ConfigPath)
    $rejected=$false
    try { Save-AssistenteITSettings -Paths $paths -DomainControllers $saved.DomainControllers -GraphAuthentication @{AuthenticationMode='Certificate';ClientId='invalid'} -UserToken 'must-not-be-saved' } catch { $rejected=$true }
    if (-not $rejected -or [Convert]::ToBase64String([IO.File]::ReadAllBytes($paths.ConfigPath)) -cne [Convert]::ToBase64String($before) -or (Test-Path (Join-Path $paths.ConfigDirectory 'glpi-credentials.dpapi.json'))) { throw 'Invalid Graph settings modified configuration or token storage.' }
    'PASS: certificate settings survive unrelated saves and invalid Graph input is rejected before configuration or credential changes.'
}
finally { $timer.Stop();$timer.Dispose();$form.Dispose();Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue }
