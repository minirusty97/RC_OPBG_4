#requires -version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$ModuleId, [string]$ConfigPath, [string]$EnvPath)
$ErrorActionPreference = 'Stop'
$activity = $null
try {
    Add-Type -AssemblyName System.Windows.Forms
    $root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $PSScriptRoot 'Suite.Core.psm1') -ErrorAction Stop
    $activity = Open-ITSuiteActivity
    Enable-ITSuiteDependencies $root
    $manifest = Read-ITSuiteManifest $root
    $module = @($manifest.Modules | Where-Object { $_.Id -eq $ModuleId })
    if ($module.Count -ne 1) { throw 'Modulo non disponibile.' }
    $arguments = @{}
    if ($module[0].UsesSuiteSettings) { $arguments.ConfigPath=$ConfigPath; $arguments.EnvPath=$EnvPath }
    & (Join-Path $root $module[0].EntryPoint) @arguments
}
catch {
    [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, 'OPBG IT Suite', 'OK', 'Error')
    exit 1
}
finally { if ($null -ne $activity) { $activity.Dispose() } }
