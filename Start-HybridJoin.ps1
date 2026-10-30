#requires -version 5.1
[CmdletBinding()]
param([string]$ConfigPath=(Join-Path $PSScriptRoot 'computer-explorer.config.local.json'),[string]$EnvPath=(Join-Path $PSScriptRoot '.env'),$GraphAccess)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'DeviceModules.UI.ps1')
Show-DeviceModuleWindow -Kind Hybrid -ConfigPath $ConfigPath -EnvPath $EnvPath -GraphAccess $GraphAccess
