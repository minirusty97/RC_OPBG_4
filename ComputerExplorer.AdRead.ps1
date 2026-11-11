#requires -version 5.1

function Read-ExplorerAdOu {
    param([string]$DomainController, $Query, [hashtable]$Log)

    Write-ExplorerSearchLog $Log 'ad.rsat_import.start'
    Import-Module ActiveDirectory -ErrorAction Stop
    Write-ExplorerSearchLog $Log 'ad.rsat_import.end'
    $domain = Get-ADDomain -Server $DomainController -ErrorAction Stop
    $domainDn = [string]$domain.DistinguishedName
    if ($domainDn -notmatch '^DC=') { throw 'Distinguished Name del dominio AD non valido.' }

    $ous = @(foreach ($relative in $Query.TargetOus) {
        $dn = [string]$relative
        $parts = $dn -split '(?<!\\),(?=DC=)', 2
        if ($parts.Count -eq 1) { $dn += ',' + $domainDn }
        elseif ($parts[1] -ine $domainDn) {
            throw 'OU esterna al dominio configurato.'
        }
        $ou = Get-ADOrganizationalUnit -Server $DomainController -Identity $dn -ErrorAction Stop
        $search = @{
            Server = $DomainController
            Filter = '*'
            SearchBase = $ou.DistinguishedName
            SearchScope = $Query.SearchScope
            Properties = @('DNSHostName','Enabled','OperatingSystem','OperatingSystemVersion','LastLogonDate','PasswordLastSet','ObjectGUID','Modified')
            ErrorAction = 'Stop'
        }
        Write-ExplorerSearchLog $Log 'ad.query.start'
        $computers = @(Get-ADComputer @search | ForEach-Object {
            [pscustomobject]@{
                Name = [string]$_.Name
                ObjectGUID = [string]$_.ObjectGUID
                DNSHostName = [string]$_.DNSHostName
                Enabled = $_.Enabled
                OperatingSystem = $_.OperatingSystem
                OperatingSystemVersion = $_.OperatingSystemVersion
                LastLogonDate = $_.LastLogonDate
                PasswordLastSet = $_.PasswordLastSet
                LastModified = $_.Modified
                DistinguishedName = [string]$_.DistinguishedName
            }
        })
        Write-ExplorerSearchLog $Log 'ad.query.end' @{Records=$computers.Count}
        [pscustomobject]@{Name=[string]$ou.Name; DistinguishedName=[string]$ou.DistinguishedName; Computers=$computers}
    })
    [pscustomobject]@{DomainController=$DomainController; Ous=$ous}
}

function Read-ExplorerAdProcess {
    param([string]$CorePath, [string]$ConfigPath, [string]$Fragment='', [string]$DomainController, [int]$TimeoutSeconds, [hashtable]$AdSearchLog, [hashtable]$OuSearch)

    . (Join-Path $PSScriptRoot 'ComputerExplorer.AdLog.ps1')
    $body = {
        $ErrorActionPreference = 'Stop'
        $WarningPreference = 'SilentlyContinue'
        $ProgressPreference = 'SilentlyContinue'
        [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
        . (Join-Path (Split-Path $env:ASSISTENTEIT_AD_CORE -Parent) 'ComputerExplorer.AdLog.ps1')
        $log=$null
        if ($env:ASSISTENTEIT_AD_LOG) {
            $log=@{Path=$env:ASSISTENTEIT_AD_LOG; Dc=$env:ASSISTENTEIT_AD_DC; Attempt=[int]$env:ASSISTENTEIT_AD_ATTEMPT}
        }
        try {
            if ($env:ASSISTENTEIT_AD_OUS) {
                . (Join-Path (Split-Path $env:ASSISTENTEIT_AD_CORE -Parent) 'ComputerExplorer.AdRead.ps1')
                $query = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:ASSISTENTEIT_AD_OUS)) | ConvertFrom-Json
                $result = Read-ExplorerAdOu -DomainController $env:ASSISTENTEIT_AD_DC -Query $query -Log $log
                Write-ExplorerSearchLog $log 'ad.serialize.start' @{Ous=$result.Ous.Count}
            }
            else {
                Write-ExplorerSearchLog $log 'ad.core_import.start'
                Import-Module $env:ASSISTENTEIT_AD_CORE -ErrorAction Stop
                Write-ExplorerSearchLog $log 'ad.core_import.end'
                $fragment = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:ASSISTENTEIT_AD_FRAGMENT))
                Write-ExplorerSearchLog $log 'ad.read.start'
                $result = Read-ExplorerSource -Source AD -ConfigPath $env:ASSISTENTEIT_AD_CONFIG -NameFragment $fragment -DomainController $env:ASSISTENTEIT_AD_DC -AdSearchLog $log
                Write-ExplorerSearchLog $log 'ad.serialize.start' @{State=$result.State; Records=$result.Records.Count}
            }
            [Console]::Out.Write([System.Management.Automation.PSSerializer]::Serialize($result, 6))
            Write-ExplorerSearchLog $log 'ad.serialize.end'
        }
        catch {
            Write-ExplorerSearchLog $log 'ad.worker.error' -Failure $_
            [Console]::Error.Write($_.Exception.Message)
            exit 1
        }
    }

    $desktop = $PSVersionTable.PSEdition -eq 'Desktop'
    $executable = 'pwsh'
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { $executable = 'pwsh.exe' }
    if ($desktop) { $executable = 'powershell.exe' }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body.ToString()))
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Join-Path $PSHOME $executable
    $info.Arguments = '-NoLogo -NoProfile -NonInteractive -EncodedCommand ' + $encoded
    if ($desktop) { $info.Arguments = '-ExecutionPolicy Bypass ' + $info.Arguments }
    $info.WorkingDirectory = $PSScriptRoot
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8
    $info.StandardErrorEncoding = [Text.Encoding]::UTF8
    $info.EnvironmentVariables['ASSISTENTEIT_AD_CORE'] = $CorePath
    $info.EnvironmentVariables['ASSISTENTEIT_AD_CONFIG'] = $ConfigPath
    $info.EnvironmentVariables['ASSISTENTEIT_AD_FRAGMENT'] = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Fragment))
    $info.EnvironmentVariables['ASSISTENTEIT_AD_DC'] = $DomainController
    $info.EnvironmentVariables.Remove('ASSISTENTEIT_AD_OUS')
    if ($null -ne $OuSearch) {
        $query = $OuSearch | ConvertTo-Json -Compress
        $info.EnvironmentVariables['ASSISTENTEIT_AD_OUS'] = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($query))
    }
    $info.EnvironmentVariables.Remove('ASSISTENTEIT_AD_LOG')
    if ($null -ne $AdSearchLog) {
        $info.EnvironmentVariables['ASSISTENTEIT_AD_LOG'] = $AdSearchLog.Path
        $info.EnvironmentVariables['ASSISTENTEIT_AD_ATTEMPT'] = [string]$AdSearchLog.Attempt
    }
    # The query targets -Server explicitly. Avoid discovering a default AD: drive on import.
    $info.EnvironmentVariables['ADPS_LoadDefaultDrive'] = '0'

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    $started = $false
    $phase = 'launch'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        Write-ExplorerSearchLog $AdSearchLog 'ad.process.start' @{TimeoutSeconds=$TimeoutSeconds}
        if (-not $process.Start()) { throw 'Impossibile avviare il lettore AD isolato.' }
        $started = $true
        $phase = 'transport'
        Write-ExplorerSearchLog $AdSearchLog 'ad.process.started' @{WorkerPid=$process.Id; ElapsedMs=$watch.ElapsedMilliseconds}
        $output = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
        while (-not ($process.HasExited -and $output.IsCompleted -and $errors.IsCompleted)) {
            if ($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                $phase = 'timeout'
                Write-ExplorerSearchLog $AdSearchLog 'ad.process.timeout' @{WorkerPid=$process.Id; ElapsedMs=$watch.ElapsedMilliseconds; TimeoutSeconds=$TimeoutSeconds}
                throw ('Tempo massimo di lettura AD superato ({0} s).' -f $TimeoutSeconds)
            }
            Start-Sleep -Milliseconds 40
        }
        Write-ExplorerSearchLog $AdSearchLog 'ad.process.exit' @{WorkerPid=$process.Id; ExitCode=$process.ExitCode; ElapsedMs=$watch.ElapsedMilliseconds}
        if ($process.ExitCode -ne 0) {
            $detail = $errors.GetAwaiter().GetResult().Trim()
            if (-not $detail) { $detail = 'Il lettore AD isolato si è chiuso senza risultato.' }
            throw $detail
        }
        $phase = 'deserialize'
        $response=[System.Management.Automation.PSSerializer]::Deserialize($output.GetAwaiter().GetResult())
        Write-ExplorerSearchLog $AdSearchLog 'ad.response.decoded' @{ElapsedMs=$watch.ElapsedMilliseconds}
        return $response
    }
    catch [System.Management.Automation.PipelineStoppedException] { throw }
    catch {
        if ($phase -ne 'timeout') { Write-ExplorerSearchLog $AdSearchLog ('ad.'+$phase+'.error') @{ElapsedMs=$watch.ElapsedMilliseconds} -Failure $_ }
        throw
    }
    finally {
        try {
            if ($started -and -not $process.HasExited) {
                try { $process.Kill() }
                catch [InvalidOperationException] { if (-not $process.HasExited) { throw } }
                $exited=$process.WaitForExit(2000)
                Write-ExplorerSearchLog $AdSearchLog 'ad.process.terminated' @{WorkerPid=$process.Id; Exited=$exited; ElapsedMs=$watch.ElapsedMilliseconds}
            }
        }
        finally { $process.Dispose(); $watch.Stop() }
    }
}
