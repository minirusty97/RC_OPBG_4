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
    $sharedContext=0
    foreach ($phase in @('Prepare','Read','Read')) {
     $worker=[RunspaceFactory]::CreateRunspace();$worker.ApartmentState='STA';$worker.ThreadOptions='ReuseThread';$worker.Open()
     $pipeline=[PowerShell]::Create();$pipeline.Runspace=$worker
     try {
      [void]$pipeline.AddScript({
       param($Graph,$Phase)
       $ErrorActionPreference='Stop';Import-Module $Graph -ErrorAction Stop
       if ($Phase -eq 'Prepare') {
        $core=@([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object {$_.GetName().Name -eq 'Microsoft.Graph.Authentication.Core'})[0]
        $sdk=@([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object {$_.GetName().Name -eq 'Microsoft.Graph.Authentication'})[0]
        $session=$core.GetType('Microsoft.Graph.PowerShell.Authentication.GraphSession',$true).GetProperty('Instance').GetValue($null,$null)
        $context=[Activator]::CreateInstance($sdk.GetType('Microsoft.Graph.PowerShell.Authentication.AuthContext',$true))
        $context.Account='synthetic@example.invalid';$context.ClientId='22222222-2222-4222-8222-222222222222';$context.Scopes=[string[]]@('Device.Read.All')
        $session.AuthContext=$context
       }
       $current=Get-MgContext -ErrorAction Stop
       if ($null -eq $current -or $current.Account -ne 'synthetic@example.invalid' -or $current.ClientId -ne '22222222-2222-4222-8222-222222222222' -or $current.Scopes -notcontains 'Device.Read.All') { throw 'Bundled Graph SDK lost the verified context between module runspaces.' }
       $true
      }.ToString()).AddArgument($Graph).AddArgument($phase)
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
    'PASS: the bundled Graph SDK preserves the verified context across disposed and reopened STA module runspaces without another login.'
    'PASS: bundled Graph SDK resolves the visible GUI for login and reuse, keeps the native console hidden throughout and restores its original owner before GUI disposal.'
}
finally { Remove-Item -LiteralPath $directory -Recurse -Force }
