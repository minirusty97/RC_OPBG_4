#requires -version 5.1
function Get-UiSetting { param($Object,[string]$Name,$Default);Get-DmValue $Object $Name $Default }

function Show-DmSelection {
    param([object[]]$Candidates,$Owner)
    $dialog=New-Object Windows.Forms.Form;$dialog.Name='HybridRegisteredSelection';$dialog.Text='Seleziona le registrazioni Entra Registered'
    $dialog.ClientSize=New-Object Drawing.Size(1120,600);$dialog.MinimumSize=New-Object Drawing.Size(850,480);$dialog.StartPosition='CenterParent';$dialog.Icon=$Owner.Icon;$dialog.Font=$Owner.Font
    $layout=New-Object Windows.Forms.TableLayoutPanel;$layout.Dock='Fill';$layout.Padding=New-Object Windows.Forms.Padding(12);$layout.RowCount=3
    foreach ($height in @(70,-1,45)) { if ($height -lt 0) { [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100))) } else { [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',$height))) } }
    $intro=New-Object Windows.Forms.Label;$intro.Dock='Fill'
    $intro.Text=$Candidates.Count.ToString()+' registrazioni Entra Registered nelle OU analizzate. Seleziona gli oggetti da verificare prima dell''anteprima BitLocker e della conferma.'
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
    $dialog=New-Object Windows.Forms.Form;$dialog.Name='RingAssignmentReview';$dialog.Text='Conferma modifiche Ring';$dialog.ClientSize=New-Object Drawing.Size(960,530);$dialog.MinimumSize=New-Object Drawing.Size(800,450);$dialog.StartPosition='CenterParent';$dialog.Icon=$Owner.Icon;$dialog.Font=$Owner.Font
    $layout=New-Object Windows.Forms.TableLayoutPanel;$layout.Dock='Fill';$layout.Padding=New-Object Windows.Forms.Padding(12);$layout.RowCount=3
    foreach ($height in @(65,-1,45)) { if ($height -lt 0) { [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100))) } else { [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',$height))) } }
    $intro=New-Object Windows.Forms.Label;$intro.Dock='Fill';$intro.Text='Verificare PC, Object ID, destinazione e origini da rimuovere. La destinazione viene aggiunta e verificata prima di rimuovere solo le origini elencate. Le schede GLPI aiutano a identificare il PC.'
    $text=New-Object Windows.Forms.RichTextBox;$text.Dock='Fill';$text.ReadOnly=$true;$text.WordWrap=$false;$text.Font=New-Object Drawing.Font('Consolas',9)
    $text.Text=(@($Plan.Items | ForEach-Object { $_.Name+' | '+$_.Action+' -> '+$_.TargetRing+"`r`n  Destinazione: "+$_.GroupName+" / "+$_.GroupId+"`r`n  Rimuovi da: "+$(if ($_.RemoveGroups) {$_.RemoveGroups} else {'Nessuna origine'})+"`r`n  Object ID: "+$_.ObjectId+"`r`n  Device ID: "+$_.DeviceId+"`r`n" }) -join "`r`n")
    $buttons=New-Object Windows.Forms.FlowLayoutPanel;$buttons.Dock='Fill';$buttons.FlowDirection='RightToLeft'
    $cancel=New-Object Windows.Forms.Button;$cancel.Text='Annulla';$cancel.DialogResult='Cancel';$cancel.Width=110
    $confirm=New-Object Windows.Forms.Button;$confirm.Name='ConfirmRingAssignments';$confirm.Text='Applica modifiche';$confirm.Width=200;$confirm.Add_Click({$dialog.DialogResult='OK';$dialog.Close()})
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
        [void]$lines.Add('Ultima modifica AD: '+(Format-ExplorerDate (Get-DmValue $Row 'ADLastModified')))
        [void]$lines.Add('OU analizzate: '+$Row.OUDistinguishedName)
        [void]$lines.Add('Hybrid: '+$Row.HybridState+' | '+$Row.Anomalies)
        foreach ($device in $Row.EntraDevices) {
            $lastActivity = Format-ExplorerDate (Get-DmValue $device 'approximateLastSignInDateTime')
            [void]$lines.Add('Entra: '+$device.displayName+' | '+$device.trustType+' | Object ID: '+$device.id+' | Device ID: '+$device.deviceId+' | MDM: '+$device.isManaged+' | Ultima attività: '+$lastActivity)
        }
        foreach ($identity in $Row.IdentityRecords) { [void]$lines.Add('Identita Hybrid: '+$identity.ObjectId+' | '+$identity.State) }
    }
    else { [void]$lines.Add('Object ID: '+$Row.ObjectId+' | Device ID: '+$Row.DeviceId);[void]$lines.Add('Ring attuali: '+$Row.Rings+' | '+$Row.State+' | Ultima attivita: '+$Row.LastSignIn) }
    [void]$lines.Add('');[void]$lines.Add('INTUNE | seriale: '+$Row.IntuneSerial)
    if ($Kind -eq 'Hybrid') {
        $attestation = 'Attestazione: ' + $Row.IntuneState
        if ($Row.IntuneReason) { $attestation += ' | ' + $Row.IntuneReason }
        [void]$lines.Add($attestation)
    }
    foreach ($item in $Row.IntuneRecords) { [void]$lines.Add('  '+$item.deviceName+' | Managed Device ID: '+$item.id+' | Entra Device ID: '+$item.azureADDeviceId+' | Utente: '+$item.userPrincipalName+' | Ultimo check-in: '+$item.lastSyncDateTime) }
    [void]$lines.Add('');[void]$lines.Add('GLPI | '+$Row.GlpiState+' | Ricerca: '+$Row.GlpiMatchBy)
    foreach ($item in $Row.GlpiRecords) {
        [void]$lines.Add('  ID: '+$item.GlpiId+' | Nome: '+$item.Name+' | Seriale: '+$item.SerialNumber+' | Inventario: '+$item.InventoryNumber)
        [void]$lines.Add('  Stato: '+$item.State+' | Gruppo: '+$item.GroupPath+' | CENSITO: '+$Row.Censito+' | Ultimo inventario: '+$item.LastInventory)
        $supplier=Get-DmValue $item 'SupplierName' ''
        $supplierError=Get-DmValue $item 'SupplierError' ''
        if ($supplier -or $supplierError) { [void]$lines.Add('  Reparto GLPI (Fornitore): '+$supplier+$supplierError) }
    }
    if ($Row.GlpiError) { [void]$lines.Add($Row.GlpiError) }
    return $lines -join "`r`n"
}

function Update-DmFilterValues {
    param([switch]$KeepSelection)
    $u=$script:DmUi
    $field=$u.FilterFields[[string]$u.Filter.SelectedItem]
    $previous=$null
    $typed=''
    if ($KeepSelection -and $u.FilterValue.SelectedIndex -ge 0) { $previous=$u.FilterChoices[$u.FilterValue.SelectedIndex] }
    if ($KeepSelection -and $u.Kind -eq 'Hybrid' -and ($null -eq $previous -or $u.FilterValue.Text -ne $previous.Label)) {
        $typed=$u.FilterValue.Text
        $previous=$null
    }
    $choices=@(
        [pscustomobject]@{Label='Tutti';Mode='All';Value=''}
        if ($null -ne $u.Snapshot) {
            if ($field -eq 'Rings') {
                [pscustomobject]@{Label='Senza Ring';Mode='None';Value=''}
                [pscustomobject]@{Label='Con almeno un Ring';Mode='Assigned';Value=''}
                [pscustomobject]@{Label='Con più Ring';Mode='Multiple';Value=''}
                foreach ($group in $u.Snapshot.Groups) {
                    [pscustomobject]@{Label=('Include '+$group.Label);Mode='Group';Value=$group.Id}
                }
            }
            elseif ($field -eq 'Anomalies') {
                foreach ($label in @('Solo problemi Hybrid','Ownership Personal','Hybrid non gestiti MDM','Account AD disabilitati')) {
                    [pscustomobject]@{Label=$label;Mode='Anomaly';Value=$label}
                }
            }
            else {
                if ($field -eq 'RegisteredCount') {
                    [pscustomobject]@{Label='Con Registered';Mode='WithRegistered';Value=''}
                    [pscustomobject]@{Label='Senza Registered';Mode='WithoutRegistered';Value=''}
                }
                $values=@($u.Snapshot.Rows | ForEach-Object { [string](Get-DmValue $_ $field '') } | Sort-Object -Unique)
                foreach ($value in $values) {
                    $label=$value
                    if (-not $label) { $label='(Vuoto)' }
                    [pscustomobject]@{Label=$label;Mode='Value';Value=$value}
                }
            }
        }
    )
    $u.Populating=$true
    $u.FilterValue.BeginUpdate()
    try {
        if ($u.Kind -eq 'Hybrid') {
            $u.FilterValue.DropDownStyle='DropDown'
            if ($field -eq 'Anomalies') { $u.FilterValue.DropDownStyle='DropDownList' }
        }
        $u.FilterValue.Items.Clear()
        $u.FilterChoices=$choices
        $index=0
        foreach ($choice in $choices) {
            $i=$u.FilterValue.Items.Add($choice.Label)
            if ($previous -and $previous.Mode -eq $choice.Mode -and $previous.Value -eq $choice.Value) { $index=$i }
        }
        $u.FilterValue.SelectedIndex=$index
        if ($typed -and $field -ne 'Anomalies') {
            $u.FilterValue.SelectedIndex=-1
            $u.FilterValue.Text=$typed
        }
    }
    finally { $u.FilterValue.EndUpdate();$u.Populating=$false }
}

function Get-DmVisibleRows {
    $u=$script:DmUi
    if ($null -eq $u.Snapshot) { return @() }
    $query=$u.Query.Text.Trim()
    $field=$u.FilterFields[[string]$u.Filter.SelectedItem]
    $choice=$null
    if ($u.FilterValue.SelectedIndex -ge 0) { $choice=$u.FilterChoices[$u.FilterValue.SelectedIndex] }
    $typed=''
    if ($u.Kind -eq 'Hybrid' -and ($null -eq $choice -or $u.FilterValue.Text -ne $choice.Label)) {
        $typed=$u.FilterValue.Text.Trim()
        $choice=$null
    }
    return @($u.Snapshot.Rows | Where-Object {
        $row=$_
        if ($query -and $row.Name.IndexOf($query,[StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
        if ($typed) { return ([string](Get-DmValue $row $field '')).IndexOf($typed,[StringComparison]::OrdinalIgnoreCase) -ge 0 }
        if ($null -eq $choice) { return $true }
        switch ($choice.Mode) {
            'None' { return $row.Orphan }
            'Assigned' { return -not $row.Orphan }
            'Multiple' { return $row.CurrentGroupIds.Count -gt 1 }
            'Group' { return $row.CurrentGroupIds -contains $choice.Value }
            'WithRegistered' { return $row.RegisteredCount -gt 0 }
            'WithoutRegistered' { return $row.RegisteredCount -eq 0 }
            'Value' { return [string](Get-DmValue $row $field '') -ieq $choice.Value }
            'Anomaly' {
                switch ($choice.Value) {
                    'Solo problemi Hybrid' { return $row.Severity -ne 'Good' }
                    'Ownership Personal' { return $row.HasPersonal }
                    'Hybrid non gestiti MDM' { return $row.HasHybridNotManaged }
                    'Account AD disabilitati' { return -not $row.ADEnabled }
                }
            }
            default { return $true }
        }
    })
}

function Update-DmCounter {
    $u=$script:DmUi;$total=0
    if ($null -ne $u.Snapshot) { $total=@($u.Snapshot.Rows).Count }
    $u.Counter.Text='Visualizzati: '+$u.Grid.Rows.Count+'/'+$total+' | Selezionati: '+$u.Grid.SelectedRows.Count
}

function Update-DmGrid {
    $u=$script:DmUi;$u.Populating=$true
    $u.Grid.SuspendLayout()
    try {
        $u.Grid.Rows.Clear()
        $visible=@(Get-DmVisibleRows)
        foreach ($row in $visible) {
            $index=$u.Grid.Rows.Add();$gridRow=$u.Grid.Rows[$index];$gridRow.Tag=$row
            foreach ($column in $u.Grid.Columns) { $gridRow.Cells[$column.Name].Value=Get-DmValue $row $column.Name '' }
            if ($u.Kind -eq 'Ring') { $gridRow.Cells['TargetRing'].ReadOnly=$u.Access.ReadOnly }
            if ($row.SerialConflict -or $row.GlpiState -like 'Duplicati*' -or ($u.Kind -eq 'Hybrid' -and $row.Severity -eq 'Error')) { $gridRow.DefaultCellStyle.BackColor=[Drawing.Color]::MistyRose }
            elseif ($row.GlpiState -eq 'Non verificabile' -or ($u.Kind -eq 'Hybrid' -and $row.Severity -eq 'Warning')) { $gridRow.DefaultCellStyle.BackColor=[Drawing.Color]::LemonChiffon }
            if ($row.Censito -eq 'Si') { $gridRow.Cells['Censito'].Style.ForeColor=[Drawing.Color]::DarkGreen }
        }
        $u.Grid.ClearSelection();$u.Details.Text=Format-DmDetail $null $u.Kind
        Update-DmCounter
    }
    finally { $u.Grid.ResumeLayout();$u.Populating=$false;Update-DmButtons }
}

function Update-DmButtons {
    $u=$script:DmUi;$idle=$null -eq $u.Pipeline
    $u.Refresh.Enabled=$idle
    $u.Query.Enabled=$idle -and $null -ne $u.Snapshot
    $u.Filter.Enabled=$u.Query.Enabled
    $u.FilterValue.Enabled=$u.Filter.Enabled
    $u.Grid.Enabled=$idle
    $u.Export.Enabled=$idle -and $u.Grid.Rows.Count -gt 0
    $u.OpenGlpi.Enabled=$idle -and $u.Grid.SelectedRows.Count -eq 1 -and $u.Grid.SelectedRows[0].Tag.GlpiRecords.Count -eq 1
    if ($u.Kind -eq 'Ring') {
        $u.Write.Enabled=$idle -and -not $u.Access.ReadOnly -and $u.Grid.SelectedRows.Count -gt 0
        $u.Ring.Enabled=$u.Query.Enabled -and -not $u.Access.ReadOnly -and $u.Ring.Items.Count -gt 1
        $u.Bulk.Enabled=$u.Write.Enabled -and $u.Ring.Enabled -and [bool]$u.Ring.SelectedItem
    }
    else {
        $u.Write.Enabled=$idle -and -not $u.Access.ReadOnly -and $null -ne $u.Snapshot -and $u.Snapshot.Statistics.RegisteredComputers -gt 0
        $u.Refresh.Text='Aggiorna'
        if (-not $idle -and -not $u.Writing) {
            $u.Refresh.Text='Interrompi'
            $u.Refresh.Enabled=-not $u.Cancelled
        }
    }
}

function Update-DmRingSummary {
    param([string]$Message)
    $u=$script:DmUi
    $u.RingSummaryCounts.Text=''
    $u.RingSummaryGroups.Items.Clear()
    if ($Message) { $u.Summary.Text=$Message;return }

    $stats=$u.Snapshot.Statistics
    $u.Summary.Text=@(
        'Dispositivi Entra letti'
        'Windows Hybrid aziendali gestiti da MDM'
        'PC già in almeno un Ring'
        'PC orfani ancora da assegnare'
        'Assegnazioni e spostamenti nella sessione'
    ) -join [Environment]::NewLine
    $u.RingSummaryCounts.Text=@($stats.DeviceTotal,$stats.EligibleTotal,$stats.AlreadyAssigned,$stats.OrphanRemaining,$u.RingChanges) -join [Environment]::NewLine
    foreach ($group in $u.Snapshot.Groups) {
        $mode='Solo controllo'
        if ($group.IsWritable -and -not $u.Access.ReadOnly) { $mode='Controllo e modifica' }
        $item=$u.RingSummaryGroups.Items.Add($group.Label)
        [void]$item.SubItems.Add([string]$group.DeviceCount)
        [void]$item.SubItems.Add($mode)
    }
}

function Update-DmHybridSummary {
    param([string]$Message)
    $u=$script:DmUi
    $u.HybridSummaryCounts.Text=''
    $u.HybridSummaryOus.Items.Clear()
    if ($Message) { $u.Summary.Text=$Message;return }

    $stats=$u.Snapshot.Statistics
    $u.Summary.Text=@('PC nelle OU','Identità Hybrid','Attestazione Intune','PC con Registered') -join [Environment]::NewLine
    $hybridOther=$stats.Computers-$stats.HybridOk
    $intuneOther=$stats.Computers-$stats.IntuneOk-$stats.IntuneUnknown
    $u.HybridSummaryCounts.Text=@(
        $stats.Computers
        ('{0} OK · {1} con anomalie' -f $stats.HybridOk,$hybridOther)
        ('{0} OK · {1} da regolarizzare · {2} N/D' -f $stats.IntuneOk,$intuneOther,$stats.IntuneUnknown)
        $stats.RegisteredComputers
    ) -join [Environment]::NewLine
    foreach ($ou in $u.Snapshot.OuStatistics) {
        $item=$u.HybridSummaryOus.Items.Add($ou.Name)
        $item.ToolTipText=$ou.DistinguishedName
        [void]$item.SubItems.Add([string]$ou.Count)
        [void]$item.SubItems.Add([string]$ou.IntuneOk)
        [void]$item.SubItems.Add([string]$ou.IntuneUnknown)
    }
}

function Stop-DmRead {
    $u=$script:DmUi
    if ($null -ne $u.Pipeline -and -not $u.Writing -and $null -eq $u.StopInvocation) {
        $u.Cancelled=$true
        $u.StopInvocation=$u.Pipeline.BeginStop($null,$null)
        $u.Status.Text='Interruzione lettura...'
        Update-DmButtons
    }
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
            'Candidates' { Get-HybridCleanupCandidates -GraphAccess $Access -ProgressQueue $Queue }
            'PrepareCleanup' { New-HybridCleanupPlan -ObjectIds $Payload -ConfigPath $Config -EnvPath $Env -GraphAccess $Access -ProgressQueue $Queue }
            'Cleanup' { Invoke-HybridCleanupPlan -PlanId $Payload.PlanId -Decision $Payload.Decision -GraphAccess $Access -ProgressQueue $Queue -Confirm:$false }
            'RingPlan' { New-RingAssignmentPlan -Assignments $Payload -ConfigPath $Config -GraphAccess $Access -ProgressQueue $Queue }
            'Assign' { Invoke-RingAssignmentPlan -PlanId $Payload -GraphAccess $Access -ProgressQueue $Queue -Confirm:$false }
            default { throw 'Operazione del modulo non prevista.' }
        }
    }
    [void]$u.Pipeline.AddScript($worker.ToString()).AddArgument($PSScriptRoot).AddArgument($u.Kind).AddArgument($Operation).AddArgument($u.ConfigPath).AddArgument($u.EnvPath).AddArgument($u.Access).AddArgument($Payload).AddArgument($u.Queue)
    $u.Status.Text='Operazione in corso: '+$Operation+'...'
    if ($Operation -eq 'Candidates') { $u.Status.Text='Verifica Entra Registered nelle OU analizzate...' }
    if ($Operation -eq 'Snapshot') {
        $message='Scansione completa dei dispositivi in corso...'
        if ($u.Kind -eq 'Ring') { Update-DmRingSummary -Message $message } else { Update-DmHybridSummary -Message $message }
        $u.Status.Text='Lettura completa delle fonti configurate. Al termine puoi filtrare l''elenco.'
    }
    Update-DmButtons
    try { $u.Invocation=$u.Pipeline.BeginInvoke();$u.Timer.Start() }
    catch { $u.Pipeline.Dispose();$u.Pipeline=$null;Update-DmButtons;throw }
}

function Save-DmCsv {
    param([object[]]$Rows,[string]$Path,[string]$Kind,[switch]$Report)
    $records=@(foreach ($row in $Rows) {
        $record=[ordered]@{}
        $fields=@('Name','IntuneSerial','GlpiState','GlpiMatchBy','GlpiIds','GlpiNames','GlpiStatus','GlpiGroup','Censito')
        if ($Report) { $fields=@('AtUtc','Name','Source','Destination','ObjectId','Id','DeviceId','GroupId','Action','TargetRing','RemoveGroups','RemovedGroupIds','State','Stage','Error') }
        elseif ($Kind -eq 'Hybrid') {
            $fields=@(
                'Name','HybridState','IdentityState','RegisteredCount','IntuneSerial','GlpiStatus','GlpiDepartment','OUName',
                'GlpiAssetId','Censito','GlpiState','ADLastModified','EntraLastActivity','GlpiLastInventory','IntuneState','IntuneReason',
                'ADGuid','ADDistinguishedName','EntraObjectIds','EntraDeviceIds','EntraCount','Anomalies','GlpiMatchBy','GlpiIds','GlpiNames','GlpiGroup'
            )
        }
        else { $fields+=@('ObjectId','DeviceId','Rings','State','TargetRing','GlpiDepartment','GlpiAssetId') }
        foreach ($field in $fields) {
            $value = Get-DmValue $row $field ''
            if (-not $Report -and $Kind -eq 'Hybrid' -and $value -is [datetime]) {
                $value = $value.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
            }
            $record[$field] = ConvertTo-DmCsvValue $value
        }
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
    if ($u.Cancelled) {
        if ($operation -eq 'Snapshot') {
            $u.Snapshot=$null
            Update-DmHybridSummary -Message 'Scansione annullata.'
            $u.Overview.Clear()
            Update-DmGrid
        }
        $u.Status.Text='Lettura annullata.'
        return
    }
    if ($errorText) {
        $u.Status.Text='Operazione non completata: '+$errorText
        if ($operation -eq 'Snapshot') {
            $u.Snapshot=$null
            if ($u.Kind -eq 'Hybrid') { Update-DmHybridSummary -Message 'Scansione non completata.' }
            else { Update-DmRingSummary -Message 'Scansione non completata.' }
            $u.Overview.Text=$u.Status.Text
            Update-DmGrid
        }
        return
    }
    switch ($operation) {
        'Snapshot' {
            $u.Snapshot=$result
            if ($u.Kind -eq 'Ring') {
                $u.Ring.Items.Clear();[void]$u.Ring.Items.Add('');$column=$u.Grid.Columns['TargetRing'];$column.Items.Clear();[void]$column.Items.Add('')
                foreach ($group in @($result.Groups | Where-Object IsWritable)) { [void]$u.Ring.Items.Add($group.Label);[void]$column.Items.Add($group.Label) };$u.Ring.SelectedIndex=0
                Update-DmRingSummary
            }
            else { Update-DmHybridSummary }
            Update-DmFilterValues -KeepSelection
            Update-DmGrid
            $status='Intune: '+$result.Sources.IntuneState+' '+$result.Sources.IntuneError+' | GLPI: '+$result.Sources.GlpiState+' '+$result.Sources.GlpiError
            $overview=@('Lettura UTC: '+$result.CapturedAtUtc)
            if ($u.Kind -eq 'Ring') {
                $overview+=@($result.Summary)
                $overview+=@($result.Groups | ForEach-Object { $mode='Solo controllo';if ($_.IsWritable) { $mode='Controllo e modifica' };$_.Label+' | '+$_.Name+' | ID: '+$_.Id+' | Oggetti transitivi: '+$_.MemberCount+' | '+$mode+' | '+$_.Reason })
            }
            else {
                $adSummary='AD: '+$result.Sources.AdServer
                $status=$adSummary+' | '+$status
                $overview+=@($adSummary+(' | {0:N1} s' -f $result.Sources.AdSeconds))
                $overview+=@('',('Intune: '+$result.Sources.IntuneState+' '+$result.Sources.IntuneError),('GLPI: '+$result.Sources.GlpiState+' '+$result.Sources.GlpiError))
            }
            $u.Overview.Text=$overview -join [Environment]::NewLine
            $u.Status.Text=$status
        }
        'Candidates' {
            if (-not $result.Candidates.Count) { $u.Status.Text='Nessuna registrazione Entra Registered nelle OU analizzate.';return }
            $ids=Show-DmSelection -Candidates $result.Candidates -Owner $u.Form
            if ($null -ne $ids -and $ids.Count) { Start-DmTask PrepareCleanup $ids }
            else { $u.Status.Text='Pulizia Registered annullata.' }
        }
        'PrepareCleanup' { $decision=Show-AssistenteITRemovalPreview -Plan $result -Owner $u.Form;if ($null -ne $decision) { Start-DmTask Cleanup ([pscustomobject]@{PlanId=$result.PlanId;Decision=$decision}) } }
        'RingPlan' { if (Show-DmRingReview -Plan $result -Owner $u.Form) { Start-DmTask Assign $result.PlanId } }
        default {
            if ($operation -eq 'Assign') { $u.RingChanges+=$result.Assigned+$result.Moved }
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
    Import-Module (Join-Path $PSScriptRoot 'ComputerExplorer.Core.psm1') -ErrorAction Stop
    . (Join-Path $PSScriptRoot 'ComputerExplorer.Recovery.UI.ps1')
    . (Join-Path $PSScriptRoot 'ComputerExplorer.Removal.UI.ps1')
    if ($null -eq $GraphAccess -or -not $GraphAccess.CanOpen) { throw 'Eseguire Accesso dal wrapper prima di aprire il modulo.' }
    $script:DmUi=@{Kind=$Kind;ConfigPath=$ConfigPath;EnvPath=$EnvPath;Access=$GraphAccess;Snapshot=$null;Pipeline=$null;Invocation=$null;StopInvocation=$null;Cancelled=$false;Closing=$false;Writing=$false;Populating=$false;LastReport=@();InitialScanStarted=$false;SuppressInitialScan=[bool]$SmokeTest;Queue=(New-Object 'Collections.Concurrent.ConcurrentQueue[object]')}
    $u=$script:DmUi
    $form=New-Object Windows.Forms.Form;$form.Name='DeviceModule-'+$Kind;$form.Text='Assistente IT - Verifica Hybrid Join';if ($Kind -eq 'Ring') { $form.Text='Assistente IT - Gestione Ring Intune' }
    $form.ClientSize=New-Object Drawing.Size(1320,850);$form.MinimumSize=New-Object Drawing.Size(1050,720);$form.StartPosition='CenterScreen';$form.Font=New-Object Drawing.Font('Segoe UI',9);$form.AutoScaleMode='Dpi'
    if ($Kind -eq 'Ring') { $form.MinimumSize=New-Object Drawing.Size(950,700) }
    $workArea=[Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position).WorkingArea
    $form.Size=New-Object Drawing.Size([Math]::Min($form.Width,$workArea.Width),[Math]::Min($form.Height,$workArea.Height))
    $icon=New-Object Drawing.Icon((Join-Path $PSScriptRoot 'assets/AssistenteIT.ico'));$form.Icon=$icon;$u.Form=$form
    $layout=New-Object Windows.Forms.TableLayoutPanel;$layout.Dock='Fill';$layout.Padding=New-Object Windows.Forms.Padding(12);$layout.ColumnCount=1
    $heights=@(140,-1,26,34,37,43)
    if ($Kind -eq 'Ring') { $heights=@(155,-1,26,40,35,38,43) }
    [void]$layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100)))
    $layout.RowCount=$heights.Count
    foreach ($height in $heights) { if ($height -lt 0) { [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100))) } else { [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',$height))) } }
    $summary=New-Object Windows.Forms.Label;$summary.Dock='Fill';$summary.Text='In attesa della scansione';$summary.Font=New-Object Drawing.Font('Segoe UI',10);$u.Summary=$summary
    if ($Kind -eq 'Ring') {
        $u.RingChanges=0
        $ringSummary=New-Object Windows.Forms.GroupBox
        $ringSummary.Name='RingSummary';$ringSummary.Text='Riepilogo';$ringSummary.Dock='Fill'
        $ringSummary.Padding=New-Object Windows.Forms.Padding(10,8,10,10)
        $summaryLayout=New-Object Windows.Forms.TableLayoutPanel
        $summaryLayout.Dock='Fill';$summaryLayout.ColumnCount=3;$summaryLayout.RowCount=1
        foreach ($width in @(33,8,59)) { [void]$summaryLayout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',$width))) }
        $summary.Font=$form.Font
        $counts=New-Object Windows.Forms.Label;$counts.Dock='Fill';$counts.Font=$summary.Font;$u.RingSummaryCounts=$counts
        $groupList=New-Object Windows.Forms.ListView
        $groupList.Name='RingSummaryGroups';$groupList.Dock='Fill';$groupList.View='Details';$groupList.HeaderStyle='Nonclickable'
        $groupList.FullRowSelect=$true;$groupList.TabStop=$false
        [void]$groupList.Columns.Add('Ring',210)
        [void]$groupList.Columns.Add('Dispositivi',90,[Windows.Forms.HorizontalAlignment]::Right)
        [void]$groupList.Columns.Add('Accesso',160)
        $u.RingSummaryGroups=$groupList
        $summaryLayout.Controls.Add($summary,0,0);$summaryLayout.Controls.Add($counts,1,0);$summaryLayout.Controls.Add($groupList,2,0)
        $ringSummary.Controls.Add($summaryLayout)
    }
    else {
        $hybridSummary=New-Object Windows.Forms.TableLayoutPanel
        $hybridSummary.Dock='Fill';$hybridSummary.Margin=New-Object Windows.Forms.Padding(0);$hybridSummary.ColumnCount=2
        foreach ($width in @(40,60)) { [void]$hybridSummary.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',$width))) }

        $general=New-Object Windows.Forms.GroupBox
        $general.Name='HybridGeneralSummary';$general.Text='Riepilogo generale';$general.Dock='Fill'
        $general.Padding=New-Object Windows.Forms.Padding(10,8,10,8)
        $summaryLayout=New-Object Windows.Forms.TableLayoutPanel
        $summaryLayout.Dock='Fill';$summaryLayout.ColumnCount=2;$summaryLayout.RowCount=1
        [void]$summaryLayout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',128)))
        [void]$summaryLayout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100)))
        $summary.Font=$form.Font
        $counts=New-Object Windows.Forms.Label;$counts.Name='HybridSummaryCounts';$counts.Dock='Fill';$u.HybridSummaryCounts=$counts
        $summaryLayout.Controls.Add($summary,0,0);$summaryLayout.Controls.Add($counts,1,0)
        $general.Controls.Add($summaryLayout)
        $hybridSummary.Controls.Add($general,0,0)

        $ous=New-Object Windows.Forms.GroupBox
        $ous.Name='HybridOuSummary';$ous.Text='OU analizzate';$ous.Dock='Fill'
        $ous.Padding=New-Object Windows.Forms.Padding(10,8,10,8)
        $ouList=New-Object Windows.Forms.ListView
        $ouList.Name='HybridSummaryOus';$ouList.Dock='Fill';$ouList.View='Details';$ouList.HeaderStyle='Nonclickable'
        $ouList.FullRowSelect=$true;$ouList.TabStop=$false;$ouList.ShowItemToolTips=$true
        [void]$ouList.Columns.Add('OU',190)
        [void]$ouList.Columns.Add('PC',64,[Windows.Forms.HorizontalAlignment]::Right)
        [void]$ouList.Columns.Add('Intune OK',92,[Windows.Forms.HorizontalAlignment]::Right)
        [void]$ouList.Columns.Add('Intune N/D',92,[Windows.Forms.HorizontalAlignment]::Right)
        $ouList.Add_Resize({
            param($sender)
            $numbers=$sender.Columns[1].Width+$sender.Columns[2].Width+$sender.Columns[3].Width
            $sender.Columns[0].Width=[Math]::Max(95,$sender.ClientSize.Width-$numbers-[Windows.Forms.SystemInformation]::VerticalScrollBarWidth)
        })
        $u.HybridSummaryOus=$ouList
        $ous.Controls.Add($ouList)
        $hybridSummary.Controls.Add($ous,1,0)
    }

    $hybridColumns=@(
        @('Name','Computer',142,92), @('HybridState','Hybrid',144,92), @('IdentityState','Identità AD/Entra',120,94),
        @('RegisteredCount','Registered',84,73), @('IntuneSerial','Seriale Intune',118,76), @('GlpiStatus','Stato GLPI',108,72),
        @('GlpiDepartment','Reparto GLPI',113,80), @('OUName','OU',118,65), @('GlpiAssetId','Asset ID',78,63),
        @('Censito','Censito',67,59), @('GlpiState','GLPI',114,82)
    )
    $hybridDateColumns=[ordered]@{
        ADLastModified=@('Ultima modifica AD','Ultima modifica dell''oggetto AD sul DC interrogato.')
        EntraLastActivity=@('Ultima attività Entra','Attività approssimativa più recente tra gli oggetti Entra della riga. Le singole date sono nei dettagli.')
        GlpiLastInventory=@('Ultimo inventario GLPI','Ultimo inventario acquisito da GLPI (orario del server). Per più schede viene mostrata la data più recente.')
    }
    $toolbar=New-Object Windows.Forms.FlowLayoutPanel;$toolbar.Dock='Fill';$toolbar.WrapContents=$false
    $buttons=@(@('Refresh','Aggiorna',110),@('Export','Esporta CSV',120),@('OpenGlpi','Apri su GLPI',125),@('Write','Verifica e pulisci Registered',215))
    if ($Kind -eq 'Ring') { $buttons=@(@('Refresh','Aggiorna',110),@('Export','Esporta CSV',120),@('OpenGlpi','Apri su GLPI',125),@('Write','Verifica ed Applica',190)) }
    foreach ($spec in $buttons) { $button=New-Object Windows.Forms.Button;$button.Name=$spec[0];$button.Text=$spec[1];$button.Width=$spec[2];$button.Height=32;$u[$spec[0]]=$button;$toolbar.Controls.Add($button) }
    $u.Write.FlatStyle='Flat';$u.Write.UseVisualStyleBackColor=$false
    $u.Write.BackColor=[Drawing.Color]::FromArgb(24,92,181);$u.Write.ForeColor=[Drawing.Color]::White
    $mode=New-Object Windows.Forms.Label;$mode.AutoSize=$true;$mode.Padding=New-Object Windows.Forms.Padding(8,8,0,0);$mode.Text='Sola lettura';if (-not $GraphAccess.ReadOnly) { $mode.Text='Lettura e scrittura' };$toolbar.Controls.Add($mode)
    $filters=New-Object Windows.Forms.FlowLayoutPanel;$filters.Dock='Fill';$filters.WrapContents=$false
    $queryLabel=New-Object Windows.Forms.Label;$queryLabel.Name='DeviceModuleFilterLabel';$queryLabel.Text='Filtra per nome';$queryLabel.AutoSize=$true;$queryLabel.Padding=New-Object Windows.Forms.Padding(0,7,0,0)
    $query=New-Object Windows.Forms.TextBox;$query.Name='DeviceModuleFilterText';$query.Width=240;$u.Query=$query
    $filter=New-Object Windows.Forms.ComboBox;$filter.Name='DeviceModuleFilter';$filter.DropDownStyle='DropDownList';$filter.Width=225;$u.Filter=$filter
    $columnLabel=New-Object Windows.Forms.Label;$columnLabel.Text='Filtra per campo';$columnLabel.AutoSize=$true;$columnLabel.Padding=$queryLabel.Padding
    $filter.Width=164
    $u.FilterFields=[ordered]@{}
    if ($Kind -eq 'Ring') {
        $columnLabel.Text='Filtra per colonna'
        $filter.Width=140
        $u.FilterFields=[ordered]@{'Ring attuali'='Rings';'GLPI'='GlpiState';'Stato GLPI'='GlpiStatus';'Reparto GLPI'='GlpiDepartment'}
    }
    else {
        foreach ($spec in $hybridColumns) {
            if ($spec[0] -ne 'Name') { $u.FilterFields[$spec[1]]=$spec[0] }
        }
        $u.FilterFields['Attestazione Intune']='IntuneState'
        $u.FilterFields['Anomalie']='Anomalies'
    }
    $filterValue=New-Object Windows.Forms.ComboBox
    $filterValue.Name='DeviceModuleFilterValue';$filterValue.DropDownStyle='DropDownList';$filterValue.Width=245;$u.FilterValue=$filterValue
    if ($Kind -eq 'Ring') { $filterValue.Name='RingFilterValue' }
    else { $filterValue.DropDownStyle='DropDown' }
    foreach ($choice in $u.FilterFields.Keys) { [void]$filter.Items.Add($choice) };$filter.SelectedIndex=0
    $filters.Controls.AddRange(@($queryLabel,$query,$columnLabel,$filter,$filterValue))
    Update-DmFilterValues

    if ($Kind -eq 'Ring') {
        $ringActions=New-Object Windows.Forms.FlowLayoutPanel;$ringActions.Dock='Fill';$ringActions.WrapContents=$false
        $ringLabel=New-Object Windows.Forms.Label;$ringLabel.Text='Ring per righe selezionate';$ringLabel.AutoSize=$true;$ringLabel.Padding=$queryLabel.Padding
        $ring=New-Object Windows.Forms.ComboBox;$ring.Name='BulkTargetRing';$ring.DropDownStyle='DropDownList';$ring.Width=225;$u.Ring=$ring
        $bulk=New-Object Windows.Forms.Button;$bulk.Name='SetRingForSelected';$bulk.Text='Imposta sui selezionati';$bulk.Width=190;$bulk.Height=28;$u.Bulk=$bulk
        $ringActions.Controls.AddRange(@($ringLabel,$ring,$bulk))
        $ring.Add_SelectedIndexChanged({Update-DmButtons})
        $bulk.Add_Click({$u=$script:DmUi;if (-not $u.Ring.SelectedItem) { return };foreach ($row in $u.Grid.SelectedRows) { if (-not $u.Access.ReadOnly) { $row.Cells['TargetRing'].Value=[string]$u.Ring.SelectedItem } }})
    }
    $split=New-Object Windows.Forms.SplitContainer;$split.Dock='Fill';$split.Size=New-Object Drawing.Size(1280,570);$split.Orientation='Horizontal';$split.SplitterDistance=330;$split.Panel1MinSize=100;$split.Panel2MinSize=80
    $split.Size=New-Object Drawing.Size(1280,480);$split.SplitterDistance=315;$split.FixedPanel='Panel2'
    if ($Kind -eq 'Ring') { $split.SplitterDistance=310 }
    $grid=New-Object Windows.Forms.DataGridView;$grid.Name='DeviceModuleGrid';$grid.Dock='Fill';$grid.AutoGenerateColumns=$false;$grid.AllowUserToAddRows=$false;$grid.AllowUserToDeleteRows=$false;$grid.AllowUserToResizeRows=$false;$grid.RowHeadersVisible=$false;$grid.MultiSelect=$true;$grid.SelectionMode='FullRowSelect';$grid.BackgroundColor=[Drawing.SystemColors]::Window;$grid.ClipboardCopyMode='EnableAlwaysIncludeHeaderText';$grid.AlternatingRowsDefaultCellStyle.BackColor=[Drawing.Color]::FromArgb(247,249,252);$u.Grid=$grid
    $grid.AutoSizeColumnsMode='Fill'
    $columns=$hybridColumns
    if ($Kind -eq 'Ring') {
        $columns=@(@('Name','Computer',155),@('Rings','Ring attuali',130),@('TargetRing','Ring destinazione',140),@('IntuneSerial','Seriale Intune',115),@('GlpiStatus','Stato GLPI',150),@('GlpiDepartment','Reparto GLPI',165),@('GlpiAssetId','Asset ID',90),@('Censito','Censito',65),@('GlpiState','GLPI',135))
    }
    else {
        $grid.ColumnHeadersHeightSizeMode='AutoSize'
        $grid.ColumnHeadersDefaultCellStyle.WrapMode='True'
        foreach ($field in $hybridDateColumns.Keys) {
            $columns+=,@($field,$hybridDateColumns[$field][0],118,110)
        }
    }
    foreach ($spec in $columns) {
        if ($spec[0] -eq 'TargetRing') { $column=New-Object Windows.Forms.DataGridViewComboBoxColumn;$column.FlatStyle='Flat';[void]$column.Items.Add('');$column.ReadOnly=$GraphAccess.ReadOnly }
        else { $column=New-Object Windows.Forms.DataGridViewTextBoxColumn;$column.ReadOnly=$true;$column.SortMode='Automatic' }
        $column.Name=$spec[0];$column.HeaderText=$spec[1]
        $column.FillWeight=$spec[2]
        if ($Kind -eq 'Hybrid') {
            $column.MinimumWidth=$spec[3]
            if ($hybridDateColumns.Contains($column.Name)) {
                $column.ValueType=[datetime]
                $column.DefaultCellStyle.Format='dd/MM/yyyy HH:mm'
                $column.DefaultCellStyle.NullValue='—'
                $column.ToolTipText=$hybridDateColumns[$column.Name][1]
            }
        }
        [void]$grid.Columns.Add($column)
    }
    $tabs=New-Object Windows.Forms.TabControl;$tabs.Dock='Fill';$u.Tabs=$tabs
    $detailsTab=New-Object Windows.Forms.TabPage;$detailsTab.Text='Dettagli dispositivo';$reportTab=New-Object Windows.Forms.TabPage;$reportTab.Text='Resoconto operazioni';$u.ReportTab=$reportTab
    $details=New-Object Windows.Forms.RichTextBox;$details.Name='DeviceModuleDetails';$details.Dock='Fill';$details.ReadOnly=$true;$details.WordWrap=$false;$details.Font=New-Object Drawing.Font('Consolas',9);$u.Details=$details
    $report=New-Object Windows.Forms.RichTextBox;$report.Dock='Fill';$report.ReadOnly=$true;$report.WordWrap=$false;$report.Font=$details.Font;$u.Report=$report
    $overviewTab=New-Object Windows.Forms.TabPage;$overviewTab.Text='Riepilogo fonti';$overviewText=New-Object Windows.Forms.RichTextBox;$overviewText.Dock='Fill';$overviewText.ReadOnly=$true;$overviewText.WordWrap=$false;$overviewText.Font=$details.Font;$overviewTab.Controls.Add($overviewText);$u.Overview=$overviewText
    $detailsTab.Controls.Add($details);$reportTab.Controls.Add($report);$tabs.TabPages.AddRange(@($detailsTab,$reportTab,$overviewTab));$split.Panel1.Controls.Add($grid);$split.Panel2.Controls.Add($tabs)
    $counter=New-Object Windows.Forms.Label;$counter.Dock='Fill';$counter.TextAlign='MiddleLeft';$u.Counter=$counter
    $status=New-Object Windows.Forms.Label;$status.Name='DeviceModuleStatus';$status.Dock='Fill';$status.Text='Accesso Microsoft condiviso con il wrapper. GLPI usa i token salvati nelle Impostazioni.';$u.Status=$status
    if ($Kind -eq 'Ring') {
        $layout.Controls.Add($ringSummary,0,0);$layout.Controls.Add($split,0,1);$layout.Controls.Add($counter,0,2);$layout.Controls.Add($status,0,3)
        $layout.Controls.Add($filters,0,4);$layout.Controls.Add($ringActions,0,5);$layout.Controls.Add($toolbar,0,6)
    }
    else {
        $layout.Controls.Add($hybridSummary,0,0);$layout.Controls.Add($split,0,1);$layout.Controls.Add($counter,0,2)
        $layout.Controls.Add($status,0,3);$layout.Controls.Add($filters,0,4);$layout.Controls.Add($toolbar,0,5)
    }
    $form.Controls.Add($layout)
    $grid.Add_SelectionChanged({$u=$script:DmUi;if ($u.Populating) { return };$row=$null;if ($u.Grid.SelectedRows.Count) { $row=$u.Grid.SelectedRows[0].Tag };$u.Details.Text=Format-DmDetail $row $u.Kind;Update-DmCounter;Update-DmButtons})
    $grid.Add_CurrentCellDirtyStateChanged({$u=$script:DmUi;if ($u.Grid.IsCurrentCellDirty) { [void]$u.Grid.CommitEdit('Commit') }})
    $grid.Add_CellValueChanged({param($sender,$eventArgs);$u=$script:DmUi;if ($u.Populating -or $u.Kind -ne 'Ring' -or $eventArgs.RowIndex -lt 0 -or $eventArgs.ColumnIndex -ne $u.Grid.Columns['TargetRing'].Index) { return };$row=$u.Grid.Rows[$eventArgs.RowIndex];if ($null -ne $row.Tag) { $row.Tag.TargetRing=[string]$row.Cells['TargetRing'].Value }})
    $grid.Add_DataError({param($sender,$eventArgs);$eventArgs.ThrowException=$false;$script:DmUi.Status.Text='Selezione Ring non valida: aggiornare i dati.'})
    $query.Add_TextChanged({if (-not $script:DmUi.Populating) { Update-DmGrid }})
    $filter.Add_SelectedIndexChanged({Update-DmFilterValues;Update-DmGrid})
    $u.FilterValue.Add_SelectedIndexChanged({if (-not $script:DmUi.Populating) { Update-DmGrid }})
    if ($Kind -eq 'Hybrid') {
        $u.FilterValue.Add_TextChanged({
            $u=$script:DmUi
            if ($u.Populating) { return }
            $value=$u.FilterValue.Text
            if ($u.FilterValue.SelectedIndex -ge 0 -and $value -ne [string]$u.FilterValue.SelectedItem) {
                # An editable combo can retain its previous list selection while displaying typed text.
                $position=$u.FilterValue.SelectionStart
                $u.Populating=$true
                try {
                    $u.FilterValue.SelectedIndex=-1
                    $u.FilterValue.Text=$value
                    $u.FilterValue.SelectionStart=[Math]::Min($position,$value.Length)
                }
                finally { $u.Populating=$false }
            }
            Update-DmGrid
        })
    }
    $u.Refresh.Add_Click({if ($null -eq $script:DmUi.Pipeline) { Start-DmTask Snapshot } else { Stop-DmRead }})
    $u.Write.Add_Click({
        $u=$script:DmUi;if ($u.Access.ReadOnly) { return }
        if ($u.Kind -eq 'Hybrid') { Start-DmTask Candidates }
        else {
            [void]$u.Grid.EndEdit()
            $assignments=@($u.Grid.Rows | Where-Object { $_.Tag.TargetRing } | ForEach-Object { [pscustomobject]@{ObjectId=$_.Tag.ObjectId;TargetRing=$_.Tag.TargetRing} })
            if (-not $assignments.Count) { $u.Status.Text='Scegliere un Ring di destinazione nelle righe, oppure impostarlo sui selezionati.';return };Start-DmTask RingPlan $assignments
        }
    })
    $u.OpenGlpi.Add_Click({
        $u=$script:DmUi
        if ($u.Grid.SelectedRows.Count -ne 1 -or $u.Grid.SelectedRows[0].Tag.GlpiRecords.Count -ne 1) { return }
        try {
            $config=Read-ExplorerConfiguration $u.ConfigPath
            $base=([string]$config.Settings.Glpi.BaseUri).TrimEnd('/')
            $id=[int]$u.Grid.SelectedRows[0].Tag.GlpiRecords[0].GlpiId
            if ($base -notmatch '^https?://' -or $base -notmatch '/apirest\.php$' -or $id -le 0) {
                throw 'URL o identificativo della scheda GLPI non valido.'
            }
            Start-Process -FilePath (($base -replace '/apirest\.php$','')+'/front/computer.form.php?id='+$id) -ErrorAction Stop
        }
        catch { $u.Status.Text='Apertura scheda GLPI non riuscita. '+$_.Exception.Message }
    })
    $u.Export.Add_Click({$u=$script:DmUi;$save=New-Object Windows.Forms.SaveFileDialog;$save.Filter='File CSV (*.csv)|*.csv';$save.DefaultExt='csv';$save.AddExtension=$true;$save.FileName=$u.Kind+'-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.csv';try { if ($save.ShowDialog($u.Form) -eq 'OK') { Save-DmCsv -Rows @($u.Grid.Rows | ForEach-Object { $_.Tag }) -Path $save.FileName -Kind $u.Kind;$u.Status.Text='CSV esportato: '+$save.FileName } } catch { $u.Status.Text='Esportazione non riuscita: '+$_.Exception.Message } finally { $save.Dispose() }})
    $form.KeyPreview=$true;$form.Add_KeyDown({param($sender,$eventArgs);if ($eventArgs.KeyCode -eq 'F5' -and $null -eq $script:DmUi.Pipeline -and $script:DmUi.Refresh.Enabled) { $script:DmUi.Refresh.PerformClick();$eventArgs.Handled=$true }})
    $form.Add_FormClosing({param($sender,$eventArgs);$u=$script:DmUi;if ($null -ne $u.Pipeline) { $eventArgs.Cancel=$true;if ($u.Writing) { $u.Status.Text='Attendere il completamento delle operazioni.' } else { $u.Closing=$true;Stop-DmRead } }})
    $worker=[RunspaceFactory]::CreateRunspace();$worker.ApartmentState='STA';$worker.ThreadOptions='ReuseThread';$worker.Open();$u.Worker=$worker;$script:Worker=$worker
    $timer=New-Object Windows.Forms.Timer;$timer.Interval=100;$timer.Add_Tick({Complete-DmTask});$u.Timer=$timer
    Update-DmButtons;Update-DmGrid
    if (Get-Command Initialize-AssistenteITWindowIdentity -ErrorAction SilentlyContinue) { Initialize-AssistenteITWindowIdentity -InstallRoot $PSScriptRoot -Window $form }
    $form.Add_Shown({
        $scanUi=$script:DmUi
        if ($scanUi.SuppressInitialScan -or $scanUi.InitialScanStarted) { return }
        $scanUi.InitialScanStarted=$true
        Start-DmTask Snapshot
    })
    try { if ($SmokeTest) { $form.CreateControl();$form.PerformLayout();return $form } else { [void]$form.ShowDialog() } }
    finally { if (-not $SmokeTest) { $timer.Stop();$timer.Dispose();if ($null -ne $u.Pipeline) { $u.Pipeline.Stop();$u.Pipeline.Dispose() };$worker.Close();$worker.Dispose();$form.Dispose();$icon.Dispose() } }
}
