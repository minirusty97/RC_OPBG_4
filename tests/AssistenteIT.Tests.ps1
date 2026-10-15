#requires -version 5.1
[CmdletBinding()]
param([string]$InstallRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
Import-Module (Join-Path $InstallRoot 'AssistenteIT/AssistenteIT.Core.psm1') -Force -ErrorAction Stop
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('suite-tests-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temporary)
try {
    $manifest = Read-AssistenteITManifest $InstallRoot
    if ($manifest.Modules[0].Id -ne 'computer-explorer') { throw 'Computer Explorer missing from manifest.' }
    if (-not (Test-Path -LiteralPath (Join-Path $InstallRoot ('docs/releases/' + $manifest.Version + '.md')))) { throw 'Release notes missing for the manifest version.' }
    $paths = Initialize-AssistenteIT -InstallRoot $InstallRoot -DataRoot (Join-Path $temporary 'user one')
    $config = Get-Content -LiteralPath $paths.ConfigPath -Raw | ConvertFrom-Json
    $config.Search.MinimumCharacters=4
    $config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $paths.ConfigPath -Encoding UTF8
    [IO.File]::WriteAllText($paths.EnvPath, "GLPI_USER_TOKEN='existing-user'`r`nGLPI_APP_TOKEN='existing-app'`r`n")
    $before = [IO.File]::ReadAllText($paths.ConfigPath); $envBefore = [IO.File]::ReadAllText($paths.EnvPath)
    $null = Initialize-AssistenteIT -InstallRoot $InstallRoot -DataRoot $paths.DataRoot
    if ([IO.File]::ReadAllText($paths.ConfigPath) -ne $before -or [IO.File]::ReadAllText($paths.EnvPath) -ne $envBefore) { throw 'Initialization overwrote existing user files.' }
    'PASS: first launch seeds user configuration; later launches preserve existing files.'

    Save-AssistenteITSettings -Paths $paths -DomainControllers @('dc1.example.invalid','dc2.example.invalid') -GlpiBaseUri 'https://glpi.example.invalid/glpi/apirest.php/' -GlpiEnabled $true -UseAppToken $true
    $config = Get-Content -LiteralPath $paths.ConfigPath -Raw | ConvertFrom-Json
    if ($config.Search.MinimumCharacters -ne 4 -or $config.Glpi.BaseUri -ne 'https://glpi.example.invalid/glpi/apirest.php' -or $config.DomainControllers.Count -ne 2 -or [IO.File]::ReadAllText($paths.EnvPath) -ne $envBefore) { throw 'Settings changed unrelated options or blank inputs erased tokens.' }
    'PASS: saving connection settings preserves search options and tokens left blank.'

    Save-AssistenteITSettings -Paths $paths -DomainControllers 'dc1.example.invalid' -GlpiBaseUri 'https://glpi.example.invalid/apirest.php' -GlpiEnabled $true -UserToken 'new#literal$token' -AppToken 'new-app'
    Import-Module (Join-Path $InstallRoot 'ComputerExplorer.Core.psm1') -ErrorAction Stop
    $credentials = Read-ExplorerGlpiCredentials -Path $paths.EnvPath -UseAppToken $true
    if ($null -eq $credentials) { throw 'Saved tokens cannot be read by the actual explorer.' }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($credentials.User)
    try { if ([Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) -cne 'new#literal$token') { throw 'Token changed during serialization.' } }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr); $credentials.User.Dispose(); $credentials.App.Dispose() }
    'PASS: saved GLPI tokens round-trip through the production credential reader as literal values.'

    $before=[IO.File]::ReadAllText($paths.ConfigPath); $envBefore=[IO.File]::ReadAllText($paths.EnvPath)
    foreach ($bad in @(@{GlpiBaseUri='file:///tmp/invalid'}, @{GlpiBaseUri='https://user:password@example.invalid/apirest.php'}, @{GlpiBaseUri='https://example.invalid/apirest.php';UserToken="bad`nvalue"})) {
        $failed=$false
        try { Save-AssistenteITSettings -Paths $paths -DomainControllers 'dc1.example.invalid' -GlpiEnabled $true @bad }
        catch { $failed=$true }
        if (-not $failed -or [IO.File]::ReadAllText($paths.ConfigPath) -ne $before -or [IO.File]::ReadAllText($paths.EnvPath) -ne $envBefore) { throw 'Invalid settings modified user files.' }
    }
    'PASS: invalid URLs and multiline tokens are rejected before changing either file.'

    $second = Initialize-AssistenteIT -InstallRoot $InstallRoot -DataRoot (Join-Path $temporary 'user two')
    if ($second.ConfigPath -eq $paths.ConfigPath -or [IO.File]::ReadAllText($second.EnvPath) -eq $envBefore) { throw 'Configuration leaked across data roots.' }
    'PASS: separate user data roots do not share credentials or configuration.'

    $expectedRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'AssistenteIT'
    if ((Get-AssistenteITPaths).DataRoot -ne $expectedRoot) { throw 'Default data root uses an obsolete product name.' }
    $legacy = Join-Path $temporary 'previous data'; $migrated = Join-Path $temporary 'new data'
    [void][IO.Directory]::CreateDirectory((Join-Path $legacy 'Config'))
    [void][IO.Directory]::CreateDirectory((Join-Path $legacy 'empty directory'))
    [IO.File]::WriteAllBytes((Join-Path $legacy 'Config/.env'), [byte[]]@(239,187,191,35,0,13,10,255))
    $hash = (Get-FileHash -LiteralPath (Join-Path $legacy 'Config/.env')).Hash
    Move-AssistenteITUserData -DataRoot $migrated -LegacyRoot $legacy
    Move-AssistenteITUserData -DataRoot $migrated -LegacyRoot $legacy
    if ((Test-Path -LiteralPath $legacy) -or -not (Test-Path -LiteralPath (Join-Path $migrated 'empty directory')) -or (Get-FileHash -LiteralPath (Join-Path $migrated 'Config/.env')).Hash -ne $hash) { throw 'Migration lost bytes, directories or repeatability.' }
    'PASS: migration moves the entire old data tree to the renamed root without changing bytes; repeated migration is harmless.'

    [void][IO.Directory]::CreateDirectory((Join-Path $legacy 'Config'))
    [IO.File]::WriteAllText((Join-Path $legacy 'Config/.env'), 'previous credentials')
    [IO.File]::WriteAllText((Join-Path $legacy 'Config/settings.json'), 'previous settings')
    Move-AssistenteITUserData -DataRoot $migrated -LegacyRoot $legacy
    Move-AssistenteITUserData -DataRoot $migrated -LegacyRoot $legacy
    $archives = @(Get-ChildItem -LiteralPath (Join-Path $migrated 'Importazione-precedente') -Directory)
    if ($archives.Count -ne 1 -or (Get-FileHash -LiteralPath (Join-Path $migrated 'Config/.env')).Hash -ne $hash -or [IO.File]::ReadAllText((Join-Path $migrated 'Config/settings.json')) -ne 'previous settings' -or [IO.File]::ReadAllText((Join-Path $archives[0].FullName 'Config/.env')) -ne 'previous credentials') { throw 'Migration overwrote current files or lost conflicting previous files.' }
    'PASS: when both data roots exist, current files win, missing files are imported and all previous files remain in a local archive.'

    [void][IO.Directory]::CreateDirectory((Join-Path $legacy 'blocked'))
    [IO.File]::WriteAllText((Join-Path $legacy 'blocked/settings.json'), 'recover after failure')
    [IO.File]::WriteAllText((Join-Path $migrated 'blocked'), 'a file prevents directory creation')
    $failed = $false
    try { Move-AssistenteITUserData -DataRoot $migrated -LegacyRoot $legacy } catch { $failed = $true }
    if (-not $failed -or -not (Test-Path -LiteralPath (Join-Path $legacy 'blocked/settings.json'))) { throw 'Failed migration lost the previous data.' }
    Remove-Item -LiteralPath (Join-Path $migrated 'blocked')
    Move-AssistenteITUserData -DataRoot $migrated -LegacyRoot $legacy
    if ((Test-Path -LiteralPath $legacy) -or [IO.File]::ReadAllText((Join-Path $migrated 'blocked/settings.json')) -ne 'recover after failure') { throw 'Migration could not resume after a copy failure.' }
    'PASS: a failed merge retains the source tree and a later retry completes the migration.'

    $fixture=Join-Path $temporary 'fixture'; [void][IO.Directory]::CreateDirectory($fixture)
    'param()' | Set-Content -LiteralPath (Join-Path $temporary 'valid.ps1') -Encoding UTF8
    'param()' | Set-Content -LiteralPath (Join-Path $fixture 'valid.ps1') -Encoding UTF8
    foreach ($entries in @(
        @([pscustomobject]@{Id='outside';EntryPoint='../valid.ps1'}),
        @([pscustomobject]@{Id='same';EntryPoint='valid.ps1'},[pscustomobject]@{Id='same';EntryPoint='valid.ps1'})
    )) {
        [pscustomobject]@{SchemaVersion=1;Product='Fixture';Version='1.0.0';Modules=$entries} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $fixture 'assistente-it.json') -Encoding UTF8
        $failed=$false; try { $null=Read-AssistenteITManifest $fixture } catch { $failed=$true }
        if (-not $failed) { throw 'Manifest accepted a duplicate or external module.' }
    }
    'PASS: module manifests reject duplicate IDs and paths outside the application.'

    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        [void][IO.Directory]::CreateDirectory((Join-Path $fixture 'AssistenteIT'))
        Copy-Item -LiteralPath (Join-Path $InstallRoot 'AssistenteIT/AssistenteIT.Core.psm1') -Destination (Join-Path $fixture 'AssistenteIT/AssistenteIT.Core.psm1')
        Copy-Item -LiteralPath (Join-Path $InstallRoot 'AssistenteIT/Invoke-Module.ps1') -Destination (Join-Path $fixture 'AssistenteIT/Invoke-Module.ps1')
        Copy-Item -LiteralPath (Join-Path $InstallRoot 'AssistenteIT/LegacyMigration.ps1') -Destination (Join-Path $fixture 'AssistenteIT/LegacyMigration.ps1')
        'param($ConfigPath,$EnvPath); [pscustomobject]@{ConfigPath=$ConfigPath;EnvPath=$EnvPath}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $PSScriptRoot "result.json") -Encoding UTF8' | Set-Content -LiteralPath (Join-Path $fixture 'valid.ps1') -Encoding UTF8
        [pscustomobject]@{SchemaVersion=1;Product='Fixture';Version='1.0.0';Modules=@([pscustomobject]@{Id='test-module';EntryPoint='valid.ps1';UsesAppSettings=$true})} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $fixture 'assistente-it.json') -Encoding UTF8
        $process=[Diagnostics.Process]::Start((Get-AssistenteITModuleStartInfo -InstallRoot $fixture -ModuleId 'test-module' -Paths $paths))
        try {
            if (-not $process.WaitForExit(10000) -or $process.ExitCode -ne 0) { throw 'Module runner did not exit successfully.' }
            $result=Get-Content -LiteralPath (Join-Path $fixture 'result.json') -Raw | ConvertFrom-Json
            if ($result.ConfigPath -ne $paths.ConfigPath -or $result.EnvPath -ne $paths.EnvPath) { throw 'Runner lost personal paths containing spaces.' }
        }
        finally { if (-not $process.HasExited) { $process.Kill() }; $process.Dispose() }
        'PASS: the native module runner passes personal configuration and credentials paths to its registered module.'
    }
}
finally { Remove-Item -LiteralPath $temporary -Recurse -Force }
