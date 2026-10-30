#requires -version 5.1
$ErrorActionPreference='Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { Write-Host 'SKIP: native recovery confirmation and printing renderer require Windows.';return }
$root=Split-Path $PSScriptRoot -Parent
$directory=Join-Path ([IO.Path]::GetTempPath()) ('recovery-ui-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($directory)
$probe=Join-Path $directory 'probe.ps1'
$source=@'
param($Root,$Directory)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
. (Join-Path $Root 'ComputerExplorer.Recovery.UI.ps1')
Import-Module (Join-Path $Root 'BitLocker.Archive.psm1')
Add-Type -Path (Join-Path $Root 'AssistenteIT/Recovery.Print.cs') -ReferencedAssemblies @('System.Drawing','System.Windows.Forms')
Add-Type -TypeDefinition 'public static class RecoveryUiFixture { public static string Text; public static string Mode; public static int Reads; public static int Saves; public static int Prints; }'
[RecoveryUiFixture]::Text=ConvertTo-ExplorerBitLockerRecoveryText -Records @([pscustomobject]@{Name='PC-UNMAPPED';Serial='SERIAL-UI';KeyId='33333333-3333-4333-8333-333333333333';Password=(@(1..8|ForEach-Object{'000011'}) -join '-');Volume='OS';Origins=@('Entra:22222222-2222-4222-8222-222222222222')})
function Get-ExplorerRecoveryCopyWorkerScript { return { param($ModulePath,$PlanId,$Names) [RecoveryUiFixture]::Reads++;if ([RecoveryUiFixture]::Mode -eq 'Fail') { throw 'Synthetic key reread failure.' };if ([RecoveryUiFixture]::Mode -eq 'CancelRead') { while ($true) { Start-Sleep -Milliseconds 20 } };[RecoveryUiFixture]::Text } }
function Save-ExplorerBitLockerRecoveryCopy { param($Text,$ComputerName,$Owner) if ($Text -cne [RecoveryUiFixture]::Text) { throw 'Download received a different key snapshot.' };[IO.File]::WriteAllText((Join-Path $Directory 'recovery-copy.txt'),$Text,(New-Object Text.UTF8Encoding($true)));[RecoveryUiFixture]::Saves++;$true }
function Print-ExplorerBitLockerRecoveryCopy { param($Text,$Owner) if ($Text -cne [RecoveryUiFixture]::Text) { throw 'Print received a different key snapshot.' };[RecoveryUiFixture]::Prints++;$true }
$form=New-Object Windows.Forms.Form;$form.Icon=[Drawing.SystemIcons]::Application;$form.Font=New-Object Drawing.Font('Segoe UI',10)
$script:Worker=[RunspaceFactory]::CreateRunspace();$script:Worker.ApartmentState='STA';$script:Worker.ThreadOptions='ReuseThread';$script:Worker.Open()
$entry=[pscustomobject]@{Name='PC-UNMAPPED';Error='';Backup=[pscustomobject]@{ComputerId=0;GlpiName='';Serial='SERIAL-UI';Keys=@();KeyCount=1;GlpiMatchCount=2;ArchiveAvailable=$false;Warning='GLPI duplicato';RequiresMappingConfirmation=$false};Targets=@()}
$plan=[pscustomobject]@{PlanId='synthetic';Sources=@('Entra');ArchiveOnly=$false;Entries=@($entry)}
$recoveryProbe=@{Mode='';Stage=0;Seen=$false;Error='';Watch=[Diagnostics.Stopwatch]::StartNew()}
$recoveryProbeTimer=New-Object Windows.Forms.Timer;$recoveryProbeTimer.Interval=40
$recoveryProbeTimer.Add_Tick({
 $lossWindows=@([Windows.Forms.Application]::OpenForms | Where-Object Name -eq 'BitLockerLossDialog')
 if (-not $lossWindows.Count) { return }
 $lossWindow=$lossWindows[0]
 try {
  if ($recoveryProbe.Watch.Elapsed.TotalSeconds -gt 10) { throw 'Recovery dialog timed out.' }
  $check=$lossWindow.Controls.Find('ConfirmBitLockerLoss',$true)[0];$confirmButton=$lossWindow.Controls.Find('ConfirmRemovalWithoutGlpi',$true)[0]
  $downloadButton=$lossWindow.Controls.Find('DownloadBitLockerKeys',$true)[0];$printButton=$lossWindow.Controls.Find('PrintBitLockerKeys',$true)[0];$cancelButton=$lossWindow.Controls.Find('CancelBitLockerLoss',$true)[0]
  if ($recoveryProbe.Stage -eq 0) {
   if ($check.Checked -or $confirmButton.Enabled -or $lossWindow.Controls.Find('BitLockerLossWarning',$true)[0].Text -notlike '*perse*') { throw 'Unchecked explicit risk confirmation or warning is missing.' }
   $recoveryProbe.Seen=$true
   if ($recoveryProbe.Mode -eq 'Cancel') { $recoveryProbeTimer.Stop();$cancelButton.PerformClick();return }
   if ($recoveryProbe.Mode -eq 'NoKeys' -and ($downloadButton.Enabled -or $printButton.Enabled)) { throw 'Empty recovery set enables copy buttons.' }
   if ($recoveryProbe.Mode -in @('Accept','NoKeys')) {
    $check.Checked=$true;if (-not $confirmButton.Enabled) { throw 'Explicit acceptance did not enable continuation without a mandatory copy.' }
    $recoveryProbeTimer.Stop();$confirmButton.PerformClick();return
   }
   $recoveryProbe.Stage=1;$downloadButton.PerformClick();return
  }
  if ($recoveryProbe.Mode -eq 'Copy' -and [RecoveryUiFixture]::Saves -eq 1 -and $recoveryProbe.Stage -eq 1) { $recoveryProbe.Stage=2;$printButton.PerformClick();return }
  if ($recoveryProbe.Mode -eq 'Copy' -and [RecoveryUiFixture]::Prints -eq 1) {
   if ([RecoveryUiFixture]::Reads -ne 1 -or [IO.File]::ReadAllText((Join-Path $Directory 'recovery-copy.txt')) -cne [RecoveryUiFixture]::Text) { throw 'Download/print did not share one verified snapshot.' }
   $bitmap=New-Object Drawing.Bitmap($lossWindow.Width,$lossWindow.Height)
   try { $lossWindow.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$bitmap.Width,$bitmap.Height)));$memory=New-Object IO.MemoryStream;try { $bitmap.Save($memory,[Drawing.Imaging.ImageFormat]::Png);Write-Host ('RECOVERY_UI_PNG:'+[Convert]::ToBase64String($memory.ToArray())) } finally { $memory.Dispose() } }
   finally { $bitmap.Dispose() }
   $check.Checked=$true;$recoveryProbeTimer.Stop();$confirmButton.PerformClick();return
  }
  if ($recoveryProbe.Mode -eq 'Fail' -and $lossWindow.Controls.Find('RecoveryCopyStatus',$true)[0].Text -like '*Ripetere*') { $check.Checked=$true;if ($confirmButton.Enabled) { throw 'A key reread failure can be overridden by checking the risk box.' };$recoveryProbeTimer.Stop();$cancelButton.PerformClick();return }
  if ($recoveryProbe.Mode -eq 'CancelRead' -and [RecoveryUiFixture]::Reads -eq 1) { $recoveryProbeTimer.Stop();$cancelButton.PerformClick();return }
 }
 catch { $recoveryProbe.Error=$_.Exception.Message;$recoveryProbeTimer.Stop();$lossWindow.Close() }
})
try {
 foreach ($mode in @('Cancel','Accept','Copy','Fail','CancelRead','NoKeys')) {
  $recoveryProbe.Mode=$mode;$recoveryProbe.Stage=0;$recoveryProbe.Seen=$false;$recoveryProbe.Error='';$recoveryProbe.Watch.Restart()
  [RecoveryUiFixture]::Mode=$mode;[RecoveryUiFixture]::Reads=0;[RecoveryUiFixture]::Saves=0;[RecoveryUiFixture]::Prints=0
  $entry.Backup.KeyCount=1;if ($mode -eq 'NoKeys') { $entry.Backup.KeyCount=0 }
  $recoveryProbeTimer.Start();$decision=Show-ExplorerBitLockerLossConfirmation -Plan $plan -Entries @($entry) -Owner $form
  if (-not $recoveryProbe.Seen -or $recoveryProbe.Error) { throw ('Native recovery confirmation failed: '+$mode+' '+$recoveryProbe.Error) }
  if ($mode -in @('Accept','Copy','NoKeys')) { if ($null -eq $decision -or $decision.Names.Count -ne 1 -or $decision.Names[0] -ne 'PC-UNMAPPED') { throw 'Explicit per-computer acceptance was lost.' } }
  elseif ($null -ne $decision) { throw 'Cancelled or failed recovery confirmation authorized removal.' }
 }
 'PASS: native risk dialog starts unconfirmed, supports optional download and print with one cached snapshot, and allows explicit acceptance without forcing a copy.'
 'PASS: cancellation, key reread failures and zero-key cases do not bypass consent or leave a worker running.'
 $tokens=$null;$parseErrors=$null;$uiAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'Start-ComputerExplorer.ps1'),[ref]$tokens,[ref]$parseErrors)
 . (Join-Path $Root 'ComputerExplorer.Removal.UI.ps1')
 foreach ($name in @('Get-UiSetting','Show-RemovalPreview')) { $definition=$uiAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true);Set-Item ('Function:'+$name) $definition.Body.GetScriptBlock() }
 $entry.Backup.KeyCount=1;$entry.Targets=@([pscustomobject]@{Source='AD';DomainController='synthetic.invalid';Id='computer-id';DistinguishedName='CN=PC-UNMAPPED,DC=invalid';AdChildren=@([pscustomobject]@{Id='child-id';DistinguishedName='CN=Recovery,CN=PC-UNMAPPED,DC=invalid';ObjectClass='msFVE-RecoveryInformation'})})
 $plan.Sources=@('AD');$recoveryProbe.Mode='Accept';$recoveryProbe.Stage=0;$recoveryProbe.Seen=$false;$recoveryProbe.Watch.Restart()
 $previewProbe=@{Seen=$false;Error=''};$previewProbeTimer=New-Object Windows.Forms.Timer;$previewProbeTimer.Interval=50
 $previewProbeTimer.Add_Tick({
  $previews=@([Windows.Forms.Application]::OpenForms | Where-Object Text -eq 'Conferma eliminazione - oggetti verificati');if (-not $previews.Count) { return }
  $previewWindow=$previews[0];$previewProbeTimer.Stop()
  try { $childCheck=$previewWindow.Controls.Find('AdChildrenConsent',$true)[0];$removeButton=$previewWindow.Controls.Find('ConfirmRemoval',$true)[0];if (-not $childCheck.Visible -or $removeButton.Enabled) { throw 'AD child consent was lost in the combined flow.' };$childCheck.Checked=$true;$previewProbe.Seen=$true;$removeButton.PerformClick() }
  catch { $previewProbe.Error=$_.Exception.Message;$previewWindow.Close() }
 })
 try {
  $recoveryProbeTimer.Start();$previewProbeTimer.Start();$decision=Show-RemovalPreview $plan
  if (-not $previewProbe.Seen -or $previewProbe.Error -or -not $recoveryProbe.Seen -or $recoveryProbe.Error -or -not $decision.IncludeAdChildren -or $decision.ConfirmBitLockerLossFor.Count -ne 1 -or $decision.ConfirmBitLockerLossFor[0] -ne 'PC-UNMAPPED') { throw ('Combined preview/loss confirmation failed: '+$previewProbe.Error+' '+$recoveryProbe.Error) }
 }
 finally { $previewProbeTimer.Stop();$previewProbeTimer.Dispose() }
 'PASS: production removal preview requires the separate AD-child and BitLocker-loss confirmations and forwards only the explicitly accepted computer names.'
 $bitmap=New-Object Drawing.Bitmap(600,800);$graphics=[Drawing.Graphics]::FromImage($bitmap)
 try {
  $longText=([RecoveryUiFixture]::Text+[Environment]::NewLine)*40;$offset=0;$pages=0
  while ($offset -lt $longText.Length) { $next=[AssistenteIT.RecoveryPrinter]::DrawPage($graphics,(New-Object Drawing.RectangleF(10,10,400,300)),$longText,$offset);if ($next -le $offset -or ++$pages -gt 100) { throw 'Print pagination did not progress.' };$offset=$next }
  if ($pages -le 1 -or $offset -ne $longText.Length) { throw 'Print pagination lost or clipped recovery text.' }
 }
 finally { $graphics.Dispose();$bitmap.Dispose() }
 'PASS: production printing renderer paginates every character of long multi-key reports without using a physical printer.'
}
finally { $recoveryProbeTimer.Stop();$recoveryProbeTimer.Dispose();$script:Worker.Close();$script:Worker.Dispose();$form.Dispose() }
'@
try {
 [IO.File]::WriteAllText($probe,$source,(New-Object Text.UTF8Encoding($true)))
 $info=New-Object Diagnostics.ProcessStartInfo;$info.FileName=Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell/v1.0/powershell.exe'
 $info.Arguments='-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "{0}" -Root "{1}" -Directory "{2}"' -f $probe,$root,$directory
 $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
 $process=[Diagnostics.Process]::Start($info)
 try { $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync();if (-not $process.WaitForExit(45000)) { $process.Kill();throw 'Native recovery UI test timed out.' };$out=$stdout.GetAwaiter().GetResult();$err=$stderr.GetAwaiter().GetResult();if ($process.ExitCode -ne 0) { throw ('Native recovery test failed: '+$err+$out) };Write-Host $out }
 finally { $process.Dispose() }
}
finally { Remove-Item $directory -Recurse -Force -ErrorAction SilentlyContinue }
