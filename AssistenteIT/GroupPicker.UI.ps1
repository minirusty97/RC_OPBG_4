#requires -version 5.1
function Get-AssistenteITPickedGroups {
    param($Grid)
    [void]$Grid.EndEdit()
    @($Grid.Rows | Where-Object { $_.Cells['Monitor'].Value -eq $true } | ForEach-Object {
        [pscustomobject]@{Id=[string]$_.Cells['Id'].Value;Name=[string]$_.Cells['Name'].Value;Label=[string]$_.Cells['Label'].Value;CanAssign=($_.Cells['Destination'].Value -eq $true)}
    })
}

function Set-AssistenteITGroupPickerRows {
    param($Grid,[object[]]$Groups,[object[]]$Selected)
    $Grid.Rows.Clear();$seen=@{}
    foreach ($group in $Groups) {
        $id=[string]$group.id;$name=[string]$group.displayName
        $match=@($Selected | Where-Object { ($_.Id -and $_.Id -ieq $id) -or (-not $_.Id -and $_.Name -ieq $name) })
        $label=$name;if ($name -match '(Ring[0-9]+[A-Za-z]*)$') { $label=$Matches[1] }
        $monitor=$match.Count -eq 1;$dest=$false;if ($monitor) { $dest=[bool]$match[0].CanAssign;$label=$match[0].Label }
        $reason=[string]$group.AssignmentReason
        if ($reason) { $dest=$false }
        $index=$Grid.Rows.Add([object[]]@($monitor,$dest,$label,$name,$id,$reason));$Grid.Rows[$index].Cells['Destination'].ReadOnly=[bool]$reason
        if ($monitor) { $seen[([string]$match[0].Id)+'|'+$match[0].Name]=$true }
    }
    foreach ($entry in $Selected) {
        if ($seen.ContainsKey(([string]$entry.Id)+'|'+$entry.Name)) { continue }
        [void]$Grid.Rows.Add([object[]]@($true,[bool]$entry.CanAssign,$entry.Label,$entry.Name,$entry.Id,'Configurato; non incluso in questa ricerca'))
    }
    $Grid.ClearSelection()
}

function Show-AssistenteITGroupPicker {
    param([object[]]$Configured,$Access,$Owner,[string]$InstallRoot)
    $picker=New-Object Windows.Forms.Form;$picker.Name='RingGroupPicker';$picker.Text='Selezione gruppi Ring da Entra';$picker.ClientSize=New-Object Drawing.Size(1080,640);$picker.MinimumSize=New-Object Drawing.Size(900,540);$picker.StartPosition='CenterParent';$picker.Icon=$Owner.Icon;$picker.Font=$Owner.Font
    $layout=New-Object Windows.Forms.TableLayoutPanel;$layout.Dock='Fill';$layout.Padding=New-Object Windows.Forms.Padding(12);$layout.RowCount=4
    foreach ($height in @(70,45,-1,55)) { if ($height -lt 0) { [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100))) } else { [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',$height))) } }
    $hint=New-Object Windows.Forms.Label;$hint.Dock='Fill';$hint.Text='Controlla: esclude gli appartenenti da quelli orfani. Destinazione: consente di aggiungere PC a quel gruppo, se statico e modificabile. Le etichette devono essere univoche. Cerca per inizio del nome; vuoto legge tutti i gruppi. Solo i gruppi spuntati vengono salvati.'
    $search=New-Object Windows.Forms.FlowLayoutPanel;$search.Dock='Fill';$search.WrapContents=$false
    $prefix=New-Object Windows.Forms.TextBox;$prefix.Name='GroupNamePrefix';$prefix.Text='INTUNE';$prefix.Width=500
    $load=New-Object Windows.Forms.Button;$load.Name='LoadEntraGroups';$load.Text='Carica gruppi Entra';$load.Width=190;$load.Height=29
    $status=New-Object Windows.Forms.Label;$status.Width=310;$status.Height=38;$status.Text='Accesso del wrapper richiesto per leggere Entra.'
    $search.Controls.AddRange(@($prefix,$load,$status))
    $grid=New-Object Windows.Forms.DataGridView;$grid.Name='AvailableRingGroups';$grid.Dock='Fill';$grid.AllowUserToAddRows=$false;$grid.AllowUserToDeleteRows=$false;$grid.RowHeadersVisible=$false;$grid.AutoSizeColumnsMode='Fill';$grid.MultiSelect=$false
    foreach ($spec in @(@('Monitor','Controlla',40),@('Destination','Destinazione',45))) { $column=New-Object Windows.Forms.DataGridViewCheckBoxColumn;$column.Name=$spec[0];$column.HeaderText=$spec[1];$column.FillWeight=$spec[2];[void]$grid.Columns.Add($column) }
    foreach ($spec in @(@('Label','Etichetta',65),@('Name','Nome gruppo Entra',180),@('Id','Object ID gruppo',160),@('Reason','Assegnazione / avvisi',120))) { $column=New-Object Windows.Forms.DataGridViewTextBoxColumn;$column.Name=$spec[0];$column.HeaderText=$spec[1];$column.FillWeight=$spec[2];$column.ReadOnly=$spec[0] -ne 'Label';[void]$grid.Columns.Add($column) }
    Set-AssistenteITGroupPickerRows -Grid $grid -Groups @() -Selected $Configured
    $grid.Add_CurrentCellDirtyStateChanged({if ($grid.IsCurrentCellDirty) { [void]$grid.CommitEdit('Commit') }})
    $grid.Add_CellValueChanged({param($sender,$eventArgs);if ($eventArgs.RowIndex -lt 0 -or $eventArgs.ColumnIndex -ne $grid.Columns['Destination'].Index) { return };$row=$grid.Rows[$eventArgs.RowIndex];if ($row.Cells['Destination'].Value -eq $true) { $row.Cells['Monitor'].Value=$true }})
    $buttons=New-Object Windows.Forms.FlowLayoutPanel;$buttons.Dock='Fill';$buttons.FlowDirection='RightToLeft'
    $cancel=New-Object Windows.Forms.Button;$cancel.Text='Annulla';$cancel.Width=120;$cancel.DialogResult='Cancel'
    $save=New-Object Windows.Forms.Button;$save.Name='ConfirmSelectedGroups';$save.Text='Usa gruppi selezionati';$save.Width=210
    $buttons.Controls.AddRange(@($cancel,$save));$layout.Controls.Add($hint,0,0);$layout.Controls.Add($search,0,1);$layout.Controls.Add($grid,0,2);$layout.Controls.Add($buttons,0,3);$picker.Controls.Add($layout);$picker.CancelButton=$cancel;$picker.AcceptButton=$cancel
    $state=@{Pipeline=$null;Runspace=$null;Invocation=$null;Stop=$null;Accepted=$false;Result=@();Closing=$false;Selected=@()}
    $timer=New-Object Windows.Forms.Timer;$timer.Interval=100
    $load.Enabled=$null -ne $Access -and $Access.CanOpen
    if ($load.Enabled) { $status.Text='Pronto: usa Carica gruppi Entra.' }
    $load.Add_Click({
        if ($null -ne $state.Pipeline) { return }
        $state.Selected=@(Get-AssistenteITPickedGroups $grid);$load.Enabled=$false;$grid.Enabled=$false;$save.Enabled=$false;$status.Text='Lettura gruppi...'
        try {
            $state.Runspace=[RunspaceFactory]::CreateRunspace();$state.Runspace.Open();$state.Pipeline=[PowerShell]::Create();$state.Pipeline.Runspace=$state.Runspace
            $worker={param($Root,$Prefix,$Access)
                $ErrorActionPreference='Stop'
                Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
                Import-Module (Join-Path $Root 'DeviceModules.Core.psm1') -ErrorAction Stop
                Import-Module (Join-Path $Root 'RingManager.Core.psm1') -ErrorAction Stop
                $groups=@(Get-DmAvailableGroups -Prefix $Prefix -Access $Access)
                foreach ($group in $groups) { $group | Add-Member -Force NoteProperty AssignmentReason (Test-RingWritable $group) }
                [pscustomobject]@{Groups=$groups}
            }
            [void]$state.Pipeline.AddScript($worker.ToString()).AddArgument($InstallRoot).AddArgument($prefix.Text).AddArgument($Access)
            $state.Invocation=$state.Pipeline.BeginInvoke();$timer.Start()
        }
        catch { $status.Text='Preparazione non riuscita: '+$_.Exception.Message;if ($null -ne $state.Pipeline) { $state.Pipeline.Dispose();$state.Pipeline=$null };if ($null -ne $state.Runspace) { $state.Runspace.Dispose();$state.Runspace=$null };$load.Enabled=$true;$grid.Enabled=$true;$save.Enabled=$true }
    })
    $timer.Add_Tick({
        if ($null -eq $state.Invocation -or -not $state.Invocation.IsCompleted) { return };$timer.Stop()
        try {
            if ($null -ne $state.Stop) { $state.Pipeline.EndStop($state.Stop) }
            $output=@($state.Pipeline.EndInvoke($state.Invocation))
            if (-not $state.Closing) {
                if ($state.Pipeline.Streams.Error.Count) { throw $state.Pipeline.Streams.Error[0] };if ($output.Count -ne 1) { throw 'Elenco gruppi incompleto.' }
                Set-AssistenteITGroupPickerRows -Grid $grid -Groups @($output[0].Groups) -Selected $state.Selected
                $status.Text='Gruppi letti: '+$output[0].Groups.Count
            }
        }
        catch { if (-not $state.Closing) { $status.Text='Lettura non riuscita: '+$_.Exception.Message } }
        finally { $state.Pipeline.Dispose();$state.Pipeline=$null;$state.Invocation=$null;$state.Runspace.Close();$state.Runspace.Dispose();$state.Runspace=$null;$load.Enabled=$true;$grid.Enabled=$true;$save.Enabled=$true }
        if ($state.Closing) { $picker.Close() }
    })
    $save.Add_Click({
        $selected=@(Get-AssistenteITPickedGroups $grid)
        if (-not $selected.Count) { $status.Text='Selezionare almeno un gruppo nella colonna Controlla.';return }
        $labels=@{};foreach ($entry in $selected) { if (-not $entry.Label.Trim() -or $labels.ContainsKey($entry.Label.Trim())) { $status.Text='Impostare etichette univoche per i gruppi.';return };$labels[$entry.Label.Trim()]=$true }
        $state.Result=$selected;$state.Accepted=$true;$picker.Close()
    })
    $picker.Add_FormClosing({param($sender,$eventArgs);if ($null -ne $state.Invocation -and -not $state.Invocation.IsCompleted) { $eventArgs.Cancel=$true;$state.Closing=$true;$save.Enabled=$false;$cancel.Enabled=$false;$status.Text='Interruzione lettura...';if ($null -eq $state.Stop) { $state.Stop=$state.Pipeline.BeginStop($null,$null) } }})
    try { [void]$picker.ShowDialog($Owner);if ($state.Accepted) { return ,$state.Result };return $null }
    finally { $timer.Stop();$timer.Dispose();if ($null -ne $state.Pipeline) { $state.Pipeline.Stop();$state.Pipeline.Dispose() };if ($null -ne $state.Runspace) { $state.Runspace.Close();$state.Runspace.Dispose() };$picker.Dispose() }
}
