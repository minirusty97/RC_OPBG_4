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
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class AuthConsoleProbe { [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window); [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr window, uint command); }'
    $form=New-Object Windows.Forms.Form
    $form.Text='Authentication host verification'; $form.Show(); [Windows.Forms.Application]::DoEvents()
    [AssistenteIT.GraphAuthConsole]::RegisterOwner($form.Handle)
    $gui=[long]$form.Handle
    Import-Module $Graph -ErrorAction Stop
    $suiteRoot=Split-Path $Bridge -Parent
    $suite=Import-Module (Join-Path $suiteRoot 'AssistenteIT/AssistenteIT.Core.psm1') -PassThru -ErrorAction Stop
    & $suite {
        param($Window,$Path)
        $ErrorActionPreference='Stop'
        $tenant='11111111-1111-4111-8111-111111111111'
        $client='22222222-2222-4222-8222-222222222222'
        $account='synthetic@example.invalid'
        $saved=[pscustomobject]@{
            SchemaVersion=1;Account=$account;ClientId=$client;TenantId=$tenant
            Scopes=@('Device.Read.All','DeviceManagementManagedDevices.ReadWrite.All');UseBroker=$false
            Record=[pscustomobject]@{username=$account;authority='login.microsoftonline.com';homeAccountId=('33333333-3333-4333-8333-333333333333.'+$tenant);tenantId=$tenant;clientId=$client;version='1.0'}
        }
        $auth=[pscustomobject]@{AuthenticationMode='Delegated';TenantId=$tenant;ClientId=$client}
        $script:FakeSilentToken=@{Calls=0;Token='';Fail=$false}
        function script:Get-AssistenteITSilentGraphToken {
            param($Credential,$Scopes)
            $script:FakeSilentToken.Calls++
            if ($Credential.GetType().FullName -ne 'Azure.Identity.InteractiveBrowserCredential' -or ($Scopes -join ',') -ne 'https://graph.microsoft.com/.default') { throw 'Wrong silent credential or scope.' }
            if ($script:FakeSilentToken.Fail) { throw 'Synthetic interaction required.' }
            [pscustomobject]@{Token=$script:FakeSilentToken.Token}
        }
        if ($null -ne (Restore-AssistenteITGraphContext $Path $auth $Window)) { throw 'A missing record restored a session.' }
        $saved | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path -Encoding UTF8
        $foreign=$auth | Select-Object *;$foreign.ClientId='44444444-4444-4444-8444-444444444444'
        if ($null -ne (Restore-AssistenteITGraphContext $Path $foreign $Window) -or $script:FakeSilentToken.Calls -ne 0) { throw 'Foreign configuration was used to get a token.' }
        $null=New-AssistenteITSilentGraphCredential -Saved $saved -WindowHandle $Window
        $saved.UseBroker=$true
        $null=New-AssistenteITSilentGraphCredential -Saved $saved -WindowHandle $Window
        $script:FakeSilentToken.Fail=$true
        if ($null -ne (Restore-AssistenteITGraphContext $Path $auth $Window) -or $script:FakeSilentToken.Calls -ne 1) { throw 'Interaction-required session was accepted or retried.' }
        $script:FakeSilentToken.Fail=$false
        $payload=@{appid=$client;tid=$tenant;upn=$account;aud='00000003-0000-0000-c000-000000000000';scp='Device.Read.All'} | ConvertTo-Json -Compress
        $script:FakeSilentToken.Token='header.'+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload)).TrimEnd('=').Replace('+','-').Replace('/','_')+'.signature'
        $context=Restore-AssistenteITGraphContext $Path $auth $Window
        $sdkSession=[Microsoft.Graph.PowerShell.Authentication.GraphSession]::Instance
        if ($null -eq $context -or $context.AuthType -ne 'Delegated' -or ($context.Scopes -join ',') -ne 'Device.Read.All' -or $null -eq $sdkSession.GraphHttpClient -or $script:FakeSilentToken.Calls -ne 2) { throw 'Silent restore did not bind the real SDK client and freshly granted scopes.' }
    } $form.Handle (Join-Path (Split-Path $Report -Parent) 'saved-session.json')
    $sharedContext=0
    foreach ($phase in 1..3) {
     $worker=[RunspaceFactory]::CreateRunspace();$worker.ApartmentState='STA';$worker.ThreadOptions='ReuseThread';$worker.Open()
     $pipeline=[PowerShell]::Create();$pipeline.Runspace=$worker
     try {
      [void]$pipeline.AddScript({
       param($Graph)
       $ErrorActionPreference='Stop';Import-Module $Graph -ErrorAction Stop
       $current=Get-MgContext -ErrorAction Stop
       if ($null -eq $current -or $current.Account -ne 'synthetic@example.invalid' -or $current.ClientId -ne '22222222-2222-4222-8222-222222222222' -or $current.Scopes -notcontains 'Device.Read.All') { throw 'Bundled Graph SDK lost the verified context between module runspaces.' }
       $true
      }.ToString()).AddArgument($Graph)
      $invocation=$pipeline.BeginInvoke()
      if (-not $invocation.AsyncWaitHandle.WaitOne(15000)) { $pipeline.Stop();throw 'Shared SDK context test timed out.' }
      $result=@($pipeline.EndInvoke($invocation))
      if ($pipeline.Streams.Error.Count) { throw $pipeline.Streams.Error[0] }
      if ($result.Count -ne 1 -or -not $result[0]) { throw 'Invalid shared SDK context result.' }
      $sharedContext++
     }
     finally { $pipeline.Dispose();$worker.Close();$worker.Dispose() }
    }
    $core=@([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object {$_.GetName().Name -eq 'Microsoft.Graph.Authentication.Core'})[0]
    $session=$core.GetType('Microsoft.Graph.PowerShell.Authentication.GraphSession',$true).GetProperty('Instance').GetValue($null,$null)
    $session.AuthContext=$null
    $session.GraphHttpClient.Dispose();$session.GraphHttpClient=$null
    $assembly=@([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'Microsoft.Graph.Authentication.Core' })[0]
    $type=$assembly.GetType('Microsoft.Graph.PowerShell.Authentication.Core.Utilities.WindowHandleUtlities',$true)
    $method=$type.GetMethod('GetConsoleOrTerminalWindow',[Reflection.BindingFlags]'Public,Static')
    $before=[long]$method.Invoke($null,@())
    $scope=[AssistenteIT.GraphAuthConsole]::Open()
    try { $during=[long]$method.Invoke($null,@()); $console=[AuthConsoleProbe]::GetConsoleWindow(); $visible=[AuthConsoleProbe]::IsWindowVisible($console) }
    finally { $scope.Dispose() }
    $after=[long]$method.Invoke($null,@()); $visibleAfter=[AuthConsoleProbe]::IsWindowVisible($console)
    [AssistenteIT.GraphAuthConsole]::ReleaseOwner()
    $released=[long]$method.Invoke($null,@())
    # A console host may already have an owner. Preserve that owner across reuse.
    $originalOwner=[long][AuthConsoleProbe]::GetWindow($console,4)
    [AssistenteIT.GraphAuthConsole]::RegisterOwner($form.Handle)
    $second=[AssistenteIT.GraphAuthConsole]::Open()
    try { $reused=[long]$method.Invoke($null,@()); $visibleReused=[AuthConsoleProbe]::IsWindowVisible($console) }
    finally { $second.Dispose() }
    [AssistenteIT.GraphAuthConsole]::ReleaseOwner()
    $releasedAgain=[long]$method.Invoke($null,@())
    $restoredOwner=[long][AuthConsoleProbe]::GetWindow($console,4)
    $form.Dispose()
    [pscustomobject]@{SharedContext=$sharedContext;Before=$before;Gui=$gui;During=$during;After=$after;Reused=$reused;Visible=$visible;VisibleAfter=$visibleAfter;VisibleReused=$visibleReused;Console=[long]$console;Released=$released;ReleasedAgain=$releasedAgain;OriginalOwner=$originalOwner;RestoredOwner=$restoredOwner} | ConvertTo-Json | Set-Content -LiteralPath $Report -Encoding UTF8
}
catch { $_.Exception.ToString() | Set-Content -LiteralPath $Report -Encoding UTF8; exit 1 }
'@
try {
    $probe | Set-Content -LiteralPath $probePath -Encoding UTF8
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell/v1.0/powershell.exe'
    $info.Arguments='-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Bridge "{1}" -Graph "{2}" -Report "{3}"' -f $probePath,(Join-Path $root 'Graph.LoginBridge.cs'),([IO.Path]::GetFullPath($GraphModulePath)),$report
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
    $process=[Diagnostics.Process]::Start($info)
    try {
        if (-not $process.WaitForExit(30000)) { $process.Kill();throw 'Hidden authentication host timed out.' }
        if ($process.ExitCode -ne 0) { throw ('Hidden host failed: '+(Get-Content -LiteralPath $report -Raw)) }
    }
    finally { $process.Dispose() }
    $result=Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
    if ($result.SharedContext -ne 3 -or $result.Before -ne 0 -or $result.During -ne $result.Gui -or $result.After -ne $result.Gui -or $result.Reused -ne $result.Gui -or $result.Visible -or $result.VisibleAfter -or $result.VisibleReused -or $result.Console -eq 0 -or $result.Released -eq 0 -or $result.Released -eq $result.Gui -or $result.ReleasedAgain -ne $result.Released -or $result.RestoredOwner -ne $result.OriginalOwner) { throw ('The bundled Graph SDK must use the visible GUI while its native console stays hidden and ownership is released safely: '+($result|ConvertTo-Json -Compress)) }
    'PASS: the bundled Graph SDK creates the silent client, rejects missing, foreign and interaction-required sessions, and uses freshly granted delegated scopes.'
    'PASS: the bundled Graph SDK preserves the verified context across disposed and reopened STA module runspaces without another login.'
    'PASS: bundled Graph SDK resolves the visible GUI for login and reuse, keeps the native console hidden throughout and restores its original owner before GUI disposal.'
}
finally { Remove-Item -LiteralPath $directory -Recurse -Force }
