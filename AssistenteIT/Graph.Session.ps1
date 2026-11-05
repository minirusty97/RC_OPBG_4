#requires -version 5.1

function Read-AssistenteITGraphSdkRecord {
    # Sign-in without a login hint uses the SDK's shared authentication record.
    $sdkPath=Join-Path ([Microsoft.Graph.PowerShell.Authentication.Core.Constants]::GraphDirectoryPath) 'mg.authrecord.json'
    if ([IO.File]::Exists($sdkPath)) { [IO.File]::ReadAllText($sdkPath) | ConvertFrom-Json -ErrorAction Stop }
}

function Save-AssistenteITGraphSession {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)]$Access)
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    $context=Get-MgContext -ErrorAction Stop
    if ($null -eq $context -or $context.AuthType -ne 'Delegated' -or $context.ContextScope -ne 'CurrentUser' -or
        $context.Environment -ne 'Global' -or $context.Account -ine $Access.Account -or
        $context.TenantId -ine $Access.TenantId -or $context.ClientId -ine $Access.ClientId) { return $false }

    $record=Read-AssistenteITGraphSdkRecord
    if ($null -eq $record -or $record.clientId -ine $context.ClientId -or $record.tenantId -ine $context.TenantId -or
        [string]::IsNullOrWhiteSpace($record.username) -or [string]::IsNullOrWhiteSpace($context.Account) -or
        [string]::IsNullOrWhiteSpace($context.HomeAccountId) -or $record.homeAccountId -cne $context.HomeAccountId) { return $false }

    # Save only account metadata. The SDK and Windows broker keep the encrypted token cache.
    $saved=[ordered]@{
        SchemaVersion=1
        Account=[string]$context.Account
        ClientId=[string]$context.ClientId
        TenantId=[string]$context.TenantId
        Scopes=@($context.Scopes)
        UseBroker=($context.TokenCredentialType -eq 'InteractiveBrowser' -and $context.WamEnabled)
        Record=[ordered]@{
            username=[string]$record.username
            authority=[string]$record.authority
            homeAccountId=[string]$record.homeAccountId
            tenantId=[string]$record.tenantId
            clientId=[string]$record.clientId
            version=[string]$record.version
        }
    }
    Write-AssistenteITAtomicFile $Path ($saved | ConvertTo-Json -Depth 5)
    return $true
}

function New-AssistenteITSilentGraphCredential {
    param($Saved,[IntPtr]$WindowHandle)
    $recordJson=$Saved.Record | ConvertTo-Json -Compress
    $stream=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($recordJson))
    try { $record=[Azure.Identity.AuthenticationRecord]::Deserialize($stream,[Threading.CancellationToken]::None) }
    finally { $stream.Dispose() }
    $options=[Azure.Identity.InteractiveBrowserCredentialOptions]::new()
    if ($Saved.UseBroker) {
        if ($WindowHandle -eq [IntPtr]::Zero) { throw 'Finestra di accesso non disponibile.' }
        $options=[Azure.Identity.Broker.InteractiveBrowserCredentialBrokerOptions]::new($WindowHandle)
        $options.UseDefaultBrokerAccount=$false
    }
    $options.ClientId=$Saved.ClientId
    $options.TenantId=$Saved.TenantId
    $options.AuthorityHost=[uri]'https://login.microsoftonline.com'
    $options.AuthenticationRecord=$record
    $options.DisableAutomaticAuthentication=$true
    $options.TokenCachePersistenceOptions=[Azure.Identity.TokenCachePersistenceOptions]::new()
    $options.TokenCachePersistenceOptions.Name='mg.msal.cache'
    $options.TokenCachePersistenceOptions.UnsafeAllowUnencryptedStorage=$false
    return [Azure.Identity.InteractiveBrowserCredential]::new($options)
}

function Get-AssistenteITSilentGraphToken {
    param($Credential,[string[]]$Scopes)
    $request=[Azure.Core.TokenRequestContext]::new($Scopes,$null,$null,$null,$true)
    $timeout=[Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(15))
    try { return $Credential.GetToken($request,$timeout.Token) }
    finally { $timeout.Dispose() }
}

function Get-AssistenteITGraphTokenClaims {
    param([string]$Token)
    # This is a token obtained directly from Azure Identity. Its claims describe
    # the session for the wrapper. Graph verifies the token on every request.
    $segments=$Token.Split('.')
    if ($segments.Length -ne 3) { throw 'Formato della sessione Graph non riconosciuto.' }
    $payload=$segments[1].Replace('-','+').Replace('_','/')
    $payload=$payload.PadRight([int](4*[Math]::Ceiling($payload.Length/4.0)),'=')
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json -ErrorAction Stop
}

function Restore-AssistenteITGraphContext {
    param([string]$Path,$Authentication,[IntPtr]$WindowHandle)
    if (-not [IO.File]::Exists($Path)) { return }
    try {
        $saved=[IO.File]::ReadAllText($Path) | ConvertFrom-Json -ErrorAction Stop
        $record=$saved.Record
        if ($saved.SchemaVersion -ne 1 -or $saved.UseBroker -isnot [bool] -or
            [string]::IsNullOrWhiteSpace($saved.Account) -or [string]::IsNullOrWhiteSpace($record.homeAccountId) -or
            $record.version -ne '1.0' -or $record.authority -notin @('login.microsoftonline.com','login.windows.net','login.microsoft.com','sts.windows.net') -or
            [string]::IsNullOrWhiteSpace($record.username) -or $record.clientId -ine $saved.ClientId -or $record.tenantId -ine $saved.TenantId) { return }
        $clientId='14d82eec-204b-4c2f-b7e8-296a70dab67e'
        if ($Authentication.AuthenticationMode -eq 'Delegated') {
            $clientId=$Authentication.ClientId
            if ($saved.TenantId -ine $Authentication.TenantId) { return }
        }
        if ($saved.ClientId -ine $clientId -or [guid]::Parse($saved.TenantId) -eq [guid]::Empty) { return }
        [string[]]$scopes=@($saved.Scopes | Where-Object { $_ -match '^[A-Za-z0-9.]+$' -and $_ -notin @('openid','profile','offline_access') })
        if ($Authentication.AuthenticationMode -eq 'Delegated') { $scopes=@('https://graph.microsoft.com/.default') }
        if (-not $scopes.Count) { return }

        Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
        [Microsoft.Graph.PowerShell.Authentication.Common.GraphSessionInitializer]::InitializeSession()
        $session=[Microsoft.Graph.PowerShell.Authentication.GraphSession]::Instance
        $credential=New-AssistenteITSilentGraphCredential -Saved $saved -WindowHandle $WindowHandle
        $accessToken=Get-AssistenteITSilentGraphToken -Credential $credential -Scopes $scopes
        $claims=Get-AssistenteITGraphTokenClaims $accessToken.Token
        $accessToken=$null
        $tokenClient=[string](Get-ExplorerGraphSetting $claims 'appid' (Get-ExplorerGraphSetting $claims 'azp'))
        $tokenAccount=[string](Get-ExplorerGraphSetting $claims 'upn' (Get-ExplorerGraphSetting $claims 'preferred_username'))
        $granted=[string](Get-ExplorerGraphSetting $claims 'scp')
        if ($tokenClient -ine $clientId -or $tokenAccount -ine $saved.Account -or $claims.tid -ine $saved.TenantId -or
            $claims.aud -notin @('00000003-0000-0000-c000-000000000000','https://graph.microsoft.com','https://graph.microsoft.com/') -or
            [string]::IsNullOrWhiteSpace($granted)) { return }

        $context=[Microsoft.Graph.PowerShell.Authentication.AuthContext]::new()
        $context.AuthType='Delegated'
        $context.ContextScope='CurrentUser'
        $context.TokenCredentialType='InteractiveBrowser'
        $context.Environment='Global'
        $context.TenantId=$saved.TenantId
        $context.ClientId=$clientId
        $context.Account=$tokenAccount
        $context.HomeAccountId=$record.homeAccountId
        $context.PSHostVersion=$Host.Version
        $context.AppName=[string](Get-ExplorerGraphSetting $claims 'app_displayname')
        $context.Scopes=$granted.Split(' ',[StringSplitOptions]::RemoveEmptyEntries)

        $environment=Get-MgEnvironment -Name 'Global' -ErrorAction Stop
        if ($null -eq $environment -or $environment.GraphEndpoint.TrimEnd('/') -ne 'https://graph.microsoft.com') { return }
        $provider=[Microsoft.Graph.Authentication.AzureIdentityAuthenticationProvider]::new($credential,[string[]]@('graph.microsoft.com'),$null,$true,$scopes)
        $handler=[Net.Http.HttpClientHandler]::new()
        $handler.AllowAutoRedirect=$false
        $handler.AutomaticDecompression=[Net.DecompressionMethods]'GZip, Deflate'
        try { $client=[Microsoft.Graph.GraphClientFactory]::Create($provider,$null,'v1.0','Global',$null,$handler,$true) }
        catch { $handler.Dispose();throw }
        $client.Timeout=$session.RequestContext.ClientTimeout

        $oldClient=$session.GraphHttpClient
        $session.Environment=$environment
        $session.GraphHttpClient=$client
        $session.AuthContext=$context
        if ($null -ne $oldClient) { $oldClient.Dispose() }
        return $context
    }
    catch {
        # Silent acquisition may require MFA, consent or a fresh sign-in. Do not
        # propagate raw identity errors, delete the cache or fall back to a prompt.
        return
    }
}
