#requires -version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $root 'AssistenteIT/AssistenteIT.Core.psm1') -Force -PassThru
$path=Join-Path ([IO.Path]::GetTempPath()) ('graph-session-'+[guid]::NewGuid().ToString('N')+'.json')
try {
    & $module {
        param($Path)
        $tenant='11111111-1111-4111-8111-111111111111'
        $client='22222222-2222-4222-8222-222222222222'
        $home='33333333-3333-4333-8333-333333333333.'+$tenant
        $script:SessionContext=[pscustomobject]@{
            AuthType='Delegated';ContextScope='CurrentUser';Environment='Global'
            Account='synthetic@example.invalid';TenantId=$tenant;ClientId=$client
            TokenCredentialType='InteractiveBrowser';WamEnabled=$true;HomeAccountId=$home
            Scopes=@('Device.Read.All')
        }
        $script:SessionRecord=[pscustomobject]@{
            username='synthetic@example.invalid';authority='login.microsoftonline.com'
            tenantId=$tenant;clientId=$client;homeAccountId=$home;version='1.0'
            token='UNEXPECTED_FIXTURE_VALUE'
        }
        function script:Import-Module { [CmdletBinding()]param($Name) }
        function script:Get-MgContext { [CmdletBinding()]param() $script:SessionContext }
        function script:Read-AssistenteITGraphSdkRecord { $script:SessionRecord }
        $access=$script:SessionContext | Select-Object Account,TenantId,ClientId
        if (-not (Save-AssistenteITGraphSession -Path $Path -Access $access)) { throw 'Confirmed session was not remembered.' }
        $raw=[IO.File]::ReadAllText($Path)
        $saved=$raw | ConvertFrom-Json
        if ($saved.Account -ne $access.Account -or -not $saved.UseBroker -or $saved.Record.homeAccountId -ne $home -or $raw -match 'UNEXPECTED_FIXTURE_VALUE') { throw 'The session file lost the identity or included an unapproved property.' }
        $script:SessionRecord.homeAccountId='foreign'
        if ((Save-AssistenteITGraphSession -Path $Path -Access $access) -or [IO.File]::ReadAllText($Path) -cne $raw) { throw 'A different cached identity replaced the confirmed one.' }
        'PASS: the remembered session is bound to the confirmed delegated account and contains only account metadata.'
    } $path
}
finally { Remove-Module -ModuleInfo $module -Force; Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue }
