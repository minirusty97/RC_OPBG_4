#requires -version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$SetupPath,
    [string]$BaselineSetupPath,
    [Parameter(Mandatory=$true)][string]$PreviousSetupPath,
    [Parameter(Mandatory=$true)][string]$OtaPreviousSetupPath
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Installer tests require an isolated Windows runner.' }
$local=[Environment]::GetFolderPath('LocalApplicationData')
$uninstallKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AssistenteIT'
$legacyKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\OPBGITSuite'
$dataRoot=Join-Path $local 'AssistenteIT'
$legacyData=Join-Path $local 'OPBG/ITSuite'
$defaultInstall=Join-Path $local 'Programs/AssistenteIT'
$legacyDefault=Join-Path $local 'Programs/OPBGITSuite'
$programs=[Environment]::GetFolderPath('Programs'); $desktop=[Environment]::GetFolderPath('DesktopDirectory')
foreach($key in @($uninstallKey,$legacyKey)) { if(Test-Path $key){throw 'Refusing to test with an existing registered installation.'} }
foreach($path in @($dataRoot,$legacyData,$defaultInstall,$legacyDefault,(Join-Path $programs 'Assistente IT'),(Join-Path $programs 'OPBG IT Suite'),(Join-Path $desktop 'Assistente IT.lnk'),(Join-Path $desktop 'OPBG IT Suite.lnk'))) {
    if(Test-Path -LiteralPath $path){throw 'Refusing to test with existing application files, shortcuts or personal data.'}
}
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('assistente-it-install-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temporary)
function Invoke-TestSetup {
    param([string]$Path, [string]$Directory, [int]$ExpectedExit=0)
    $arguments='/S'
    if($Directory){$arguments+=' /D='+$Directory}
    $process=Start-Process -FilePath $Path -ArgumentList $arguments -PassThru
    try {
        if(-not $process.WaitForExit(60000)){$process.Kill();throw 'Installer timed out.'}
        if($process.ExitCode -ne $ExpectedExit){throw ('Unexpected installer exit: {0}; expected {1}' -f $process.ExitCode,$ExpectedExit)}
    }
    finally{$process.Dispose()}
}
function Invoke-TestUninstall {
    param([string]$Directory,[string]$Key=$uninstallKey)
    $uninstaller=Join-Path $Directory 'Uninstall.exe'
    if(Test-Path -LiteralPath $uninstaller){
        $process=Start-Process -FilePath $uninstaller -ArgumentList '/S' -PassThru
        try{if(-not $process.WaitForExit(30000)){$process.Kill();throw 'Uninstaller timed out.'}}
        finally{$process.Dispose()}
        $deadline=[datetime]::UtcNow.AddSeconds(15)
        while((Test-Path $Key) -and [datetime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 100}
        if(Test-Path $Key){throw 'Uninstaller left its registration.'}
    }
}
function Invoke-TestWindow {
    param([string]$Launcher)
    $probe=Join-Path $temporary ('launch-'+[guid]::NewGuid().ToString('N')+'.json')
    $process=Start-Process -FilePath $Launcher -ArgumentList ('--smoke-test "'+$probe+'"') -PassThru
    try{
        if(-not $process.WaitForExit(30000)){$process.Kill();throw 'Installed GUI timed out.'}
        if($process.ExitCode -ne 0){throw 'Installed GUI failed to start.'}
    }
    finally{$process.Dispose()}
    return Get-Content -LiteralPath $probe -Raw | ConvertFrom-Json
}
function Invoke-TestUpdateFromHub {
    param([string]$Directory,[string]$Version)
    $app=Join-Path $Directory 'app'
    $launcher=Join-Path $Directory 'AssistenteIT.exe'
    $module=Join-Path $app 'AssistenteIT/AssistenteIT.Update.psm1'
    $hub=Join-Path $app 'Start-AssistenteIT.ps1'
    $helper=Join-Path $app 'AssistenteIT/Install-Update.ps1'
    $utf8=New-Object Text.UTF8Encoding($true)
    $env:ASSISTENTEIT_TEST_OTA_ASSETS=Split-Path (Resolve-Path -LiteralPath $SetupPath).ProviderPath -Parent
    $env:ASSISTENTEIT_TEST_OTA_STATUS=Join-Path $temporary 'ota-status.txt'
    $env:ASSISTENTEIT_TEST_OTA_ERROR=Join-Path $temporary 'ota-error.txt'
    # Keep the real feed parser, verification, hub timer, worker and installer.
    # Serve only the bytes from this build and simulate approval in the test window.
    [IO.File]::AppendAllText($module, @'

function Invoke-UpdateDownload {
    param([uri]$Uri,[string]$Path,[long]$MaxBytes,$Queue)
    Assert-UpdateUri $Uri
    [IO.File]::Copy((Join-Path $env:ASSISTENTEIT_TEST_OTA_ASSETS ([IO.Path]::GetFileName($Uri.AbsolutePath))),$Path)
}
'@)
    $probe=@'
$script:TestOtaApproved=$false
$testOtaTimer=New-Object Windows.Forms.Timer
$testOtaTimer.Interval=200
$testOtaTimer.Add_Tick({
    [IO.File]::WriteAllText($env:ASSISTENTEIT_TEST_OTA_STATUS,$status.Text)
    if (-not $script:TestOtaApproved -and $null -ne $script:UpdateInfo -and $script:UpdateInfo.Available -and $null -eq $script:UpdateInvocation) {
        $script:TestOtaApproved=$true
        Start-AssistenteITUpdateOperation Download
    }
})
$form.Add_Shown({$testOtaTimer.Start()})

'@
    $text=[IO.File]::ReadAllText($hub)
    $marker=[regex]::Match($text,'(?m)^try \{\r?\n    if \(\$SmokeTestOutput\) \{')
    if (-not $marker.Success) { throw 'Installed hub lacks the OTA test entry point.' }
    [IO.File]::WriteAllText($hub,$text.Insert($marker.Index,$probe+[Environment]::NewLine),$utf8)
    $text=[IO.File]::ReadAllText($helper)
    $catchStart=[regex]::Match($text,'(?m)^catch \{\r?\n')
    if (-not $catchStart.Success) { throw 'Installed updater lacks an error handler.' }
    $report='    [IO.File]::WriteAllText($env:ASSISTENTEIT_TEST_OTA_ERROR,$_.Exception.Message)' + [Environment]::NewLine
    [IO.File]::WriteAllText($helper,$text.Insert($catchStart.Index+$catchStart.Length,$report),$utf8)

    $process=$null;$window=$null
    try {
        $process=Start-Process -FilePath $launcher -PassThru
        if (-not $process.WaitForExit(45000)) { throw 'The hub did not close after verifying the download.' }
        if ($process.ExitCode -ne 0) { throw ('The hub exited with code {0} before handing off the update.' -f $process.ExitCode) }
        $deadline=[datetime]::UtcNow.AddSeconds(65)
        while ([datetime]::UtcNow -lt $deadline) {
            if (Test-Path -LiteralPath $env:ASSISTENTEIT_TEST_OTA_ERROR) { throw 'The update worker reported an error.' }
            $window=Get-Process -Name powershell -ErrorAction SilentlyContinue | Where-Object MainWindowTitle -eq ('Assistente IT - '+$Version) | Select-Object -First 1
            if ($null -ne $window -and (Get-ItemProperty $uninstallKey).DisplayVersion -eq $Version) { break }
            Start-Sleep -Milliseconds 250
        }
        if ($null -eq $window -or (Get-ItemProperty $uninstallKey).DisplayVersion -ne $Version) { throw 'The installed update did not reopen the new hub.' }
        if (-not $window.CloseMainWindow() -or -not $window.WaitForExit(20000)) { throw 'Could not close the relaunched test hub.' }
    }
    catch {
        foreach ($path in @($env:ASSISTENTEIT_TEST_OTA_STATUS,$env:ASSISTENTEIT_TEST_OTA_ERROR)) {
            if (Test-Path -LiteralPath $path) { Write-Host ('OTA '+[IO.Path]::GetFileName($path)+' '+[IO.File]::ReadAllText($path)) }
        }
        throw
    }
    finally {
        if ($null -ne $process) { $process.Dispose() }
        if ($null -ne $window) { $window.Dispose() }
        # Clean up only processes from this isolated installation if the probe failed.
        $fixtureProcesses=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='AssistenteIT.exe'" | Where-Object {
            $_.ExecutablePath -ieq $launcher -or ([string]$_.CommandLine).IndexOf($Directory,[StringComparison]::OrdinalIgnoreCase) -ge 0
        })
        foreach ($fixtureProcess in $fixtureProcesses) { Stop-Process -Id $fixtureProcess.ProcessId -Force -ErrorAction SilentlyContinue }
        Remove-Item Env:ASSISTENTEIT_TEST_OTA_ASSETS,Env:ASSISTENTEIT_TEST_OTA_STATUS,Env:ASSISTENTEIT_TEST_OTA_ERROR -ErrorAction SilentlyContinue
    }
}
function Assert-InstalledApplication {
    param([string]$Directory,[switch]$VerifyWeeklyReport)
    $installed=Get-Content -LiteralPath (Join-Path $Directory 'app/assistente-it.json') -Raw | ConvertFrom-Json
    $launcher=Join-Path $Directory 'AssistenteIT.exe'
    $entry=Get-ItemProperty $uninstallKey
    if($installed.Product -ne 'Assistente IT' -or $entry.DisplayName -ne 'Assistente IT' -or $entry.DisplayVersion -ne $installed.Version -or $entry.InstallLocation -ne $Directory -or [Diagnostics.FileVersionInfo]::GetVersionInfo($launcher).ProductName -ne 'Assistente IT'){throw 'Incorrect product name, version or installation path.'}
    if((Test-Path $legacyKey) -or -not(Test-Path -LiteralPath (Join-Path $Directory 'assistente-it-install.marker'))){throw 'Legacy registration remains or the new installation marker is missing.'}
    foreach($old in @('OPBGITSuite.exe','suite-install.marker','app/Start-ITSuite.ps1','app/suite.json','app/Suite')){if(Test-Path -LiteralPath (Join-Path $Directory $old)){throw ('Obsolete program file remains: '+$old)}}
    foreach($file in @('.env','computer-explorer.config.local.json','Remove-Computer-FullTool.ps1')){if(Test-Path -LiteralPath (Join-Path $Directory ('app/'+$file))){throw 'Non-distributable file found in installed payload.'}}
    if ($VerifyWeeklyReport) {
        $reportModule = Join-Path $Directory 'app/HybridJoin.Report.psm1'
        Import-Module $reportModule -ErrorAction Stop
        try {
            $reportPath = Join-Path $temporary 'installed-report.xlsx'
            $snapshot = [pscustomobject]@{Rows=@(); CapturedAtUtc=[datetimeoffset]::UtcNow}
            $report = Save-HybridWeeklyReport -Snapshot $snapshot -Path $reportPath -Overwrite
            if ($report.Computers -ne 0 -or -not (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
                throw 'Installed Hybrid weekly report could not run from the installed application.'
            }
        }
        finally { Remove-Module HybridJoin.Report }
    }
    $shortcutPath=Join-Path $programs 'Assistente IT/Assistente IT.lnk'
    if(-not(Test-Path -LiteralPath $shortcutPath) -or -not(Test-Path -LiteralPath (Join-Path $desktop 'Assistente IT.lnk')) -or (Test-Path -LiteralPath (Join-Path $programs 'OPBG IT Suite')) -or (Test-Path -LiteralPath (Join-Path $desktop 'OPBG IT Suite.lnk'))){throw 'New shortcuts are missing or legacy shortcuts remain.'}
    $shell=New-Object -ComObject WScript.Shell; $shortcut=$null
    try{$shortcut=$shell.CreateShortcut($shortcutPath);if($shortcut.TargetPath -ne $launcher){throw 'Shortcut points to the wrong launcher.'}}
    finally{if($null -ne $shortcut){[void][Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut)};[void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)}
    $window=Invoke-TestWindow $launcher
    if($window.Product -ne 'Assistente IT' -or $window.WindowTitle -ne ('Assistente IT - '+$installed.Version) -or -not $window.GraphAvailable -or $window.ModuleCount -ne @($installed.Modules).Count -or $window.DataRoot -ne $dataRoot -or $window.ConfigPath -ne (Join-Path $dataRoot 'Config/computer-explorer.config.local.json')){throw 'Installed window, renamed paths or bundled Graph failed verification.'}
}
try{
    $cases=@(
        @{Version='1.0.1';Setup=$PreviousSetupPath;Directory=(Join-Path $temporary 'previous install with spaces');InPlace=$false},
        @{Version='1.0.1';Setup=$PreviousSetupPath;Directory=(Join-Path $temporary 'in place with spaces');InPlace=$true}
    )
    if ($BaselineSetupPath) { $cases=@(@{Version='1.0.0';Setup=$BaselineSetupPath;Directory=$legacyDefault;InPlace=$false})+$cases }
    foreach($case in $cases){
        Invoke-TestSetup $case.Setup -Directory $case.Directory
        if((Get-ItemProperty $legacyKey).DisplayVersion -ne $case.Version){throw 'Original published installer did not register its version.'}
        $oldExe='AssistenteIT.exe';if($case.Version -eq '1.0.0'){$oldExe='OPBGITSuite.exe'}
        $oldWindow=Invoke-TestWindow (Join-Path $case.Directory $oldExe)
        if(-not $oldWindow.GraphAvailable -or $oldWindow.DataRoot -ne $legacyData){throw 'Original application did not initialize its legacy data.'}
        $configPath=Join-Path $legacyData 'Config/computer-explorer.config.local.json';$envPath=Join-Path $legacyData 'Config/.env'
        $config=Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        $config.Search.MinimumCharacters=4;$config.Glpi.BaseUri='https://personal.example.invalid/apirest.php'
        $config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath -Encoding UTF8
        [IO.File]::WriteAllText($envPath,"GLPI_USER_TOKEN='synthetic#literal`$user'`r`nGLPI_APP_TOKEN='synthetic-app'`r`n",(New-Object Text.UTF8Encoding($true)))
        $configHash=(Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash;$envHash=(Get-FileHash -LiteralPath $envPath -Algorithm SHA256).Hash
        [IO.File]::WriteAllText((Join-Path $case.Directory 'unrelated.txt'),'keep this user file')
        [void][IO.Directory]::CreateDirectory((Join-Path $legacyData 'Other'))
        [IO.File]::WriteAllText((Join-Path $legacyData 'Other/note.txt'),'preserve all personal data')
        $target=$defaultInstall;if($case.InPlace){$target=$case.Directory}
        $activity=New-Object Threading.EventWaitHandle($false,[Threading.EventResetMode]::ManualReset,'Local\OPBGITSuite.Running')
        try{Invoke-TestSetup $SetupPath -Directory $target -ExpectedExit 2}
        finally{$activity.Dispose()}
        if(-not(Test-Path $legacyKey) -or -not(Test-Path -LiteralPath $legacyData)){throw 'Blocked update modified legacy installation or data.'}
        if($case.InPlace){Invoke-TestSetup $SetupPath -Directory $target}else{Invoke-TestSetup $SetupPath}
        Assert-InstalledApplication $target -VerifyWeeklyReport
        $newConfig=Join-Path $dataRoot 'Config/computer-explorer.config.local.json';$newEnv=Join-Path $dataRoot 'Config/.env'
        if((Get-FileHash -LiteralPath $newConfig -Algorithm SHA256).Hash -ne $configHash -or (Get-FileHash -LiteralPath $newEnv -Algorithm SHA256).Hash -ne $envHash -or (Test-Path -LiteralPath $legacyData) -or [IO.File]::ReadAllText((Join-Path $dataRoot 'Other/note.txt')) -ne 'preserve all personal data'){throw 'Migration changed personal bytes or left the old data path.'}
        if(-not(Test-Path -LiteralPath (Join-Path $case.Directory 'unrelated.txt'))){throw 'Upgrade removed an unrelated file from the old install root.'}
        if(-not $case.InPlace -and (Test-Path -LiteralPath (Join-Path $case.Directory 'app'))){throw 'Old application payload remained after migration.'}
        'PASS: upgrade from published '+$case.Version+' (in place: '+$case.InPlace+') migrates names, paths and registration, preserves SHA256 of config/tokens and keeps unrelated files.'
        # Repair without /D must find even an existing custom installation path.
        Invoke-TestSetup $SetupPath
        Assert-InstalledApplication $target -VerifyWeeklyReport
        if((Get-FileHash -LiteralPath $newConfig).Hash -ne $configHash -or (Get-FileHash -LiteralPath $newEnv).Hash -ne $envHash){throw 'Repair changed personal files.'}
        'PASS: repeated setup finds the registered path and preserves migrated settings.'
        $activity=New-Object Threading.EventWaitHandle($false,[Threading.EventResetMode]::ManualReset,'Local\AssistenteIT.Running')
        try{Invoke-TestSetup $SetupPath -ExpectedExit 2}finally{$activity.Dispose()}
        $version=(Get-ItemProperty $uninstallKey).DisplayVersion
        try{Set-ItemProperty $uninstallKey DisplayVersion '99.0.0';Invoke-TestSetup $SetupPath -ExpectedExit 2}
        finally{Set-ItemProperty $uninstallKey DisplayVersion $version}
        'PASS: the renamed activity guard and newer-version check refuse unsafe replacement.'
        Invoke-TestUninstall $target
        if((Test-Path $uninstallKey) -or (Test-Path -LiteralPath (Join-Path $target 'app')) -or (Get-FileHash -LiteralPath $newConfig).Hash -ne $configHash -or (Get-FileHash -LiteralPath $newEnv).Hash -ne $envHash){throw 'Uninstall left program files or changed personal data.'}
        'PASS: uninstall removes program and registry entry while retaining migrated personal files.'
        Remove-Item -LiteralPath $dataRoot -Recurse -Force
        if(Test-Path -LiteralPath $target){Remove-Item -LiteralPath $target -Recurse -Force}
        if(Test-Path -LiteralPath $case.Directory){Remove-Item -LiteralPath $case.Directory -Recurse -Force}
    }
    Invoke-TestSetup $SetupPath
    Assert-InstalledApplication $defaultInstall -VerifyWeeklyReport
    $otaPayload=Join-Path $temporary 'candidate-app'
    Copy-Item -LiteralPath (Join-Path $defaultInstall 'app') -Destination $otaPayload -Recurse
    if((Test-Path -LiteralPath $legacyDefault) -or (Test-Path -LiteralPath $legacyData)){throw 'Clean setup created a legacy path.'}
    'PASS: clean setup uses only Assistente IT names, new default directories, manifest and shortcuts.'
    Invoke-TestUninstall $defaultInstall
    if(-not(Test-Path -LiteralPath (Join-Path $dataRoot 'Config/.env'))){throw 'Clean uninstall removed personal data.'}
    Remove-Item -LiteralPath $dataRoot -Recurse -Force
    if(Test-Path -LiteralPath $defaultInstall){Remove-Item -LiteralPath $defaultInstall -Recurse -Force}
    $otaTarget=Join-Path $temporary 'OTA install with spaces'
    Invoke-TestSetup $OtaPreviousSetupPath -Directory $otaTarget
    Assert-InstalledApplication $otaTarget
    $project=Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $project 'AssistenteIT/AssistenteIT.Core.psm1') -Force
    $personal=Get-AssistenteITPaths
    Save-AssistenteITSettings -Paths $personal -DomainControllers @('dc.example.invalid') -GlpiBaseUri 'https://glpi.example.invalid/apirest.php' -GlpiEnabled $true -UserToken 'ota-synthetic-user' -AppToken 'ota-synthetic-app'
    $encrypted=Join-Path $personal.ConfigDirectory 'glpi-credentials.dpapi.json'
    $configHash=(Get-FileHash -LiteralPath $personal.ConfigPath).Hash; $secretHash=(Get-FileHash -LiteralPath $encrypted).Hash
    $candidate=Get-Content -LiteralPath (Join-Path $project 'assistente-it.json') -Raw | ConvertFrom-Json
    # Test the candidate updater with all packaged dependencies while the old
    # manifest and installer registration still identify the version being upgraded.
    $otaApp=Join-Path $otaTarget 'app'
    foreach ($item in (Get-ChildItem -LiteralPath $otaPayload -Force | Where-Object Name -ne 'assistente-it.json')) {
        Copy-Item -LiteralPath $item.FullName -Destination $otaApp -Recurse -Force
    }
    Invoke-TestUpdateFromHub -Directory $otaTarget -Version $candidate.Version
    Assert-InstalledApplication $otaTarget -VerifyWeeklyReport
    if ((Get-FileHash $personal.ConfigPath).Hash -ne $configHash -or (Get-FileHash $encrypted).Hash -ne $secretHash) { throw 'Real OTA upgrade lost personal configuration or encrypted credentials.' }
    $updates=Join-Path $personal.DataRoot 'Updates'
    $logs=@(Get-ChildItem -LiteralPath $updates -Recurse -File -Filter 'update-install.log')
    if ($logs.Count -ne 1 -or [IO.File]::ReadAllText($logs[0].FullName) -notlike '*Launcher riavviato.*' -or
        @(Get-ChildItem -LiteralPath $updates -Recurse -File -Filter 'Install-Update.ps1').Count) { throw 'OTA did not log its outcome or copied executable scripts into the download directory.' }
    'PASS: the packaged updater finds and verifies the staged update, confirms worker startup, closes, installs at its custom path, reopens and preserves personal data.'
    Invoke-TestUninstall $otaTarget

}
finally{
    foreach($key in @($uninstallKey,$legacyKey)){
        if(Test-Path $key){$location=(Get-ItemProperty $key).InstallLocation;Invoke-TestUninstall $location -Key $key}
    }
    foreach($path in @($dataRoot,$legacyData,$defaultInstall,$legacyDefault,$temporary)){
        if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse -Force}
    }
}
