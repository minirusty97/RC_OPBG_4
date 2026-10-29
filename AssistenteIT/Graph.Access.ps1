#requires -version 5.1
function Show-AssistenteITModuleAccess {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$InstallRoot,[Parameter(Mandatory=$true)]$Module,[Parameter(Mandatory=$true)][string]$ConfigPath,[switch]$VerifyOnly,$Owner)
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $dialog=New-Object Windows.Forms.Form
    $dialog.Text='Assistente IT - Accesso e verifica';$dialog.ClientSize=New-Object Drawing.Size(760,500)
    $dialog.StartPosition='CenterScreen';$dialog.Font=New-Object Drawing.Font('Segoe UI',10)
    $icon=New-Object Drawing.Icon((Join-Path $InstallRoot 'assets/AssistenteIT.ico'));$dialog.Icon=$icon
    $title=New-Object Windows.Forms.Label;$title.Text='Accesso Microsoft e verifica autorizzazioni';$title.SetBounds(18,14,724,28)
    $status=New-Object Windows.Forms.Label;$status.Name='GraphAccessStatus';$status.Text='Preparazione accesso Microsoft...';$status.SetBounds(18,46,724,56)
    $grid=New-Object Windows.Forms.DataGridView;$grid.Name='GraphAccessPermissions';$grid.SetBounds(18,112,724,225)
    $grid.ReadOnly=$true;$grid.AllowUserToAddRows=$false;$grid.AllowUserToDeleteRows=$false;$grid.RowHeadersVisible=$false
    $grid.AutoSizeColumnsMode='Fill';$grid.MultiSelect=$false
    [void]$grid.Columns.Add('Name','Funzione');[void]$grid.Columns.Add('State','Esito');[void]$grid.Columns.Add('Detail','Dettaglio')
    $grid.Columns['Name'].FillWeight=28;$grid.Columns['State'].FillWeight=20;$grid.Columns['Detail'].FillWeight=52
    $hint=New-Object Windows.Forms.Label;$hint.Text='Le funzioni senza consenso saranno indisponibili. Gli ambiti non sostituiscono i ruoli dell''utente: i diritti sulle operazioni restano verificati dalle API. Questa verifica non elimina dispositivi e non legge password BitLocker.';$hint.SetBounds(18,348,724,60)
    $codeBox=New-Object Windows.Forms.TextBox;$codeBox.ReadOnly=$true;$codeBox.Visible=$false;$codeBox.SetBounds(18,414,200,25)
    $browserButton=New-Object Windows.Forms.Button;$browserButton.Text='Apri accesso Microsoft';$browserButton.Visible=$false;$browserButton.SetBounds(230,411,190,30)
    $browserButton.Add_Click({ [void][Diagnostics.Process]::Start('https://microsoft.com/devicelogin') })
    $open=New-Object Windows.Forms.Button;$open.Name='OpenVerifiedModule';$open.Text='Apri modulo';$open.Enabled=$false;$open.SetBounds(420,454,185,32)
    if ($VerifyOnly) { $open.Text='Conferma accesso' }
    $cancel=New-Object Windows.Forms.Button;$cancel.Text='Annulla';$cancel.SetBounds(617,454,125,32)
    $dialog.Controls.AddRange(@($title,$status,$grid,$hint,$codeBox,$browserButton,$open,$cancel))
    $state=@{Pipeline=$null;Runspace=$null;Invocation=$null;Stop=$null;Cancelled=$false;Accepted=$false;Result=$null;BrowserShown=$false}
    $queue=New-Object 'Collections.Concurrent.ConcurrentQueue[object]'
    $timer=New-Object Windows.Forms.Timer;$timer.Interval=100
    $requestCancel={
        $state.Cancelled=$true;$open.Enabled=$false;$cancel.Enabled=$false
        if ($null -ne $state.Invocation -and -not $state.Invocation.IsCompleted) {
            $status.Text='Annullamento accesso...'
            if ($null -eq $state.Stop) { $state.Stop=$state.Pipeline.BeginStop($null,$null) }
        }
        else { $dialog.Close() }
    }
    $cancel.Add_Click($requestCancel)
    $open.Add_Click({ $state.Accepted=$true;$dialog.Close() })
    $dialog.Add_FormClosing({param($sender,$eventArgs)
        if ($null -ne $state.Invocation -and -not $state.Invocation.IsCompleted) { $eventArgs.Cancel=$true;& $requestCancel }
    })
    $timer.Add_Tick({
        $notice=$null
        while ($queue.TryDequeue([ref]$notice)) {
            if ($state.Cancelled) { continue }
            $status.Text=[string]$notice.Message
            if ($notice.Kind -eq 'GraphLogin') {
                $codeBox.Text=[string]$notice.Code;$codeBox.Visible=$true;$browserButton.Visible=$true
                if (-not $state.BrowserShown) { $state.BrowserShown=$true;try { [void][Diagnostics.Process]::Start('https://microsoft.com/devicelogin') } catch { } }
            }
        }
        if ($null -eq $state.Invocation -or -not $state.Invocation.IsCompleted) { return }
        # Stop before EndInvoke and any UI updates: no re-entrant completion dialogs.
        $timer.Stop();$codeBox.Visible=$false;$browserButton.Visible=$false
        try {
            if ($null -ne $state.Stop) { $state.Pipeline.EndStop($state.Stop) }
            $output=@($state.Pipeline.EndInvoke($state.Invocation))
            if ($state.Cancelled) { $dialog.Close();return }
            if ($state.Pipeline.Streams.Error.Count -gt 0 -or $output.Count -ne 1) { throw 'Verifica non completata. Controllare configurazione, connessione e consensi con il sistemista.' }
            $state.Result=$output[0]
            foreach ($permission in $state.Result.Permissions) {
                $label='Non disponibile';if ($permission.Available) { $label='Ambito disponibile' }
                $index=$grid.Rows.Add($permission.Name,$label,$permission.Detail)
                if (-not $permission.Available) { $grid.Rows[$index].DefaultCellStyle.BackColor=[Drawing.Color]::MistyRose }
                else { $grid.Rows[$index].DefaultCellStyle.BackColor=[Drawing.Color]::Honeydew }
            }
            $status.Text=('Account: {0}. App: {1}.{2}Verifica completata; nessuna richiesta di nuovi permessi verra avviata nel modulo.' -f $state.Result.Account,$state.Result.AppName,[Environment]::NewLine)
            if (-not $VerifyOnly -and @($state.Result.Permissions | Where-Object { -not $_.Available }).Count) { $open.Text='Apri funzioni disponibili' }
            $open.Enabled=$true
        }
        catch {
            if ($state.Cancelled) { $dialog.Close();return }
            $status.Text='Accesso o verifica non riusciti: '+$_.Exception.Message+'. Il modulo non e stato aperto.'
        }
    })
    $dialog.Add_Shown({
        try {
            $state.Runspace=[RunspaceFactory]::CreateRunspace();$state.Runspace.ApartmentState='STA';$state.Runspace.ThreadOptions='ReuseThread';$state.Runspace.Open()
            $state.Pipeline=[PowerShell]::Create();$state.Pipeline.Runspace=$state.Runspace
            $worker={
                param($Root,$Config,$ModuleDefinition,$Queue)
                $ErrorActionPreference='Stop'
                Import-Module (Join-Path $Root 'AssistenteIT/AssistenteIT.Core.psm1') -ErrorAction Stop
                Initialize-AssistenteITModuleAccess -Module $ModuleDefinition -ConfigPath $Config -ProgressQueue $Queue
            }
            [void]$state.Pipeline.AddScript($worker.ToString()).AddArgument($InstallRoot).AddArgument($ConfigPath).AddArgument($Module).AddArgument($queue)
            $state.Invocation=$state.Pipeline.BeginInvoke();$timer.Start()
        }
        catch { $status.Text='Preparazione accesso non riuscita: '+$_.Exception.Message }
    })
    try {
        if ($null -ne $Owner) { [void]$dialog.ShowDialog($Owner) } else { [void]$dialog.ShowDialog() }
        if ($state.Accepted) { return $state.Result }
        return $null
    }
    finally {
        $timer.Stop();$timer.Dispose()
        if ($null -ne $state.Pipeline) { $state.Pipeline.Stop();$state.Pipeline.Dispose() }
        if ($null -ne $state.Runspace) { $state.Runspace.Close();$state.Runspace.Dispose() }
        $dialog.Dispose();$icon.Dispose()
    }
}
