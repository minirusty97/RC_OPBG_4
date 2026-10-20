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
function Assert-InstalledApplication {
    param([string]$Directory)
    $installed=Get-Content -LiteralPath (Join-Path $Directory 'app/assistente-it.json') -Raw | ConvertFrom-Json
    $launcher=Join-Path $Directory 'AssistenteIT.exe'
    $entry=Get-ItemProperty $uninstallKey
    if($installed.Product -ne 'Assistente IT' -or $entry.DisplayName -ne 'Assistente IT' -or $entry.DisplayVersion -ne $installed.Version -or $entry.InstallLocation -ne $Directory -or [Diagnostics.FileVersionInfo]::GetVersionInfo($launcher).ProductName -ne 'Assistente IT'){throw 'Incorrect product name, version or installation path.'}
    if((Test-Path $legacyKey) -or -not(Test-Path -LiteralPath (Join-Path $Directory 'assistente-it-install.marker'))){throw 'Legacy registration remains or the new installation marker is missing.'}
    foreach($old in @('OPBGITSuite.exe','suite-install.marker','app/Start-ITSuite.ps1','app/suite.json','app/Suite')){if(Test-Path -LiteralPath (Join-Path $Directory $old)){throw ('Obsolete program file remains: '+$old)}}
    foreach($file in @('.env','computer-explorer.config.local.json','Remove-Computer-FullTool.ps1')){if(Test-Path -LiteralPath (Join-Path $Directory ('app/'+$file))){throw 'Non-distributable file found in installed payload.'}}
    $shortcutPath=Join-Path $programs 'Assistente IT/Assistente IT.lnk'
    if(-not(Test-Path -LiteralPath $shortcutPath) -or -not(Test-Path -LiteralPath (Join-Path $desktop 'Assistente IT.lnk')) -or (Test-Path -LiteralPath (Join-Path $programs 'OPBG IT Suite')) -or (Test-Path -LiteralPath (Join-Path $desktop 'OPBG IT Suite.lnk'))){throw 'New shortcuts are missing or legacy shortcuts remain.'}
    $shell=New-Object -ComObject WScript.Shell; $shortcut=$null
    try{$shortcut=$shell.CreateShortcut($shortcutPath);if($shortcut.TargetPath -ne $launcher){throw 'Shortcut points to the wrong launcher.'}}
    finally{if($null -ne $shortcut){[void][Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut)};[void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)}
    $window=Invoke-TestWindow $launcher
    if($window.Product -ne 'Assistente IT' -or $window.WindowTitle -ne ('Assistente IT - '+$installed.Version) -or -not $window.GraphAvailable -or $window.ModuleCount -ne 1 -or $window.DataRoot -ne $dataRoot -or $window.ConfigPath -ne (Join-Path $dataRoot 'Config/computer-explorer.config.local.json')){throw 'Installed window, renamed paths or bundled Graph failed verification.'}
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
        Assert-InstalledApplication $target
        $newConfig=Join-Path $dataRoot 'Config/computer-explorer.config.local.json';$newEnv=Join-Path $dataRoot 'Config/.env'
        if((Get-FileHash -LiteralPath $newConfig -Algorithm SHA256).Hash -ne $configHash -or (Get-FileHash -LiteralPath $newEnv -Algorithm SHA256).Hash -ne $envHash -or (Test-Path -LiteralPath $legacyData) -or [IO.File]::ReadAllText((Join-Path $dataRoot 'Other/note.txt')) -ne 'preserve all personal data'){throw 'Migration changed personal bytes or left the old data path.'}
        if(-not(Test-Path -LiteralPath (Join-Path $case.Directory 'unrelated.txt'))){throw 'Upgrade removed an unrelated file from the old install root.'}
        if(-not $case.InPlace -and (Test-Path -LiteralPath (Join-Path $case.Directory 'app'))){throw 'Old application payload remained after migration.'}
        'PASS: upgrade from published '+$case.Version+' (in place: '+$case.InPlace+') migrates names, paths and registration, preserves SHA256 of config/tokens and keeps unrelated files.'
        # Repair without /D must find even an existing custom installation path.
        Invoke-TestSetup $SetupPath
        Assert-InstalledApplication $target
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
    Assert-InstalledApplication $defaultInstall
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
    Import-Module (Join-Path $project 'AssistenteIT/AssistenteIT.Update.psm1') -Force
    $personal=Get-AssistenteITPaths
    Save-AssistenteITSettings -Paths $personal -DomainControllers @('dc.example.invalid') -GlpiBaseUri 'https://glpi.example.invalid/apirest.php' -GlpiEnabled $true -UserToken 'ota-synthetic-user' -AppToken 'ota-synthetic-app'
    $encrypted=Join-Path $personal.ConfigDirectory 'glpi-credentials.dpapi.json'
    $configHash=(Get-FileHash -LiteralPath $personal.ConfigPath).Hash; $secretHash=(Get-FileHash -LiteralPath $encrypted).Hash
    $candidate=Get-Content -LiteralPath (Join-Path $project 'assistente-it.json') -Raw | ConvertFrom-Json
    $staged=Join-Path $temporary ('Assistente-IT-Setup-'+$candidate.Version+'.exe')
    Copy-Item -LiteralPath $SetupPath -Destination $staged
    $receipt=Join-Path $temporary 'ota-plan.json'
    [ordered]@{SchemaVersion=1;Version=$candidate.Version;SetupName=[IO.Path]::GetFileName($staged);Size=(Get-Item $staged).Length;SHA256=(Get-FileHash $staged -Algorithm SHA256).Hash} | ConvertTo-Json | Set-Content -LiteralPath $receipt -Encoding UTF8
    $result=Invoke-AssistenteITUpdateInstall -PlanPath $receipt -InstallRoot (Join-Path $otaTarget 'app')
    Assert-InstalledApplication $otaTarget
    if ($result.Version -ne $candidate.Version -or (Get-FileHash $personal.ConfigPath).Hash -ne $configHash -or (Get-FileHash $encrypted).Hash -ne $secretHash) { throw 'Real OTA upgrade lost personal configuration or encrypted credentials.' }
    'PASS: OTA installer upgrades published 1.0.7 at its registered custom path and preserves configuration plus DPAPI bytes.'
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
