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
  if ($script:ModuleScanCalls.Count -ne 1 -or $script:ModuleScanCalls[0].Operation -ne 'Snapshot' -or $null -ne $script:ModuleScanCalls[0].Payload -or -not $u.InitialScanStarted) { throw 'Opening a module did not start one full unfiltered scan.' }
  if ($u.Query.Enabled -or $u.Filter.Enabled) { throw 'An unscanned module enabled filters before loading.' }
  $window.Hide();$window.Show();[Windows.Forms.Application]::DoEvents()
  if ($script:ModuleScanCalls.Count -ne 1) { throw 'Redisplaying the same module repeated its initial scan.' }
  if ($u.Write.Enabled -or -not $u.Refresh.Enabled -or -not $u.Grid.MultiSelect -or $u.Grid.AllowUserToResizeRows -or $null -eq $window.Icon) { throw 'New module bypassed read-only mode or lost common native controls.' }
  if ($kind -eq 'Hybrid') {
   $layout=$window.Controls[0];$filterRow=$layout.GetRow($u.Query.Parent)
   $headers='Computer|Hybrid|Identità AD/Entra|Registered|Seriale Intune|Stato GLPI|Reparto GLPI|OU|Asset ID|Censito|GLPI'
   if ((@($u.Grid.Columns | ForEach-Object HeaderText) -join '|') -cne $headers -or
       ($u.Filter.Items -join '|') -cne ($headers+'|Attestazione Intune|Anomalie') -or $u.FilterValue.SelectedItem -ne 'Tutti' -or
       (($u.Write.Parent.Controls | ForEach-Object Text) -join '|') -ne 'Aggiorna|Esporta CSV|Apri su GLPI|Verifica e pulisci Registered|Sola lettura' -or
       $layout.GetRow($u.Write.Parent) -ne $filterRow+1 -or $layout.GetRow($u.Write.Parent) -ne $layout.RowCount-1 -or
       $window.Controls.Find('HybridGeneralSummary',$true)[0].Text -ne 'Riepilogo generale' -or
       $window.Controls.Find('HybridOuSummary',$true)[0].Text -ne 'OU analizzate') {
       throw 'Hybrid columns, filters, top summaries or bottom actions do not match the requested layout.'
   }
  }
  if ($kind -eq 'Ring') {
   $layout=$window.Controls[0];$filterRow=$layout.GetRow($u.Query.Parent)
   if ($window.Controls.Find('Stop',$true).Count -ne 0 -or $u.Refresh.Text -ne 'Aggiorna' -or $u.Export.Text -ne 'Esporta CSV' -or
       $u.OpenGlpi.Text -ne 'Apri su GLPI' -or $u.Write.Text -ne 'Verifica ed Applica' -or $u.Write.BackColor.B -le $u.Write.BackColor.R -or
       $layout.GetRow($u.Bulk.Parent) -ne $filterRow+1 -or $layout.GetRow($u.Write.Parent) -ne $filterRow+2 -or $layout.GetRow($u.Write.Parent) -ne $layout.RowCount-1 -or
       ($u.Filter.Items -join '|') -ne 'Ring attuali|GLPI|Stato GLPI|Reparto GLPI' -or $u.FilterValue.SelectedItem -ne 'Tutti' -or $u.FilterValue.Enabled -or
       (@($u.Grid.Columns | ForEach-Object HeaderText) -join '|') -ne 'Computer|Ring attuali|Ring destinazione|Seriale Intune|Stato GLPI|Reparto GLPI|Asset ID|Censito|GLPI') {
       throw 'Ring grid, filter and action rows or button labels do not match the requested layout.'
   }
  }
  $row=[pscustomobject]@{Key='33333333-3333-4333-8333-333333333333';Name='PC-SYNTHETIC';ObjectId='33333333-3333-4333-8333-333333333333';DeviceId='44444444-4444-4444-8444-444444444444';ADGuid='44444444-4444-4444-8444-444444444444';ADDistinguishedName='CN=PC-SYNTHETIC,OU=Lab,DC=example,DC=invalid';OUName='Lab';HybridState='HYBRID OK';IdentityState='Corrisponde';IdentityRecords=@();Anomalies='';EntraDevices=@();EntraCount=1;RegisteredCount=1;Severity='Good';IntuneSerial='SYNTHETIC-SERIAL';SerialConflict=$false;IntuneRecords=@();GlpiRecords=@([pscustomobject]@{GlpiId=12;Name='GLPI-RENAMED';SerialNumber='SYNTHETIC-SERIAL';InventoryNumber='123';State='Assegnato';GroupPath='CENSITO';LastInventory='2026-10-30'});GlpiState='Presente';GlpiMatchBy='Seriale Intune';GlpiError='';GlpiIds='12';GlpiNames='GLPI-RENAMED';GlpiStatus='Assegnato';GlpiGroup='CENSITO';Censito='Si';Orphan=$true;State='Orfano';Rings='';TargetRing='';LastSignIn='2026-10-30'}
  $second=$row | Select-Object *;$second.Key='55555555-5555-4555-8555-555555555555';$second.ObjectId=$second.Key;$second.Name='OTHER-COMPUTER';$second.Orphan=$false;$second.State='Assegnato';$second.Rings='Ring1';$second.IntuneSerial='OTHER-SERIAL';$second.GlpiIds='13';$second.GlpiNames='OTHER-GLPI'
  $u.Snapshot=[pscustomobject]@{Rows=@($row,$second)}
  $row | Add-Member NoteProperty GlpiDepartment 'Synthetic department'
  $row | Add-Member NoteProperty GlpiAssetId '00017'
  $row.GlpiRecords[0] | Add-Member NoteProperty SupplierName $row.GlpiDepartment
  $second | Add-Member NoteProperty GlpiDepartment ''
  $second | Add-Member NoteProperty GlpiAssetId ''
  if ($kind -eq 'Ring') {
   $row | Add-Member NoteProperty CurrentGroupIds @()
   $second | Add-Member NoteProperty CurrentGroupIds @('g1','g2')
   $second.State='Piu Ring';$second.Rings='Ring1, Ring2';$second.GlpiStatus='In magazzino';$second.GlpiState='Presente (solo nome)'
   $u.Snapshot | Add-Member NoteProperty Statistics ([pscustomobject]@{DeviceTotal=5;EligibleTotal=2;AlreadyAssigned=1;OrphanRemaining=1})
   $u.Snapshot | Add-Member NoteProperty Groups @([pscustomobject]@{Id='g1';Label='Ring1';DeviceCount=1;IsWritable=$true},[pscustomobject]@{Id='g2';Label='Ring2';DeviceCount=2;IsWritable=$false})
   [void]$u.Ring.Items.Add('');[void]$u.Ring.Items.Add('Ring1');[void]$u.Grid.Columns['TargetRing'].Items.Add('Ring1')
   Update-DmRingSummary
   Update-DmFilterValues
   if ($u.Summary.Text -notlike '*PC orfani*' -or ($u.RingSummaryCounts.Text.Split([string[]]@([Environment]::NewLine),[StringSplitOptions]::None) -join '|') -ne '5|2|1|1|0' -or $u.RingSummaryGroups.Items.Count -ne 2 -or
       $u.RingSummaryGroups.Items[1].SubItems[1].Text -ne '2' -or $u.RingSummaryGroups.Items[0].SubItems[2].Text -ne 'Solo controllo') {
       throw 'Ring summary lost inventory totals, per-group device counts or the effective read-only mode.'
   }
  }
  else {
   $row | Add-Member -NotePropertyMembers @{OUDistinguishedName='OU=Lab,DC=example,DC=invalid';IntuneState='OK';IntuneReason=''}
   $second | Add-Member -NotePropertyMembers @{OUDistinguishedName='OU=Other,DC=example,DC=invalid';IntuneState='Da regolarizzare';IntuneReason='Synthetic'}
   $second.OUName='Other';$second.IdentityState='Non applicabile';$second.HybridState='SENZA HYBRID';$second.RegisteredCount=0
   $second.GlpiState='Assente';$second.GlpiStatus='';$second.Censito=''
   $u.Snapshot | Add-Member NoteProperty Statistics ([pscustomobject]@{Computers=2;HybridOk=1;IntuneOk=1;IntuneUnknown=0;RegisteredComputers=1})
   $u.Snapshot | Add-Member NoteProperty OuStatistics @(
    [pscustomobject]@{Name='Lab';DistinguishedName=$row.OUDistinguishedName;Count=1;IntuneOk=1;IntuneUnknown=0}
    [pscustomobject]@{Name='Other';DistinguishedName=$second.OUDistinguishedName;Count=1;IntuneOk=0;IntuneUnknown=0}
   )
   Update-DmHybridSummary
   Update-DmFilterValues
   if ($u.HybridSummaryCounts.Text -notlike '*1 OK*1 da regolarizzare*0 N/D*' -or $u.HybridSummaryOus.Items.Count -ne 2 -or
       $u.HybridSummaryOus.Items[0].SubItems[2].Text -ne '1' -or $u.HybridSummaryOus.Items[1].SubItems[3].Text -ne '0') {
       throw 'Hybrid summary did not expose per-OU and general Intune coverage.'
   }
  }
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
   if ($u.Grid.Rows[0].Cells['GlpiDepartment'].Value -ne 'Synthetic department' -or $u.Grid.Rows[0].Cells['GlpiAssetId'].Value -cne '00017' -or
       $u.Grid.Rows[1].Cells['GlpiAssetId'].Value -or $u.Details.Text -notlike '*Synthetic department*') { throw 'Ring grid lost the supplier or inventory number.' }
   $u.FilterValue.SelectedItem='Senza Ring'
   if ($u.Grid.Rows.Count -ne 1 -or $u.Counter.Text -ne 'Visualizzati: 1/2 | Selezionati: 0') { throw 'Orphan filtering lost loaded assigned devices or the total count.' }
   foreach ($spec in @(@('Ring attuali','Include Ring2','OTHER-COMPUTER'),@('GLPI','Presente (solo nome)','OTHER-COMPUTER'),@('Stato GLPI','Assegnato','PC-SYNTHETIC'),@('Reparto GLPI','Synthetic department','PC-SYNTHETIC'),@('Reparto GLPI','(Vuoto)','OTHER-COMPUTER'))) {
    $u.Filter.SelectedItem=$spec[0];$u.FilterValue.SelectedItem=$spec[1]
    if ($u.Grid.Rows.Count -ne 1 -or $u.Grid.Rows[0].Tag.Name -ne $spec[2]) { throw ('Ring column filter produced the wrong row: '+$spec[0]+' / '+$spec[1]) }
   }
   $u.Query.Text='PC-SYNTHETIC'
   if ($u.Grid.Rows.Count) { throw 'The Ring name and column filters were not combined.' }
   $u.FilterValue.SelectedItem='Tutti'
   $u.Query.Text='SYNTHETIC-SERIAL'
   if ($u.Grid.Rows.Count) { throw 'The Ring name filter matched a serial.' }
  }
  else {
   foreach ($spec in @(@('Computer','PC-SYNTHETIC'),@('Hybrid','HYBRID OK'),@('Identità AD/Entra','Corrisponde'),@('Registered','Con Registered'),
      @('Seriale Intune','SYNTHETIC-SERIAL'),@('Stato GLPI','Assegnato'),@('Reparto GLPI','Synthetic department'),@('OU','Lab'),
      @('Asset ID','00017'),@('Censito','Si'),@('GLPI','Presente'),@('Attestazione Intune','OK'))) {
    $u.Filter.SelectedItem=$spec[0];$u.FilterValue.SelectedItem=$spec[1]
    if ($u.Grid.Rows.Count -ne 1 -or $u.Grid.Rows[0].Tag.Name -ne $row.Name) { throw ('Hybrid column filter failed: '+$spec[0]) }
   }
   $u.Filter.SelectedItem='Seriale Intune';$u.FilterValue.Text='OTHER-SER'
   if ($u.Grid.Rows.Count -ne 1 -or $u.Grid.Rows[0].Tag.Name -ne $second.Name) { throw 'The Hybrid field filter ignored typed partial values.' }
   $u.Query.Text=$row.Name
   if ($u.Grid.Rows.Count) { throw 'The Hybrid name and field filters were not combined.' }
   $u.FilterValue.SelectedItem='Tutti'
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
  if ($kind -eq 'Ring') {
   $u.RingChanges=1;Update-DmRingSummary
   if ($u.RingSummaryGroups.Items[0].SubItems[2].Text -ne 'Controllo e modifica' -or $u.RingSummaryCounts.Text -notlike '*1') { throw 'Summary hid effective write mode or session changes.' }
   $u.Grid.SelectAll();$u.Ring.SelectedItem='Ring1';$u.Bulk.PerformClick()
   if ($row.TargetRing -ne 'Ring1' -or $second.TargetRing -ne 'Ring1' -or $u.Grid.Rows[1].Cells['TargetRing'].ReadOnly) { throw 'Bulk target failed for an orphan or an already assigned selected device.' }
   $u.Write.PerformClick()
   if ($script:ModuleScanCalls.Count -ne 3 -or $script:ModuleScanCalls[2].Operation -ne 'RingPlan' -or $script:ModuleScanCalls[2].Payload.Count -ne 2) { throw 'Verify and apply bypassed preview or lost staged targets.' }
   $window.Size=New-Object Drawing.Size(1000,720)
   $window.PerformLayout();[Windows.Forms.Application]::DoEvents()
   $last=$u.Grid.GetColumnDisplayRectangle($u.Grid.Columns['GlpiState'].Index,$false)
   if (-not $u.Grid.Columns['GlpiState'].Displayed -or $last.Right -gt $u.Grid.ClientSize.Width -or
       $u.Grid.Width -gt $window.ClientSize.Width -or $u.Write.Right -gt $u.Write.Parent.ClientSize.Width) {
       throw 'Ring columns or actions were clipped at a narrower window size.'
   }
  }
  else {
   $u.Query.Text='NO-MATCH'
   if (-not $u.Write.Enabled -or $u.Grid.Rows.Count -ne 0) { throw 'Hybrid Registered cleanup depends on the grid filter or selection.' }
   $u.Write.PerformClick()
   if ($script:ModuleScanCalls.Count -ne 3 -or $script:ModuleScanCalls[2].Operation -ne 'Candidates' -or $null -ne $script:ModuleScanCalls[2].Payload) {
       throw 'Hybrid cleanup passed the grid selection or skipped candidate discovery.'
   }
   $u.Query.Clear()
   $window.Size=New-Object Drawing.Size(1050,720)
   $window.PerformLayout();[Windows.Forms.Application]::DoEvents()
   $last=$u.Grid.GetColumnDisplayRectangle($u.Grid.Columns['GlpiState'].Index,$false)
   if (-not $u.Grid.Columns['GlpiState'].Displayed -or $last.Right -gt $u.Grid.ClientSize.Width -or
       $u.Write.Right -gt $u.Write.Parent.ClientSize.Width -or $u.FilterValue.Right -gt $u.FilterValue.Parent.ClientSize.Width) {
       throw 'Hybrid columns, filters or actions were clipped at the minimum window size.'
   }
  }
  Write-ModuleUiImage $window $kind
 }
 finally { if ($null -ne $window) { $u=$script:DmUi;$u.Timer.Stop();$u.Timer.Dispose();$u.Worker.Close();$u.Worker.Dispose();$window.Icon.Dispose();$window.Dispose() } }
}
'PASS: both modules start exactly one full scan on first display, initially show all statuses, filter loaded rows without rescanning and refresh the complete inventory independently of active filters.'
'PASS: both native module windows share fonts, icons, multi-selection, filters, counters, GLPI detail and independent read-only/write controls; Ring bulk targets include selected already assigned devices for explicit moves.'
'PASS: both module windows open the selected GLPI asset in read-only mode and report browser errors in the status bar.'
'PASS: Hybrid has compact summaries above the ordered grid, local name and field filters, and bottom actions. Registered verification begins for the full inventory even when no row is visible.'
'PASS: the Ring dashboard shows ordered inventory columns, group counts and separate filter, bulk target and action rows. All column filters work locally and the primary button opens verification before writes.'
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
   if ($grid.Rows.Count -ne 2 -or $grid.Rows[0].Cells['Selected'].Value -eq $true -or $grid.Rows[1].Cells['Selected'].Value -eq $true -or $dialog.AcceptButton.Text -ne 'Annulla') { throw 'Registered selection was preconfirmed.' }
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
 $ids=Show-DmSelection -Candidates @(
  [pscustomobject]@{Name='PC-SYNTHETIC';ObjectId='77777777-7777-4777-8777-777777777777';DeviceId='88888888-8888-4888-8888-888888888888';IsManaged=$false;Users='Synthetic';UserNotes=''}
  [pscustomobject]@{Name='PC-OTHER';ObjectId='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';DeviceId='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';IsManaged=$false;Users='';UserNotes=''}
 ) -Owner $owner
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
