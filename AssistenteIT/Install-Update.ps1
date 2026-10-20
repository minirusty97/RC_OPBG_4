#requires -version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$PlanPath,[Parameter(Mandatory=$true)][string]$InstallRoot,[int]$ParentProcessId,[int]$LauncherProcessId)
$ErrorActionPreference='Stop'
try {
    Import-Module (Join-Path $PSScriptRoot 'AssistenteIT.Update.psm1') -ErrorAction Stop
    $result=Invoke-AssistenteITUpdateInstall -PlanPath $PlanPath -InstallRoot $InstallRoot -ParentProcessId $ParentProcessId -LauncherProcessId $LauncherProcessId
    $info=New-Object Diagnostics.ProcessStartInfo; $info.FileName=$result.LauncherPath; $info.UseShellExecute=$true
    [void][Diagnostics.Process]::Start($info)
}
catch {
    Add-Type -AssemblyName System.Windows.Forms
    [void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'Aggiornamento Assistente IT','OK','Error')
    exit 1
}
