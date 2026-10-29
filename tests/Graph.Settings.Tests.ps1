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
$manifest=[pscustomobject]@{Product='Assistente IT user settings test'}
$status=[pscustomobject]@{Text=''}
$form=New-Object Windows.Forms.Form;$form.Icon=[Drawing.SystemIcons]::Application;$form.Font=New-Object Drawing.Font('Segoe UI',9)
$timer=New-Object Windows.Forms.Timer;$timer.Interval=60
$script:SettingsSeen=$false;$script:SettingsError='';$script:SettingsPhase='Default'
$timer.Add_Tick({
    $windows=@([Windows.Forms.Application]::OpenForms | Where-Object Text -eq 'Impostazioni - Assistente IT user settings test')
    if ($windows.Count -eq 0) { return }
    $timer.Stop();$dialog=$windows[0];$script:SettingsSeen=$true
    try {
        $mode=$dialog.Controls.Find('GraphAuthenticationMode',$true)[0]
        if ($mode.Items.Count -ne 2 -or $dialog.Controls.Find('GraphCertificateThumbprint',$true).Count -ne 0 -or $dialog.Controls.Find('GraphCertificateStore',$true).Count -ne 0) { throw 'Certificate controls are still exposed.' }
        if ($script:SettingsPhase -eq 'Default' -and $mode.SelectedIndex -ne 0) { throw 'A new configuration does not default to user login.' }
        if ($script:SettingsPhase -eq 'LegacyCertificate' -and $dialog.Controls.Find('GraphAuthenticationHint',$true)[0].Text -notlike '*certificato e stata rimossa*') { throw 'Legacy certificate settings cannot be edited with a clear migration notice.' }
        $mode.SelectedIndex=1
        if (-not $dialog.Controls.Find('GraphTenantId',$true)[0].Enabled -or -not $dialog.Controls.Find('GraphClientId',$true)[0].Enabled) { throw 'Delegated identity fields are disabled.' }
        $dialog.Controls.Find('GraphTenantId',$true)[0].Text='11111111-1111-4111-8111-111111111111'
        $dialog.Controls.Find('GraphClientId',$true)[0].Text='22222222-2222-4222-8222-222222222222'
        if ($dialog.Controls.Find('GraphRestrictionsHint',$true)[0].Text -notlike '*wrapper verifica accesso e permessi*') { throw 'Initial authentication verification is not explained in settings.' }
        $dialog.Controls.Find('SaveSettings',$true)[0].PerformClick()
    }
    catch { $script:SettingsError=$_.Exception.Message;$dialog.Close() }
})
try {
    $form.Show();$timer.Start();Show-AssistenteITSettings
    if (-not $script:SettingsSeen -or $script:SettingsError) { throw ('Delegated settings UI failed: '+$script:SettingsError) }
    $saved=Get-Content $paths.ConfigPath -Raw | ConvertFrom-Json
    if ($saved.Graph.AuthenticationMode -ne 'Delegated' -or $saved.Graph.TenantId -ne '11111111-1111-4111-8111-111111111111' -or $saved.Graph.ClientId -ne '22222222-2222-4222-8222-222222222222' -or @($saved.Graph.PSObject.Properties).Count -ne 3 -or $saved.DomainControllers.Count -ne 5) { throw 'Native settings changed the delegated identity, retained certificate settings or changed the DCs.' }
    'PASS: native Graph settings expose only user modes, preserve the dedicated app identity and explain initial verification in the wrapper.'
    Save-AssistenteITSettings -Paths $paths -DomainControllers $saved.DomainControllers -GlpiEnabled $false
    $again=Get-Content $paths.ConfigPath -Raw | ConvertFrom-Json
    if ($again.Graph.AuthenticationMode -ne 'Delegated' -or $again.Graph.ClientId -ne $saved.Graph.ClientId) { throw 'Saving unrelated settings erased the delegated configuration.' }
    $before=[Convert]::ToBase64String([IO.File]::ReadAllBytes($paths.ConfigPath))
    foreach ($bad in @(@{AuthenticationMode='Certificate'},@{AuthenticationMode='Delegated';TenantId=$saved.Graph.TenantId},@{AuthenticationMode='Delegated';TenantId=$saved.Graph.TenantId;ClientId='invalid'})) {
        $rejected=$false
        try { Save-AssistenteITSettings -Paths $paths -DomainControllers $saved.DomainControllers -GraphAuthentication $bad -UserToken 'must-not-be-saved' } catch { $rejected=$true }
        if (-not $rejected -or [Convert]::ToBase64String([IO.File]::ReadAllBytes($paths.ConfigPath)) -cne $before -or (Test-Path (Join-Path $paths.ConfigDirectory 'glpi-credentials.dpapi.json'))) { throw 'Invalid or removed authentication changed settings or token storage.' }
    }
    'PASS: delegated settings survive unrelated saves; invalid and removed authentication is rejected before configuration or token changes.'
    $saved.Graph.AuthenticationMode='Certificate'
    $saved.Graph | Add-Member NoteProperty CertificateThumbprint 'obsolete-value'
    $saved.Graph | Add-Member NoteProperty CertificateStore 'obsolete-store'
    $saved | ConvertTo-Json -Depth 20 | Set-Content $paths.ConfigPath -Encoding UTF8
    $script:SettingsPhase='LegacyCertificate';$script:SettingsSeen=$false;$timer.Start();Show-AssistenteITSettings
    if (-not $script:SettingsSeen -or $script:SettingsError) { throw ('Legacy settings recovery failed: '+$script:SettingsError) }
    $again=Get-Content $paths.ConfigPath -Raw | ConvertFrom-Json
    if ($again.Graph.AuthenticationMode -ne 'Delegated' -or @($again.Graph.PSObject.Properties).Count -ne 3) { throw 'Legacy certificate settings were not replaced by an explicitly saved user mode.' }
    'PASS: old certificate configurations can be corrected in native settings without an automatic login fallback and without retaining certificate metadata.'
}
finally { $timer.Stop();$timer.Dispose();$form.Dispose();Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue }
