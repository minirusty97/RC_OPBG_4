#requires -version 5.1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$temp = Join-Path ([IO.Path]::GetTempPath()) ('test-ad-parallel-' + [guid]::NewGuid().ToString('N'))
$app = Join-Path $temp 'app prova AD'
[void][IO.Directory]::CreateDirectory($app)
$modulePath = Join-Path $app 'ComputerExplorer.Parallel.psm1'
$fragment = 'PC-''"(*)è'
$controllers = @(1..5 | ForEach-Object { "dc$_.example.invalid" })

function New-TestCase {
    param([string]$Name, [hashtable]$Actions = @{}, [int]$DelayMs = 0)
    $directory = Join-Path $temp $Name
    [void][IO.Directory]::CreateDirectory($directory)
    $path = Join-Path $directory 'config.json'
    @{DomainControllers=$controllers; Fixture=$Actions; DelayMs=$DelayMs; Fragment=$fragment} |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding UTF8
    [pscustomobject]@{ Directory=$directory; Config=$path; Log=(Join-Path $directory ('search-'+[guid]::NewGuid().ToString('N')+'.log')) }
}

function Start-TestRead {
    param($Case, [switch]$Parallel, [int]$Timeout = 25)
    $pipeline = [PowerShell]::Create()
    try {
        [void]$pipeline.AddScript({
            param($ModulePath,$Config,$Fragment,$Parallel,$Timeout,$Log)
            $ErrorActionPreference='Stop'
            Import-Module $ModulePath -ErrorAction Stop
            Invoke-ComputerExplorerParallelSearch -NameFragment $Fragment -ConfigPath $Config -EnabledSources AD -ParallelAdReads:$Parallel -AdReadTimeoutSeconds $Timeout -SearchLogPath $Log
        }.ToString()).AddArgument($modulePath).AddArgument($Case.Config).AddArgument($fragment).AddArgument([bool]$Parallel).AddArgument($Timeout).AddArgument($Case.Log)
        [pscustomobject]@{Pipeline=$pipeline; Operation=$pipeline.BeginInvoke()}
    }
    catch { $pipeline.Dispose(); throw }
}

function Wait-ForFixture {
    param([scriptblock]$Condition)
    $limit=[datetime]::UtcNow.AddSeconds(20)
    while (-not (& $Condition)) {
        if ([datetime]::UtcNow -ge $limit) { throw 'Synthetic AD workers did not reach the expected state.' }
        Start-Sleep -Milliseconds 40
    }
}

function Complete-TestRead {
    param($Task)
    if (-not $Task.Operation.AsyncWaitHandle.WaitOne(40000)) { throw 'AD search did not terminate.' }
    $result=@($Task.Pipeline.EndInvoke($Task.Operation))
    if ($Task.Pipeline.HadErrors -or $result.Count -ne 1 -or -not $result[0].Complete) {
        throw ('AD search returned an invalid result: ' + ($Task.Pipeline.Streams.Error | Out-String))
    }
    return $result[0]
}

function Close-TestRead {
    param($Task)
    try { if (-not $Task.Operation.IsCompleted) { $Task.Pipeline.Stop() } }
    finally { $Task.Pipeline.Dispose() }
}

function Get-TestWorkerId {
    param($Case, [string]$Dc, [int]$Attempt = 1)
    return [int]([IO.File]::ReadAllText((Join-Path $Case.Directory "$Dc.$Attempt.pid")))
}

function Get-TestEvents {
    param($Case)
    Get-Content -LiteralPath $Case.Log -Encoding UTF8 | ForEach-Object { ConvertFrom-Json -InputObject $_ }
}

$holdAll=@{}
foreach ($dc in $controllers) { $holdAll[$dc]='Hold' }

try {
    foreach ($file in @('ComputerExplorer.Parallel.psm1','ComputerExplorer.AdRead.ps1','ComputerExplorer.AdLog.ps1','ComputerExplorer.Core.psm1',
        'ComputerExplorer.Identity.ps1','Glpi.Credentials.ps1','Graph.Authentication.ps1')) {
        Copy-Item -LiteralPath (Join-Path $root $file) -Destination $app
    }
    @'
[CmdletBinding()]
param([string]$ConfigPath,[string]$NameFragment,[string]$DomainController,[switch]$PassThru,[hashtable]$AdSearchLog)
. (Join-Path $PSScriptRoot 'ComputerExplorer.AdLog.ps1')
$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($NameFragment -cne $config.Fragment -or -not $PassThru) { throw 'Query arguments changed across the process boundary.' }
$directory = Split-Path $ConfigPath -Parent
$first = Join-Path $directory "$DomainController.1.pid"
$attempt = 1
if ([IO.File]::Exists($first)) { $attempt = 2 }
$marker = Join-Path $directory "$DomainController.$attempt.pid"
[IO.File]::WriteAllText("$marker.tmp", [string]$PID)
[IO.File]::Move("$marker.tmp", $marker)
if ($attempt -eq 2) {
    $otherWorkers = @(Get-ChildItem -LiteralPath $directory -Filter '*.pid' | ForEach-Object {
        $workerId = [int][IO.File]::ReadAllText($_.FullName)
        if ($workerId -ne $PID) { Get-Process -Id $workerId -ErrorAction SilentlyContinue }
    })
    if ($otherWorkers.Count) { throw 'Synthetic serial retry started with another AD worker still running.' }
}
Write-ExplorerSearchLog $AdSearchLog 'ad.query.start'
$action = $config.Fixture.PSObject.Properties[$DomainController]
if ($null -ne $action) {
    if ($action.Value -eq 'Error') {
        Write-Error -ErrorId SyntheticReadFailure -Category ResourceUnavailable -Message 'Synthetic AD refusal. DiagnosticPrivateFixture.' -ErrorAction Stop
    }
    if ($action.Value -eq 'Timeout' -and $attempt -eq 1) { Start-Sleep -Seconds 60 }
    if ($action.Value -eq 'Hold') {
        $release = Join-Path $directory "$DomainController.release"
        while (-not [IO.File]::Exists($release)) { Start-Sleep -Milliseconds 40 }
    }
}
Start-Sleep -Milliseconds $config.DelayMs
Write-ExplorerSearchLog $AdSearchLog 'ad.query.end' @{Records=1}
[pscustomobject]@{
    CheckedAtUtc=[datetimeoffset]::UtcNow
    Sources=@([pscustomobject]@{DomainController=$DomainController;Stato='OK';Verificato=$true;Trovati=1;Errore=$null})
    Computers=@([pscustomobject]@{
        Name='PC-FIXTURE'; DomainController=$DomainController; ObjectGUID='11111111-1111-4111-8111-111111111111'
        DistinguishedName='CN=PC-FIXTURE,DC=example,DC=invalid'; CanonicalName='example.invalid/PC-FIXTURE'; ParentPath='example.invalid'
        DNSHostName='pc-fixture.example.invalid'; SamAccountName='PC-FIXTURE$'; Enabled=$true; LastModified=[datetime]'2026-01-02T03:04:05Z'
    })
}
'@ | Set-Content -LiteralPath (Join-Path $app 'Test-AdLookup.ps1') -Encoding UTF8

    $case = New-TestCase 'overlap' $holdAll
    $task = Start-TestRead $case -Parallel
    try {
        Wait-ForFixture { @(Get-ChildItem $case.Directory -Filter '*.pid').Count -eq 5 }
        $ids = @($controllers | ForEach-Object { Get-TestWorkerId $case $_ })
        if ($ids -contains $PID -or @($ids | Sort-Object -Unique).Count -ne 5 -or
            @(Get-Process -Id $ids -ErrorAction SilentlyContinue).Count -ne 5) {
            throw 'Expected five independent workers to be alive before releasing any DC.'
        }
        [IO.File]::WriteAllText((Join-Path $case.Directory ($controllers[1]+'.release')), '')
        Wait-ForFixture {
            try { @(Get-TestEvents $case | Where-Object { $_.Event -eq 'ad.attempt.end' -and $_.Dc -eq $controllers[1] }).Count -gt 0 }
            catch { $false }
        }
        if (-not (Get-Process -Id $ids[0] -ErrorAction SilentlyContinue)) { throw 'A secondary DC did not finish before the blocked primary.' }
        foreach ($dc in @($controllers[0]) + @($controllers[2..4])) {
            [IO.File]::WriteAllText((Join-Path $case.Directory ($dc+'.release')), '')
        }
        $result = Complete-TestRead $task
        $ad = $result.Sources[0]
        if ($ad.State -ne 'OK' -or $result.Rows[0].AD -ne '5/5' -or $result.Rows[0].PrimaryDomainController -ne $controllers[0] -or
            ($ad.DcSources.DomainController -join ',') -ne ($controllers -join ',') -or
            $result.Rows[0].ADRecords[0].LastModified -isnot [datetime] -or -not $result.Rows[0].ADRecords[0].Enabled) {
            throw 'Out-of-order completion changed coverage, priority or record types.'
        }
        $events=@(Get-TestEvents $case)
        $dispatch=@($events | Where-Object Event -eq 'ad.dispatch')
        $workerPids=@($events | Where-Object Event -eq 'ad.process.started' | ForEach-Object { $_.WorkerPid })
        if (($dispatch.Dc -join ',') -ne ($controllers -join ',') -or $dispatch[4].ActiveReaders -ne 5 -or
            @(Compare-Object ($ids | Sort-Object) ($workerPids | Sort-Object)).Count -ne 0 -or
            $events[0].Event -ne 'search.start' -or $events[-1].Event -ne 'search.end') { throw 'Trace lost launch order, worker PIDs or search boundaries.' }
        'PASS: five independent DC processes overlap, secondary results arrive while the primary waits, and the search log identifies each worker.'
    }
    finally { Close-TestRead $task }

    $case = New-TestCase 'retry' @{$controllers[0]='Timeout';$controllers[4]='Error'}
    $task = Start-TestRead $case -Parallel -Timeout 8
    try {
        $result = Complete-TestRead $task
        $ad = $result.Sources[0]
        $timedOut = $ad.DcSources[0]
        $refused = $ad.DcSources[4]
        if ($ad.State -ne 'Errore' -or $result.Rows[0].ADColor -ne 'Grigio' -or $result.Rows[0].Verificati -ne '4/5' -or
            $ad.DcSources.Count -ne 5 -or -not $timedOut.Verificato -or $timedOut.Attempts -ne 2 -or
            $timedOut.FirstFailure.Error -notlike '*Tempo massimo*' -or $refused.Verificato -or $refused.Attempts -ne 2 -or
            $refused.Errore -notlike '*Synthetic AD refusal*' -or (Get-Process -Id (Get-TestWorkerId $case $controllers[0]) -ErrorAction SilentlyContinue)) {
            throw ('Timeout/retry or failed coverage mishandled: ' + ($ad.DcSources | ConvertTo-Json -Depth 5 -Compress))
        }
        $events=@(Get-TestEvents $case)
        $timeout=@($events | Where-Object { $_.Event -eq 'ad.process.timeout' -and $_.Dc -eq $controllers[0] -and $_.Attempt -eq 1 })
        $retry=@($events | Where-Object { $_.Event -eq 'ad.attempt.end' -and $_.Dc -eq $controllers[0] -and $_.Attempt -eq 2 -and $_.Verified })
        $failures=@($events | Where-Object { $_.Event -eq 'ad.read.error' -and $_.Dc -eq $controllers[4] -and $_.Error.Id -like 'SyntheticReadFailure*' })
        $rawLog=[IO.File]::ReadAllText($case.Log)
        if ($timeout.Count -ne 1 -or $retry.Count -ne 1 -or $failures.Count -ne 2 -or
            $rawLog -match 'DiagnosticPrivateFixture|PC-FIXTURE|CN=PC|example.invalid/PC' -or $rawLog.Contains($fragment)) {
            throw 'Trace lost the timeout, retry or error code, or retained sensitive search data.'
        }
        'PASS: the log separates timeout, successful serial retry and repeat failure without storing error messages or returned computer data.'
    }
    finally { Close-TestRead $task }

    $case = New-TestCase 'cancel' $holdAll
    $task = Start-TestRead $case -Parallel
    try {
        Wait-ForFixture { @(Get-ChildItem $case.Directory -Filter '*.pid').Count -eq 5 }
        $ids = @($controllers | ForEach-Object { Get-TestWorkerId $case $_ })
        $stop = $task.Pipeline.BeginStop($null,$null)
        if (-not $stop.AsyncWaitHandle.WaitOne(10000)) { throw 'Cancellation waited on a blocked worker.' }
        $task.Pipeline.EndStop($stop)
        if ((Get-Process -Id $ids -ErrorAction SilentlyContinue) -or @(Get-ChildItem $case.Directory -Filter '*.pid').Count -ne 5) {
            throw 'Cancellation left an AD process running or launched a retry.'
        }
        $events=@(Get-TestEvents $case)
        if (@($events | Where-Object { $_.Event -eq 'ad.process.terminated' -and $_.Exited }).Count -ne 5 -or
            $events[-1].Event -ne 'search.interrupted') { throw 'The log did not record cancellation and cleanup for every active worker.' }
        'PASS: cancellation terminates and records all five blocked workers without starting a retry.'
    }
    finally { Close-TestRead $task }

    $times=@{}
    foreach ($mode in @('Sequenziale','Parallelo')) {
        $case = New-TestCase $mode -DelayMs 1700
        $task = Start-TestRead $case -Parallel:($mode -eq 'Parallelo')
        try {
            $result = Complete-TestRead $task
            if ($result.Sources[0].State -ne 'OK' -or $result.Rows[0].AD -ne '5/5') { throw 'A/B benchmark lost a DC.' }
            $times[$mode] = $result.Sources[0].CompletedAfterSeconds
        }
        finally { Close-TestRead $task }
    }
    'BENCHMARK AD sintetico (5 DC da 1,7 s): {0:N2} s sequenziale, {1:N2} s parallelo, 5/5 in entrambe le prove.' -f $times.Sequenziale,$times.Parallelo
}
finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
