#requires -version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$ModuleId, [string]$ConfigPath, [string]$EnvPath)
$ErrorActionPreference = 'Stop'
$activity = $null
try {
    Add-Type -AssemblyName System.Windows.Forms
    $root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $PSScriptRoot 'AssistenteIT.Core.psm1') -ErrorAction Stop
    $activity = Open-AssistenteITActivity
    Enable-AssistenteITDependencies $root
    $manifest = Read-AssistenteITManifest $root
    $module = @($manifest.Modules | Where-Object { $_.Id -eq $ModuleId })
    if ($module.Count -ne 1) { throw 'Modulo non disponibile.' }
    $arguments = @{}
    if ($module[0].UsesAppSettings) { $arguments.ConfigPath=$ConfigPath; $arguments.EnvPath=$EnvPath }
    $permissions=$module[0].PSObject.Properties['GraphPermissions']
    if ($null -ne $permissions -and @($permissions.Value).Count -gt 0) {
        . (Join-Path $PSScriptRoot 'Graph.Access.ps1')
        $access=Show-AssistenteITModuleAccess -InstallRoot $root -Module $module[0] -ConfigPath $ConfigPath
        if ($null -eq $access) { return }
        $passesAccess=$module[0].PSObject.Properties['UsesGraphAccess']
        if ($null -ne $passesAccess -and [bool]$passesAccess.Value) { $arguments.GraphAccess=$access }
    }
    & (Join-Path $root $module[0].EntryPoint) @arguments
}
catch {
    [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Assistente IT', 'OK', 'Error')
    exit 1
}
finally { if ($null -ne $activity) { $activity.Dispose() } }
