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
$script:ModuleScanCalls=New-Object 'Collections.Generic.List[object]'
function Start-DmTask {
 param([string]$Operation,$Payload=$null)
 [void]$script:ModuleScanCalls.Add([pscustomobject]@{Kind=$script:DmUi.Kind;Operation=$Operation;Payload=$Payload})
}
$configPath=Join-Path $PSScriptRoot 'module.config.json'
'{"Glpi":{"BaseUri":"https://glpi.example.invalid/helpdesk/apirest.php/"}}' | Set-Content -LiteralPath $configPath -Encoding UTF8
$script:OpenedGlpiUrl=''
$script:FailBrowser=$false
function Start-Process {
 [CmdletBinding()]param([string]$FilePath)
 if ($script:FailBrowser) { throw 'Synthetic browser error.' }
 $script:OpenedGlpiUrl=$FilePath
}
foreach ($kind in @('Hybrid','Ring')) {
 $window=$null
 try {
  $access.ReadOnly=$true
  $window=Show-DeviceModuleWindow -Kind $kind -ConfigPath $configPath -EnvPath synthetic -GraphAccess $access -SmokeTest
  $u=$script:DmUi;$script:ModuleScanCalls.Clear();$u.SuppressInitialScan=$false
  $window.Show();[Windows.Forms.Application]::DoEvents()
  if ($script:ModuleScanCalls.Count -ne 1 -or $script:ModuleScanCalls[0].Operation -ne 'Snapshot' -or $null -ne $script:ModuleScanCalls[0].Payload -or -not $u.InitialScanStarted -or $u.Filter.SelectedItem -ne 'Tutti') { throw 'Opening a module did not start one full unfiltered scan with all-results view.' }
  if ($window.Controls.Find('DeviceModuleFilterLabel',$true)[0].Text -ne 'Filtra elenco:' -or $u.Query.Enabled -or $u.Filter.Enabled) { throw 'An unscanned module exposes a search flow or enables filters before loading.' }
  $window.Hide();$window.Show();[Windows.Forms.Application]::DoEvents()
  if ($script:ModuleScanCalls.Count -ne 1) { throw 'Redisplaying the same module repeated its initial scan.' }
  if ($u.Write.Enabled -or $u.Stop.Enabled -or -not $u.Refresh.Enabled -or -not $u.Grid.MultiSelect -or $u.Grid.AllowUserToResizeRows -or $null -eq $window.Icon) { throw 'New module bypassed read-only mode or lost common native controls.' }
  $row=[pscustomobject]@{Key='33333333-3333-4333-8333-333333333333';Name='PC-SYNTHETIC';ObjectId='33333333-3333-4333-8333-333333333333';DeviceId='44444444-4444-4444-8444-444444444444';ADGuid='44444444-4444-4444-8444-444444444444';ADDistinguishedName='CN=PC-SYNTHETIC,OU=Lab,DC=example,DC=invalid';OUName='Lab';HybridState='HYBRID OK';IdentityState='Corrisponde';IdentityRecords=@();Anomalies='';EntraDevices=@();EntraCount=1;RegisteredCount=1;Severity='Good';IntuneSerial='SYNTHETIC-SERIAL';SerialConflict=$false;IntuneRecords=@();GlpiRecords=@([pscustomobject]@{GlpiId=12;Name='GLPI-RENAMED';SerialNumber='SYNTHETIC-SERIAL';InventoryNumber='123';State='Assegnato';GroupPath='CENSITO';LastInventory='2026-10-30'});GlpiState='Presente';GlpiMatchBy='Seriale Intune';GlpiError='';GlpiIds='12';GlpiNames='GLPI-RENAMED';GlpiStatus='Assegnato';GlpiGroup='CENSITO';Censito='Si';Orphan=$true;State='Orfano';Rings='';TargetRing='';LastSignIn='2026-10-30'}
  $second=$row | Select-Object *;$second.Key='55555555-5555-4555-8555-555555555555';$second.ObjectId=$second.Key;$second.Name='OTHER-COMPUTER';$second.Orphan=$false;$second.State='Assegnato';$second.Rings='Ring1';$second.IntuneSerial='OTHER-SERIAL';$second.GlpiIds='13';$second.GlpiNames='OTHER-GLPI'
  $u.Snapshot=[pscustomobject]@{Rows=@($row,$second)}
  if ($kind -eq 'Ring') { [void]$u.Ring.Items.Add('Ring1');[void]$u.Grid.Columns['TargetRing'].Items.Add('Ring1') }
  Update-DmGrid;$u.Grid.Rows[0].Selected=$true
  if ($u.Write.Enabled -or $u.Details.Text -notlike '*GLPI-RENAMED*' -or $u.Details.Text -notlike '*SYNTHETIC-SERIAL*' -or $u.Counter.Text -notlike '*Selezionati: 1') { throw 'Read-only selection enabled writes or lost GLPI detail/counters.' }
  $script:OpenedGlpiUrl=''
  $u.OpenGlpi.PerformClick()
  if ($script:OpenedGlpiUrl -cne 'https://glpi.example.invalid/helpdesk/front/computer.form.php?id=12') { throw 'Opening the selected GLPI computer did not use its configured server and exact asset ID.' }
  $script:FailBrowser=$true
  $u.OpenGlpi.PerformClick()
  $script:FailBrowser=$false
  if ($u.Status.Text -notlike '*Synthetic browser error.*') { throw 'Opening a GLPI computer failed outside the status bar.' }
  if ($kind -eq 'Ring' -and -not $u.Grid.Rows[0].Cells['TargetRing'].ReadOnly) { throw 'Read-only Ring mode exposed an editable target.' }
  if ($u.Grid.Rows.Count -ne 2 -or $u.Counter.Text -ne 'Visualizzati: 2/2 | Selezionati: 1') { throw 'Default view hides loaded device status or loses full-scan totals.' }
  if ($kind -eq 'Ring') {
   $u.Filter.SelectedItem='Orfani'
   if ($u.Grid.Rows.Count -ne 1 -or $u.Counter.Text -ne 'Visualizzati: 1/2 | Selezionati: 0') { throw 'Orphan filtering lost loaded assigned devices or the total count.' }
   $u.Filter.SelectedItem='Tutti'
  }
  $u.Query.Text='NO-MATCH'
  if ($u.Grid.Rows.Count -ne 0 -or $u.Snapshot.Rows.Count -ne 2 -or $u.Counter.Text -ne 'Visualizzati: 0/2 | Selezionati: 0') { throw 'Local filtering changed the full inventory or its total.' }
  $u.Query.Text='PC-SYNTHETIC'
  if ($u.Grid.Rows.Count -ne 1 -or $script:ModuleScanCalls.Count -ne 1) { throw 'Typing or changing status filters restarted collection instead of using loaded data.' }
  $u.Refresh.PerformClick()
  if ($script:ModuleScanCalls.Count -ne 2 -or $script:ModuleScanCalls[1].Operation -ne 'Snapshot' -or $null -ne $script:ModuleScanCalls[1].Payload) { throw 'Refresh applied a name/filter query instead of repeating the complete scan.' }
  $u.Query.Clear()
  $access.ReadOnly=$false;Update-DmGrid;$u.Grid.Rows[0].Selected=$true;Update-DmButtons
  if (-not $u.Write.Enabled) { throw 'Verified write access did not enable selected-device actions.' }
  if ($kind -eq 'Ring') { $u.Grid.SelectAll();$u.Ring.SelectedItem='Ring1';$u.Bulk.PerformClick();if ($row.TargetRing -ne 'Ring1' -or $second.TargetRing -ne 'Ring1' -or $u.Grid.Rows[1].Cells['TargetRing'].ReadOnly) { throw 'Bulk target failed for an orphan or an already assigned selected device.' } }
  Write-ModuleUiImage $window $kind
 }
 finally { if ($null -ne $window) { $u=$script:DmUi;$u.Timer.Stop();$u.Timer.Dispose();$u.Worker.Close();$u.Worker.Dispose();$window.Icon.Dispose();$window.Dispose() } }
}
'PASS: both modules start exactly one full scan on first display, initially show all statuses, filter loaded rows without rescanning and refresh the complete inventory independently of active filters.'
'PASS: both native module windows share fonts, icons, multi-selection, filters, counters, GLPI detail and independent read-only/write controls; Ring bulk targets include selected already assigned devices for explicit moves.'
'PASS: both module windows open the selected GLPI asset in read-only mode and report browser errors in the status bar.'
$owner=New-Object Windows.Forms.Form;$owner.Font=New-Object Drawing.Font('Segoe UI',9);$owner.Icon=[Drawing.SystemIcons]::Application
$uiState=@{Seen=$false;Error='';Mode='Picker'};$uiTimer=New-Object Windows.Forms.Timer;$uiTimer.Interval=50
$uiTimer.Add_Tick({
 $windows=@([Windows.Forms.Application]::OpenForms | Where-Object { $_.Name -in @('RingGroupPicker','HybridRegisteredSelection','RingAssignmentReview') });if (-not $windows.Count) { return };$dialog=$windows[0];$uiTimer.Stop()
 try {
  if ($uiState.Mode -eq 'Picker') {
   $grid=$dialog.Controls.Find('AvailableRingGroups',$true)[0]
   if ($dialog.Controls.Find('LoadEntraGroups',$true)[0].Enabled) { throw 'Picker attempted access before wrapper verification.' }
   Set-AssistenteITGroupPickerRows -Grid $grid -Groups @([pscustomobject]@{id='55555555-5555-4555-8555-555555555555';displayName='RENAMED-GROUP';AssignmentReason=''},[pscustomobject]@{id='66666666-6666-4666-8666-666666666666';displayName='DYNAMIC-GROUP';AssignmentReason='Appartenenza dinamica'}) -Selected @([pscustomobject]@{Id='55555555-5555-4555-8555-555555555555';Name='OLD-NAME';Label='Ring1';CanAssign=$true})
   if ($grid.Rows.Count -ne 2 -or $grid.Rows[0].Cells['Monitor'].Value -ne $true -or $grid.Rows[0].Cells['Name'].Value -ne 'RENAMED-GROUP' -or $grid.Rows[0].Cells['Destination'].ReadOnly -or $grid.Columns['Destination'].HeaderText -ne 'Modifica' -or -not $grid.Rows[1].Cells['Destination'].ReadOnly) { throw 'Group picker lost ID binding or allowed dynamic destinations.' }
   $grid.Rows[1].Cells['Monitor'].Value=$true;$grid.Rows[1].Cells['Label'].Value='MonitorOnly'
   Write-ModuleUiImage $dialog 'GROUP_PICKER';$dialog.Controls.Find('ConfirmSelectedGroups',$true)[0].PerformClick()
  }
  elseif ($uiState.Mode -eq 'Selection') {
   $grid=@($dialog.Controls[0].Controls | Where-Object { $_ -is [Windows.Forms.DataGridView] })[0]
   if ($grid.Rows[0].Cells['Selected'].Value -eq $true -or $dialog.AcceptButton.Text -ne 'Annulla') { throw 'Registered selection was preconfirmed.' }
   $grid.Rows[0].Cells['Selected'].Value=$true;$dialog.Controls.Find('VerifyRegisteredSelection',$true)[0].PerformClick()
  }
  else { $review=@($dialog.Controls[0].Controls | Where-Object { $_ -is [Windows.Forms.RichTextBox] })[0];if ($review.Text -notlike '*Sposta*' -or $review.Text -notlike '*ORIGIN-SYNTHETIC / 66666666-6666-4666-8666-666666666666*' -or $review.Text -notlike '*GROUP-SYNTHETIC / 55555555-5555-4555-8555-555555555555*') { throw 'Move review hid the action or exact source/destination group IDs.' };Write-ModuleUiImage $dialog 'RING_MOVE_REVIEW';if ($dialog.AcceptButton.Text -ne 'Annulla') { throw 'Ring confirmation defaults to applying writes.' };$dialog.Controls.Find('ConfirmRingAssignments',$true)[0].PerformClick() }
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
 $accepted=Show-DmRingReview -Plan ([pscustomobject]@{Items=@([pscustomobject]@{Name='PC-SYNTHETIC';ObjectId='77777777-7777-4777-8777-777777777777';DeviceId='88888888-8888-4888-8888-888888888888';TargetRing='Ring1';GroupId='55555555-5555-4555-8555-555555555555';GroupName='GROUP-SYNTHETIC';Action='Sposta';RemoveGroups='ORIGIN-SYNTHETIC / 66666666-6666-4666-8666-666666666666'})}) -Owner $owner
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
