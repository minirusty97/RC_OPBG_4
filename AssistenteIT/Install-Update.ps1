#requires -version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$PlanPath,[Parameter(Mandatory=$true)][string]$InstallRoot,[int]$ParentProcessId,[int]$LauncherProcessId,[string]$ReadyEvent)
$ErrorActionPreference='Stop'
$log=Join-Path (Split-Path ([IO.Path]::GetFullPath($PlanPath)) -Parent) 'update-install.log'
$acknowledged=-not $ReadyEvent
function Write-UpdateLog {
    param([string]$Message)
    try { [IO.File]::AppendAllText($log,([datetime]::Now.ToString('s')+' '+$Message+[Environment]::NewLine),[Text.Encoding]::UTF8) }
    catch { }
}
try {
    Write-UpdateLog 'Processo di aggiornamento avviato.'
    Import-Module (Join-Path $PSScriptRoot 'AssistenteIT.Update.psm1') -ErrorAction Stop
    if ($ReadyEvent) {
        if ($ReadyEvent -notmatch '^Local\\AssistenteIT\.UpdateReady\.[0-9a-f]{32}$') { throw 'Conferma di avvio non valida.' }
        $ready=[Threading.EventWaitHandle]::OpenExisting($ReadyEvent)
        try { [void]$ready.Set(); $acknowledged=$true }
        finally { $ready.Dispose() }
    }
    Write-UpdateLog 'Attesa chiusura del programma e installazione del setup verificato.'
    $result=Invoke-AssistenteITUpdateInstall -PlanPath $PlanPath -InstallRoot $InstallRoot -ParentProcessId $ParentProcessId -LauncherProcessId $LauncherProcessId
    Write-UpdateLog ('Installazione verificata. Versione '+$result.Version+'.')
    $info=New-Object Diagnostics.ProcessStartInfo; $info.FileName=$result.LauncherPath; $info.UseShellExecute=$true
    [void][Diagnostics.Process]::Start($info)
    Write-UpdateLog 'Launcher riavviato.'
}
catch {
    $message=$_.Exception.Message
    Write-UpdateLog ('Errore: '+$message)
    if ($acknowledged) {
        Add-Type -AssemblyName System.Windows.Forms
        if ([IO.File]::Exists($log)) { $message+=[Environment]::NewLine+'Registro: '+$log }
        [void][Windows.Forms.MessageBox]::Show($message,'Aggiornamento Assistente IT','OK','Error')
    }
    exit 1
}
