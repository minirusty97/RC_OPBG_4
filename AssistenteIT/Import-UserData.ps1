#requires -version 5.1
$ErrorActionPreference = 'Stop'
try {
    Import-Module (Join-Path $PSScriptRoot 'AssistenteIT.Core.psm1') -ErrorAction Stop
    $paths = Get-AssistenteITPaths
    Move-AssistenteITUserData -DataRoot $paths.DataRoot
    exit 0
}
catch {
    # Setup reports the error without including personal file contents.
    [Console]::Error.WriteLine('Migrazione dei dati personali non completata. I file precedenti sono conservati; riprovare il setup.')
    exit 1
}
