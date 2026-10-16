#requires -version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'NSIS installation requires Windows.' }
# Same NSIS version as before; hash published by its Chocolatey package maintainer:
# https://github.com/mkevenaar/chocolatey-packages/blob/master/automatic/nsis.install/legal/VERIFICATION.txt
$expected='DB9A1038BBC0E53FEF24F423FD609979BD578E942F1BE1198DB186D1C42652A3'
$urls=@(
    'https://phoenixnap.dl.sourceforge.net/project/nsis/NSIS%203/3.13/nsis-3.13-setup.exe',
    'https://netix.dl.sourceforge.net/project/nsis/NSIS%203/3.13/nsis-3.13-setup.exe',
    'https://pilotfiber.dl.sourceforge.net/project/nsis/NSIS%203/3.13/nsis-3.13-setup.exe',
    'https://downloads.sourceforge.net/project/nsis/NSIS%203/3.13/nsis-3.13-setup.exe',
    'https://sourceforge.net/projects/nsis/files/NSIS%203/3.13/nsis-3.13-setup.exe/download'
)
$setup=Join-Path ([IO.Path]::GetTempPath()) ('nsis-3.13-'+[guid]::NewGuid().ToString('N')+'.exe')
try {
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    $downloaded=$false
    foreach ($url in $urls) {
        try {
            & curl.exe --fail --location --connect-timeout 15 --max-time 60 --output $setup $url
            if ($LASTEXITCODE -ne 0) { throw ('NSIS download failed with curl exit code '+$LASTEXITCODE) }
            $actual=(Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash
            if ($actual -ne $expected) { throw ('NSIS checksum mismatch: SHA256='+$actual+'; bytes='+([IO.FileInfo]$setup).Length) }
            $downloaded=$true; break
        }
        catch { Write-Warning ('NSIS download failed: '+$_.Exception.Message) }
    }
    if (-not $downloaded) { throw 'Unable to obtain the pinned NSIS compiler with the expected SHA256.' }
    $process=Start-Process -FilePath $setup -ArgumentList '/S' -Wait -PassThru
    try { if ($process.ExitCode -notin @(0,3010)) { throw 'NSIS installation failed.' } }
    finally { $process.Dispose() }
    $compiler=Join-Path ${env:ProgramFiles(x86)} 'NSIS/makensis.exe'
    if (-not (Test-Path -LiteralPath $compiler)) { throw 'NSIS compiler missing after setup.' }
    $version=(& $compiler /VERSION | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $version -ne 'v3.13') { throw ('Unexpected NSIS compiler version: '+$version) }
    Write-Host 'Pinned NSIS 3.13 verified and installed.'
}
finally { if (Test-Path -LiteralPath $setup) { Remove-Item -LiteralPath $setup -Force } }
