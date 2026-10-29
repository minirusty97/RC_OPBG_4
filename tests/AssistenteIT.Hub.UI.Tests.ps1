#requires -version 5.1
$ErrorActionPreference='Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { Write-Host 'SKIP: native hub workflow requires Windows.';return }
$root=Split-Path $PSScriptRoot -Parent
$source=Get-Content (Join-Path $root 'Start-AssistenteIT.ps1') -Raw -Encoding UTF8
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
 Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class HubUiFixture { public static object Context; public static int Connections; [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr handle,uint message,IntPtr w,IntPtr l); }'
 $sdkDirectory=Join-Path $paths.DataRoot 'FakeSdk/Microsoft.Graph.Authentication';[void][IO.Directory]::CreateDirectory($sdkDirectory)
 @"
function Get-MgContext { [CmdletBinding()]param() return [HubUiFixture]::Context }
function Disconnect-MgGraph { [CmdletBinding()]param() [HubUiFixture]::Context=`$null }
function Connect-MgGraph {
 [CmdletBinding()]param(`$Scopes,`$TenantId,`$ClientId,`$Environment,`$ContextScope,[switch]`$NoWelcome)
 [HubUiFixture]::Connections++
 [HubUiFixture]::Context=[pscustomobject]@{AuthType='Delegated';TenantId=`$TenantId;ClientId=`$ClientId;Environment='Global';ContextScope='CurrentUser';Account='synthetic@example.invalid';AppName='Synthetic app';Scopes=@('Device.Read.All','DeviceManagementManagedDevices.Read.All','BitlockerKey.Read.All')}
}
function Invoke-MgGraphRequest { [CmdletBinding()]param(`$Method,`$Uri,`$OutputType) if (`$Method -ne 'GET') { throw 'Unexpected write in hub verification.' };[pscustomobject]@{value=@()} }
Export-ModuleMember -Function Get-MgContext,Disconnect-MgGraph,Connect-MgGraph,Invoke-MgGraphRequest
"@ | Set-Content (Join-Path $sdkDirectory 'Microsoft.Graph.Authentication.psm1') -Encoding UTF8
 $env:PSModulePath=(Split-Path $sdkDirectory -Parent)+[IO.Path]::PathSeparator+$env:PSModulePath
 $configuration=Get-Content $paths.ConfigPath -Raw | ConvertFrom-Json
 $configuration.Graph.AuthenticationMode='Delegated';$configuration.Graph.TenantId='11111111-1111-4111-8111-111111111111';$configuration.Graph.ClientId='22222222-2222-4222-8222-222222222222'
 $configuration | ConvertTo-Json -Depth 10 | Set-Content $paths.ConfigPath -Encoding UTF8
 $form.Show();[Windows.Forms.Application]::DoEvents()
 $button=$script:ModuleButtons['computer-explorer']
 if ($button.Enabled -or $button.Text -ne 'Apri modulo' -or $accessButton.Parent -ne $toolbar -or $accessButton.Text -ne 'Accesso' -or $releaseButton.Text -ne 'Cerca aggiornamenti') { throw 'Hub exposes login on module cards or enables modules before verification.' }
 if ([AssistenteIT.WindowIdentity]::CurrentId() -ne 'AssistenteIT.Desktop' -or [AssistenteIT.WindowIdentity]::WindowId($form.Handle) -ne 'AssistenteIT.Desktop' -or $null -eq $form.Icon -or -not [Windows.Forms.Application]::RenderWithVisualStyles) { throw 'Application identity, icon or native visual style is missing.' }
 'PASS: the hub has a separate bottom Accesso button, disabled module cards, Cerca aggiornamenti and its own application identity/icon with visual styles.'
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
 if (-not $hubProbeState.Seen -or $hubProbeState.Error -or -not $button.Enabled -or $script:ModuleAccessLabels['computer-explorer'].Text -ne 'Sola lettura') { throw ('Initial access did not enable the correct module mode: '+$hubProbeState.Error) }
 'PASS: bottom Accesso verifies the common session once and enables the module in read-only mode without opening it automatically.'
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
 $bitmap=New-Object Drawing.Bitmap($form.ClientSize.Width,$form.ClientSize.Height)
 try { $form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$bitmap.Width,$bitmap.Height)));$memory=New-Object IO.MemoryStream;try { $bitmap.Save($memory,[Drawing.Imaging.ImageFormat]::Png);Write-Host ('HUB_UI_PNG:'+ [Convert]::ToBase64String($memory.ToArray())) } finally { $memory.Dispose() } }
 finally { $bitmap.Dispose() }
}
finally {
 if ($null -ne $hubProbeTimer) { $hubProbeTimer.Stop();$hubProbeTimer.Dispose() }
 $moduleTimer.Stop();$moduleTimer.Dispose();$updateTimer.Stop();$updateTimer.Dispose()
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
