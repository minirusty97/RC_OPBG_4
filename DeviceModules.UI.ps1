#requires -version 5.1
function Get-UiSetting { param($Object,[string]$Name,$Default);Get-DmValue $Object $Name $Default }

function Show-DmSelection {
    param([object[]]$Candidates,$Owner)
    $dialog=New-Object Windows.Forms.Form;$dialog.Name='HybridRegisteredSelection';$dialog.Text='Seleziona le registrazioni Entra Registered'
    $dialog.ClientSize=New-Object Drawing.Size(1120,600);$dialog.MinimumSize=New-Object Drawing.Size(850,480);$dialog.StartPosition='CenterParent';$dialog.Icon=$Owner.Icon;$dialog.Font=$Owner.Font
    $layout=New-Object Windows.Forms.TableLayoutPanel;$layout.Dock='Fill';$layout.Padding=New-Object Windows.Forms.Padding(12);$layout.RowCount=3
    foreach ($height in @(70,-1,45)) { if ($height -lt 0) { [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100))) } else { [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',$height))) } }
    $intro=New-Object Windows.Forms.Label;$intro.Dock='Fill';$intro.Text='Selezionare gli Object ID Workplace da verificare. Proprietari e utenti registrati non indicano l''utente attualmente connesso a Windows. Seguono anteprima, verifica BitLocker e conferma; nessun oggetto AD o Intune viene eliminato.'
    $list=New-Object Windows.Forms.DataGridView;$list.Dock='Fill';$list.AllowUserToAddRows=$false;$list.RowHeadersVisible=$false;$list.AutoSizeColumnsMode='Fill';$list.AllowUserToDeleteRows=$false
    $check=New-Object Windows.Forms.DataGridViewCheckBoxColumn;$check.Name='Selected';$check.HeaderText='Seleziona';$check.FillWeight=30;[void]$list.Columns.Add($check)
    foreach ($column in @(@('Name','Nome Entra'),@('ObjectId','Object ID'),@('DeviceId','Device ID'),@('IsManaged','MDM'),@('Users','Proprietari / utenti'),@('UserNotes','Avvisi utenti'))) { $c=New-Object Windows.Forms.DataGridViewTextBoxColumn;$c.Name=$column[0];$c.HeaderText=$column[1];$c.ReadOnly=$true;[void]$list.Columns.Add($c) }
    foreach ($candidate in $Candidates) { $i=$list.Rows.Add([object[]]@($false,$candidate.Name,$candidate.ObjectId,$candidate.DeviceId,$candidate.IsManaged,$candidate.Users,$candidate.UserNotes));$list.Rows[$i].Tag=$candidate }
    $buttons=New-Object Windows.Forms.FlowLayoutPanel;$buttons.Dock='Fill';$buttons.FlowDirection='RightToLeft'
    $cancel=New-Object Windows.Forms.Button;$cancel.Text='Annulla';$cancel.DialogResult='Cancel';$cancel.Width=110
    $verify=New-Object Windows.Forms.Button;$verify.Name='VerifyRegisteredSelection';$verify.Text='Verifica selezionati';$verify.Width=180
    $verify.Add_Click({[void]$list.EndEdit();if (@($list.Rows | Where-Object { $_.Cells['Selected'].Value -eq $true }).Count) { $dialog.DialogResult='OK';$dialog.Close() }})
    $buttons.Controls.AddRange(@($cancel,$verify));$layout.Controls.Add($intro,0,0);$layout.Controls.Add($list,0,1);$layout.Controls.Add($buttons,0,2);$dialog.Controls.Add($layout);$dialog.CancelButton=$cancel;$dialog.AcceptButton=$cancel
    try { if ($dialog.ShowDialog($Owner) -eq 'OK') { return ,@($list.Rows | Where-Object { $_.Cells['Selected'].Value -eq $true } | ForEach-Object { $_.Tag.ObjectId }) };return $null }
    finally { $dialog.Dispose() }
}

function Show-DmRingReview {
    param($Plan,$Owner)
    $dialog=New-Object Windows.Forms.Form;$dialog.Name='RingAssignmentReview';$dialog.Text='Conferma assegnazioni Ring';$dialog.ClientSize=New-Object Drawing.Size(960,530);$dialog.MinimumSize=New-Object Drawing.Size(800,450);$dialog.StartPosition='CenterParent';$dialog.Icon=$Owner.Icon;$dialog.Font=$Owner.Font
    $layout=New-Object Windows.Forms.TableLayoutPanel;$layout.Dock='Fill';$layout.Padding=New-Object Windows.Forms.Padding(12);$layout.RowCount=3
    foreach ($height in @(65,-1,45)) { if ($height -lt 0) { [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100))) } else { [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',$height))) } }
    $intro=New-Object Windows.Forms.Label;$intro.Dock='Fill';$intro.Text='Verificare PC, Object ID e gruppo di destinazione. Saranno aggiunte solo le appartenenze elencate, dopo una nuova verifica. Le schede GLPI sono consultate per identificare il PC.'
    $text=New-Object Windows.Forms.RichTextBox;$text.Dock='Fill';$text.ReadOnly=$true;$text.WordWrap=$false;$text.Font=New-Object Drawing.Font('Consolas',9)
    $text.Text=(@($Plan.Items | ForEach-Object { $_.Name+' -> '+$_.TargetRing+"`r`n  Gruppo: "+$_.GroupName+"`r`n  Object ID: "+$_.ObjectId+"`r`n  Device ID: "+$_.DeviceId+"`r`n" }) -join "`r`n")
    $buttons=New-Object Windows.Forms.FlowLayoutPanel;$buttons.Dock='Fill';$buttons.FlowDirection='RightToLeft'
    $cancel=New-Object Windows.Forms.Button;$cancel.Text='Annulla';$cancel.DialogResult='Cancel';$cancel.Width=110
    $confirm=New-Object Windows.Forms.Button;$confirm.Name='ConfirmRingAssignments';$confirm.Text='Applica assegnazioni';$confirm.Width=200;$confirm.Add_Click({$dialog.DialogResult='OK';$dialog.Close()})
    $buttons.Controls.AddRange(@($cancel,$confirm));$layout.Controls.Add($intro,0,0);$layout.Controls.Add($text,0,1);$layout.Controls.Add($buttons,0,2);$dialog.Controls.Add($layout);$dialog.CancelButton=$cancel;$dialog.AcceptButton=$cancel
    try { return $dialog.ShowDialog($Owner) -eq 'OK' } finally { $dialog.Dispose() }
}

function Format-DmDetail {
    param($Row,[string]$Kind)
    if ($null -eq $Row) { return 'Selezionare una riga per consultare identita, date e inventario GLPI.' }
    $lines=New-Object 'Collections.Generic.List[string]';[void]$lines.Add($Row.Name)
    if ($Kind -eq 'Hybrid') {
        [void]$lines.Add('AD GUID: '+$Row.ADGuid+' | '+$Row.IdentityState)
        [void]$lines.Add('Percorso AD: '+$Row.ADDistinguishedName)
        [void]$lines.Add('Hybrid: '+$Row.HybridState+' | '+$Row.Anomalies)
        foreach ($device in $Row.EntraDevices) { [void]$lines.Add('Entra: '+$device.displayName+' | '+$device.trustType+' | Object ID: '+$device.id+' | Device ID: '+$device.deviceId+' | MDM: '+$device.isManaged+' | Ultima attivita: '+$device.approximateLastSignInDateTime) }
        foreach ($identity in $Row.IdentityRecords) { [void]$lines.Add('Identita Hybrid: '+$identity.ObjectId+' | '+$identity.State) }
    }
    else { [void]$lines.Add('Object ID: '+$Row.ObjectId+' | Device ID: '+$Row.DeviceId);[void]$lines.Add('Ring attuali: '+$Row.Rings+' | '+$Row.State+' | Ultima attivita: '+$Row.LastSignIn) }
    [void]$lines.Add('');[void]$lines.Add('INTUNE | seriale: '+$Row.IntuneSerial)
    foreach ($item in $Row.IntuneRecords) { [void]$lines.Add('  '+$item.deviceName+' | Managed Device ID: '+$item.id+' | Entra Device ID: '+$item.azureADDeviceId+' | Utente: '+$item.userPrincipalName+' | Ultimo check-in: '+$item.lastSyncDateTime) }
    [void]$lines.Add('');[void]$lines.Add('GLPI | '+$Row.GlpiState+' | Ricerca: '+$Row.GlpiMatchBy)
    foreach ($item in $Row.GlpiRecords) { [void]$lines.Add('  ID: '+$item.GlpiId+' | Nome: '+$item.Name+' | Seriale: '+$item.SerialNumber+' | Inventario: '+$item.InventoryNumber);[void]$lines.Add('  Stato: '+$item.State+' | Gruppo: '+$item.GroupPath+' | CENSITO: '+$Row.Censito+' | Ultimo inventario: '+$item.LastInventory) }
    if ($Row.GlpiError) { [void]$lines.Add($Row.GlpiError) }
    return $lines -join "`r`n"
}

function Get-DmVisibleRows {
    $u=$script:DmUi
    if ($null -eq $u.Snapshot) { return @() }
    $query=$u.Query.Text.Trim();$filter=[string]$u.Filter.SelectedItem
    @($u.Snapshot.Rows | Where-Object {
        $row=$_;$match=$true
        if ($query) { $text=@($row.Name,$row.IntuneSerial,$row.GlpiIds,$row.GlpiNames,$row.GlpiStatus,$row.GlpiGroup,(Get-DmValue $row 'OUName' ''),(Get-DmValue $row 'ADGuid' ''),(Get-DmValue $row 'ObjectId' ''),(Get-DmValue $row 'EntraObjectIds' ''),(Get-DmValue $row 'EntraDeviceIds' '')) -join ' ';$match=$text.IndexOf($query,[StringComparison]::OrdinalIgnoreCase) -ge 0 }
        if (-not $match) { return $false }
        switch ($filter) {
            'Orfani' { return $row.Orphan }
            'Gia assegnati' { return -not $row.Orphan }
            'Piu Ring' { return $row.State -eq 'Piu Ring' }
            'Solo problemi Hybrid' { return $row.Severity -ne 'Good' }
            'Assenti da Entra' { return $row.EntraCount -eq 0 }
            'Senza Hybrid' { return $row.HybridCount -eq 0 }
            'Hybrid duplicati' { return $row.HybridCount -gt 1 }
            'Ownership Personal' { return $row.HasPersonal }
            'Hybrid non gestiti MDM' { return $row.HasHybridNotManaged }
            'Account AD disabilitati' { return -not $row.ADEnabled }
            'Con Registered' { return $row.RegisteredCount -gt 0 }
            'GUID non corrispondente' { return $row.IdentityState -eq 'Non corrisponde' }
            'GLPI assente' { return $row.GlpiState -eq 'Assente' }
            'GLPI duplicato' { return $row.GlpiState -like 'Duplicati*' }
            default { return $true }
        }
    })
}

function Update-DmGrid {
    $u=$script:DmUi;$u.Populating=$true
    try {
        $u.Grid.Rows.Clear()
        $visible=@(Get-DmVisibleRows)
        foreach ($row in $visible) {
            $index=$u.Grid.Rows.Add();$gridRow=$u.Grid.Rows[$index];$gridRow.Tag=$row
            foreach ($column in $u.Grid.Columns) { $gridRow.Cells[$column.Name].Value=Get-DmValue $row $column.Name '' }
            if ($u.Kind -eq 'Ring') { $gridRow.Cells['TargetRing'].ReadOnly=$u.Access.ReadOnly -or -not $row.Orphan }
            if ($row.SerialConflict -or $row.GlpiState -like 'Duplicati*' -or ($u.Kind -eq 'Hybrid' -and $row.Severity -eq 'Error')) { $gridRow.DefaultCellStyle.BackColor=[Drawing.Color]::MistyRose }
            elseif ($row.GlpiState -eq 'Non verificabile' -or ($u.Kind -eq 'Hybrid' -and $row.Severity -eq 'Warning')) { $gridRow.DefaultCellStyle.BackColor=[Drawing.Color]::LemonChiffon }
            if ($row.Censito -eq 'Si') { $gridRow.Cells['Censito'].Style.ForeColor=[Drawing.Color]::DarkGreen }
        }
        $u.Grid.ClearSelection();$u.Details.Text=Format-DmDetail $null $u.Kind
        $u.Counter.Text='Risultati: '+$visible.Count+' | Selezionati: 0'
    }
    finally { $u.Populating=$false;Update-DmButtons }
}

function Update-DmButtons {
    $u=$script:DmUi;$idle=$null -eq $u.Pipeline
    $u.Refresh.Enabled=$idle;$u.Stop.Enabled=-not $idle -and -not $u.Writing
    $u.Query.Enabled=$idle;$u.Filter.Enabled=$idle;$u.Grid.Enabled=$idle
    $u.Export.Enabled=$idle -and $u.Grid.Rows.Count -gt 0
    $u.Write.Enabled=$idle -and -not $u.Access.ReadOnly -and $u.Grid.SelectedRows.Count -gt 0
    $u.OpenGlpi.Enabled=$idle -and $u.Grid.SelectedRows.Count -eq 1 -and $u.Grid.SelectedRows[0].Tag.GlpiRecords.Count -eq 1
    if ($u.Kind -eq 'Ring') { $u.Bulk.Enabled=$u.Write.Enabled;$u.Ring.Enabled=$idle -and -not $u.Access.ReadOnly }
}

function Start-DmTask {
    param([string]$Operation,$Payload=$null)
    $u=$script:DmUi;if ($null -ne $u.Pipeline) { return }
    $u.Operation=$Operation;$u.Cancelled=$false;$u.StopInvocation=$null;$u.Writing=$Operation -in @('Cleanup','Assign')
    $u.Pipeline=[PowerShell]::Create();$u.Pipeline.Runspace=$u.Worker
    $worker={
        param($Root,$Kind,$Operation,$Config,$Env,$Access,$Payload,$Queue)
        $ErrorActionPreference='Stop'
        Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
        $file='HybridJoin.Core.psm1';if ($Kind -eq 'Ring') { $file='RingManager.Core.psm1' }
        Import-Module (Join-Path $Root $file) -ErrorAction Stop
        switch ($Operation) {
            'Snapshot' { if ($Kind -eq 'Hybrid') { Get-HybridJoinSnapshot -ConfigPath $Config -EnvPath $Env -GraphAccess $Access -ProgressQueue $Queue } else { Get-RingManagerSnapshot -ConfigPath $Config -EnvPath $Env -GraphAccess $Access -ProgressQueue $Queue } }
            'Candidates' { Get-HybridCleanupCandidates -RowKeys $Payload -GraphAccess $Access -ProgressQueue $Queue }
            'PrepareCleanup' { New-HybridCleanupPlan -ObjectIds $Payload -ConfigPath $Config -EnvPath $Env -GraphAccess $Access -ProgressQueue $Queue }
            'Cleanup' { Invoke-HybridCleanupPlan -PlanId $Payload.PlanId -Decision $Payload.Decision -GraphAccess $Access -ProgressQueue $Queue -Confirm:$false }
            'RingPlan' { New-RingAssignmentPlan -Assignments $Payload -ConfigPath $Config -GraphAccess $Access -ProgressQueue $Queue }
            'Assign' { Invoke-RingAssignmentPlan -PlanId $Payload -GraphAccess $Access -ProgressQueue $Queue -Confirm:$false }
            default { throw 'Operazione del modulo non prevista.' }
        }
    }
    [void]$u.Pipeline.AddScript($worker.ToString()).AddArgument($PSScriptRoot).AddArgument($u.Kind).AddArgument($Operation).AddArgument($u.ConfigPath).AddArgument($u.EnvPath).AddArgument($u.Access).AddArgument($Payload).AddArgument($u.Queue)
    $u.Status.Text='Operazione in corso: '+$Operation+'...';Update-DmButtons
    try { $u.Invocation=$u.Pipeline.BeginInvoke();$u.Timer.Start() }
    catch { $u.Pipeline.Dispose();$u.Pipeline=$null;Update-DmButtons;throw }
}

function Save-DmCsv {
    param([object[]]$Rows,[string]$Path,[string]$Kind,[switch]$Report)
    $records=@(foreach ($row in $Rows) {
        $record=[ordered]@{}
        $fields=@('Name','IntuneSerial','GlpiState','GlpiMatchBy','GlpiIds','GlpiNames','GlpiStatus','GlpiGroup','Censito')
        if ($Report) { $fields=@('AtUtc','Name','Source','Destination','ObjectId','Id','DeviceId','GroupId','TargetRing','State','Error') }
        elseif ($Kind -eq 'Hybrid') { $fields+=@('ADGuid','ADDistinguishedName','OUName','EntraObjectIds','EntraDeviceIds','HybridState','IdentityState','EntraCount','RegisteredCount','Anomalies') }
        else { $fields+=@('ObjectId','DeviceId','Rings','State','TargetRing') }
        foreach ($field in $fields) { $record[$field]=ConvertTo-DmCsvValue (Get-DmValue $row $field '') }
        [pscustomobject]$record
    })
    $records | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8 -Delimiter ';'
}

function Complete-DmTask {
    $u=$script:DmUi
    $notice=$null;while ($u.Queue.TryDequeue([ref]$notice)) { if ($notice.Message) { $u.Status.Text=$notice.Message } }
    if ($null -eq $u.Invocation -or -not $u.Invocation.IsCompleted) { return }
    $u.Timer.Stop();$operation=$u.Operation;$result=$null;$errorText=''
    try {
        if ($null -ne $u.StopInvocation) { $u.Pipeline.EndStop($u.StopInvocation) }
        $output=@($u.Pipeline.EndInvoke($u.Invocation))
        if (-not $u.Cancelled) {
            if ($u.Pipeline.Streams.Error.Count) { throw $u.Pipeline.Streams.Error[0] }
            if ($output.Count -ne 1) { throw 'Risposta del modulo incompleta.' };$result=$output[0]
        }
    }
    catch { if (-not $u.Cancelled) { $errorText=$_.Exception.Message } }
    finally { $u.Pipeline.Dispose();$u.Pipeline=$null;$u.Invocation=$null;$u.StopInvocation=$null;$u.Writing=$false;Update-DmButtons }
    if ($u.Closing) { $u.Form.Close();return }
    if ($u.Cancelled) { $u.Status.Text='Lettura annullata. Aggiornare i dati prima delle operazioni.';$u.Snapshot=$null;Update-DmGrid;return }
    if ($errorText) { $u.Status.Text='Operazione non completata: '+$errorText;if ($operation -eq 'Snapshot') { $u.Snapshot=$null;Update-DmGrid };return }
    switch ($operation) {
        'Snapshot' {
            $u.Snapshot=$result
            if ($u.Kind -eq 'Ring') {
                $u.Ring.Items.Clear();[void]$u.Ring.Items.Add('');$column=$u.Grid.Columns['TargetRing'];$column.Items.Clear();[void]$column.Items.Add('')
                foreach ($group in @($result.Groups | Where-Object IsWritable)) { [void]$u.Ring.Items.Add($group.Label);[void]$column.Items.Add($group.Label) };$u.Ring.SelectedIndex=0
            }
            Update-DmGrid;$u.Summary.Text=$result.Summary
            $overview=@($result.Summary,'Lettura UTC: '+$result.CapturedAtUtc)
            if ($u.Kind -eq 'Ring') { $overview+=@($result.Groups | ForEach-Object { $mode='Solo controllo';if ($_.IsWritable) { $mode='Controllo e destinazione' };$_.Label+' | '+$_.Name+' | ID: '+$_.Id+' | Oggetti transitivi: '+$_.MemberCount+' | '+$mode+' | '+$_.Reason }) }
            else { $overview+=@($result.OuStatistics | ForEach-Object { $_.Name+' | Computer: '+$_.Count+' | '+$_.DistinguishedName }) }
            $u.Overview.Text=$overview -join [Environment]::NewLine
            $u.Status.Text='Intune: '+$result.Sources.IntuneState+' '+$result.Sources.IntuneError+' | GLPI: '+$result.Sources.GlpiState+' '+$result.Sources.GlpiError
        }
        'Candidates' {
            if (-not $result.Candidates.Count) { $u.Status.Text='Nessuna registrazione Workplace per i PC selezionati.';return }
            $ids=Show-DmSelection -Candidates $result.Candidates -Owner $u.Form
            if ($null -ne $ids -and $ids.Count) { Start-DmTask PrepareCleanup $ids }
        }
        'PrepareCleanup' { $decision=Show-AssistenteITRemovalPreview -Plan $result -Owner $u.Form;if ($null -ne $decision) { Start-DmTask Cleanup ([pscustomobject]@{PlanId=$result.PlanId;Decision=$decision}) } }
        'RingPlan' { if (Show-DmRingReview -Plan $result -Owner $u.Form) { Start-DmTask Assign $result.PlanId } }
        default {
            $u.LastReport=@($result.Results);$u.Report.Text=($u.LastReport | Format-List * | Out-String);$u.Tabs.SelectedTab=$u.ReportTab
            $directory=Join-Path (Split-Path (Split-Path $u.ConfigPath -Parent) -Parent) ('Reports/'+$u.Kind)
            try { [void][IO.Directory]::CreateDirectory($directory);$path=Join-Path $directory ((Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'.csv');Save-DmCsv -Rows $u.LastReport -Path $path -Kind $u.Kind -Report;$u.Report.Text+="`r`nResoconto salvato: "+$path }
            catch { $u.Report.Text+="`r`nResoconto non salvato: "+$_.Exception.Message }
            $u.Snapshot=$null;Update-DmGrid;Start-DmTask Snapshot
        }
    }
}

function Show-DeviceModuleWindow {
    param([ValidateSet('Hybrid','Ring')][string]$Kind,[string]$ConfigPath,[string]$EnvPath,$GraphAccess,[switch]$SmokeTest)
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Il modulo richiede Windows PowerShell in STA.' }
    Add-Type -AssemblyName System.Windows.Forms;Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    Import-Module (Join-Path $PSScriptRoot 'DeviceModules.Core.psm1') -ErrorAction Stop
    . (Join-Path $PSScriptRoot 'ComputerExplorer.Recovery.UI.ps1')
    . (Join-Path $PSScriptRoot 'ComputerExplorer.Removal.UI.ps1')
    if ($null -eq $GraphAccess -or -not $GraphAccess.CanOpen) { throw 'Eseguire Accesso dal wrapper prima di aprire il modulo.' }
    $script:DmUi=@{Kind=$Kind;ConfigPath=$ConfigPath;EnvPath=$EnvPath;Access=$GraphAccess;Snapshot=$null;Pipeline=$null;Invocation=$null;StopInvocation=$null;Cancelled=$false;Closing=$false;Writing=$false;Populating=$false;LastReport=@();Queue=(New-Object 'Collections.Concurrent.ConcurrentQueue[object]')}
    $u=$script:DmUi
    $form=New-Object Windows.Forms.Form;$form.Name='DeviceModule-'+$Kind;$form.Text='Assistente IT - Verifica Hybrid Join';if ($Kind -eq 'Ring') { $form.Text='Assistente IT - Gestione Ring Intune' }
    $form.ClientSize=New-Object Drawing.Size(1320,850);$form.MinimumSize=New-Object Drawing.Size(1050,720);$form.StartPosition='CenterScreen';$form.Font=New-Object Drawing.Font('Segoe UI',9);$form.AutoScaleMode='Dpi'
    $icon=New-Object Drawing.Icon((Join-Path $PSScriptRoot 'assets/AssistenteIT.ico'));$form.Icon=$icon;$u.Form=$form
    $layout=New-Object Windows.Forms.TableLayoutPanel;$layout.Dock='Fill';$layout.Padding=New-Object Windows.Forms.Padding(12);$layout.ColumnCount=1;$layout.RowCount=6
    foreach ($height in @(58,48,42,-1,38,65)) { if ($height -lt 0) { [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100))) } else { [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',$height))) } }
    $summary=New-Object Windows.Forms.Label;$summary.Dock='Fill';$summary.Text='Premere Aggiorna dati per leggere le fonti.';$summary.Font=New-Object Drawing.Font('Segoe UI',10);$u.Summary=$summary
    $toolbar=New-Object Windows.Forms.FlowLayoutPanel;$toolbar.Dock='Fill';$toolbar.WrapContents=$false
    foreach ($spec in @(@('Refresh','Aggiorna dati (F5)',160),@('Stop','Interrompi lettura',145),@('Export','Esporta CSV',120),@('OpenGlpi','Apri GLPI',115),@('Write','Pulizia Registered',175))) { $button=New-Object Windows.Forms.Button;$button.Name=$spec[0];$button.Text=$spec[1];$button.Width=$spec[2];$button.Height=32;$u[$spec[0]]=$button;$toolbar.Controls.Add($button) }
    if ($Kind -eq 'Ring') { $u.Write.Text='Verifica assegnazioni';$u.Write.Width=190 }
    $mode=New-Object Windows.Forms.Label;$mode.AutoSize=$true;$mode.Padding=New-Object Windows.Forms.Padding(8,8,0,0);$mode.Text='Sola lettura';if (-not $GraphAccess.ReadOnly) { $mode.Text='Lettura e scrittura' };$toolbar.Controls.Add($mode)
    $filters=New-Object Windows.Forms.FlowLayoutPanel;$filters.Dock='Fill';$filters.WrapContents=$false
    $queryLabel=New-Object Windows.Forms.Label;$queryLabel.Text='Cerca:';$queryLabel.AutoSize=$true;$queryLabel.Padding=New-Object Windows.Forms.Padding(0,7,0,0)
    $query=New-Object Windows.Forms.TextBox;$query.Name='DeviceModuleSearch';$query.Width=240;$u.Query=$query
    $filter=New-Object Windows.Forms.ComboBox;$filter.Name='DeviceModuleFilter';$filter.DropDownStyle='DropDownList';$filter.Width=225;$u.Filter=$filter
    $choices=@('Tutti','Solo problemi Hybrid','Con Registered','GUID non corrispondente','Assenti da Entra','Senza Hybrid','Hybrid duplicati','Ownership Personal','Hybrid non gestiti MDM','Account AD disabilitati','GLPI assente','GLPI duplicato');if ($Kind -eq 'Ring') { $choices=@('Orfani','Tutti','Gia assegnati','Piu Ring','GLPI assente','GLPI duplicato') }
    foreach ($choice in $choices) { [void]$filter.Items.Add($choice) };$filter.SelectedIndex=0;$filters.Controls.AddRange(@($queryLabel,$query,$filter))
    if ($Kind -eq 'Ring') {
        $ring=New-Object Windows.Forms.ComboBox;$ring.Name='BulkTargetRing';$ring.DropDownStyle='DropDownList';$ring.Width=120;$u.Ring=$ring
        $bulk=New-Object Windows.Forms.Button;$bulk.Name='SetRingForSelected';$bulk.Text='Imposta sui selezionati';$bulk.Width=190;$bulk.Height=28;$u.Bulk=$bulk;$filters.Controls.AddRange(@($ring,$bulk))
        $bulk.Add_Click({$u=$script:DmUi;if (-not $u.Ring.SelectedItem) { return };foreach ($row in $u.Grid.SelectedRows) { if ($row.Tag.Orphan -and -not $u.Access.ReadOnly) { $row.Cells['TargetRing'].Value=[string]$u.Ring.SelectedItem } }})
    }
    $split=New-Object Windows.Forms.SplitContainer;$split.Dock='Fill';$split.Size=New-Object Drawing.Size(1280,570);$split.Orientation='Horizontal';$split.SplitterDistance=330;$split.Panel1MinSize=100;$split.Panel2MinSize=80
    $grid=New-Object Windows.Forms.DataGridView;$grid.Name='DeviceModuleGrid';$grid.Dock='Fill';$grid.AutoGenerateColumns=$false;$grid.AllowUserToAddRows=$false;$grid.AllowUserToDeleteRows=$false;$grid.AllowUserToResizeRows=$false;$grid.RowHeadersVisible=$false;$grid.MultiSelect=$true;$grid.SelectionMode='FullRowSelect';$grid.BackgroundColor=[Drawing.SystemColors]::Window;$grid.ClipboardCopyMode='EnableAlwaysIncludeHeaderText';$grid.AlternatingRowsDefaultCellStyle.BackColor=[Drawing.Color]::FromArgb(247,249,252);$u.Grid=$grid
    $columns=@(@('Name','Computer',165),@('HybridState','Hybrid',180),@('IdentityState','Identita AD/Entra',145),@('RegisteredCount','Registered',90),@('OUName','OU',175))
    if ($Kind -eq 'Ring') { $columns=@(@('Name','Computer',165),@('State','Stato Ring',120),@('Rings','Ring attuali',130),@('TargetRing','Ring destinazione',140),@('ObjectId','Object ID Entra',245)) }
    $columns+=@(@('IntuneSerial','Seriale Intune',135),@('GlpiState','GLPI',125),@('GlpiIds','ID GLPI',80),@('GlpiNames','Nome GLPI',155),@('GlpiStatus','Stato GLPI',165),@('Censito','Censito',75))
    foreach ($spec in $columns) {
        if ($spec[0] -eq 'TargetRing') { $column=New-Object Windows.Forms.DataGridViewComboBoxColumn;$column.FlatStyle='Flat';[void]$column.Items.Add('');$column.ReadOnly=$GraphAccess.ReadOnly }
        else { $column=New-Object Windows.Forms.DataGridViewTextBoxColumn;$column.ReadOnly=$true;$column.SortMode='Automatic' }
        $column.Name=$spec[0];$column.HeaderText=$spec[1];$column.Width=$spec[2];[void]$grid.Columns.Add($column)
    }
    $tabs=New-Object Windows.Forms.TabControl;$tabs.Dock='Fill';$u.Tabs=$tabs
    $detailsTab=New-Object Windows.Forms.TabPage;$detailsTab.Text='Dettagli dispositivo';$reportTab=New-Object Windows.Forms.TabPage;$reportTab.Text='Resoconto operazioni';$u.ReportTab=$reportTab
    $details=New-Object Windows.Forms.RichTextBox;$details.Name='DeviceModuleDetails';$details.Dock='Fill';$details.ReadOnly=$true;$details.WordWrap=$false;$details.Font=New-Object Drawing.Font('Consolas',9);$u.Details=$details
    $report=New-Object Windows.Forms.RichTextBox;$report.Dock='Fill';$report.ReadOnly=$true;$report.WordWrap=$false;$report.Font=$details.Font;$u.Report=$report
    $overviewTab=New-Object Windows.Forms.TabPage;$overviewTab.Text='Riepilogo fonti';$overviewText=New-Object Windows.Forms.RichTextBox;$overviewText.Dock='Fill';$overviewText.ReadOnly=$true;$overviewText.WordWrap=$false;$overviewText.Font=$details.Font;$overviewTab.Controls.Add($overviewText);$u.Overview=$overviewText
    $detailsTab.Controls.Add($details);$reportTab.Controls.Add($report);$tabs.TabPages.AddRange(@($detailsTab,$reportTab,$overviewTab));$split.Panel1.Controls.Add($grid);$split.Panel2.Controls.Add($tabs)
    $counter=New-Object Windows.Forms.Label;$counter.Dock='Fill';$counter.TextAlign='MiddleLeft';$u.Counter=$counter
    $status=New-Object Windows.Forms.Label;$status.Name='DeviceModuleStatus';$status.Dock='Fill';$status.Text='Accesso Microsoft condiviso con il wrapper. GLPI usa i token salvati nelle Impostazioni.';$u.Status=$status
    $layout.Controls.Add($summary,0,0);$layout.Controls.Add($toolbar,0,1);$layout.Controls.Add($filters,0,2);$layout.Controls.Add($split,0,3);$layout.Controls.Add($counter,0,4);$layout.Controls.Add($status,0,5);$form.Controls.Add($layout)
    $grid.Add_SelectionChanged({$u=$script:DmUi;if ($u.Populating) { return };$row=$null;if ($u.Grid.SelectedRows.Count) { $row=$u.Grid.SelectedRows[0].Tag };$u.Details.Text=Format-DmDetail $row $u.Kind;$u.Counter.Text='Risultati: '+$u.Grid.Rows.Count+' | Selezionati: '+$u.Grid.SelectedRows.Count;Update-DmButtons})
    $grid.Add_CurrentCellDirtyStateChanged({$u=$script:DmUi;if ($u.Grid.IsCurrentCellDirty) { [void]$u.Grid.CommitEdit('Commit') }})
    $grid.Add_CellValueChanged({param($sender,$eventArgs);$u=$script:DmUi;if ($u.Populating -or $u.Kind -ne 'Ring' -or $eventArgs.RowIndex -lt 0 -or $eventArgs.ColumnIndex -ne $u.Grid.Columns['TargetRing'].Index) { return };$row=$u.Grid.Rows[$eventArgs.RowIndex];if ($null -ne $row.Tag) { $row.Tag.TargetRing=[string]$row.Cells['TargetRing'].Value }})
    $grid.Add_DataError({param($sender,$eventArgs);$eventArgs.ThrowException=$false;$script:DmUi.Status.Text='Selezione Ring non valida: aggiornare i dati.'})
    $query.Add_TextChanged({if (-not $script:DmUi.Populating) { Update-DmGrid }});$filter.Add_SelectedIndexChanged({Update-DmGrid})
    $u.Refresh.Add_Click({Start-DmTask Snapshot})
    $u.Stop.Add_Click({$u=$script:DmUi;if ($null -ne $u.Pipeline -and -not $u.Writing -and $null -eq $u.StopInvocation) { $u.Cancelled=$true;$u.StopInvocation=$u.Pipeline.BeginStop($null,$null);$u.Status.Text='Interruzione lettura...' }})
    $u.Write.Add_Click({
        $u=$script:DmUi;if ($u.Access.ReadOnly) { return }
        if ($u.Kind -eq 'Hybrid') { Start-DmTask Candidates ([string[]]@($u.Grid.SelectedRows | ForEach-Object { $_.Tag.Key })) }
        else {
            [void]$u.Grid.EndEdit()
            $assignments=@($u.Grid.Rows | Where-Object { $_.Tag.Orphan -and $_.Tag.TargetRing } | ForEach-Object { [pscustomobject]@{ObjectId=$_.Tag.ObjectId;TargetRing=$_.Tag.TargetRing} })
            if (-not $assignments.Count) { $u.Status.Text='Scegliere un Ring nelle righe degli orfani, oppure impostarlo sui selezionati.';return };Start-DmTask RingPlan $assignments
        }
    })
    $u.OpenGlpi.Add_Click({$u=$script:DmUi;if ($u.Grid.SelectedRows.Count -ne 1 -or $u.Grid.SelectedRows[0].Tag.GlpiRecords.Count -ne 1) { return };$config=Read-ExplorerConfiguration $u.ConfigPath;$base=([string]$config.Settings.Glpi.BaseUri).TrimEnd('/');$id=[int]$u.Grid.SelectedRows[0].Tag.GlpiRecords[0].GlpiId;if ($base -match '^https?://' -and $base -match '/apirest\.php$' -and $id -gt 0) { [void][Diagnostics.Process]::Start(($base -replace '/apirest\.php$','')+'/front/computer.form.php?id='+$id) }})
    $u.Export.Add_Click({$u=$script:DmUi;$save=New-Object Windows.Forms.SaveFileDialog;$save.Filter='File CSV (*.csv)|*.csv';$save.DefaultExt='csv';$save.AddExtension=$true;$save.FileName=$u.Kind+'-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.csv';try { if ($save.ShowDialog($u.Form) -eq 'OK') { Save-DmCsv -Rows @($u.Grid.Rows | ForEach-Object { $_.Tag }) -Path $save.FileName -Kind $u.Kind;$u.Status.Text='CSV esportato: '+$save.FileName } } catch { $u.Status.Text='Esportazione non riuscita: '+$_.Exception.Message } finally { $save.Dispose() }})
    $form.KeyPreview=$true;$form.Add_KeyDown({param($sender,$eventArgs);if ($eventArgs.KeyCode -eq 'F5' -and $script:DmUi.Refresh.Enabled) { $script:DmUi.Refresh.PerformClick();$eventArgs.Handled=$true }})
    $form.Add_FormClosing({param($sender,$eventArgs);$u=$script:DmUi;if ($null -ne $u.Pipeline) { $eventArgs.Cancel=$true;if ($u.Writing) { $u.Status.Text='Attendere il completamento delle operazioni.' } else { $u.Closing=$true;$u.Stop.PerformClick() } }})
    $worker=[RunspaceFactory]::CreateRunspace();$worker.ApartmentState='STA';$worker.ThreadOptions='ReuseThread';$worker.Open();$u.Worker=$worker;$script:Worker=$worker
    $timer=New-Object Windows.Forms.Timer;$timer.Interval=100;$timer.Add_Tick({Complete-DmTask});$u.Timer=$timer
    Update-DmButtons;Update-DmGrid
    if (Get-Command Initialize-AssistenteITWindowIdentity -ErrorAction SilentlyContinue) { Initialize-AssistenteITWindowIdentity -InstallRoot $PSScriptRoot -Window $form }
    try { if ($SmokeTest) { $form.CreateControl();$form.PerformLayout();return $form } else { [void]$form.ShowDialog() } }
    finally { if (-not $SmokeTest) { $timer.Stop();$timer.Dispose();if ($null -ne $u.Pipeline) { $u.Pipeline.Stop();$u.Pipeline.Dispose() };$worker.Close();$worker.Dispose();$form.Dispose();$icon.Dispose() } }
}
