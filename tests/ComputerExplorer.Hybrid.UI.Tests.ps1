#requires -version 5.1
$ErrorActionPreference='Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { Write-Host 'SKIP: native hybrid confirmation and BitLocker diagnostics require Windows.';return }
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
$directory=Join-Path ([IO.Path]::GetTempPath()) ('hybrid-ui-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($directory)
$probe=Join-Path $directory 'probe.ps1'
$source=@'
param([string]$Root)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
[Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'Start-ComputerExplorer.ps1'),[ref]$tokens,[ref]$errors)
foreach ($name in @('Get-UiSetting','Show-RemovalPreview','Show-ArchivedBitLockerKeys')) { $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true);Set-Item ('Function:'+$name) $definition.Body.GetScriptBlock() }
function Write-UiImage {
 param($Window,[string]$Prefix)
 $bitmap=New-Object Drawing.Bitmap($Window.Width,$Window.Height)
 try { $Window.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$bitmap.Width,$bitmap.Height)));$stream=New-Object IO.MemoryStream;try { $bitmap.Save($stream,[Drawing.Imaging.ImageFormat]::Png);Write-Host ($Prefix+':'+[Convert]::ToBase64String($stream.ToArray())) } finally { $stream.Dispose() } }
 finally { $bitmap.Dispose() }
}
$form=New-Object Windows.Forms.Form;$form.Font=New-Object Drawing.Font('Segoe UI',9);$form.Icon=[Drawing.SystemIcons]::Application
$entry=[pscustomobject]@{Name='PC-HYBRID';Error='';Backup=[pscustomobject]@{ComputerId=1;Serial='SYNTHETIC';KeyCount=0;Keys=@();RequiresMappingConfirmation=$false;ArchiveAvailable=$true};HybridIdentity=[pscustomobject]@{State='Non corrisponde';RequiresConfirmation=$true;Records=@([pscustomobject]@{TrustType='ServerAd';DeviceId='33333333-3333-4333-8333-333333333333';State='Non corrisponde';Detail='GUID AD differente dal Device ID Entra.';AdMatches=@()})};Targets=@([pscustomobject]@{Source='AD';Id='11111111-1111-4111-8111-111111111111';DomainController='dc.invalid';DistinguishedName='CN=PC-HYBRID,DC=invalid';AdChildren=@([pscustomobject]@{Id='44444444-4444-4444-8444-444444444444';ObjectClass='msFVE-RecoveryInformation';DistinguishedName='CN=Recovery,CN=PC-HYBRID,DC=invalid'})})}
$plan=[pscustomobject]@{PlanId='synthetic';ArchiveOnly=$false;Sources=@('AD','Entra');Entries=@($entry)}
$hybridUiState=@{Error='';Seen=$false;Mode='Hybrid'};$hybridUiTimer=New-Object Windows.Forms.Timer;$hybridUiTimer.Interval=50
$hybridUiTimer.Add_Tick({
 $windows=@([Windows.Forms.Application]::OpenForms | Where-Object { $_.Text -eq 'Conferma eliminazione - oggetti verificati' -or $_.Name -eq 'BitLockerKeysDialog' })
 if (-not $windows.Count) { return }
 $window=$windows[0];$hybridUiTimer.Stop()
 try {
  if ($hybridUiState.Mode -eq 'Hybrid') {
   $child=$window.Controls.Find('AdChildrenConsent',$true)[0];$hybrid=$window.Controls.Find('HybridIdentityConsent',$true)[0];$confirm=$window.Controls.Find('ConfirmRemoval',$true)[0]
   if (-not $child.Visible -or -not $hybrid.Visible -or $child.Checked -or $hybrid.Checked -or $confirm.Enabled -or $window.AcceptButton.Text -ne 'Annulla') { throw 'Consent was preselected or a separate confirmation disappeared.' }
   $child.Checked=$true;if ($confirm.Enabled) { throw 'AD-child consent authorized a hybrid mismatch.' }
   $hybrid.Checked=$true;if (-not $confirm.Enabled) { throw 'Both confirmations did not enable removal.' }
   $child.Checked=$false;if ($confirm.Enabled) { throw 'Unchecking child consent was ignored.' };$child.Checked=$true
   $hybrid.Checked=$false;if ($confirm.Enabled) { throw 'Unchecking hybrid consent was ignored.' };$hybrid.Checked=$true
   Write-UiImage $window 'HYBRID_UI_PNG';$hybridUiState.Seen=$true;$confirm.PerformClick()
  }
  else {
   $copy=$window.Controls.Find('CopyBitLockerDiagnostics',$true)[0];$information=$window.Controls.Find('BitLockerDiagnosticText',$true)[0]
   if (-not $copy.Visible -or -not $copy.Enabled -or [string]$copy.Tag -cne $expectedDiagnostic -or $information.Text -notlike '*HTTP 403*request-id*' -or [string]$copy.Tag -like '*000011-000011*') { throw 'Copy diagnostics lost the report or included a recovery password.' }
   $copy.PerformClick();if ([Windows.Forms.Clipboard]::GetText() -cne $expectedDiagnostic) { throw 'The production copy button did not copy the diagnostic report.' }
   Write-UiImage $window 'BITLOCKER_DIAGNOSTIC_UI_PNG';$hybridUiState.Seen=$true;$window.Close()
  }
 }
 catch { $hybridUiState.Error=$_.Exception.Message;$window.Close() }
})
try {
 $hybridUiTimer.Start();$decision=Show-RemovalPreview $plan
 if (-not $hybridUiState.Seen -or $hybridUiState.Error -or $null -eq $decision -or -not $decision.IncludeAdChildren -or $decision.ConfirmHybridMismatchFor.Count -ne 1 -or $decision.ConfirmHybridMismatchFor[0] -ne 'PC-HYBRID') { throw ('Hybrid preview failed: '+$hybridUiState.Error) }
 'PASS: native preview independently requires AD-child and hybrid mismatch consent, supports unchecking either consent and forwards only the confirmed computer names.'
 $expectedDiagnostic='Intune: Errore; HTTP 403; Graph Authorization_RequestDenied; request-id 77777777-7777-4777-8777-777777777777'+[Environment]::NewLine+'BitLockerMetadata: OK; Numero=1'+[Environment]::NewLine+'BitLockerSecret: Errore'
 $record=[pscustomobject]@{KeyId='33333333-3333-4333-8333-333333333333';Serial='SYNTHETIC';Volume='operatingSystemVolume';Origins=@('AD');CreatedAt='2026-10-30';Password='000011-000011-000011-000011-000011-000011-000011-000011'}
 $result=[pscustomobject]@{Name='PC-HYBRID';Live=$true;Records=@($record);Sources=@([pscustomobject]@{Name='Intune';State='Errore';Count=0;Error='HTTP 403'});DiagnosticText=$expectedDiagnostic}
 $hybridUiState.Seen=$false;$hybridUiState.Mode='Diagnostics';$hybridUiTimer.Start();Show-ArchivedBitLockerKeys $result
 if (-not $hybridUiState.Seen -or $hybridUiState.Error) { throw ('BitLocker diagnostics UI failed: '+$hybridUiState.Error) }
 'PASS: the actual BitLocker results dialog shows detailed phases and copies a diagnostic report independently of the recovery password display.'
}
finally { $hybridUiTimer.Stop();$hybridUiTimer.Dispose();$form.Dispose() }
'@
try {
 [IO.File]::WriteAllText($probe,$source,(New-Object Text.UTF8Encoding($true)))
 $info=New-Object Diagnostics.ProcessStartInfo;$info.FileName=Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell/v1.0/powershell.exe'
 $info.Arguments='-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "{0}" -Root "{1}"' -f $probe,$root
 $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
 $process=[Diagnostics.Process]::Start($info)
 try { $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync();if (-not $process.WaitForExit(45000)) { $process.Kill();throw 'Native hybrid UI test timed out.' };$out=$stdout.GetAwaiter().GetResult();$err=$stderr.GetAwaiter().GetResult();if ($process.ExitCode -ne 0) { throw ('Native hybrid UI test failed: '+$err+$out) };Write-Host $out }
 finally { $process.Dispose() }
}
finally { Remove-Item $directory -Recurse -Force -ErrorAction SilentlyContinue }
