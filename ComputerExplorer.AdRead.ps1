#requires -version 5.1

function Read-ExplorerAdProcess {
    param([string]$CorePath, [string]$ConfigPath, [string]$Fragment, [string]$DomainController, [int]$TimeoutSeconds)

    $body = {
        $ErrorActionPreference = 'Stop'
        $WarningPreference = 'SilentlyContinue'
        $ProgressPreference = 'SilentlyContinue'
        [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
        try {
            Import-Module $env:ASSISTENTEIT_AD_CORE -ErrorAction Stop
            $fragment = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:ASSISTENTEIT_AD_FRAGMENT))
            $result = Read-ExplorerSource -Source AD -ConfigPath $env:ASSISTENTEIT_AD_CONFIG -NameFragment $fragment -DomainController $env:ASSISTENTEIT_AD_DC
            [Console]::Out.Write([System.Management.Automation.PSSerializer]::Serialize($result, 6))
        }
        catch {
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
    # The query targets -Server explicitly. Avoid discovering a default AD: drive on import.
    $info.EnvironmentVariables['ADPS_LoadDefaultDrive'] = '0'

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    $started = $false
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        if (-not $process.Start()) { throw 'Impossibile avviare il lettore AD isolato.' }
        $started = $true
        $output = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
        while (-not ($process.HasExited -and $output.IsCompleted -and $errors.IsCompleted)) {
            if ($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                throw ('Tempo massimo di lettura AD superato ({0} s).' -f $TimeoutSeconds)
            }
            Start-Sleep -Milliseconds 40
        }
        if ($process.ExitCode -ne 0) {
            $detail = $errors.GetAwaiter().GetResult().Trim()
            if (-not $detail) { $detail = 'Il lettore AD isolato si è chiuso senza risultato.' }
            throw $detail
        }
        [System.Management.Automation.PSSerializer]::Deserialize($output.GetAwaiter().GetResult())
    }
    finally {
        try {
            if ($started -and -not $process.HasExited) {
                try { $process.Kill() }
                catch [InvalidOperationException] { if (-not $process.HasExited) { throw } }
                [void]$process.WaitForExit(2000)
            }
        }
        finally { $process.Dispose(); $watch.Stop() }
    }
}
