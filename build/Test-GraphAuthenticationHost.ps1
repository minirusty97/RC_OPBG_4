#requires -version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$GraphModulePath)
$ErrorActionPreference='Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Native authentication-host verification requires Windows.' }
$root=Split-Path $PSScriptRoot -Parent
$directory=Join-Path ([IO.Path]::GetTempPath()) ('graph-window-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($directory)
$probePath=Join-Path $directory 'probe.ps1';$report=Join-Path $directory 'result.json'
$probe=@'
param($Bridge,$Graph,$Report)
$ErrorActionPreference='Stop'
try {
    Add-Type -Path $Bridge
    Import-Module $Graph -ErrorAction Stop
    $assembly=@([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'Microsoft.Graph.Authentication.Core' })[0]
    $type=$assembly.GetType('Microsoft.Graph.PowerShell.Authentication.Core.Utilities.WindowHandleUtlities',$true)
    $method=$type.GetMethod('GetConsoleOrTerminalWindow',[Reflection.BindingFlags]'Public,Static')
    $before=[long]$method.Invoke($null,@())
    $scope=[AssistenteIT.GraphAuthConsole]::Open()
    try { $during=[long]$method.Invoke($null,@()) }
    finally { $scope.Dispose() }
    $after=[long]$method.Invoke($null,@())
    $second=[AssistenteIT.GraphAuthConsole]::Open()
    try { $reused=[long]$method.Invoke($null,@()) }
    finally { $second.Dispose() }
    [pscustomobject]@{Before=$before;During=$during;After=$after;Reused=$reused} | ConvertTo-Json | Set-Content -LiteralPath $Report -Encoding UTF8
}
catch { $_.Exception.ToString() | Set-Content -LiteralPath $Report -Encoding UTF8; exit 1 }
'@
try {
    $probe | Set-Content -LiteralPath $probePath -Encoding UTF8
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell/v1.0/powershell.exe'
    $info.Arguments='-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Bridge "{1}" -Graph "{2}" -Report "{3}"' -f $probePath,(Join-Path $root 'Graph.LoginBridge.cs'),([IO.Path]::GetFullPath($GraphModulePath)),$report
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $process=[Diagnostics.Process]::Start($info)
    try {
        if (-not $process.WaitForExit(30000)) { $process.Kill();throw 'Hidden authentication host timed out.' }
        if ($process.ExitCode -ne 0) { throw ('Hidden host failed: '+(Get-Content -LiteralPath $report -Raw)) }
    }
    finally { $process.Dispose() }
    $result=Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
    if ($result.Before -ne 0 -or $result.During -eq 0 -or $result.After -ne $result.During -or $result.Reused -ne $result.During) { throw ('The bundled Graph SDK cannot find a valid reusable WAM parent in a hidden GUI process: '+($result|ConvertTo-Json -Compress)) }
    'PASS: bundled Graph SDK has no WAM parent in the old hidden host, receives a valid native window during sign-in and retains its handle for later refreshes.'
}
finally { Remove-Item -LiteralPath $directory -Recurse -Force }
