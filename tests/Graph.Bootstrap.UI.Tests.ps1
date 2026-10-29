#requires -version 5.1
$ErrorActionPreference='Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { Write-Host 'SKIP: wrapper access UI requires Windows.';return }
$root=Split-Path $PSScriptRoot -Parent
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if (-not ('BootstrapUiFixture' -as [type])) { Add-Type -TypeDefinition 'public static class BootstrapUiFixture { public static object Context; public static int Connections; public static string Mode; }' }
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('bootstrap-ui-'+[guid]::NewGuid().ToString('N'))
$moduleDirectory=Join-Path $fixture 'Microsoft.Graph.Authentication';[void][IO.Directory]::CreateDirectory($moduleDirectory)
@'
function Get-MgContext { [CmdletBinding()]param() return [BootstrapUiFixture]::Context }
function Disconnect-MgGraph { [CmdletBinding()]param() [BootstrapUiFixture]::Context=$null }
function Connect-MgGraph {
 [CmdletBinding()]param($Scopes,$TenantId,$ClientId,$Environment,$ContextScope,[switch]$NoWelcome)
 [BootstrapUiFixture]::Connections++
 if ([BootstrapUiFixture]::Mode -eq 'Denied') { throw 'Synthetic initial consent denied.' }
 if ([BootstrapUiFixture]::Mode -eq 'Hold') { while ($true) { Start-Sleep -Milliseconds 20 } }
 if (@($Scopes).Count -ne 1 -or (@($Scopes))[0] -ne 'https://graph.microsoft.com/.default') { throw 'Unexpected dynamic scope request.' }
 [BootstrapUiFixture]::Context=[pscustomobject]@{AuthType='Delegated';TenantId=$TenantId;ClientId=$ClientId;Environment='Global';ContextScope='CurrentUser';Account='synthetic@example.invalid';AppName='Synthetic application';Scopes=@('Device.Read.All','DeviceManagementManagedDevices.ReadWrite.All','BitlockerKey.Read.All')}
}
function Invoke-MgGraphRequest { [CmdletBinding()]param($Method,$Uri,$OutputType) if ($Method -ne 'GET') { throw 'Unexpected preflight write.' };[pscustomobject]@{value=@()} }
Export-ModuleMember -Function Get-MgContext,Disconnect-MgGraph,Connect-MgGraph,Invoke-MgGraphRequest
'@ | Set-Content (Join-Path $moduleDirectory 'Microsoft.Graph.Authentication.psm1') -Encoding UTF8
$config=Join-Path $fixture 'config.json'
@{Graph=@{AuthenticationMode='Delegated';TenantId='11111111-1111-4111-8111-111111111111';ClientId='22222222-2222-4222-8222-222222222222'}} | ConvertTo-Json -Depth 5 | Set-Content $config -Encoding UTF8
$previousModulePath=$env:PSModulePath;$env:PSModulePath=$fixture+[IO.Path]::PathSeparator+$previousModulePath
. (Join-Path $root 'AssistenteIT/Graph.Access.ps1')
$moduleInfo=(Get-Content (Join-Path $root 'assistente-it.json') -Raw | ConvertFrom-Json).Modules[0]
$bootstrapTestTimer=New-Object Windows.Forms.Timer;$bootstrapTestTimer.Interval=50
$testState=@{Mode='';Error='';Seen=$false;Watch=[Diagnostics.Stopwatch]::StartNew()}
$bootstrapTestTimer.Add_Tick({
 $dialogs=@([Windows.Forms.Application]::OpenForms | Where-Object Text -eq 'Assistente IT - Accesso e verifica')
 if ($dialogs.Count -ne 1) { return }
 $dialog=$dialogs[0]
 try {
  if ($testState.Watch.Elapsed.TotalSeconds -gt 12) { throw 'Bootstrap UI timed out.' }
  $open=$dialog.Controls.Find('OpenVerifiedModule',$true)[0]
  $status=$dialog.Controls.Find('GraphAccessStatus',$true)[0]
  if ($testState.Mode -eq 'Success' -and $open.Enabled) {
   $rows=$dialog.Controls.Find('GraphAccessPermissions',$true)[0].Rows
   if ($rows.Count -ne 5 -or @($rows | Where-Object { $_.Cells['Name'].Value -eq 'Eliminazione Entra ID' -and $_.Cells['State'].Value -eq 'Non disponibile' }).Count -ne 1) { throw 'Missing consent is not reported before opening the module.' }
   $testState.Seen=$true;$bootstrapTestTimer.Stop();$open.PerformClick()
  }
  elseif ($testState.Mode -eq 'Denied' -and $status.Text -like 'Accesso o verifica non riusciti*') {
   if ($open.Enabled) { throw 'Module opening is offered after failed authentication.' }
   $testState.Seen=$true;$bootstrapTestTimer.Stop();@($dialog.Controls | Where-Object Text -eq 'Annulla')[0].PerformClick()
  }
  elseif ($testState.Mode -eq 'Hold' -and [BootstrapUiFixture]::Connections -gt 2) {
   if ($open.Enabled) { throw 'Module opening was offered while initial login was pending.' }
   $testState.Seen=$true;$bootstrapTestTimer.Stop();@($dialog.Controls | Where-Object Text -eq 'Annulla')[0].PerformClick()
  }
 }
 catch { $testState.Error=$_.Exception.Message;$bootstrapTestTimer.Stop();@($dialog.Controls | Where-Object Text -eq 'Annulla')[0].PerformClick() }
})
try {
 foreach ($mode in @('Success','Denied','Hold')) {
  $testState.Mode=$mode;$testState.Seen=$false;$testState.Watch.Restart();[BootstrapUiFixture]::Mode=$mode;[BootstrapUiFixture]::Context=$null
  $bootstrapTestTimer.Start();$access=Show-AssistenteITModuleAccess -InstallRoot $root -Module $moduleInfo -ConfigPath $config
  if (-not $testState.Seen -or $testState.Error) { throw ('Native bootstrap failed: '+$testState.Error) }
  if ($mode -eq 'Success') {
   if ($null -eq $access -or $access.Permissions.Count -ne 5) { throw 'Verified access did not reach the module launcher.' }
   $savedAccess=$access
   Import-Module (Join-Path $root 'ComputerExplorer.Core.psm1') -Force
   Connect-ExplorerGraph -Sources Entra,Intune -ForBitLocker -GraphAuthentication @{AuthenticationMode='Delegated';TenantId=$access.TenantId;ClientId=$access.ClientId}
   if ([BootstrapUiFixture]::Connections -ne 1) { throw 'The module requested another login after initial verification.' }
  }
  elseif ($null -ne $access) { throw 'Failed or cancelled bootstrap returned an accepted module session.' }
 }
 if ([BootstrapUiFixture]::Connections -ne 3) { throw 'Native bootstrap retried authentication unexpectedly.' }
 'PASS: module operations reuse the process SDK session after initial verification without a second authentication or credential handoff file.'
 'PASS: the native initial wrapper reports partial consent before module opening and refuses opening after denied or cancelled authentication, with exactly one login attempt each.'
 $GraphAccess=$savedAccess;$tokens=$null;$errors=$null
 $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Start-ComputerExplorer.ps1'),[ref]$tokens,[ref]$errors)
 foreach ($name in @('Test-UiGraphPermission','Show-RemovalSources')) { $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true);Set-Item ('Function:'+$name) $definition.Body.GetScriptBlock() }
 $form=New-Object Windows.Forms.Form;$form.Icon=[Drawing.SystemIcons]::Application
 $pickTimer=New-Object Windows.Forms.Timer;$pickTimer.Interval=60;$pickState=@{Seen=$false;Error=''}
 $pickTimer.Add_Tick({
  $dialogs=@([Windows.Forms.Application]::OpenForms | Where-Object Text -eq 'Elimina computer - origini')
  if ($dialogs.Count -eq 0) { return }
  $pickTimer.Stop();$dialog=$dialogs[0]
  try {
   $entra=$dialog.Controls.Find('RemovalSourceEntra',$true)[0];$intune=$dialog.Controls.Find('RemovalSourceIntune',$true)[0]
   if ($entra.Enabled -or $entra.Checked -or -not $intune.Enabled -or -not $intune.Checked) { throw 'Deletion choices do not reflect the upfront permission report.' }
   $pickState.Seen=$true;$dialog.AcceptButton.PerformClick()
  }
  catch { $pickState.Error=$_.Exception.Message;$dialog.Close() }
 })
 try { $pickTimer.Start();$sources=Show-RemovalSources -Names PC-TEST;if (-not $pickState.Seen -or $pickState.Error -or ($sources -join ',') -ne 'AD,Intune') { throw ('Native permission filtering failed: '+$pickState.Error) } }
 finally { $pickTimer.Stop();$pickTimer.Dispose();$form.Dispose() }
 'PASS: the existing Entra deletion feature is retained but its choice is disabled when the initial report lacks consent; AD and Intune remain available.'
}
finally { $bootstrapTestTimer.Stop();$bootstrapTestTimer.Dispose();$env:PSModulePath=$previousModulePath;Remove-Module Microsoft.Graph.Authentication -Force -ErrorAction SilentlyContinue;Remove-Item $fixture -Recurse -Force }
