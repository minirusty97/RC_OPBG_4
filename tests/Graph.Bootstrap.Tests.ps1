#requires -version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$definitions=(Get-Content (Join-Path $root 'assistente-it.json') -Raw | ConvertFrom-Json).Modules[0].GraphPermissions
$module=Import-Module (Join-Path $root 'ComputerExplorer.Core.psm1') -Force -PassThru
try {
    & $module {
        param($Definitions)
        $tenant='11111111-1111-4111-8111-111111111111';$client='22222222-2222-4222-8222-222222222222'
        $auth=[pscustomobject]@{AuthenticationMode='Delegated';TenantId=$tenant;ClientId=$client}
        $script:Bootstrap=@{Context=$null;Logins=(New-Object 'Collections.Generic.List[object]');Requests=(New-Object 'Collections.Generic.List[string]');Mode='';Disconnects=0}
        function script:Import-Module { [CmdletBinding()]param($Name) }
        function script:Get-MgContext { [CmdletBinding()]param() return $script:Bootstrap.Context }
        function script:Disconnect-MgGraph { [CmdletBinding()]param() $script:Bootstrap.Context=$null;$script:Bootstrap.Disconnects++ }
        function script:Connect-MgGraph {
            [CmdletBinding()]param($Scopes,$TenantId,$ClientId,$Environment,$ContextScope,[switch]$NoWelcome)
            [void]$script:Bootstrap.Logins.Add([pscustomobject]@{Scopes=@($Scopes);TenantId=$TenantId;ClientId=$ClientId;ContextScope=$ContextScope})
            if ($script:Bootstrap.Mode -eq 'Denied') { throw 'Synthetic denied consent or cancelled sign-in.' }
            $script:Bootstrap.Context=[pscustomobject]@{AuthType='Delegated';TenantId=$TenantId;ClientId=$ClientId;Environment='Global';ContextScope=$ContextScope;Account='operator@example.invalid';AppName='Fixture';Scopes=@('Device.Read.All','DeviceManagementManagedDevices.ReadWrite.All','BitlockerKey.Read.All')}
            if ($script:Bootstrap.Mode -eq 'WrongClient') { $script:Bootstrap.Context.ClientId='33333333-3333-4333-8333-333333333333' }
        }
        function script:Invoke-MgGraphRequest {
            [CmdletBinding()]param($Method,$Uri,$OutputType)
            if ($Method -ne 'GET' -or $Uri -match 'recoveryKeys') { throw 'Preflight must not write or read recovery passwords.' }
            [void]$script:Bootstrap.Requests.Add($Uri)
            if ($script:Bootstrap.Mode -eq 'IntuneDenied' -and $Uri -like '*managedDevices*') { throw 'Synthetic Intune RBAC denied.' }
            [pscustomobject]@{value=@()}
        }
        $queue=New-Object 'Collections.Concurrent.ConcurrentQueue[object]'
        $context=Initialize-ExplorerGraphSession -Scopes @('Directory.AccessAsUser.All','BitlockerKey.Read.All') -GraphAuthentication $auth -ProgressQueue $queue
        $login=$script:Bootstrap.Logins[0]
        if ($login.Scopes.Count -ne 1 -or $login.Scopes[0] -ne 'https://graph.microsoft.com/.default' -or $login.TenantId -ne $tenant -or $login.ClientId -ne $client -or $login.ContextScope -ne 'CurrentUser') { throw 'Dedicated bootstrap requested unapproved feature scopes or changed app identity.' }
        $statuses=@(Get-ExplorerGraphPermissionStatus -Definitions $Definitions -Context $context -Probe)
        if ($statuses.Count -ne 5 -or @($statuses | Where-Object { -not $_.Available }).Count -ne 1 -or @($statuses | Where-Object Id -eq 'entra-remove')[0].Available -or $script:Bootstrap.Requests.Count -ne 2 -or $queue.Count -ne 2) { throw 'Initial verification did not expose the missing Entra-delete consent or used destructive probes.' }
        'PASS: dedicated bootstrap uses only existing app grants via .default, displays missing Entra removal and safely probes Entra/Intune reads without reading keys or modifying devices.'
        Connect-ExplorerGraph -Sources Entra,Intune -ForBitLocker -GraphAuthentication $auth
        Connect-ExplorerGraph -Sources Intune -ForRemoval -ForBitLocker -GraphAuthentication $auth
        $rejected=$false;try { Connect-ExplorerGraph -Sources Entra -ForRemoval -GraphAuthentication $auth } catch { $rejected=$_.Exception.Message -like '*verifica iniziale*' }
        if (-not $rejected -or $script:Bootstrap.Logins.Count -ne 1 -or $queue.Count -ne 2) { throw 'A feature requested additional consent after initial verification.' }
        'PASS: permitted features reuse the bootstrap session; Entra deletion without consent fails locally without a login, consent request or automatic switch to the Microsoft app.'
        foreach ($mode in @('Missing','WrongClient','WrongTenant','AppOnly')) {
            $script:Bootstrap.Context=$context | Select-Object *
            if ($mode -eq 'Missing') { $script:Bootstrap.Context=$null }
            if ($mode -eq 'WrongClient') { $script:Bootstrap.Context.ClientId='33333333-3333-4333-8333-333333333333' }
            if ($mode -eq 'WrongTenant') { $script:Bootstrap.Context.TenantId='33333333-3333-4333-8333-333333333333' }
            if ($mode -eq 'AppOnly') { $script:Bootstrap.Context.AuthType='AppOnly' }
            $rejected=$false;try { Connect-ExplorerGraph -Sources Intune -GraphAuthentication $auth } catch { $rejected=$true }
            if (-not $rejected -or $script:Bootstrap.Logins.Count -ne 1 -or $script:Bootstrap.Disconnects -ne 0) { throw 'Invalid operation context opened an automatic login or changed identity.' }
        }
        'PASS: missing, foreign app/tenant and app-only contexts are rejected during operations without any authentication side effect.'
        $script:Bootstrap.Context=$context;$script:Bootstrap.Mode='IntuneDenied'
        $statuses=@(Get-ExplorerGraphPermissionStatus -Definitions $Definitions -Context $context -Probe)
        if (@($statuses | Where-Object Id -eq 'intune-remove')[0].Available -or @($statuses | Where-Object Id -eq 'intune-read')[0].Available -or @($statuses | Where-Object Id -eq 'intune-read')[0].Detail -notlike '*RBAC denied*') { throw 'A failed read probe was reported as verified.' }
        'PASS: initial read verification reports backend denial separately from consent and does not claim that granted scopes prove effective user roles.'
        foreach ($mode in @('Denied','WrongClient')) {
            $script:Bootstrap.Mode=$mode;$script:Bootstrap.Context=$null
            $before=$script:Bootstrap.Logins.Count;$queue=New-Object 'Collections.Concurrent.ConcurrentQueue[object]'
            $rejected=$false;try { $null=Initialize-ExplorerGraphSession -Scopes @('Device.Read.All') -GraphAuthentication $auth -ProgressQueue $queue } catch { $rejected=$true }
            if (-not $rejected -or $script:Bootstrap.Logins.Count -ne ($before+1) -or $queue.Count -ne 2 -or -not $queue.ToArray()[1].Error) { throw 'Bootstrap failure retried login or lost its completion event.' }
        }
        'PASS: cancelled/denied initial sign-in and wrong resulting identity stop once, before module opening, through a single UI completion event.'
        $script:Bootstrap.Mode='';$script:Bootstrap.Context=$null
        $requested=@('Directory.AccessAsUser.All','DeviceManagementManagedDevices.ReadWrite.All','BitlockerKey.Read.All')
        $null=Initialize-ExplorerGraphSession -Scopes $requested -GraphAuthentication @{AuthenticationMode='Interactive'}
        $last=$script:Bootstrap.Logins[$script:Bootstrap.Logins.Count-1]
        if (($last.Scopes -join ',') -ne ($requested -join ',') -or $last.ClientId) { throw 'The legacy Microsoft app did not request module permissions upfront or was replaced with a custom app.' }
        'PASS: the existing Microsoft app login remains available and requests all declared module permissions only in the initial wrapper.'
    } $definitions
}
finally { Remove-Module -ModuleInfo $module -Force -ErrorAction SilentlyContinue }
