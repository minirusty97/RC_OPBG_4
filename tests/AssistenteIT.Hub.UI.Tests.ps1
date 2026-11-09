#requires -version 5.1
$ErrorActionPreference='Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { Write-Host 'SKIP: native hub workflow requires Windows.';return }
$root=Split-Path $PSScriptRoot -Parent
$source=Get-Content (Join-Path $root 'Start-AssistenteIT.ps1') -Raw -Encoding UTF8
$restoreCall='            Initialize-AssistenteITModuleAccess -Module $Definition -ConfigPath $Config -SessionPath $SessionPath -WindowHandle $WindowHandle'
if (-not $source.Contains($restoreCall)) { throw 'The hub startup worker was not found.' }
$fixtureRestore=@'
            $core=Get-Module AssistenteIT.Core
            & $core {
                function script:Restore-AssistenteITGraphContext {
                    param($Path,$Authentication,$WindowHandle)
                    if (-not [IO.File]::Exists($Path) -or $WindowHandle -eq [IntPtr]::Zero) { throw 'The wrapper lost its session path or window handle.' }
                    [HubUiFixture]::Restores++
                    if ([HubUiFixture]::RestoreValid) {
                        Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
                        return [HubUiFixture]::Context
                    }
                }
            }
'@
$source=$source.Replace($restoreCall,$fixtureRestore+[Environment]::NewLine+$restoreCall)
$updateCall='                ''Check'' { Get-AssistenteITUpdateStatus -CurrentVersion $Version }'
$glpiCall='            Get-AssistenteITGlpiStatus -ConfigPath $Config -EnvPath $EnvPath'
if (-not $source.Contains($updateCall) -or -not $source.Contains($glpiCall)) { throw 'Hub status workers not found.' }
$source=$source.Replace($updateCall,'                ''Check'' { Get-Content -LiteralPath (Join-Path (Split-Path $Directory -Parent) ''fixture-update.json'') -Raw | ConvertFrom-Json }')
$source=$source.Replace($glpiCall,@'
            $fixture=Join-Path (Split-Path $Config -Parent) 'fixture-glpi.json'
            if (Test-Path -LiteralPath $fixture) { Get-Content -LiteralPath $fixture -Raw | ConvertFrom-Json }
            else { Get-AssistenteITGlpiStatus -ConfigPath $Config -EnvPath $EnvPath }
'@)
$marker="try {`r`n    if (`$SmokeTestOutput) {"
$position=$source.IndexOf($marker,[StringComparison]::Ordinal)
if ($position -lt 0) { $marker="try {`n    if (`$SmokeTestOutput) {";$position=$source.IndexOf($marker,[StringComparison]::Ordinal) }
if ($position -lt 0) { throw 'Hub entry point not found.' }
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('hub-ui-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temporary)
$probePath=Join-Path $root ('hub-ui-'+[guid]::NewGuid().ToString('N')+'.local.ps1')
$probe=@'
$hubProbeTimer=$null
try {
 Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class HubUiFixture { public static object Context; public static int Connections; public static int Restores; public static bool RestoreValid; public static bool RejectIntune; [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr handle,uint message,IntPtr w,IntPtr l); }'
 $sdkDirectory=Join-Path $paths.DataRoot 'FakeSdk/Microsoft.Graph.Authentication';[void][IO.Directory]::CreateDirectory($sdkDirectory)
 @"
function Get-MgContext { [CmdletBinding()]param() return [HubUiFixture]::Context }
function Disconnect-MgGraph { [CmdletBinding()]param() [HubUiFixture]::Context=`$null }
function Connect-MgGraph {
 [CmdletBinding()]param(`$Scopes,`$TenantId,`$ClientId,`$Environment,`$ContextScope,[switch]`$NoWelcome)
 [HubUiFixture]::Connections++
 [HubUiFixture]::Context=[pscustomobject]@{AuthType='Delegated';TenantId=`$TenantId;ClientId=`$ClientId;Environment='Global';ContextScope='CurrentUser';Account='synthetic@example.invalid';AppName='Synthetic app';Scopes=@('Device.Read.All','DeviceManagementManagedDevices.Read.All','BitlockerKey.Read.All')}
}
function Invoke-MgGraphRequest {
 [CmdletBinding()]param(`$Method,`$Uri,`$OutputType,`$Headers)
 if (`$Method -ne 'GET') { throw 'Unexpected write in hub verification.' }
 if ([HubUiFixture]::RejectIntune -and `$Uri -like '*managedDevices?*') {
   `$failure=New-Object InvalidOperationException('Synthetic token rejection.')
   `$failure.Data['AssistenteIT.HttpStatus']=401
   throw `$failure
 }
 [pscustomobject]@{value=@()}
}
Export-ModuleMember -Function Get-MgContext,Disconnect-MgGraph,Connect-MgGraph,Invoke-MgGraphRequest
"@ | Set-Content (Join-Path $sdkDirectory 'Microsoft.Graph.Authentication.psm1') -Encoding UTF8
 $env:PSModulePath=(Split-Path $sdkDirectory -Parent)+[IO.Path]::PathSeparator+$env:PSModulePath
 $prerequisites.GraphAvailable=$true
 Set-AssistenteITHubStatus GraphSdk Ready 'Disponibile'
 $configuration=Get-Content $paths.ConfigPath -Raw | ConvertFrom-Json
 $configuration.Graph.AuthenticationMode='Delegated';$configuration.Graph.TenantId='11111111-1111-4111-8111-111111111111';$configuration.Graph.ClientId='22222222-2222-4222-8222-222222222222'
 $configuration | ConvertTo-Json -Depth 10 | Set-Content $paths.ConfigPath -Encoding UTF8
 $form.Show();[Windows.Forms.Application]::DoEvents()
 $settingsProbe=@{Seen=$false;Error=''};$settingsTimer=New-Object Windows.Forms.Timer;$settingsTimer.Interval=50
 $settingsTimer.Add_Tick({
  $windows=@([Windows.Forms.Application]::OpenForms | Where-Object Text -like 'Impostazioni - *');if (-not $windows.Count) { return };$settingsTimer.Stop();$window=$windows[0]
  try {
   $dc=$window.Controls.Find('ExplorerSearchDc',$true)[0]
   $tabs=@($window.Controls | Where-Object { $_ -is [Windows.Forms.TabControl] })[0]
   $tabs.SelectedTab=$dc.Parent
   if ($window.Controls.Find('ExplorerAllSearchDcs',$true).Count -or $tabs.SelectedTab.Text -ne 'Ricerca computer' -or
       @($dc.Parent.Controls | Where-Object Text -like 'DC principale*').Count -ne 1) { throw 'Primary DC settings are missing or still offer the retired single-DC mode.' }
   $dc.Text='dc1.example.invalid';$settingsProbe.Seen=$true
   $bitmap=New-Object Drawing.Bitmap($window.Width,$window.Height)
   try { $window.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$bitmap.Width,$bitmap.Height)));$memory=New-Object IO.MemoryStream;try { $bitmap.Save($memory,[Drawing.Imaging.ImageFormat]::Png);Write-Host ('SEARCH_SETTINGS_UI_PNG:'+ [Convert]::ToBase64String($memory.ToArray())) } finally {$memory.Dispose()} } finally {$bitmap.Dispose()}
   $window.Controls.Find('SaveSettings',$true)[0].PerformClick()
  }
  catch { $settingsProbe.Error=$_.Exception.Message;$window.Close() }
 })
 try { $settingsTimer.Start();$settingsButton.PerformClick() } finally {$settingsTimer.Stop();$settingsTimer.Dispose()}
 $saved=Get-Content $paths.ConfigPath -Raw|ConvertFrom-Json
 if (-not $settingsProbe.Seen -or $settingsProbe.Error -or $saved.Search.DomainController -ne 'dc1.example.invalid' -or -not $saved.Search.AllDomainControllers) { throw ('Search settings UI failed: '+$settingsProbe.Error) }
 'PASS: native search settings select the primary DC for an all-controller search and save without opening Graph login.'

 Start-AssistenteITSavedAccessCheck
 if ($script:StatusRows.Microsoft.State -ne 'Error' -or $script:StatusRows.Microsoft.Value.Text -ne 'Accesso richiesto' -or
     [HubUiFixture]::Connections -ne 0 -or [HubUiFixture]::Restores -ne 0) { throw 'Startup without a saved session attempted to authenticate or failed to require Accesso.' }
 $button=$script:ModuleButtons['computer-explorer']
 if ($button.Enabled -or $button.Text -ne 'Apri modulo' -or $accessButton.Parent -ne $toolbar -or $accessButton.Text -ne 'Accesso' -or $releaseButton.Text -ne 'Cerca aggiornamenti') { throw 'Hub exposes login on module cards or enables modules before verification.' }
 if ([AssistenteIT.WindowIdentity]::CurrentId() -ne 'AssistenteIT.Desktop' -or [AssistenteIT.WindowIdentity]::WindowId($form.Handle) -ne 'AssistenteIT.Desktop' -or $null -eq $form.Icon -or -not [Windows.Forms.Application]::RenderWithVisualStyles) { throw 'Application identity, icon or native visual style is missing.' }
 $moduleLabel=$script:ModuleAccessLabels['computer-explorer']
 if ($moduleLabel.Parent -ne $button.Parent -or $moduleLabel.Right -gt $button.Left -or $button.Parent.Height -gt 75 -or
     $accessPanel.Parent -ne $components.Parent -or $accessPanel.Right -gt $components.Left -or $script:StatusRows.Count -ne 9 -or
     $script:StatusRows.Microsoft.Dot.ForeColor -ne $hubColors.Error -or
     $script:StatusRows['intune-read'].Dot.Top -ne $script:StatusRows.Repository.Dot.Top -or
     $script:StatusRows.GLPI.Value.Parent -ne $accessPanel -or
     $script:StatusRows.GLPI.Value.Bottom -gt $accessPanel.ClientSize.Height) { throw 'Hub status is ungrouped, clipped, lacks colored dots, or cards do not align access left of the button.' }
 'PASS: the compact hub places module access beside its button and groups GLPI with the access statuses.'
 foreach ($control in @($accessPanel,$components,$button.Parent,$button,$accessButton)) {
  if ($null -eq $control.Region -or $control.Region.IsVisible(0,0) -or
      -not $control.Region.IsVisible(($control.Width - 1),[int]($control.Height / 2))) { throw ('Control lost its rounded bounds: ' + $control.Name) }
 }
 if ($button.BackColor -ne $hubColors.DisabledFill -or $button.ForeColor -ne $hubColors.DisabledInk -or
     $accessButton.BackColor -ne $settingsButton.BackColor -or $accessButton.ForeColor -ne $settingsButton.ForeColor) {
  throw 'Disabled buttons or Accesso use the wrong palette.'
 }
 'PASS: native module cards, status panels and buttons have rounded corners and use a distinct disabled palette.'
 $hubProbeState=@{Seen=$false;Error='';Watch=[Diagnostics.Stopwatch]::StartNew()}
 $hubProbeTimer=New-Object Windows.Forms.Timer;$hubProbeTimer.Interval=50
 $hubProbeTimer.Add_Tick({
  $windows=@([Windows.Forms.Application]::OpenForms | Where-Object Text -eq 'Assistente IT - Accesso e verifica')
  if ($windows.Count -eq 0) { return }
  $window=$windows[0]
  try {
   if ($hubProbeState.Watch.Elapsed.TotalSeconds -gt 15) { throw 'Hub login timed out.' }
   $confirm=$window.Controls.Find('OpenVerifiedModule',$true)[0]
   if (-not $confirm.Enabled) { return }
   if ($confirm.Text -ne 'Conferma accesso') { throw 'Separate login still offers to open a module.' }
   $hubProbeState.Seen=$true;$hubProbeTimer.Stop();$confirm.PerformClick()
  }
  catch { $hubProbeState.Error=$_.Exception.Message;$hubProbeTimer.Stop();@($window.Controls | Where-Object Text -eq 'Annulla')[0].PerformClick() }
 })
 $hubProbeTimer.Start();$accessButton.PerformClick()
 if (-not $hubProbeState.Seen -or $hubProbeState.Error -or -not $button.Enabled -or $button.BackColor -ne $hubColors.Action -or
     $button.ForeColor -ne $hubColors.Ink -or $script:ModuleAccessLabels['computer-explorer'].Text -ne 'Sola lettura') { throw ('Initial access did not enable the correct module mode or palette: '+$hubProbeState.Error) }
 'PASS: bottom Accesso verifies the common session once and enables the module in read-only mode without opening it automatically.'
 '{}' | Set-Content -LiteralPath $paths.GraphSessionPath -Encoding UTF8
 foreach ($case in @(@{Restore=$false;Reject=$false;Expected=$false},@{Restore=$true;Reject=$true;Expected=$false},@{Restore=$true;Reject=$false;Expected=$true})) {
  [HubUiFixture]::RestoreValid=$case.Restore
  [HubUiFixture]::RejectIntune=$case.Reject
  Start-AssistenteITSavedAccessCheck
  if ($button.Enabled -or $script:StatusRows.Microsoft.State -ne 'Pending') { throw 'Startup kept the old authorization while checking.' }
  $restoreWatch=[Diagnostics.Stopwatch]::StartNew()
  while ($null -ne $script:AccessTask -and $restoreWatch.Elapsed.TotalSeconds -lt 10) { [Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 20 }
  $expectedState='Error';if ($case.Expected) { $expectedState='Ready' }
  if ($null -ne $script:AccessTask -or $button.Enabled -ne $case.Expected -or $script:StatusRows.Microsoft.State -ne $expectedState -or
      [HubUiFixture]::Connections -ne 1 -or [Windows.Forms.Application]::OpenForms.Count -ne 1) { throw 'Silent startup opened a login or enabled modules after an invalid or rejected session.' }
 }
 if ([HubUiFixture]::Restores -ne 3 -or $script:StatusRows.Microsoft.Value.Text -ne 'synthetic@example.invalid' -or
     $script:StatusRows['entra-read'].State -ne 'Ready' -or $script:StatusRows['intune-read'].State -ne 'Ready' -or
     $script:StatusRows['groups-read'].State -ne 'Error') { throw 'Missing account, successful reads or separate denied permission status.' }
 'PASS: silent startup opens no additional windows, requires Accesso after a missing or rejected session and enables verified modules after restore.'

 $serviceWatch=[Diagnostics.Stopwatch]::StartNew()
 while ($null -ne $script:GlpiTask -and $serviceWatch.Elapsed.TotalSeconds -lt 8) { [Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 20 }
 if ($script:StatusRows.GLPI.Value.Text -ne 'Non configurato') { throw 'Unconfigured GLPI showed a live status.' }
 '{"State":"Ready","Account":"inventario.test","Detail":""}' | Set-Content -LiteralPath (Join-Path $paths.ConfigDirectory 'fixture-glpi.json') -Encoding UTF8
 Start-AssistenteITGlpiCheck
 $serviceWatch.Restart()
 while ($null -ne $script:GlpiTask -and $serviceWatch.Elapsed.TotalSeconds -lt 8) { [Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 20 }
 if ($script:StatusRows.GLPI.State -ne 'Ready' -or $script:StatusRows.GLPI.Value.Text -notlike '*inventario.test') { throw 'GLPI API username was not shown in the status panel.' }

 $updateFixture=Join-Path $paths.DataRoot 'fixture-update.json'
 foreach ($repoCase in @(@{State='Closed';Text='Chiusa'},@{State='Offline';Text='Nessuna connessione'},@{State='Available';Text='Disponibile'})) {
  $fixtureUpdate=$null
  if ($repoCase.State -eq 'Available') { $fixtureUpdate=@{Available=$false;Version=$manifest.Version} }
  @{RepositoryState=$repoCase.State;RepositoryDetail='Synthetic probe';Update=$fixtureUpdate;UpdateDetail='Synthetic feed status'} |
    ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $updateFixture -Encoding UTF8
  Start-AssistenteITUpdateOperation Check
  $serviceWatch.Restart()
  while ($null -ne $script:UpdateInvocation -and $serviceWatch.Elapsed.TotalSeconds -lt 8) { [Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 20 }
  $updateState='Error';if ($repoCase.State -eq 'Available') { $updateState='Ready' }
  if ($script:StatusRows.Repository.Value.Text -ne $repoCase.Text -or $script:StatusRows.Update.State -ne $updateState) { throw 'Repository and updater states did not reach the native panel independently.' }
 }
 'PASS: native status panel shows GLPI account and distinguishes repository closed, offline and available.'
 $button.PerformClick();$watch=[Diagnostics.Stopwatch]::StartNew();$moduleWindow=$null
 while ($null -eq $moduleWindow -and $watch.Elapsed.TotalSeconds -lt 12) {
  [Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 20
  $windows=@([Windows.Forms.Application]::OpenForms | Where-Object { $_.Text -like 'Computer Explorer*' })
  if ($windows.Count) { $moduleWindow=$windows[0] }
 }
 if ($null -eq $moduleWindow -or $moduleWindow.Text -notlike '*Sola lettura*' -or [HubUiFixture]::Connections -ne 1 -or $accessButton.Enabled) { throw 'Opening a verified module repeated login, lost read-only mode or allowed identity changes.' }
 $delete=$moduleWindow.Controls.Find('DeleteComputers',$true)[0];$archive=$moduleWindow.Controls.Find('ArchiveBitLocker',$true)[0]
 if ($delete.Enabled -or $archive.Enabled) { throw 'Read-only module exposes writing controls.' }
 [void][HubUiFixture]::PostMessage($moduleWindow.Handle,0x0010,[IntPtr]::Zero,[IntPtr]::Zero)
 $watch.Restart()
 while ((Get-AssistenteITOpenModules) -gt 0 -and $watch.Elapsed.TotalSeconds -lt 10) { [Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 20 }
 if ((Get-AssistenteITOpenModules) -ne 0) { throw 'Closed module did not release its worker.' }
 'PASS: a verified module opens with the existing process session, locks account changes while open and releases its worker on close; read-only writing controls stay disabled.'
 $watch.Restart()
 while (-not $accessButton.Enabled -and $watch.Elapsed.TotalSeconds -lt 2) { [Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 20 }
 $bitmap=New-Object Drawing.Bitmap($form.ClientSize.Width,$form.ClientSize.Height)
 try { $form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$bitmap.Width,$bitmap.Height)));$memory=New-Object IO.MemoryStream;try { $bitmap.Save($memory,[Drawing.Imaging.ImageFormat]::Png);Write-Host ('HUB_UI_PNG:'+ [Convert]::ToBase64String($memory.ToArray())) } finally { $memory.Dispose() } }
 finally { $bitmap.Dispose() }
}
finally {
 if ($null -ne $hubProbeTimer) { $hubProbeTimer.Stop();$hubProbeTimer.Dispose() }
 $accessTimer.Stop();$accessTimer.Dispose()
 if ($null -ne $script:AccessTask) { $script:AccessTask.Pipeline.Stop();$script:AccessTask.Pipeline.Dispose() }
 $moduleTimer.Stop();$moduleTimer.Dispose();$updateTimer.Stop();$updateTimer.Dispose()
 if ($null -ne $script:UpdatePipeline) { $script:UpdatePipeline.Stop();$script:UpdatePipeline.Dispose() }
 if ($null -ne $script:UpdateWorker) { $script:UpdateWorker.Close();$script:UpdateWorker.Dispose() }
 $glpiTimer.Stop();$glpiTimer.Dispose()
 if ($null -ne $script:GlpiTask) { $script:GlpiTask.Pipeline.Stop();$script:GlpiTask.Pipeline.Dispose() }
 if ((Get-AssistenteITOpenModules) -eq 0) { $form.Dispose() }
 $applicationIcon.Dispose();$activity.Dispose()
}
'@
try {
 [IO.File]::WriteAllText($probePath,$source.Substring(0,$position)+$probe,(New-Object Text.UTF8Encoding($true)))
 $info=New-Object Diagnostics.ProcessStartInfo
 $info.FileName=Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell/v1.0/powershell.exe'
 $info.Arguments='-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "{0}" -DataRoot "{1}" -SmokeTestOutput "{2}"' -f $probePath,(Join-Path $temporary 'user'),(Join-Path $temporary 'ignored.json')
 $info.UseShellExecute=$false;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.CreateNoWindow=$true
 $process=[Diagnostics.Process]::Start($info)
 try {
  $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
  if (-not $process.WaitForExit(45000)) { $process.Kill();throw 'Native hub workflow timed out.' }
  $out=$stdout.GetAwaiter().GetResult();$err=$stderr.GetAwaiter().GetResult()
  if ($process.ExitCode -ne 0) { throw ('Hub workflow failed: '+$err+$out) }
  Write-Host $out
 }
 finally { $process.Dispose() }
}
finally { Remove-Item $probePath -Force -ErrorAction SilentlyContinue;Remove-Item $temporary -Recurse -Force -ErrorAction SilentlyContinue }
