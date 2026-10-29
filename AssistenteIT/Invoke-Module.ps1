#requires -version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$ModuleId, [string]$ConfigPath, [string]$EnvPath,$VerifiedAccess)
$ErrorActionPreference = 'Stop'
$activity = $null
try {
    Add-Type -AssemblyName System.Windows.Forms
    [Windows.Forms.Application]::EnableVisualStyles()
    $root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $PSScriptRoot 'AssistenteIT.Core.psm1') -ErrorAction Stop
    $activity = Open-AssistenteITActivity
    Enable-AssistenteITDependencies $root
    Initialize-AssistenteITWindowIdentity -InstallRoot $root
    $manifest = Read-AssistenteITManifest $root
    $module = @($manifest.Modules | Where-Object { $_.Id -eq $ModuleId })
    if ($module.Count -ne 1) { throw 'Modulo non disponibile.' }
    $arguments = @{}
    if ($module[0].UsesAppSettings) { $arguments.ConfigPath=$ConfigPath; $arguments.EnvPath=$EnvPath }
    $permissions=$module[0].PSObject.Properties['GraphPermissions']
    if ($null -ne $permissions -and @($permissions.Value).Count -gt 0) {
        if ($null -eq $VerifiedAccess -or -not $VerifiedAccess.CanOpen) { throw 'Eseguire Accesso dal wrapper prima di aprire il modulo.' }
        $passesAccess=$module[0].PSObject.Properties['UsesGraphAccess']
        if ($null -ne $passesAccess -and [bool]$passesAccess.Value) { $arguments.GraphAccess=$VerifiedAccess }
    }
    & (Join-Path $root $module[0].EntryPoint) @arguments
}
catch { throw }
finally { if ($null -ne $activity) { $activity.Dispose() } }
