#requires -version 5.1
Set-StrictMode -Version 2.0
$script:Repository='minirusty97/RC_OPBG_4'

function ConvertTo-UpdateVersion {
    param([string]$Value)
    if ($Value -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') { throw 'Versione aggiornamento non valida.' }
    $version=$null
    if (-not [version]::TryParse($Value,[ref]$version) -or $version.Major -gt 65535 -or $version.Minor -gt 65535 -or $version.Build -gt 65535) { throw 'Versione aggiornamento non valida.' }
    return $version
}

function Assert-UpdateUri {
    param([Uri]$Uri)
    if (-not $Uri.IsAbsoluteUri -or $Uri.Scheme -ne 'https' -or $Uri.Port -ne 443 -or $Uri.UserInfo -or $Uri.Fragment -or
        $Uri.Host -notin @('api.github.com','github.com','release-assets.githubusercontent.com','objects.githubusercontent.com')) { throw 'Indirizzo aggiornamento non consentito.' }
}

function New-UpdateWebRequest {
    param([Uri]$Uri)
    return [Net.HttpWebRequest]::Create($Uri)
}

function Invoke-UpdateDownload {
    param([Uri]$Uri,[string]$Path,[long]$MaxBytes,$Queue)
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    Assert-UpdateUri $Uri
    $current=$Uri
    for ($redirect=0;$redirect -le 5;$redirect++) {
        Assert-UpdateUri $current
        $request=New-UpdateWebRequest $current
        $request.UserAgent='AssistenteIT-Updater'; $request.Accept='application/vnd.github+json, application/octet-stream'
        $request.AllowAutoRedirect=$false; $request.Timeout=20000; $request.ReadWriteTimeout=20000
        $request.Proxy=[Net.WebRequest]::DefaultWebProxy
        if ($null -ne $request.Proxy) { $request.Proxy.Credentials=[Net.CredentialCache]::DefaultNetworkCredentials }
        $response=$null
        try {
            try { $response=$request.GetResponse() }
            catch [Net.WebException] {
                if ($null -ne $_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { throw 'Release non raggiungibile senza autenticazione. Verificare che la repository GitHub sia pubblica.' }
                throw 'Download aggiornamento non riuscito. Verificare connessione, proxy e disponibilita GitHub.'
            }
            if ([int]$response.StatusCode -in @(301,302,303,307,308)) {
                $location=$response.Headers['Location']
                if (-not $location) { throw 'Redirect aggiornamento incompleto.' }
                $current=New-Object Uri($current,$location)
                continue
            }
            if ([int]$response.StatusCode -ne 200) { throw 'Risposta aggiornamento non valida.' }
            if ($response.ContentLength -gt $MaxBytes) { throw 'Pacchetto aggiornamento troppo grande.' }
            $inputStream=$response.GetResponseStream(); $outputStream=$null
            try {
                $outputStream=New-Object IO.FileStream($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                $buffer=New-Object byte[] 65536; [long]$total=0; $last=[datetime]::MinValue
                while (($read=$inputStream.Read($buffer,0,$buffer.Length)) -gt 0) {
                    $total+=$read
                    if ($total -gt $MaxBytes) { throw 'Download aggiornamento oltre il limite consentito.' }
                    $outputStream.Write($buffer,0,$read)
                    if ($null -ne $Queue -and ([datetime]::UtcNow-$last).TotalMilliseconds -ge 250) {
                        $Queue.Enqueue([pscustomobject]@{Kind='UpdateProgress';Bytes=$total;Total=$response.ContentLength})
                        $last=[datetime]::UtcNow
                    }
                }
                if ($response.ContentLength -ge 0 -and $total -ne $response.ContentLength) { throw 'Download aggiornamento incompleto.' }
            }
            finally { if ($null -ne $outputStream) { $outputStream.Dispose() }; $inputStream.Dispose() }
            return
        }
        finally { if ($null -ne $response) { $response.Dispose() } }
    }
    throw 'Troppi reindirizzamenti durante il download.'
}

function ConvertTo-AssistenteITUpdate {
    param($Release,[string]$CurrentVersion)
    $current=ConvertTo-UpdateVersion $CurrentVersion
    if ($null -eq $Release -or $Release.draft -or $Release.prerelease -or [string]$Release.tag_name -notmatch '^v(.+)$') { throw 'La release non e una versione stabile valida.' }
    $versionText=$Matches[1]; $version=ConvertTo-UpdateVersion $versionText
    if ($version -le $current) { return [pscustomobject]@{Available=$false;Version=$versionText;Notes=''} }
    $setup='Assistente-IT-Setup-'+$versionText+'.exe'; $checksum='Assistente-IT-'+$versionText+'-SHA256.txt'
    $setupAssets=@($Release.assets | Where-Object { $_.name -ceq $setup })
    $checksumAssets=@($Release.assets | Where-Object { $_.name -ceq $checksum })
    if ($setupAssets.Count -ne 1 -or $checksumAssets.Count -ne 1) { throw 'La release non contiene un setup e un checksum univoci.' }
    [long]$size=$setupAssets[0].size
    if ($size -le 0 -or $size -gt 209715200 -or [long]$checksumAssets[0].size -le 0 -or [long]$checksumAssets[0].size -gt 4096) { throw 'Dimensioni degli asset non valide.' }
    $prefix='https://github.com/'+$script:Repository+'/releases/download/v'+$versionText+'/'
    if ([string]$setupAssets[0].browser_download_url -cne ($prefix+$setup) -or [string]$checksumAssets[0].browser_download_url -cne ($prefix+$checksum)) { throw 'Gli asset non appartengono alla release prevista.' }
    $notes=[string]$Release.body
    if ($notes.Length -gt 16000) { $notes=$notes.Substring(0,16000) }
    [pscustomobject]@{Available=$true;Version=$versionText;Notes=$notes;SetupName=$setup;SetupUri=($prefix+$setup);ChecksumUri=($prefix+$checksum);Size=$size}
}

function ConvertTo-AssistenteITFeed {
    param($Feed,[string]$CurrentVersion)
    if ($Feed.SchemaVersion -ne 1 -or $Feed.Product -cne 'Assistente IT' -or $Feed.Repository -cne $script:Repository -or
        $Feed.Channel -cne 'stable' -or $Feed.SHA256 -notmatch '^[A-Fa-f0-9]{64}$') { throw 'Manifest aggiornamento non valido.' }
    $version=ConvertTo-UpdateVersion ([string]$Feed.Version)
    $checksum='Assistente-IT-'+$version.ToString()+'-SHA256.txt'
    $release=[pscustomobject]@{draft=$false;prerelease=$false;tag_name=('v'+$version.ToString());body=[string]$Feed.Notes
        assets=@([pscustomobject]@{name=$Feed.SetupName;size=$Feed.Size;browser_download_url=$Feed.SetupUri},
                 [pscustomobject]@{name=$checksum;size=97;browser_download_url=$Feed.ChecksumUri})}
    $result=ConvertTo-AssistenteITUpdate -Release $release -CurrentVersion $CurrentVersion
    $result | Add-Member NoteProperty SHA256 ([string]$Feed.SHA256).ToUpperInvariant()
    return $result
}

function Get-AssistenteITUpdate {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$CurrentVersion)
    $path=Join-Path ([IO.Path]::GetTempPath()) ('assistente-it-release-'+[guid]::NewGuid().ToString('N')+'.json')
    try {
        # The static release asset avoids anonymous GitHub REST rate limits shared by a corporate NAT.
        Invoke-UpdateDownload -Uri ('https://github.com/'+$script:Repository+'/releases/latest/download/update.json') -Path $path -MaxBytes 131072
        $release=[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
        ConvertTo-AssistenteITFeed -Feed $release -CurrentVersion $CurrentVersion
    }
    finally { if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) } }
}

function Save-AssistenteITUpdate {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Update,[Parameter(Mandatory=$true)][string]$CacheDirectory,$ProgressQueue)
    $version=ConvertTo-UpdateVersion ([string]$Update.Version)
    $name='Assistente-IT-Setup-'+$version.ToString()+'.exe'
    $prefix='https://github.com/'+$script:Repository+'/releases/download/v'+$version.ToString()+'/'
    if ($Update.SetupName -cne $name -or $Update.SetupUri -cne ($prefix+$name) -or
        $Update.ChecksumUri -cne ($prefix+'Assistente-IT-'+$version.ToString()+'-SHA256.txt') -or $Update.SHA256 -notmatch '^[A-Fa-f0-9]{64}$' -or $Update.Size -le 0 -or $Update.Size -gt 209715200) { throw 'Piano di download non valido.' }
    $directory=Join-Path ([IO.Path]::GetFullPath($CacheDirectory)) ([guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($directory)
    $success=$false
    try {
        $checksumPath=Join-Path $directory 'checksum.txt'; $setupPath=Join-Path $directory $name
        Invoke-UpdateDownload -Uri $Update.ChecksumUri -Path $checksumPath -MaxBytes 4096
        $text=[IO.File]::ReadAllText($checksumPath,[Text.Encoding]::UTF8).Trim()
        if ($text -notmatch ('\A([A-Fa-f0-9]{64})[ \t]+\*?'+[regex]::Escape($name)+'\z')) { throw 'File checksum non valido o riferito a un altro setup.' }
        $expected=$Matches[1].ToUpperInvariant()
        if ($expected -ine $Update.SHA256) { throw 'Checksum discordante dal manifest aggiornamento.' }
        Invoke-UpdateDownload -Uri $Update.SetupUri -Path $setupPath -MaxBytes ([long]$Update.Size) -Queue $ProgressQueue
        if ((Get-Item -LiteralPath $setupPath).Length -ne $Update.Size -or (Get-FileHash -LiteralPath $setupPath -Algorithm SHA256).Hash -ne $expected) { throw 'Integrita del setup non verificata. Installazione annullata.' }
        $receipt=[ordered]@{SchemaVersion=1;Version=$version.ToString();SetupName=$name;Size=[long]$Update.Size;SHA256=$expected}
        $plan=Join-Path $directory 'update-plan.json'
        [IO.File]::WriteAllText($plan,($receipt | ConvertTo-Json),(New-Object Text.UTF8Encoding($true)))
        $success=$true
        [pscustomobject]@{Version=$version.ToString();PlanPath=$plan;SetupPath=$setupPath}
    }
    finally { if (-not $success -and [IO.Directory]::Exists($directory)) { [IO.Directory]::Delete($directory,$true) } }
}

function Open-AssistenteITVerifiedSetup {
    # A read handle disallows replacement/deletion while checksum and setup execute.
    param([string]$PlanPath,[string]$CurrentVersion)
    $plan=Get-Content -LiteralPath $PlanPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $version=ConvertTo-UpdateVersion ([string]$plan.Version)
    if ($plan.SchemaVersion -ne 1 -or $version -le (ConvertTo-UpdateVersion $CurrentVersion) -or
        $plan.SetupName -cne ('Assistente-IT-Setup-'+$version.ToString()+'.exe') -or $plan.SHA256 -notmatch '^[A-Fa-f0-9]{64}$' -or $plan.Size -le 0 -or $plan.Size -gt 209715200) { throw 'Piano di installazione non valido o versione non piu recente.' }
    $setup=Join-Path (Split-Path ([IO.Path]::GetFullPath($PlanPath)) -Parent) $plan.SetupName
    $stream=New-Object IO.FileStream($setup,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        $hash=[Security.Cryptography.SHA256]::Create()
        try { $actual=([BitConverter]::ToString($hash.ComputeHash($stream))).Replace('-','') }
        finally { $hash.Dispose() }
        if ($stream.Length -ne $plan.Size -or $actual -ine $plan.SHA256) { throw 'Setup modificato dopo il download. Ripetere il controllo aggiornamenti.' }
        return [pscustomobject]@{Stream=$stream;Path=$setup;Version=$version.ToString()}
    }
    catch { $stream.Dispose(); throw }
}

function Test-AssistenteITRunning {
    try { $handle=[Threading.EventWaitHandle]::OpenExisting('Local\AssistenteIT.Running'); $handle.Dispose(); return $true }
    catch [Threading.WaitHandleCannotBeOpenedException] { return $false }
}

function Start-AssistenteITUpdateInstaller {
    param([string]$SetupPath)
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$SetupPath; $info.Arguments='/S'; $info.UseShellExecute=$false
    $info.WorkingDirectory=Split-Path $SetupPath -Parent
    $process=[Diagnostics.Process]::Start($info)
    try { $process.WaitForExit(); return $process.ExitCode }
    finally { $process.Dispose() }
}

function Invoke-AssistenteITUpdateInstall {
    [CmdletBinding()]
    param([string]$PlanPath,[string]$InstallRoot,[int]$ParentProcessId=0,[int]$LauncherProcessId=0)
    $root=[IO.Path]::GetFullPath($InstallRoot)
    $program=Split-Path $root -Parent
    $marker=Join-Path $program 'assistente-it-install.marker'
    if (-not [IO.File]::Exists($marker) -or [IO.File]::ReadAllText($marker).Trim() -ne 'AssistenteIT-56bc1182-02a3-4b1a-9d4a-99d44231c26b') { throw 'Aggiornamento automatico disponibile soltanto per la versione installata.' }
    $manifest=Get-Content -LiteralPath (Join-Path $root 'assistente-it.json') -Raw | ConvertFrom-Json
    foreach ($id in @($ParentProcessId,$LauncherProcessId) | Where-Object { $_ -gt 0 -and $_ -ne $PID } | Select-Object -Unique) {
        try { $process=Get-Process -Id $id -ErrorAction Stop } catch { continue }
        try { if (-not $process.WaitForExit(30000)) { throw 'La finestra precedente non si e chiusa. Aggiornamento annullato.' } }
        finally { $process.Dispose() }
    }
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while (Test-AssistenteITRunning) {
        if ($watch.Elapsed.TotalSeconds -ge 120) { throw 'Chiudere Assistente IT e tutti i moduli, poi ripetere l''aggiornamento.' }
        Start-Sleep -Milliseconds 250
    }
    $verified=Open-AssistenteITVerifiedSetup -PlanPath $PlanPath -CurrentVersion $manifest.Version
    try {
        $exitCode=Start-AssistenteITUpdateInstaller $verified.Path
        if ($exitCode -ne 0) { throw ('Installer terminato con codice '+$exitCode+'. Ripetere l''aggiornamento a programma chiuso.') }
        $installed=Get-Content -LiteralPath (Join-Path $root 'assistente-it.json') -Raw | ConvertFrom-Json
        if ([string]$installed.Version -cne $verified.Version) { throw 'La versione installata non corrisponde all''aggiornamento richiesto.' }
    }
    finally { $verified.Stream.Dispose() }
    [pscustomobject]@{Version=$verified.Version;LauncherPath=(Join-Path $program 'AssistenteIT.exe')}
}

function Start-AssistenteITUpdateHandoff {
    param([string]$PlanPath,[string]$InstallRoot)
    if ($PlanPath.Contains('"') -or $InstallRoot.Contains('"')) { throw 'Percorso aggiornamento non valido.' }
    $marker=Join-Path (Split-Path $InstallRoot -Parent) 'assistente-it-install.marker'
    if (-not [IO.File]::Exists($marker) -or [IO.File]::ReadAllText($marker).Trim() -ne 'AssistenteIT-56bc1182-02a3-4b1a-9d4a-99d44231c26b') { throw 'Installare prima Assistente IT con il setup; gli aggiornamenti automatici richiedono la versione installata.' }
    $directory=Split-Path ([IO.Path]::GetFullPath($PlanPath)) -Parent
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Install-Update.ps1') -Destination (Join-Path $directory 'Install-Update.ps1')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'AssistenteIT.Update.psm1') -Destination (Join-Path $directory 'AssistenteIT.Update.psm1')
    $launcherId=0
    try {
        $parent=Get-CimInstance Win32_Process -Filter ('ProcessId='+$PID) -ErrorAction Stop
        $process=Get-Process -Id $parent.ParentProcessId -ErrorAction Stop
        try { if ($process.Path -ieq (Join-Path (Split-Path $InstallRoot -Parent) 'AssistenteIT.exe')) { $launcherId=$process.Id } }
        finally { $process.Dispose() }
    }
    catch { }
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'WindowsPowerShell/v1.0/powershell.exe'
    $info.Arguments='-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -PlanPath "{1}" -InstallRoot "{2}" -ParentProcessId {3} -LauncherProcessId {4}' -f (Join-Path $directory 'Install-Update.ps1'),$PlanPath,$InstallRoot,$PID,$launcherId
    $info.WorkingDirectory=$directory; $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    $process=[Diagnostics.Process]::Start($info); $process.Dispose()
}

Export-ModuleMember -Function Get-AssistenteITUpdate, Save-AssistenteITUpdate, Open-AssistenteITVerifiedSetup, Invoke-AssistenteITUpdateInstall, Start-AssistenteITUpdateHandoff
