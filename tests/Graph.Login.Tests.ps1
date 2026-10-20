#requires -version 5.1
$ErrorActionPreference='Stop'
$core=(Resolve-Path (Join-Path $PSScriptRoot '../ComputerExplorer.Core.psm1')).ProviderPath
$queue=New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$release=New-Object Threading.ManualResetEventSlim($false)
$worker=[RunspaceFactory]::CreateRunspace();$worker.Open();$ps=[PowerShell]::Create();$ps.Runspace=$worker
try {
    $code={
        param($Core,$Queue,$Release)
        $m=Import-Module $Core -Force -PassThru
        & $m {
            param($Queue,$Release)
            function script:Import-Module { param($Name) }
            function script:Get-MgContext { return $null }
            function script:Connect-MgGraph {
                [CmdletBinding()]param($Scopes,$ContextScope,[switch]$NoWelcome,[switch]$UseDeviceAuthentication)
                if (-not $UseDeviceAuthentication -or $ContextScope -ne 'Process' -or $Scopes -notcontains 'Directory.AccessAsUser.All') { throw 'First login did not request a visible device flow with existing scopes.' }
                'To sign in, use a web browser to open the page https://microsoft.com/devicelogin and enter the code ABCD12345 to authenticate.'
                if (-not $Release.Wait(5000)) { throw 'Synthetic login timed out.' }
            }
            Connect-ExplorerGraph -Sources Entra -ProgressQueue $Queue
            'Finished'
        } $Queue $Release
    }
    [void]$ps.AddScript($code.ToString()).AddArgument($core).AddArgument($queue).AddArgument($release)
    $operation=$ps.BeginInvoke();$watch=[Diagnostics.Stopwatch]::StartNew()
    while ($queue.Count -eq 0 -and -not $operation.IsCompleted -and $watch.Elapsed.TotalSeconds -lt 4) { Start-Sleep -Milliseconds 20 }
    $notice=$null
    if (-not $queue.TryDequeue([ref]$notice) -or $notice.Kind -ne 'GraphLogin' -or $notice.Code -ne 'ABCD12345' -or $notice.Uri -ne 'https://microsoft.com/devicelogin' -or $operation.IsCompleted) { throw 'Login instructions were hidden until authentication completed.' }
    'PASS: first Graph login streams Microsoft code and verified browser address to the UI while authentication is still pending.'
    $release.Set();$out=@($ps.EndInvoke($operation))
    if ($ps.Streams.Error.Count -gt 0 -or $out.Count -ne 1 -or $out[0] -ne 'Finished') { throw 'Login messages contaminated the result protocol.' }
    'PASS: login callback produces no extra source result and preserves process-scoped authentication.'
}
finally { $release.Set();$ps.Stop();$ps.Dispose();$worker.Close();$worker.Dispose();$release.Dispose() }
