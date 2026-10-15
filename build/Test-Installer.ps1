#requires -version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$SetupPath, [Parameter(Mandatory=$true)][string]$BaselineSetupPath)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Installer smoke test requires Windows.' }
$uninstallKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\OPBGITSuite'
$dataRoot=Join-Path (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'OPBG') 'ITSuite'
if (Test-Path $uninstallKey) { throw 'Run this test only on an isolated Windows runner without an installed suite.' }
if (Test-Path -LiteralPath $dataRoot) { throw 'Refusing to test against existing personal suite data.' }
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('suite-install-' + [guid]::NewGuid().ToString('N'))
$install=Join-Path $temporary 'install with spaces'
[void][IO.Directory]::CreateDirectory($temporary)
function Invoke-TestSetup {
    param([string]$Path, [int]$ExpectedExit=0)
    $process=Start-Process -FilePath $Path -ArgumentList ('/S /D=' + $install) -PassThru
    try {
        if (-not $process.WaitForExit(60000)) { $process.Kill(); throw 'Installer timed out.' }
        if ($process.ExitCode -ne $ExpectedExit) { throw ('Unexpected installer exit: {0}; expected {1}' -f $process.ExitCode,$ExpectedExit) }
    }
    finally { $process.Dispose() }
}
function Invoke-TestUninstall {
    $uninstaller=Join-Path $install 'Uninstall.exe'
    if (Test-Path -LiteralPath $uninstaller) {
        $process=Start-Process -FilePath $uninstaller -ArgumentList '/S' -PassThru
        try { if (-not $process.WaitForExit(30000)) { $process.Kill(); throw 'Uninstaller timed out.' } }
        finally { $process.Dispose() }
        $deadline=[datetime]::UtcNow.AddSeconds(15)
        while ((Test-Path $uninstallKey) -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
    }
}
function Invoke-TestSuiteWindow {
    param([string]$Launcher)
    $probe=Join-Path $temporary 'launch.json'
    $process=Start-Process -FilePath $Launcher -ArgumentList ('--smoke-test "' + $probe + '"') -PassThru
    try {
        if (-not $process.WaitForExit(30000)) { $process.Kill(); throw 'Installed GUI did not complete its smoke test.' }
        if ($process.ExitCode -ne 0) { throw 'Installed GUI failed to start.' }
    }
    finally { $process.Dispose() }
    return Get-Content -LiteralPath $probe -Raw | ConvertFrom-Json
}
try {
    Invoke-TestSetup $BaselineSetupPath
    if ((Get-ItemProperty $uninstallKey).DisplayVersion -ne '1.0.0') { throw 'Baseline installer did not register its version.' }
    $launcher=Join-Path $install 'OPBGITSuite.exe'
    $result=Invoke-TestSuiteWindow $launcher
    if (-not $result.GraphAvailable -or $result.ModuleCount -ne 1 -or $result.DataRoot -ne $dataRoot) { throw 'Installed suite did not find its module, bundled Graph or user data root.' }
    if (-not (Test-Path -LiteralPath (Join-Path ([Environment]::GetFolderPath('Programs')) 'OPBG IT Suite/OPBG IT Suite.lnk'))) { throw 'Start menu shortcut missing.' }
    'PASS: clean per-user setup registers the suite, creates its shortcut and starts the installed WinForms hub with bundled Graph.'

    $configPath=Join-Path $dataRoot 'Config/computer-explorer.config.local.json'; $envPath=Join-Path $dataRoot 'Config/.env'
    $config=Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $config.Search.MinimumCharacters=4; $config.Glpi.BaseUri='https://personal.example.invalid/apirest.php'
    $config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath -Encoding UTF8
    [IO.File]::WriteAllText($envPath,"GLPI_USER_TOKEN='synthetic-user'`r`nGLPI_APP_TOKEN='synthetic-app'`r`n")
    $configBefore=[IO.File]::ReadAllText($configPath); $envBefore=[IO.File]::ReadAllText($envPath)
    Invoke-TestSetup $SetupPath
    $installed=Get-Content -LiteralPath (Join-Path $install 'app/suite.json') -Raw | ConvertFrom-Json
    if ([version]$installed.Version -le [version]'1.0.0' -or (Get-ItemProperty $uninstallKey).DisplayVersion -ne $installed.Version) { throw 'Upgrade failed to replace the application version.' }
    if ([IO.File]::ReadAllText($configPath) -ne $configBefore -or [IO.File]::ReadAllText($envPath) -ne $envBefore) { throw 'Upgrade overwrote personal configuration or credentials.' }
    'PASS: upgrade from the published 1.0.0 preserves personal configuration and tokens byte for byte.'

    if (Test-Path -LiteralPath $launcher) { throw 'Legacy launcher remained after rename.' }
    $launcher=Join-Path $install 'AssistenteIT.exe'
    if ($installed.Product -ne 'Assistente IT' -or (Get-ItemProperty $uninstallKey).DisplayName -ne 'Assistente IT' -or [Diagnostics.FileVersionInfo]::GetVersionInfo($launcher).ProductName -ne 'Assistente IT') { throw 'Application metadata did not adopt the new product name.' }
    $programs=[Environment]::GetFolderPath('Programs'); $desktop=[Environment]::GetFolderPath('DesktopDirectory')
    $shortcutPath=Join-Path $programs 'Assistente IT/Assistente IT.lnk'
    if (-not (Test-Path -LiteralPath $shortcutPath) -or -not (Test-Path -LiteralPath (Join-Path $desktop 'Assistente IT.lnk')) -or
        (Test-Path -LiteralPath (Join-Path $programs 'OPBG IT Suite/OPBG IT Suite.lnk')) -or (Test-Path -LiteralPath (Join-Path $desktop 'OPBG IT Suite.lnk'))) { throw 'Renamed shortcuts are missing or legacy shortcuts remain.' }
    $shell=New-Object -ComObject WScript.Shell
    $shortcut=$null
    try { $shortcut=$shell.CreateShortcut($shortcutPath); if ($shortcut.TargetPath -ne $launcher) { throw 'New shortcut points to the old launcher.' } }
    finally { if ($null -ne $shortcut) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut) }; [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
    $renamed=Invoke-TestSuiteWindow $launcher
    if ($renamed.Product -ne 'Assistente IT' -or $renamed.WindowTitle -ne ('Assistente IT - ' + $installed.Version)) { throw 'Installed window did not adopt the new name.' }
    'PASS: update renames the window, EXE, Apps entry and working shortcuts, removing the legacy launcher and shortcuts.'

    $activity=New-Object Threading.EventWaitHandle($false,[Threading.EventResetMode]::ManualReset,'Local\OPBGITSuite.Running')
    try { Invoke-TestSetup $SetupPath -ExpectedExit 2 }
    finally { $activity.Dispose() }
    if (-not (Test-Path -LiteralPath $launcher)) { throw 'Running-app guard changed the installation.' }
    'PASS: setup refuses to replace an application while a suite process is running.'

    Invoke-TestSetup $BaselineSetupPath -ExpectedExit 2
    if ((Get-ItemProperty $uninstallKey).DisplayVersion -ne $installed.Version) { throw 'Older setup downgraded the suite.' }
    'PASS: an older installer cannot downgrade the installed suite.'

    foreach ($file in @('.env','computer-explorer.config.local.json','Remove-Computer-FullTool.ps1')) {
        if (Test-Path -LiteralPath (Join-Path $install ('app/' + $file))) { throw ('Non-distributable file found in installed payload: ' + $file) }
    }
    'PASS: the installed payload excludes personal files and the legacy removal tool.'

    Invoke-TestUninstall
    if ((Test-Path $uninstallKey) -or (Test-Path -LiteralPath (Join-Path $install 'app'))) { throw 'Uninstall left registered program files.' }
    if ([IO.File]::ReadAllText($configPath) -ne $configBefore -or [IO.File]::ReadAllText($envPath) -ne $envBefore) { throw 'Uninstall removed personal data.' }
    'PASS: uninstall removes the application and keeps personal configuration and tokens.'
}
finally {
    Invoke-TestUninstall
    if (Test-Path -LiteralPath $dataRoot) { Remove-Item -LiteralPath $dataRoot -Recurse -Force }
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
}
