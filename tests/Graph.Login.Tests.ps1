#requires -version 5.1
[CmdletBinding()]
param([string]$CorePath=(Join-Path $PSScriptRoot '../ComputerExplorer.Core.psm1'))
$ErrorActionPreference='Stop'
$core=(Resolve-Path $CorePath).ProviderPath
if (-not ('GraphLoginConsoleFixture' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Threading.Tasks;
public static class GraphLoginConsoleFixture {
    public static volatile bool Hold = true;
    public static Task Emit(string message) { return Task.Run(() => Console.WriteLine(message)); }
}
'@
}
foreach ($channel in @('Console','Success','Information','Warning','Cancel')) {
    $queue=New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $release=New-Object Threading.ManualResetEventSlim($false)
    $original=[Console]::Out
    $worker=[RunspaceFactory]::CreateRunspace();$worker.Open();$ps=[PowerShell]::Create();$ps.Runspace=$worker
    try {
        $code={
            param($Core,$Queue,$Release,$Channel)
            $m=Import-Module $Core -Force -PassThru
            & $m {
                param($Queue,$Release,$Channel)
                function script:Import-Module { param($Name) }
                function script:Get-MgContext { return $null }
                function script:Connect-MgGraph {
                    [CmdletBinding()]param($Scopes,$ContextScope,[switch]$NoWelcome,[switch]$UseDeviceAuthentication)
                    if ($UseDeviceAuthentication -or $ContextScope -ne 'CurrentUser' -or $Scopes -notcontains 'Directory.AccessAsUser.All') { throw 'Login must preserve interactive authentication, CurrentUser cache and existing scopes.' }
                    $message='To sign in, use a web browser to open https://microsoft.com/devicelogin and enter the code ABCD12345 to authenticate.'
                    if ($Channel -in @('Console','Cancel')) { [GraphLoginConsoleFixture]::Emit($message).GetAwaiter().GetResult() }
                    elseif ($Channel -eq 'Information') { Write-Information $message -InformationAction Continue }
                    elseif ($Channel -eq 'Warning') { Write-Warning $message }
                    else { $message }
                    $watch=[Diagnostics.Stopwatch]::StartNew()
                    while (-not $Release.IsSet -and $watch.Elapsed.TotalSeconds -lt 8) { Start-Sleep -Milliseconds 20 }
                    if (-not $Release.IsSet) { throw 'Synthetic login timed out.' }
                }
                Connect-ExplorerGraph -Sources Entra -ProgressQueue $Queue
                'Finished'
            } $Queue $Release $Channel
        }
        [void]$ps.AddScript($code.ToString()).AddArgument($core).AddArgument($queue).AddArgument($release).AddArgument($channel)
        $operation=$ps.BeginInvoke();$watch=[Diagnostics.Stopwatch]::StartNew();$notice=$null;$found=$null;$started=$false
        while ($null -eq $found -and -not $operation.IsCompleted -and $watch.Elapsed.TotalSeconds -lt 6) {
            while ($queue.TryDequeue([ref]$notice)) {
                if ($notice.Kind -eq 'GraphLoginStarting') { $started=$true }
                if ($notice.Kind -eq 'GraphLogin') { $found=$notice }
            }
            Start-Sleep -Milliseconds 20
        }
        if ($null -eq $found -or $found.Code -ne 'ABCD12345' -or $found.Uri -ne 'https://microsoft.com/devicelogin' -or $operation.IsCompleted) { throw ('Graph instructions hidden while login is pending: '+$channel+'; '+(($ps.Streams.Error | ForEach-Object {$_.ToString()}) -join ' | ')) }
        if (-not $started) { throw 'UI receives no authentication-start notice before waiting on Microsoft.' }
        ('PASS: Graph '+$channel+' instructions reach the UI before authentication completes, including a visible start state.')
        if ($channel -eq 'Cancel') {
            $ps.Stop()
            if (-not [object]::ReferenceEquals($original,[Console]::Out)) { throw 'Cancellation did not restore console output.' }
            'PASS: cancelled authentication restores the process console writer.'
        }
        else {
            $release.Set();$out=@($ps.EndInvoke($operation))
            if ($ps.Streams.Error.Count -gt 0 -or $out.Count -ne 1 -or $out[0] -ne 'Finished' -or -not [object]::ReferenceEquals($original,[Console]::Out)) { throw 'Login contaminated results or did not restore the console.' }
            $complete=$false
            while ($queue.TryDequeue([ref]$notice)) { if ($notice.Kind -eq 'GraphLoginComplete' -and -not $notice.Error) { $complete=$true } }
            if (-not $complete) { throw 'Login did not close its UI after successful authentication.' }
            'PASS: completed authentication restores output, emits one close event and keeps the result protocol clean.'
        }
    }
    finally { $release.Set();$ps.Stop();$ps.Dispose();$worker.Close();$worker.Dispose();$release.Dispose() }
}

# Exercise the complete production coordinator and child auth runspace. Only
# the remote SDK boundary is replaced; no AD/Graph/GLPI network call is made.
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('graph-auth-'+[guid]::NewGuid().ToString('N'))
$moduleDirectory=Join-Path $fixture 'Microsoft.Graph.Authentication'
[void][IO.Directory]::CreateDirectory($moduleDirectory)
$fixtureModule=@'
function Get-MgContext {
    [CmdletBinding()]param()
    if ([GraphLoginConsoleFixture]::Hold) { return $null }
    [pscustomobject]@{TenantId='fixture';ClientId='fixture';Account='synthetic@example.invalid';AuthType='Delegated';Environment='Global';Scopes=@('Directory.AccessAsUser.All')}
}
function Connect-MgGraph {
    [CmdletBinding()]param($Scopes,$ContextScope,[switch]$NoWelcome,[switch]$UseDeviceAuthentication)
    [GraphLoginConsoleFixture]::Emit('Open https://microsoft.com/devicelogin and enter the code ABCD12345 to authenticate.').GetAwaiter().GetResult()
    while ([GraphLoginConsoleFixture]::Hold) { Start-Sleep -Milliseconds 20 }
}
function Invoke-MgGraphRequest {
    [CmdletBinding()]param($Method,$Uri,$OutputType)
    [pscustomobject]@{value=@()}
}
Export-ModuleMember -Function Get-MgContext,Connect-MgGraph,Invoke-MgGraphRequest
'@
$fixtureModule | Set-Content -LiteralPath (Join-Path $moduleDirectory 'Microsoft.Graph.Authentication.psm1') -Encoding UTF8
$previousModulePath=$env:PSModulePath
$queue=New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$worker=[RunspaceFactory]::CreateRunspace();$ps=[PowerShell]::Create();$original=[Console]::Out
try {
    $env:PSModulePath=$fixture+[IO.Path]::PathSeparator+$previousModulePath
    $worker.Open();$ps.Runspace=$worker
    $root=Split-Path (Resolve-Path (Join-Path $PSScriptRoot '../ComputerExplorer.Core.psm1')).ProviderPath -Parent
    [void]$ps.AddScript({param($Root,$Queue)
        Import-Module (Join-Path $Root 'ComputerExplorer.Parallel.psm1')
        Invoke-ComputerExplorerParallelSearch -NameFragment 'PC-TEST' -ConfigPath (Join-Path $Root 'computer-explorer.config.example.json') -EnabledSources Entra -ProgressQueue $Queue
    }.ToString()).AddArgument($root).AddArgument($queue)
    $operation=$ps.BeginInvoke();$watch=[Diagnostics.Stopwatch]::StartNew();$found=$false;$notice=$null
    while (-not $found -and -not $operation.IsCompleted -and $watch.Elapsed.TotalSeconds -lt 6) {
        while ($queue.TryDequeue([ref]$notice)) { if ($notice.PSObject.Properties['Kind'] -and $notice.Kind -eq 'GraphLogin') { $found=$notice.Code -eq 'ABCD12345' } }
        Start-Sleep -Milliseconds 20
    }
    if (-not $found -or $operation.IsCompleted) { throw 'Production parallel auth worker lost the real-time login queue.' }
    [GraphLoginConsoleFixture]::Hold=$false
    $output=@($ps.EndInvoke($operation))
    if ($ps.Streams.Error.Count -gt 0 -or $output.Count -ne 1 -or -not $output[0].Complete -or @($output[0].Sources | Where-Object { $_.Name -eq 'Entra' -and $_.State -eq 'OK' }).Count -ne 1 -or -not [object]::ReferenceEquals($original,[Console]::Out)) { throw 'Production coordinator failed to complete after visible login.' }
    'PASS: the production parallel coordinator forwards native console login instructions immediately and completes cloud reads after authentication.'
}
finally {
    [GraphLoginConsoleFixture]::Hold=$false
    $ps.Stop();$ps.Dispose();$worker.Close();$worker.Dispose()
    $env:PSModulePath=$previousModulePath
    Remove-Item -LiteralPath $fixture -Recurse -Force
}
