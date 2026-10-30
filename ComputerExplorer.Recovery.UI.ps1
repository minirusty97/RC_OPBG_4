#requires -version 5.1
function Save-ExplorerBitLockerRecoveryCopy {
    param([string]$Text,[string]$ComputerName,$Owner)
    $saveDialog=New-Object Windows.Forms.SaveFileDialog
    $saveDialog.Title='Salva copia delle chiavi BitLocker';$saveDialog.Filter='File di testo (*.txt)|*.txt'
    $saveDialog.DefaultExt='txt';$saveDialog.AddExtension=$true;$saveDialog.OverwritePrompt=$true
    $safeName=$ComputerName -replace '[^A-Za-z0-9_.-]','_'
    if ($safeName.Length -gt 80) { $safeName=$safeName.Substring(0,80) }
    $saveDialog.FileName='BitLocker_'+$safeName+'_'+[datetime]::Now.ToString('yyyyMMdd-HHmmss')+'.txt'
    try {
        if ($saveDialog.ShowDialog($Owner) -ne 'OK') { return $false }
        [IO.File]::WriteAllText($saveDialog.FileName,$Text,(New-Object Text.UTF8Encoding($true)))
        return $true
    }
    finally { $saveDialog.Dispose() }
}

function Print-ExplorerBitLockerRecoveryCopy {
    param([string]$Text,$Owner)
    if (-not ('AssistenteIT.RecoveryPrinter' -as [type])) {
        try { Add-Type -Path (Join-Path $PSScriptRoot 'AssistenteIT/Recovery.Print.cs') -ReferencedAssemblies @('System.Drawing','System.Windows.Forms') -ErrorAction Stop }
        catch { if (-not ('AssistenteIT.RecoveryPrinter' -as [type])) { throw } }
    }
    return [AssistenteIT.RecoveryPrinter]::Print($Text,$Owner)
}

function Get-ExplorerRecoveryCopyWorkerScript {
    return {
        param($ModulePath,$PlanId,$Names)
        $ErrorActionPreference='Stop'
        Import-Module $ModulePath -ErrorAction Stop
        Import-Module (Join-Path (Split-Path $ModulePath -Parent) 'BitLocker.Archive.psm1') -ErrorAction Stop
        $records=@(Get-ExplorerRemovalPlanKeys -PlanId $PlanId -Names $Names)
        if ($records.Count -eq 0) { throw 'Nessuna chiave da copiare. Ripetere la verifica.' }
        ConvertTo-ExplorerBitLockerRecoveryText -Records $records
    }
}

function Show-ExplorerBitLockerLossConfirmation {
    param($Plan,[object[]]$Entries,$Owner)
    $lossNames=[string[]]@($Entries | ForEach-Object { $_.Name })
    $keyCount=0;foreach ($entry in $Entries) { $keyCount+=[int]$entry.Backup.KeyCount }
    $lossDialog=New-Object Windows.Forms.Form;$lossDialog.Name='BitLockerLossDialog'
    $lossDialog.Text='Conferma eliminazione senza archivio GLPI';$lossDialog.ClientSize=New-Object Drawing.Size(820,440)
    $lossDialog.MinimumSize=New-Object Drawing.Size(740,440);$lossDialog.StartPosition='CenterParent';$lossDialog.Icon=$Owner.Icon;$lossDialog.Font=$Owner.Font
    $lossLayout=New-Object Windows.Forms.TableLayoutPanel;$lossLayout.Dock='Fill';$lossLayout.Padding=New-Object Windows.Forms.Padding(12)
    $lossLayout.ColumnCount=1;$lossLayout.RowCount=5
    foreach ($height in @(85,-1,40,65,45)) { if ($height -lt 0) { [void]$lossLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100))) } else { [void]$lossLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',$height))) } }
    $lossWarning=New-Object Windows.Forms.Label;$lossWarning.Name='BitLockerLossWarning';$lossWarning.Dock='Fill';$lossWarning.ForeColor=[Drawing.Color]::DarkRed
    $lossWarning.Text='Per i PC elencati GLPI non contiene una sola scheda utilizzabile. Le chiavi BitLocker non saranno archiviate in GLPI e potranno andare perse dopo la cancellazione se non ne conservi una copia. Puoi scaricarle o stamparle prima di continuare.'
    $lossList=New-Object Windows.Forms.ListView;$lossList.Dock='Fill';$lossList.View='Details';$lossList.FullRowSelect=$true
    [void]$lossList.Columns.Add('Computer',300);[void]$lossList.Columns.Add('Schede GLPI trovate',190);[void]$lossList.Columns.Add('Chiavi recuperate',180)
    foreach ($entry in $Entries) { $item=New-Object Windows.Forms.ListViewItem([string]$entry.Name);[void]$item.SubItems.Add([string]$entry.Backup.GlpiMatchCount);[void]$item.SubItems.Add([string]$entry.Backup.KeyCount);[void]$lossList.Items.Add($item) }
    $lossStatus=New-Object Windows.Forms.Label;$lossStatus.Name='RecoveryCopyStatus';$lossStatus.Dock='Fill';$lossStatus.Text='Scarica o stampa una copia, oppure conferma di voler proseguire senza archivio GLPI.'
    if (-not $keyCount) { $lossStatus.Text='Nessuna chiave rilevata nelle origini selezionate: download e stampa non disponibili.' }
    $lossConsent=New-Object Windows.Forms.CheckBox;$lossConsent.Name='ConfirmBitLockerLoss';$lossConsent.Dock='Fill'
    $lossConsent.Text='Confermo l''eliminazione di questi PC senza archivio GLPI e accetto il rischio di perdita delle chiavi BitLocker non conservate in una copia esterna.'
    $lossButtons=New-Object Windows.Forms.FlowLayoutPanel;$lossButtons.Dock='Fill'
    $lossDownload=New-Object Windows.Forms.Button;$lossDownload.Name='DownloadBitLockerKeys';$lossDownload.Text='Scarica chiavi';$lossDownload.Width=140;$lossDownload.Enabled=$keyCount -gt 0
    $lossPrint=New-Object Windows.Forms.Button;$lossPrint.Name='PrintBitLockerKeys';$lossPrint.Text='Stampa chiavi';$lossPrint.Width=140;$lossPrint.Enabled=$keyCount -gt 0
    $lossConfirm=New-Object Windows.Forms.Button;$lossConfirm.Name='ConfirmRemovalWithoutGlpi';$lossConfirm.Text='Prosegui senza GLPI';$lossConfirm.Width=195;$lossConfirm.Enabled=$false
    $lossCancel=New-Object Windows.Forms.Button;$lossCancel.Name='CancelBitLockerLoss';$lossCancel.Text='Annulla';$lossCancel.Width=110
    $lossButtons.Controls.AddRange(@($lossDownload,$lossPrint,$lossConfirm,$lossCancel))
    $lossLayout.Controls.Add($lossWarning,0,0);$lossLayout.Controls.Add($lossList,0,1);$lossLayout.Controls.Add($lossStatus,0,2);$lossLayout.Controls.Add($lossConsent,0,3);$lossLayout.Controls.Add($lossButtons,0,4)
    $lossDialog.Controls.Add($lossLayout);$lossDialog.AcceptButton=$lossCancel;$lossDialog.CancelButton=$lossCancel
    $lossState=@{Text=$null;Pipeline=$null;Invocation=$null;Stop=$null;Closing=$false;Accepted=$false;Action='';ReadFailed=$false}
    $lossTimer=New-Object Windows.Forms.Timer;$lossTimer.Interval=100
    $lossDispatch={
        param([string]$Action)
        try {
            if ($Action -eq 'Download') { $saved=Save-ExplorerBitLockerRecoveryCopy -Text $lossState.Text -ComputerName ($lossNames -join '_') -Owner $lossDialog;$lossStatus.Text='Salvataggio annullato.';if ($saved) { $lossStatus.Text='Copia delle chiavi salvata nel file scelto.' } }
            else { $printed=Print-ExplorerBitLockerRecoveryCopy -Text $lossState.Text -Owner $lossDialog;$lossStatus.Text='Stampa annullata.';if ($printed) { $lossStatus.Text='Stampa inviata alla stampante scelta.' } }
        }
        catch { $lossStatus.Text='Copia non completata. Verificare percorso o stampante e riprovare.' }
    }
    $lossStartCopy={
        param([string]$Action)
        if ($null -ne $lossState.Pipeline) { return }
        if ($null -ne $lossState.Text) { & $lossDispatch $Action;return }
        try {
            $lossState.ReadFailed=$false;$lossState.Action=$Action
            $lossState.Pipeline=[PowerShell]::Create();$lossState.Pipeline.Runspace=$script:Worker
            $copyBody=Get-ExplorerRecoveryCopyWorkerScript
            [void]$lossState.Pipeline.AddScript($copyBody.ToString()).AddArgument((Join-Path $PSScriptRoot 'ComputerExplorer.Removal.psm1')).AddArgument($Plan.PlanId).AddArgument($lossNames)
            $lossState.Invocation=$lossState.Pipeline.BeginInvoke()
            $lossDownload.Enabled=$false;$lossPrint.Enabled=$false;$lossConfirm.Enabled=$false;$lossConsent.Enabled=$false
            $lossStatus.Text='Rilettura e verifica delle chiavi da copiare...';$lossTimer.Start()
        }
        catch { if ($null -ne $lossState.Pipeline) { $lossState.Pipeline.Dispose();$lossState.Pipeline=$null };$lossState.ReadFailed=$true;$lossConfirm.Enabled=$false;$lossStatus.Text='Lettura non completata. Ripetere l''anteprima prima di eliminare.' }
    }
    $lossDownload.Add_Click({ & $lossStartCopy 'Download' });$lossPrint.Add_Click({ & $lossStartCopy 'Print' })
    $lossConsent.Add_CheckedChanged({ $lossConfirm.Enabled=$lossConsent.Checked -and $null -eq $lossState.Pipeline -and -not $lossState.ReadFailed })
    $lossConfirm.Add_Click({ if ($lossConfirm.Enabled) { $lossState.Accepted=$true;$lossDialog.Close() } })
    $lossCancel.Add_Click({
        $lossState.Closing=$true
        if ($null -ne $lossState.Invocation -and -not $lossState.Invocation.IsCompleted) {
            $lossCancel.Enabled=$false;$lossStatus.Text='Annullamento lettura...'
            if ($null -eq $lossState.Stop) { $lossState.Stop=$lossState.Pipeline.BeginStop($null,$null) }
        }
        else { $lossDialog.Close() }
    })
    $lossDialog.Add_FormClosing({ param($sender,$eventArgs)
        if ($null -ne $lossState.Invocation -and -not $lossState.Invocation.IsCompleted) { $eventArgs.Cancel=$true;$lossCancel.PerformClick() }
    })
    $lossTimer.Add_Tick({
        if ($null -eq $lossState.Invocation -or -not $lossState.Invocation.IsCompleted) { return }
        $lossTimer.Stop();$success=$false
        try {
            if ($null -ne $lossState.Stop) { $lossState.Pipeline.EndStop($lossState.Stop) }
            $output=@($lossState.Pipeline.EndInvoke($lossState.Invocation))
            if ($lossState.Pipeline.Streams.Error.Count -gt 0) { throw $lossState.Pipeline.Streams.Error[0] }
            if ($output.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$output[0])) { throw 'Risposta della copia non valida.' }
            $lossState.Text=[string]$output[0];$success=$true
        }
        catch { if (-not $lossState.Closing) { $lossState.ReadFailed=$true;$lossStatus.Text='Lettura delle chiavi non completata. Ripetere l''anteprima prima di eliminare.' } }
        finally { $lossState.Pipeline.Dispose();$lossState.Pipeline=$null;$lossState.Invocation=$null;$lossState.Stop=$null }
        if ($lossState.Closing) { $lossDialog.Close();return }
        $lossDownload.Enabled=$keyCount -gt 0;$lossPrint.Enabled=$keyCount -gt 0;$lossConsent.Enabled=$true
        $lossConfirm.Enabled=$lossConsent.Checked -and -not $lossState.ReadFailed
        if ($success) { & $lossDispatch $lossState.Action }
    })
    try { [void]$lossDialog.ShowDialog($Owner);if ($lossState.Accepted) { return [pscustomobject]@{Names=$lossNames.Clone()} };return $null }
    finally {
        $lossTimer.Stop();$lossTimer.Dispose()
        if ($null -ne $lossState.Pipeline) { $lossState.Pipeline.Stop();$lossState.Pipeline.Dispose() }
        $lossState.Text=$null;$lossDialog.Dispose()
    }
}
