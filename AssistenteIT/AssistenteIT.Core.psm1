#requires -version 5.1
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'LegacyMigration.ps1')
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'Glpi.Credentials.ps1')

function Read-AssistenteITManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$InstallRoot)
    $root = [IO.Path]::GetFullPath($InstallRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $manifest = Get-Content -LiteralPath (Join-Path $root 'assistente-it.json') -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
    if ($manifest.SchemaVersion -ne 1 -or $manifest.Version -notmatch '^\d+\.\d+\.\d+$' -or [string]::IsNullOrWhiteSpace($manifest.Product)) { throw 'Manifest della suite non valido.' }
    if (@($manifest.Modules).Count -eq 0) { throw 'Nessun modulo configurato nella suite.' }
    $ids = @{}
    foreach ($module in $manifest.Modules) {
        if ($module.Id -notmatch '^[a-z][a-z0-9-]{1,63}$' -or $ids.ContainsKey($module.Id)) { throw 'Identificativo di modulo non valido o duplicato.' }
        $ids[$module.Id] = $true
        if ([string]::IsNullOrWhiteSpace($module.EntryPoint) -or [IO.Path]::IsPathRooted($module.EntryPoint)) { throw 'Percorso del modulo non valido.' }
        $entry = [IO.Path]::GetFullPath((Join-Path $root $module.EntryPoint))
        if (-not $entry.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetExtension($entry) -ne '.ps1' -or -not (Test-Path -LiteralPath $entry -PathType Leaf)) { throw ('Modulo assente o esterno alla suite: ' + $module.Id) }
    }
    return $manifest
}

function Get-AssistenteITPaths {
    [CmdletBinding()]
    param([string]$DataRoot)
    if ([string]::IsNullOrWhiteSpace($DataRoot)) {
        $local = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
        if ([string]::IsNullOrWhiteSpace($local)) { throw 'Cartella dati utente non disponibile.' }
        $DataRoot = Join-Path $local 'AssistenteIT'
    }
    $data = [IO.Path]::GetFullPath($DataRoot)
    $config = Join-Path $data 'Config'
    return [pscustomobject]@{DataRoot=$data; ConfigDirectory=$config; ConfigPath=(Join-Path $config 'computer-explorer.config.local.json'); EnvPath=(Join-Path $config '.env')}
}

function Initialize-AssistenteIT {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$InstallRoot, [string]$DataRoot)
    $null = Read-AssistenteITManifest $InstallRoot
    $paths = Get-AssistenteITPaths $DataRoot
    if ([string]::IsNullOrWhiteSpace($DataRoot)) { Move-AssistenteITUserData -DataRoot $paths.DataRoot }
    [void][IO.Directory]::CreateDirectory($paths.ConfigDirectory)
    foreach ($item in @(
        @{Source='computer-explorer.config.example.json'; Target=$paths.ConfigPath},
        @{Source='.env.example'; Target=$paths.EnvPath}
    )) {
        if (-not (Test-Path -LiteralPath $item.Target)) {
            [IO.File]::Copy((Join-Path $InstallRoot $item.Source), $item.Target, $false)
        }
    }
    return $paths
}

function Write-AssistenteITAtomicFile {
    param([string]$Path, [string]$Text)
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, $Text, (New-Object Text.UTF8Encoding($true)))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, [System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    }
    finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function ConvertTo-AssistenteITEnvValue {
    param([string]$Value)
    if ($Value.IndexOfAny([char[]]@([char]0, [char]10, [char]13)) -ge 0) { throw 'Il token deve occupare una sola riga.' }
    if (-not $Value.Contains("'")) { return "'" + $Value + "'" }
    if (-not $Value.Contains('"')) { return '"' + $Value + '"' }
    throw 'Il formato del token non è supportato.'
}

function Save-AssistenteITSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$Paths,
        [Parameter(Mandatory=$true)][string[]]$DomainControllers,
        [string]$GlpiBaseUri='', [bool]$GlpiEnabled, [bool]$UseAppToken=$true,
        [string]$UserToken, [string]$AppToken
    )
    $controllers = @($DomainControllers | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
    if ($controllers.Count -eq 0 -or @($controllers | Where-Object { $_ -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.-]*$' }).Count -gt 0) { throw 'Inserire almeno un DC valido, uno per riga.' }
    $uriText = $GlpiBaseUri.Trim().TrimEnd('/')
    if ($GlpiEnabled -and -not $uriText) { throw 'Specificare l''URL API di GLPI.' }
    if ($uriText) {
        $uri = $null
        if (-not [Uri]::TryCreate($uriText, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http','https') -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) { throw 'URL API GLPI non valido. Esempio: https://server/glpi/apirest.php' }
    }
    foreach ($value in @($UserToken,$AppToken)) {
        if ($null -ne $value -and $value.IndexOfAny([char[]]@([char]0,[char]10,[char]13)) -ge 0) { throw 'Il token deve occupare una sola riga.' }
    }
    $configuration = Get-Content -LiteralPath $Paths.ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $configuration.DomainControllers = $controllers
    $configuration.Glpi.Enabled = $GlpiEnabled; $configuration.Glpi.BaseUri = $uriText; $configuration.Glpi.UseAppToken = $UseAppToken
    $user=$null; $app=$null
    try {
        if (-not [string]::IsNullOrWhiteSpace($UserToken)) { $user=ConvertTo-SecureString $UserToken.Trim() -AsPlainText -Force }
        if (-not [string]::IsNullOrWhiteSpace($AppToken)) { $app=ConvertTo-SecureString $AppToken.Trim() -AsPlainText -Force }
        Save-ExplorerGlpiCredentials -Path $Paths.EnvPath -User $user -App $app
    }
    finally { if ($null -ne $user) { $user.Dispose() }; if ($null -ne $app) { $app.Dispose() } }
    Write-AssistenteITAtomicFile $Paths.ConfigPath (($configuration | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
}

function Enable-AssistenteITDependencies {
    param([Parameter(Mandatory=$true)][string]$InstallRoot)
    $dependencies = Join-Path $InstallRoot 'Dependencies'
    if (Test-Path -LiteralPath $dependencies -PathType Container) {
        $parts = @($env:PSModulePath -split [IO.Path]::PathSeparator)
        if ($parts -notcontains $dependencies) { $env:PSModulePath = $dependencies + [IO.Path]::PathSeparator + $env:PSModulePath }
    }
}

function Get-AssistenteITPrerequisites {
    [CmdletBinding()]
    param()
    [pscustomobject]@{
        GraphAvailable = @(Get-Module -ListAvailable -Name Microsoft.Graph.Authentication -ErrorAction SilentlyContinue).Count -gt 0
        ActiveDirectoryAvailable = @(Get-Module -ListAvailable -Name ActiveDirectory -ErrorAction SilentlyContinue).Count -gt 0
    }
}

function Open-AssistenteITActivity {
    # All suite processes keep a handle open. Setup/uninstall refuses to run
    # while any handle exists; no running search or removal is killed.
    return New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, 'Local\AssistenteIT.Running')
}

function Get-AssistenteITModuleStartInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$InstallRoot, [Parameter(Mandatory=$true)][string]$ModuleId, [Parameter(Mandatory=$true)]$Paths)
    $manifest = Read-AssistenteITManifest $InstallRoot
    if (@($manifest.Modules | Where-Object { $_.Id -eq $ModuleId }).Count -ne 1) { throw 'Modulo non disponibile.' }
    $runner = Join-Path $InstallRoot 'AssistenteIT/Invoke-Module.ps1'
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'WindowsPowerShell/v1.0/powershell.exe'
    $info.Arguments = '-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -ModuleId "{1}" -ConfigPath "{2}" -EnvPath "{3}"' -f $runner, $ModuleId, $Paths.ConfigPath, $Paths.EnvPath
    $info.WorkingDirectory = $InstallRoot; $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $info.EnvironmentVariables['PSModulePath'] = (Join-Path $InstallRoot 'Dependencies') + [IO.Path]::PathSeparator + $env:PSModulePath
    return $info
}

Export-ModuleMember -Function Read-AssistenteITManifest, Get-AssistenteITPaths, Initialize-AssistenteIT, Save-AssistenteITSettings, Enable-AssistenteITDependencies, Get-AssistenteITPrerequisites, Open-AssistenteITActivity, Get-AssistenteITModuleStartInfo, Move-AssistenteITUserData
