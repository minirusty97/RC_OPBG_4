#requires -version 5.1
[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) 'output/assistente-it'),
    [string]$Version,
    [switch]$AdSearchTestPortable,
    [string]$MakeNsisPath = (Join-Path ${env:ProgramFiles(x86)} 'NSIS/makensis.exe')
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or -not [Environment]::Is64BitProcess) { throw 'La build richiede Windows PowerShell a 64 bit.' }
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'AssistenteIT/AssistenteIT.Core.psm1') -ErrorAction Stop
$manifest = Read-AssistenteITManifest $root
if (-not $Version) { $Version=$manifest.Version }
if ($Version -notmatch '^\d+\.\d+\.\d+$' -or @($Version.Split('.') | Where-Object { [int]$_ -gt 65535 }).Count -gt 0) { throw 'Versione non valida. Usare major.minor.patch.' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
[void][IO.Directory]::CreateDirectory($OutputDirectory)
if (-not $AdSearchTestPortable -and -not (Test-Path -LiteralPath $MakeNsisPath -PathType Leaf)) { throw 'NSIS non trovato. Installare NSIS 3.13.0 oppure specificare -MakeNsisPath.' }
$cache = Join-Path $OutputDirectory 'dependency-cache'
$graph = Join-Path (Join-Path $cache 'Microsoft.Graph.Authentication') $manifest.GraphVersion
$graphManifest = Join-Path $graph 'Microsoft.Graph.Authentication.psd1'
if (-not (Test-Path -LiteralPath $graphManifest)) {
    [void][IO.Directory]::CreateDirectory($cache)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) { $null=Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force }
    Save-Module -Name Microsoft.Graph.Authentication -RequiredVersion $manifest.GraphVersion -Repository PSGallery -Path $cache -Force -AcceptLicense -ErrorAction Stop
}
$dependency = Test-ModuleManifest -Path $graphManifest -ErrorAction Stop
if ($dependency.Version.ToString() -ne $manifest.GraphVersion) { throw 'Versione Graph diversa da quella fissata nel manifest.' }
# Import without login to verify the bundled Desktop assemblies and commands.
Import-Module $graphManifest -ErrorAction Stop
$null = Get-Command Connect-MgGraph, Invoke-MgGraphRequest -ErrorAction Stop
$stage = Join-Path $OutputDirectory ('stage-' + [guid]::NewGuid().ToString('N'))
$app = Join-Path $stage 'app'
try {
    [void][IO.Directory]::CreateDirectory($app)
    # Explicit runtime allowlist: never copy the checkout recursively.
    $files = @(
        'Start-AssistenteIT.ps1', 'assistente-it.json', 'AssistenteIT/AssistenteIT.Core.psm1', 'AssistenteIT/Invoke-Module.ps1',
        'AssistenteIT/Graph.Access.ps1', 'AssistenteIT/Graph.Session.ps1', 'AssistenteIT/GroupPicker.UI.ps1', 'AssistenteIT/Window.Identity.cs', 'AssistenteIT/LegacyMigration.ps1', 'AssistenteIT/Import-UserData.ps1',
        'AssistenteIT/AssistenteIT.Update.psm1', 'AssistenteIT/Install-Update.ps1',
        'Graph.Authentication.ps1', 'Graph.LoginBridge.cs', 'Start-ComputerExplorer.ps1', 'ComputerExplorer.Core.psm1', 'ComputerExplorer.Identity.ps1', 'ComputerExplorer.Parallel.psm1', 'ComputerExplorer.AdRead.ps1', 'ComputerExplorer.AdLog.ps1', 'ComputerExplorer.Removal.psm1',
        'Start-HybridJoin.ps1', 'Start-RingManager.ps1', 'DeviceModules.Core.psm1', 'DeviceModules.UI.ps1', 'HybridJoin.Core.psm1', 'RingManager.Core.psm1', 'ComputerExplorer.Removal.UI.ps1',
        'BitLocker.Archive.psm1', 'ComputerExplorer.Recovery.UI.ps1', 'AssistenteIT/Recovery.Print.cs', 'GLPI.Inventory.psm1', 'Glpi.Credentials.ps1', 'Test-AdLookup.ps1', 'computer-explorer.config.example.json', '.env.example',
        'docs/Autenticazione-Graph-Delegata.md', 'docs/Accesso-Iniziale.md', 'docs/Installazione-AssistenteIT.md', 'docs/Third-Party-Notices.txt', 'assets/AssistenteIT.ico'
    )
    foreach ($file in $files) {
        $target = Join-Path $app $file
        [void][IO.Directory]::CreateDirectory((Split-Path $target -Parent))
        Copy-Item -LiteralPath (Join-Path $root $file) -Destination $target -ErrorAction Stop
    }
    $manifest.Version=$Version
    [IO.File]::WriteAllText((Join-Path $app 'assistente-it.json'), ($manifest | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
    $targetGraph = Join-Path (Join-Path (Join-Path $app 'Dependencies') 'Microsoft.Graph.Authentication') $manifest.GraphVersion
    [void][IO.Directory]::CreateDirectory((Split-Path $targetGraph -Parent))
    Copy-Item -LiteralPath $graph -Destination $targetGraph -Recurse -ErrorAction Stop
    $null = Read-AssistenteITManifest $app
    if (Test-Path -LiteralPath (Join-Path $app '.env')) { throw 'Credenziali presenti nel pacchetto.' }
    if (Test-Path -LiteralPath (Join-Path $app 'computer-explorer.config.local.json')) { throw 'Configurazione personale presente nel pacchetto.' }
    $commit = $env:GITHUB_SHA
    if (-not $commit) { $commit='local-build' }
    [pscustomobject]@{Version=$Version;Commit=$commit;GraphVersion=$manifest.GraphVersion} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $app 'build-info.json') -Encoding UTF8
    $launcherSource = Join-Path $stage 'Launcher.cs'
    [IO.File]::WriteAllText($launcherSource, ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Launcher.cs')).Replace('__VERSION__',$Version)), (New-Object Text.UTF8Encoding($true)))
    $compiler = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
    & $compiler /nologo /target:winexe /platform:x64 /reference:System.Windows.Forms.dll (('/win32icon:' + (Join-Path $root 'assets/AssistenteIT.ico'))) (('/out:' + (Join-Path $stage 'AssistenteIT.exe'))) $launcherSource | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { throw 'Compilazione del launcher non riuscita.' }
    Remove-Item -LiteralPath $launcherSource -Force
    if ($AdSearchTestPortable) {
        [IO.File]::WriteAllText((Join-Path $app 'ad-search-test.flag'), $commit)
        $testLauncher = Join-Path $stage 'AssistenteIT-Test-AD.exe'
        Move-Item -LiteralPath (Join-Path $stage 'AssistenteIT.exe') -Destination $testLauncher
        Copy-Item -LiteralPath (Join-Path $root 'docs/Test-AD-Parallelo.md') -Destination (Join-Path $stage 'ISTRUZIONI.md')

        $smokePath = Join-Path $OutputDirectory ('test-ad-smoke-' + [guid]::NewGuid().ToString('N') + '.json')
        try {
            $process = Start-Process -FilePath $testLauncher -ArgumentList ('--smoke-test "' + $smokePath + '"') -Wait -PassThru
            if ($process.ExitCode -ne 0 -or -not [IO.File]::Exists($smokePath)) { throw 'Avvio della prova AD non riuscito.' }
            $smoke = [IO.File]::ReadAllText($smokePath) | ConvertFrom-Json
            $checks = [ordered]@{
                WindowTitle = ($smoke.WindowTitle -like '*Test ricerca AD')
                ModuleCount = ($smoke.ModuleCount -eq 1)
                OtaDisabled = [string]::IsNullOrEmpty([string]$smoke.UpdateButton)
                GraphAvailable = [bool]$smoke.GraphAvailable
                SeparateDataRoot = ($smoke.DataRoot -like '*AssistenteIT-TestAD')
            }
            $failures = @($checks.Keys | Where-Object { -not $checks[$_] })
            if ($failures.Count) {
                throw ('Controlli di avvio falliti ({0}). Risposta: {1}' -f ($failures -join ', '), ($smoke | ConvertTo-Json -Compress))
            }
            Write-Host 'PASS: il launcher portatile avvia la prova AD con Graph, un solo modulo, dati separati e OTA disabilitato.'
        }
        finally { if ([IO.File]::Exists($smokePath)) { [IO.File]::Delete($smokePath) } }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = Join-Path $OutputDirectory ('Assistente-IT-' + $Version + '-5DC-Test-AD.zip')
        if ([IO.File]::Exists($zip)) { [IO.File]::Delete($zip) }
        [IO.Compression.ZipFile]::CreateFromDirectory($stage,$zip,[IO.Compression.CompressionLevel]::Optimal,$false)
        $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
        $checksum = $zip + '.sha256'
        [IO.File]::WriteAllText($checksum, ($hash + ' *' + [IO.Path]::GetFileName($zip) + "`r`n"))
        return [pscustomobject]@{Version=$Version;ZipPath=$zip;ChecksumPath=$checksum;GraphVersion=$manifest.GraphVersion}
    }
    $setup = Join-Path $OutputDirectory ('Assistente-IT-Setup-' + $Version + '.exe')
    & $MakeNsisPath /V3 /NOCD (('/DAPP_VERSION=' + $Version)) (('/DPACKAGE_ROOT=' + $stage)) (('/DOUTPUT_FILE=' + $setup)) (Join-Path $PSScriptRoot 'AssistenteIT.nsi') | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $setup)) { throw 'Creazione dell''installer non riuscita.' }
    $checksum = Join-Path $OutputDirectory ('Assistente-IT-' + $Version + '-SHA256.txt')
    [IO.File]::WriteAllText($checksum, ((Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash + ' *' + [IO.Path]::GetFileName($setup) + "`r`n"), (New-Object Text.UTF8Encoding($false)))
    $feedPath=Join-Path $OutputDirectory 'update.json'
    $prefix='https://github.com/minirusty97/RC_OPBG_4/releases/download/v'+$Version+'/'
    $notesPath=Join-Path $root ('docs/releases/'+$Version+'.md')
    $notes='Nuova versione Assistente IT.'
    if (Test-Path -LiteralPath $notesPath) { $notes=[IO.File]::ReadAllText($notesPath,[Text.Encoding]::UTF8) }
    [ordered]@{SchemaVersion=1;Product='Assistente IT';Repository='minirusty97/RC_OPBG_4';Channel='stable';Version=$Version
        SetupName=[IO.Path]::GetFileName($setup);SetupUri=($prefix+[IO.Path]::GetFileName($setup));ChecksumUri=($prefix+[IO.Path]::GetFileName($checksum))
        Size=(Get-Item -LiteralPath $setup).Length;SHA256=(Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash;Notes=$notes
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $feedPath -Encoding UTF8
    [pscustomobject]@{Version=$Version; SetupPath=$setup; ChecksumPath=$checksum; UpdateManifestPath=$feedPath; GraphVersion=$manifest.GraphVersion}
}
finally { if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force } }
