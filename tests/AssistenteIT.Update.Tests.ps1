#requires -version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '../AssistenteIT/AssistenteIT.Update.psm1') -Force -PassThru
$directory=Join-Path ([IO.Path]::GetTempPath()) ('assistente-update-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($directory)
try {
    & $module {
        param($Directory)
        $script:Responses=New-Object 'System.Collections.Generic.Queue[object]'
        $script:Requested=New-Object 'System.Collections.Generic.List[string]'
        function New-TestResponse {
            param([byte[]]$Body=@(),[int]$Status=200,[string]$Location='', [long]$Length=-2)
            if ($Length -eq -2) { $Length=$Body.Length }
            $r=[pscustomobject]@{StatusCode=$Status;ContentLength=$Length;Headers=@{Location=$Location};Body=$Body}
            $r | Add-Member ScriptMethod GetResponseStream { return [IO.MemoryStream]::new([byte[]]$this.Body) }
            $r | Add-Member ScriptMethod Dispose {}
            return $r
        }
        function script:New-UpdateWebRequest {
            param([Uri]$Uri)
            [void]$script:Requested.Add($Uri.AbsoluteUri)
            if ($script:Responses.Count -eq 0) { throw 'Unexpected network request.' }
            $r=[pscustomobject]@{UserAgent='';Accept='';AllowAutoRedirect=$true;Timeout=0;ReadWriteTimeout=0;Proxy=$null;Response=$script:Responses.Dequeue()}
            $r | Add-Member ScriptMethod GetResponse { return $this.Response }
            return $r
        }
        function Assert-Fails {
            param([scriptblock]$Action)
            $failed=$false;try { & $Action | Out-Null } catch { $failed=$true }
            if (-not $failed) { throw 'Unsafe update input accepted.' }
        }
        $payload=[Text.Encoding]::UTF8.GetBytes('synthetic installer payload')
        $sha=[Security.Cryptography.SHA256]::Create()
        try { $digest=([BitConverter]::ToString($sha.ComputeHash($payload))).Replace('-','') } finally { $sha.Dispose() }
        $feed=[pscustomobject]@{SchemaVersion=1;Product='Assistente IT';Repository='minirusty97/RC_OPBG_4';Channel='stable';Version='1.10.0';SetupName='Assistente-IT-Setup-1.10.0.exe'
            SetupUri='https://github.com/minirusty97/RC_OPBG_4/releases/download/v1.10.0/Assistente-IT-Setup-1.10.0.exe'
            ChecksumUri='https://github.com/minirusty97/RC_OPBG_4/releases/download/v1.10.0/Assistente-IT-1.10.0-SHA256.txt';Size=$payload.Length;SHA256=$digest;Notes='Synthetic notes'}
        $script:Responses.Enqueue((New-TestResponse ([Text.Encoding]::UTF8.GetBytes(($feed | ConvertTo-Json)))))
        $update=Get-AssistenteITUpdate '1.9.0'
        if (-not $update.Available -or $update.Version -ne '1.10.0' -or $script:Requested[0] -notlike 'https://github.com/*/releases/latest/download/update.json') { throw 'Version order or public static feed incorrect.' }
        if ((ConvertTo-AssistenteITFeed $feed '1.10.0').Available -or (ConvertTo-AssistenteITFeed $feed '2.0.0').Available) { throw 'Same/older release offered.' }
        'PASS: public release feed compares versions numerically and excludes same/older versions without GitHub credentials.'
        foreach ($field in @('SetupUri','ChecksumUri','Repository','Version','SHA256','Channel')) {
            $bad=$feed | ConvertTo-Json | ConvertFrom-Json
            $bad.$field='https://example.invalid/unsafe'
            Assert-Fails { ConvertTo-AssistenteITFeed $bad '1.0.0' }
        }
        'PASS: foreign assets, malformed versions/hashes, wrong repository and unstable channels are rejected.'
        foreach ($uri in @('http://github.com/test','https://github.com:444/test','https://user:pass@github.com/test','https://example.invalid/file','https://github.com/test#fragment')) {
            Assert-Fails { Assert-UpdateUri ([Uri]$uri) }
        }
        $path=Join-Path $Directory 'redirect.bin'
        $script:Responses.Enqueue((New-TestResponse -Status 302 -Location 'https://example.invalid/steal'))
        Assert-Fails { Invoke-UpdateDownload -Uri $feed.SetupUri -Path $path -MaxBytes 1000 }
        if (Test-Path $path) { throw 'Foreign redirect created a download.' }
        'PASS: HTTPS/host restrictions also reject an untrusted redirect before following it.'
        $script:Responses.Enqueue((New-TestResponse -Status 302 -Location 'https://release-assets.githubusercontent.com/synthetic/file?signature=value'))
        $script:Responses.Enqueue((New-TestResponse $payload))
        Invoke-UpdateDownload -Uri $feed.SetupUri -Path $path -MaxBytes 1000
        if ((Get-Item $path).Length -ne $payload.Length) { throw 'Binary redirect download changed bytes.' }
        Remove-Item $path
        $script:Responses.Enqueue((New-TestResponse $payload -Length 1))
        Assert-Fails { Invoke-UpdateDownload -Uri $feed.SetupUri -Path $path -MaxBytes 1000 }; Remove-Item $path -ErrorAction SilentlyContinue
        $script:Responses.Enqueue((New-TestResponse $payload -Length -1))
        Assert-Fails { Invoke-UpdateDownload -Uri $feed.SetupUri -Path $path -MaxBytes 1 }; Remove-Item $path -ErrorAction SilentlyContinue
        'PASS: binary streaming preserves bytes and refuses incomplete/oversized responses, including unknown content length.'
        $checksum=[Text.Encoding]::UTF8.GetBytes($digest+' *'+$feed.SetupName)
        $script:Responses.Enqueue((New-TestResponse $checksum));$script:Responses.Enqueue((New-TestResponse $payload))
        $download=Save-AssistenteITUpdate $update $Directory
        $verified=Open-AssistenteITVerifiedSetup $download.PlanPath '1.0.0'
        try {
            if ($verified.Version -ne '1.10.0') { throw 'Wrong verified setup.' }
            if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { Assert-Fails { [IO.File]::WriteAllText($verified.Path,'tampered') } }
        }
        finally { $verified.Stream.Dispose() }
        Assert-Fails { Open-AssistenteITVerifiedSetup $download.PlanPath '1.10.0' }
        [IO.File]::WriteAllText($download.SetupPath,'tampered')
        Assert-Fails { Open-AssistenteITVerifiedSetup $download.PlanPath '1.0.0' }
        'PASS: checksum-verified setup gets rechecked before installation and cannot be downgraded or modified while held open.'
        $before=@(Get-ChildItem $Directory -Directory).Count
        $script:Responses.Enqueue((New-TestResponse ([Text.Encoding]::UTF8.GetBytes(('0'*64)+' *'+$feed.SetupName))))
        Assert-Fails { Save-AssistenteITUpdate $update $Directory }
        if (@(Get-ChildItem $Directory -Directory).Count -ne $before) { throw 'Bad checksum left a staged update.' }
        'PASS: manifest/checksum disagreement leaves no staged installer and never starts execution.'
        # Installer orchestration uses a stub; the real NSIS upgrade is tested separately.
        $script:Responses.Enqueue((New-TestResponse $checksum));$script:Responses.Enqueue((New-TestResponse $payload))
        $download=Save-AssistenteITUpdate $update $Directory
        $program=Join-Path $Directory 'program';$app=Join-Path $program 'app';[void][IO.Directory]::CreateDirectory($app)
        $script:InstallManifest=Join-Path $app 'assistente-it.json'
        [IO.File]::WriteAllText($script:InstallManifest,'{"Version":"1.0.0"}')
        [IO.File]::WriteAllText((Join-Path $program 'assistente-it-install.marker'),'AssistenteIT-56bc1182-02a3-4b1a-9d4a-99d44231c26b')
        $script:InstallerCalls=0
        function script:Test-AssistenteITRunning { return $false }
        function script:Start-AssistenteITUpdateInstaller {
            param([string]$SetupPath)
            $script:InstallerCalls++
            [IO.File]::WriteAllText($script:InstallManifest,'{"Version":"1.10.0"}')
            return 0
        }
        $result=Invoke-AssistenteITUpdateInstall -PlanPath $download.PlanPath -InstallRoot $app
        if ($script:InstallerCalls -ne 1 -or $result.Version -ne '1.10.0' -or $result.LauncherPath -ne (Join-Path $program 'AssistenteIT.exe')) { throw 'Installer handoff failed.' }
        Assert-Fails { Invoke-AssistenteITUpdateInstall -PlanPath $download.PlanPath -InstallRoot $app }
        if ($script:InstallerCalls -ne 1) { throw 'Already-installed version executed again.' }
        'PASS: installation validates registered payload marker, newer version and resulting manifest before relaunch.'
    } $directory
}
finally { Remove-Module -ModuleInfo $module -Force; Remove-Item -LiteralPath $directory -Recurse -Force }
