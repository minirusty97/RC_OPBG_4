#requires -version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '../ComputerExplorer.Core.psm1') -Force -PassThru
try {
    & $module {
        $tenant='11111111-1111-4111-8111-111111111111';$client='22222222-2222-4222-8222-222222222222'
        $auth=[pscustomobject]@{AuthenticationMode='Delegated';TenantId=$tenant;ClientId=$client}
        $script:DelegatedTest=@{Context=$null;Connections=(New-Object 'Collections.Generic.List[object]');Disconnects=0;Mode=''}
        function script:Import-Module { [CmdletBinding()]param($Name) if ($Name -ne 'Microsoft.Graph.Authentication') { throw 'Unexpected import.' } }
        function script:Get-MgContext { [CmdletBinding()]param() return $script:DelegatedTest.Context }
        function script:Get-Item { [CmdletBinding()]param($LiteralPath) throw 'Delegated authentication must not read a certificate.' }
        function script:Disconnect-MgGraph { [CmdletBinding()]param() $script:DelegatedTest.Disconnects++;$script:DelegatedTest.Context=$null }
        function script:Connect-MgGraph {
            [CmdletBinding()]param($TenantId,$ClientId,$Scopes,$Environment,$ContextScope,[switch]$NoWelcome,$Certificate,$CertificateThumbprint,$ClientSecretCredential,[switch]$UseDeviceAuthentication)
            if ($Certificate -or $CertificateThumbprint -or $ClientSecretCredential -or $UseDeviceAuthentication) { throw 'A user login was replaced by another authentication flow.' }
            [void]$script:DelegatedTest.Connections.Add([pscustomobject]@{Tenant=$TenantId;Client=$ClientId;Scopes=@($Scopes);Scope=$ContextScope;Environment=$Environment})
            if ($script:DelegatedTest.Mode -eq 'LoginFailure') { throw 'Synthetic user cancellation or denied consent.' }
            $script:DelegatedTest.Context=[pscustomobject]@{AuthType='Delegated';TenantId=$TenantId;ClientId=$ClientId;Environment=$Environment;ContextScope=$ContextScope;Scopes=@($Scopes);Account='operator@example.invalid'}
            if ($script:DelegatedTest.Mode -eq 'WrongClient') { $script:DelegatedTest.Context.ClientId='33333333-3333-4333-8333-333333333333' }
            if ($script:DelegatedTest.Mode -eq 'WrongTenant') { $script:DelegatedTest.Context.TenantId='33333333-3333-4333-8333-333333333333' }
            if ($script:DelegatedTest.Mode -eq 'AppOnly') { $script:DelegatedTest.Context.AuthType='AppOnly' }
            if ($script:DelegatedTest.Mode -eq 'WrongCloud') { $script:DelegatedTest.Context.Environment='USGov' }
            if ($script:DelegatedTest.Mode -eq 'MissingConsent') { $script:DelegatedTest.Context.Scopes=@('User.Read') }
        }
        $normalized=ConvertTo-ExplorerGraphAuthentication @{AuthenticationMode='delegated';TenantId=('{'+$tenant+'}');ClientId=$client}
        if ($normalized.AuthenticationMode -cne 'Delegated' -or $normalized.TenantId -ne $tenant -or $normalized.ClientId -ne $client -or $normalized.CertificateThumbprint) { throw 'A dedicated delegated app unexpectedly requires a certificate.' }
        foreach ($bad in @(@{AuthenticationMode='Delegated'},@{AuthenticationMode='Delegated';TenantId=$tenant},@{AuthenticationMode='Delegated';ClientId=$client},@{AuthenticationMode='Delegated';TenantId='invalid';ClientId=$client})) {
            $rejected=$false;try { $null=ConvertTo-ExplorerGraphAuthentication $bad } catch { $rejected=$true }
            if (-not $rejected) { throw 'An incomplete dedicated app silently selected the default Microsoft app.' }
        }
        if ((ConvertTo-ExplorerGraphAuthentication $null).AuthenticationMode -ne 'Interactive') { throw 'Existing interactive configurations changed.' }
        'PASS: delegated configuration requires both tenant and client, normalizes valid IDs and needs no certificate; legacy defaults remain unchanged.'

        $queue=New-Object 'Collections.Concurrent.ConcurrentQueue[object]'
        $script:CloudCache['old-identity']=$true
        Connect-ExplorerGraph -Sources Entra,Intune -GraphAuthentication $auth -ProgressQueue $queue
        $login=$script:DelegatedTest.Connections[0]
        if ($login.Tenant -ne $tenant -or $login.Client -ne $client -or $login.Scope -ne 'CurrentUser' -or $login.Environment -ne 'Global' -or $login.Scopes.Count -ne 2 -or $login.Scopes -notcontains 'Device.Read.All' -or $login.Scopes -notcontains 'DeviceManagementManagedDevices.Read.All' -or $script:CloudCache.Count -ne 0) { throw 'Dedicated delegated search used the wrong identity or requested write permissions.' }
        $events=@($queue.ToArray())
        if ($events.Count -ne 2 -or $events[0].Kind -ne 'GraphLoginStarting' -or $events[1].Kind -ne 'GraphLoginComplete' -or $events[1].Error) { throw 'Delegated login did not use the existing single interactive UI lifecycle.' }
        'PASS: the dedicated app signs in the operator with explicit tenant/client, Global cloud and the protected user cache, requesting only device read scopes for search.'

        Connect-ExplorerGraph -Sources Entra,Intune -GraphAuthentication $auth
        if ($script:DelegatedTest.Connections.Count -ne 1 -or $script:DelegatedTest.Disconnects -ne 0) { throw 'A matching delegated context was not reused.' }
        'PASS: an already authenticated operator with sufficient read permissions is reused without another login.'

        Connect-ExplorerGraph -Sources Intune -ForBitLocker -GraphAuthentication $auth
        $login=$script:DelegatedTest.Connections[1]
        if ($login.Scopes -notcontains 'BitlockerKey.Read.All' -or $login.Scopes -notcontains 'DeviceManagementManagedDevices.Read.All' -or $login.Scopes -contains 'Directory.AccessAsUser.All' -or $login.Scopes -contains 'DeviceManagementManagedDevices.ReadWrite.All') { throw 'Key lookup requested write permissions or dropped existing consent.' }
        'PASS: key lookup adds BitlockerKey.Read.All to the same operator session without requesting deletion permissions.'

        Connect-ExplorerGraph -Sources Entra,Intune -ForRemoval -ForBitLocker -GraphAuthentication $auth
        $login=$script:DelegatedTest.Connections[2]
        if ($login.Scopes -notcontains 'Directory.AccessAsUser.All' -or $login.Scopes -notcontains 'DeviceManagementManagedDevices.ReadWrite.All' -or $login.Scopes -notcontains 'BitlockerKey.Read.All' -or $login.Tenant -ne $tenant -or $login.Client -ne $client) { throw 'Removal failed to request the documented delegated scopes in the configured app.' }
        'PASS: removal adds the documented delegated deletion scopes and retains the same app, tenant and key-read permission.'

        foreach ($mismatch in @('AppOnly','WrongClient','WrongTenant','WrongCloud','WrongScope')) {
            $script:DelegatedTest.Context=[pscustomobject]@{AuthType='Delegated';TenantId=$tenant;ClientId=$client;Environment='Global';ContextScope='CurrentUser';Scopes=@('Foreign.Permission');Account='operator@example.invalid'}
            if ($mismatch -eq 'AppOnly') { $script:DelegatedTest.Context.AuthType='AppOnly' }
            if ($mismatch -eq 'WrongClient') { $script:DelegatedTest.Context.ClientId='33333333-3333-4333-8333-333333333333' }
            if ($mismatch -eq 'WrongTenant') { $script:DelegatedTest.Context.TenantId='33333333-3333-4333-8333-333333333333' }
            if ($mismatch -eq 'WrongCloud') { $script:DelegatedTest.Context.Environment='USGov' }
            if ($mismatch -eq 'WrongScope') { $script:DelegatedTest.Context.ContextScope='Process' }
            $connections=$script:DelegatedTest.Connections.Count;$disconnects=$script:DelegatedTest.Disconnects
            $script:CloudCache['old-identity']=$true
            Connect-ExplorerGraph -Sources Intune -GraphAuthentication $auth
            $login=$script:DelegatedTest.Connections[$connections]
            if ($script:DelegatedTest.Connections.Count -ne ($connections+1) -or $script:DelegatedTest.Disconnects -ne ($disconnects+1) -or $script:CloudCache.Count -ne 0 -or $login.Scopes.Count -ne 1 -or $login.Scopes[0] -ne 'DeviceManagementManagedDevices.Read.All') { throw ('A different authentication context was reused or leaked scopes: '+$mismatch) }
        }
        'PASS: app-only, foreign app/tenant/cloud and differently scoped SDK contexts are disconnected, clear inventory cache and cannot leak permissions into the dedicated user login.'

        foreach ($mode in @('LoginFailure','WrongClient','WrongTenant','AppOnly','WrongCloud','MissingConsent')) {
            $script:DelegatedTest.Mode=$mode;$script:DelegatedTest.Context=$null
            $connections=$script:DelegatedTest.Connections.Count
            $queue=New-Object 'Collections.Concurrent.ConcurrentQueue[object]'
            $rejected=$false;try { Connect-ExplorerGraph -Sources Intune -GraphAuthentication $auth -ProgressQueue $queue } catch { $rejected=$true }
            $events=@($queue.ToArray())
            if (-not $rejected -or $script:DelegatedTest.Connections.Count -ne ($connections+1) -or $events.Count -ne 2 -or $events[1].Kind -ne 'GraphLoginComplete' -or -not $events[1].Error) { throw ('Denied consent, cancellation or wrong identity triggered a retry/fallback or success: '+$mode) }
        }
        'PASS: cancellation, denied or missing consent and wrong resulting identities fail once through the existing UI lifecycle without retrying as an application or with the default app.'
    }
}
finally { Remove-Module -ModuleInfo $module -Force -ErrorAction SilentlyContinue }
