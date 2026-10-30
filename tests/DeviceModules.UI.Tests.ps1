#requires -version 5.1
$ErrorActionPreference='Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { Write-Host 'SKIP: new module windows and group picker require native Windows.';return }
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('device-modules-ui-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temporary)
$probePath=Join-Path $temporary 'probe.ps1'
$probe=@'
param([string]$Root)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
. (Join-Path $Root 'DeviceModules.UI.ps1')
. (Join-Path $Root 'AssistenteIT/GroupPicker.UI.ps1')
$access=[pscustomobject]@{CanOpen=$true;ReadOnly=$true;Account='synthetic@example.invalid';ClientId='11111111-1111-4111-8111-111111111111';TenantId='22222222-2222-4222-8222-222222222222';Permissions=@()}
function Write-ModuleUiImage {
 param($Window,[string]$Name)
 $bitmap=New-Object Drawing.Bitmap($Window.Width,$Window.Height)
 try { $Window.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$bitmap.Width,$bitmap.Height)));$memory=New-Object IO.MemoryStream;try { $bitmap.Save($memory,[Drawing.Imaging.ImageFormat]::Png);Write-Host ($Name+'_UI_PNG:'+ [Convert]::ToBase64String($memory.ToArray())) } finally { $memory.Dispose() } } finally { $bitmap.Dispose() }
}
foreach ($kind in @('Hybrid','Ring')) {
 $window=$null
 try {
  $access.ReadOnly=$true
  $window=Show-DeviceModuleWindow -Kind $kind -ConfigPath synthetic -EnvPath synthetic -GraphAccess $access -SmokeTest
  $window.Show();[Windows.Forms.Application]::DoEvents();$u=$script:DmUi
  if ($u.Write.Enabled -or $u.Stop.Enabled -or -not $u.Refresh.Enabled -or -not $u.Grid.MultiSelect -or $u.Grid.AllowUserToResizeRows -or $null -eq $window.Icon) { throw 'New module bypassed read-only mode or lost common native controls.' }
  $row=[pscustomobject]@{Key='33333333-3333-4333-8333-333333333333';Name='PC-SYNTHETIC';ObjectId='33333333-3333-4333-8333-333333333333';DeviceId='44444444-4444-4444-8444-444444444444';ADGuid='44444444-4444-4444-8444-444444444444';ADDistinguishedName='CN=PC-SYNTHETIC,OU=Lab,DC=example,DC=invalid';OUName='Lab';HybridState='HYBRID OK';IdentityState='Corrisponde';IdentityRecords=@();Anomalies='';EntraDevices=@();EntraCount=1;RegisteredCount=1;Severity='Good';IntuneSerial='SYNTHETIC-SERIAL';SerialConflict=$false;IntuneRecords=@();GlpiRecords=@([pscustomobject]@{GlpiId=12;Name='GLPI-RENAMED';SerialNumber='SYNTHETIC-SERIAL';InventoryNumber='123';State='Assegnato';GroupPath='CENSITO';LastInventory='2026-10-30'});GlpiState='Presente';GlpiMatchBy='Seriale Intune';GlpiError='';GlpiIds='12';GlpiNames='GLPI-RENAMED';GlpiStatus='Assegnato';GlpiGroup='CENSITO';Censito='Si';Orphan=$true;State='Orfano';Rings='';TargetRing='';LastSignIn='2026-10-30'}
  $u.Snapshot=[pscustomobject]@{Rows=@($row)}
  if ($kind -eq 'Ring') { [void]$u.Ring.Items.Add('Ring1');[void]$u.Grid.Columns['TargetRing'].Items.Add('Ring1') }
  Update-DmGrid;$u.Grid.Rows[0].Selected=$true
  if ($u.Write.Enabled -or $u.Details.Text -notlike '*GLPI-RENAMED*' -or $u.Details.Text -notlike '*SYNTHETIC-SERIAL*' -or $u.Counter.Text -notlike '*Selezionati: 1') { throw 'Read-only selection enabled writes or lost GLPI detail/counters.' }
  if ($kind -eq 'Ring' -and -not $u.Grid.Rows[0].Cells['TargetRing'].ReadOnly) { throw 'Read-only Ring mode exposed an editable target.' }
  $u.Query.Text='NO-MATCH';if ($u.Grid.Rows.Count -ne 0) { throw 'Shared search filter failed.' };$u.Query.Clear()
  $access.ReadOnly=$false;Update-DmGrid;$u.Grid.Rows[0].Selected=$true;Update-DmButtons
  if (-not $u.Write.Enabled) { throw 'Verified write access did not enable selected-device actions.' }
  if ($kind -eq 'Ring') { $u.Ring.SelectedItem='Ring1';$u.Bulk.PerformClick();if ($row.TargetRing -ne 'Ring1') { throw 'Bulk target did not update the selected orphan.' } }
  Write-ModuleUiImage $window $kind
 }
 finally { if ($null -ne $window) { $u=$script:DmUi;$u.Timer.Stop();$u.Timer.Dispose();$u.Worker.Close();$u.Worker.Dispose();$window.Icon.Dispose();$window.Dispose() } }
}
'PASS: both native module windows share fonts, icons, multi-selection, filters, counters, GLPI detail and independent read-only/write controls; Ring bulk assignment updates only selected orphans.'
$owner=New-Object Windows.Forms.Form;$owner.Font=New-Object Drawing.Font('Segoe UI',9);$owner.Icon=[Drawing.SystemIcons]::Application
$uiState=@{Seen=$false;Error='';Mode='Picker'};$uiTimer=New-Object Windows.Forms.Timer;$uiTimer.Interval=50
$uiTimer.Add_Tick({
 $windows=@([Windows.Forms.Application]::OpenForms | Where-Object { $_.Name -in @('RingGroupPicker','HybridRegisteredSelection','RingAssignmentReview') });if (-not $windows.Count) { return };$dialog=$windows[0];$uiTimer.Stop()
 try {
  if ($uiState.Mode -eq 'Picker') {
   $grid=$dialog.Controls.Find('AvailableRingGroups',$true)[0]
   if ($dialog.Controls.Find('LoadEntraGroups',$true)[0].Enabled) { throw 'Picker attempted access before wrapper verification.' }
   Set-AssistenteITGroupPickerRows -Grid $grid -Groups @([pscustomobject]@{id='55555555-5555-4555-8555-555555555555';displayName='RENAMED-GROUP';AssignmentReason=''},[pscustomobject]@{id='66666666-6666-4666-8666-666666666666';displayName='DYNAMIC-GROUP';AssignmentReason='Appartenenza dinamica'}) -Selected @([pscustomobject]@{Id='55555555-5555-4555-8555-555555555555';Name='OLD-NAME';Label='Ring1';CanAssign=$true})
   if ($grid.Rows.Count -ne 2 -or $grid.Rows[0].Cells['Monitor'].Value -ne $true -or $grid.Rows[0].Cells['Name'].Value -ne 'RENAMED-GROUP' -or -not $grid.Rows[1].Cells['Destination'].ReadOnly) { throw 'Group picker lost ID binding or allowed dynamic destinations.' }
   $grid.Rows[1].Cells['Monitor'].Value=$true;$grid.Rows[1].Cells['Label'].Value='MonitorOnly'
   Write-ModuleUiImage $dialog 'GROUP_PICKER';$dialog.Controls.Find('ConfirmSelectedGroups',$true)[0].PerformClick()
  }
  elseif ($uiState.Mode -eq 'Selection') {
   $grid=@($dialog.Controls[0].Controls | Where-Object { $_ -is [Windows.Forms.DataGridView] })[0]
   if ($grid.Rows[0].Cells['Selected'].Value -eq $true -or $dialog.AcceptButton.Text -ne 'Annulla') { throw 'Registered selection was preconfirmed.' }
   $grid.Rows[0].Cells['Selected'].Value=$true;$dialog.Controls.Find('VerifyRegisteredSelection',$true)[0].PerformClick()
  }
  else { if ($dialog.AcceptButton.Text -ne 'Annulla') { throw 'Ring confirmation defaults to applying writes.' };$dialog.Controls.Find('ConfirmRingAssignments',$true)[0].PerformClick() }
  $uiState.Seen=$true
 }
 catch { $uiState.Error=$_.Exception.Message;$dialog.Close() }
})
try {
 $uiTimer.Start();$groups=Show-AssistenteITGroupPicker -Configured @() -Access $null -Owner $owner -InstallRoot $Root
 if (-not $uiState.Seen -or $uiState.Error -or $groups.Count -ne 2 -or $groups[0].Id -ne '55555555-5555-4555-8555-555555555555' -or $groups[1].CanAssign) { throw ('Group picker failed: '+$uiState.Error) }
 $uiState.Mode='Selection';$uiState.Seen=$false;$uiTimer.Start()
 $ids=Show-DmSelection -Candidates @([pscustomobject]@{Name='PC-SYNTHETIC';ObjectId='77777777-7777-4777-8777-777777777777';DeviceId='88888888-8888-4888-8888-888888888888';IsManaged=$false;Users='Synthetic';UserNotes=''}) -Owner $owner
 if (-not $uiState.Seen -or $uiState.Error -or $ids.Count -ne 1 -or $ids[0] -ne '77777777-7777-4777-8777-777777777777') { throw ('Registered selection failed: '+$uiState.Error) }
 $uiState.Mode='Review';$uiState.Seen=$false;$uiTimer.Start()
 $accepted=Show-DmRingReview -Plan ([pscustomobject]@{Items=@([pscustomobject]@{Name='PC-SYNTHETIC';ObjectId='77777777-7777-4777-8777-777777777777';DeviceId='88888888-8888-4888-8888-888888888888';TargetRing='Ring1';GroupName='GROUP-SYNTHETIC'})}) -Owner $owner
 if (-not $accepted -or -not $uiState.Seen -or $uiState.Error) { throw ('Ring review failed: '+$uiState.Error) }
 'PASS: the native group picker preserves selected group IDs across renames, separates monitor/destination flags and disables unsupported destinations; Registered selection and Ring review require explicit confirmation.'
}
finally { $uiTimer.Stop();$uiTimer.Dispose();$owner.Dispose() }
'@
try {
 [IO.File]::WriteAllText($probePath,$probe,(New-Object Text.UTF8Encoding($true)))
 $info=New-Object Diagnostics.ProcessStartInfo;$info.FileName=Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell/v1.0/powershell.exe'
 $info.Arguments='-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "{0}" -Root "{1}"' -f $probePath,$root;$info.UseShellExecute=$false;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.CreateNoWindow=$true
 $process=[Diagnostics.Process]::Start($info)
 try { $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync();if (-not $process.WaitForExit(45000)) { $process.Kill();throw 'Native new-module UI timed out.' };$out=$stdout.GetAwaiter().GetResult();$err=$stderr.GetAwaiter().GetResult();if ($process.ExitCode -ne 0) { throw ('Native new-module UI failed: '+$err+$out) };Write-Host $out }
 finally { $process.Dispose() }
}
finally { Remove-Item $temporary -Recurse -Force -ErrorAction SilentlyContinue }
