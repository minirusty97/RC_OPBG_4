#requires -version 5.1
$ErrorActionPreference='Stop'
$corePath=Join-Path $PSScriptRoot '../ComputerExplorer.Core.psm1'
$module=Import-Module $corePath -Force -PassThru
try {
    & $module {
        $tenant='11111111-1111-4111-8111-111111111111';$client='22222222-2222-4222-8222-222222222222';$thumb=('AB'*20)
        $script:CertificateTest=@{Context=$null;Connections=(New-Object 'Collections.Generic.List[object]');Disconnects=0;Mode='';Paths=(New-Object 'Collections.Generic.List[string]')}
        $script:CertificateTest.Certificate=[pscustomobject]@{Thumbprint=$thumb;HasPrivateKey=$true;NotBefore=[datetime]::UtcNow.AddDays(-1);NotAfter=[datetime]::UtcNow.AddDays(30)}
        $auth=[pscustomobject]@{AuthenticationMode='Certificate';TenantId=$tenant;ClientId=$client;CertificateThumbprint=$thumb;CertificateStore='CurrentUser'}
        function script:Import-Module { [CmdletBinding()]param($Name) if ($Name -ne 'Microsoft.Graph.Authentication') { throw 'Unexpected import.' } }
        function script:Get-MgContext { [CmdletBinding()]param() return $script:CertificateTest.Context }
        function script:Get-Item {
            [CmdletBinding()]param($LiteralPath)
            [void]$script:CertificateTest.Paths.Add($LiteralPath)
            if ($script:CertificateTest.Mode -eq 'MissingCertificate') { throw 'Synthetic missing certificate.' }
            return $script:CertificateTest.Certificate
        }
        function script:Disconnect-MgGraph { [CmdletBinding()]param() $script:CertificateTest.Disconnects++;$script:CertificateTest.Context=$null }
        function script:Connect-MgGraph {
            [CmdletBinding()]param($TenantId,$ClientId,$Certificate,$Environment,$ContextScope,[switch]$NoWelcome)
            [void]$script:CertificateTest.Connections.Add([pscustomobject]@{Tenant=$TenantId;Client=$ClientId;Certificate=$Certificate;Scope=$ContextScope;Environment=$Environment})
            if ($script:CertificateTest.Mode -eq 'LoginFailure') { throw 'Synthetic credential failure: do not echo arbitrary SDK details.' }
            $script:CertificateTest.Context=[pscustomobject]@{AuthType='AppOnly';TenantId=$TenantId;ClientId=$ClientId;Certificate=$Certificate;CertificateThumbprint='';Environment=$Environment;ContextScope=$ContextScope}
            if ($script:CertificateTest.Mode -eq 'WrongClient') { $script:CertificateTest.Context.ClientId='33333333-3333-4333-8333-333333333333' }
        }
        if ((ConvertTo-ExplorerGraphAuthentication $null).AuthenticationMode -ne 'Interactive') { throw 'Existing configurations no longer default to interactive login.' }
        $normalized=ConvertTo-ExplorerGraphAuthentication @{AuthenticationMode='Certificate';TenantId=('{'+$tenant+'}');ClientId=$client;CertificateThumbprint=('ab '*20);CertificateStore='CurrentUser'}
        if ($normalized.TenantId -ne $tenant -or $normalized.CertificateThumbprint -cne $thumb) { throw 'Valid pasted IDs or thumbprints were not normalized.' }
        foreach ($bad in @(@{AuthenticationMode='Unknown'},@{AuthenticationMode='Certificate'},@{TenantId='not-a-guid'},@{ClientId=[guid]::Empty.ToString()},@{CertificateThumbprint='AABB'},@{CertificateStore='Untrusted'})) {
            $rejected=$false;try { $null=ConvertTo-ExplorerGraphAuthentication $bad } catch { $rejected=$true }
            if (-not $rejected) { throw 'Invalid certificate configuration was accepted.' }
        }
        'PASS: Graph certificate settings validate mode, tenant, client, store and thumbprint while preserving the legacy default.'
        $queue=New-Object 'Collections.Concurrent.ConcurrentQueue[object]'
        $script:CloudCache['synthetic-old-context']=$true
        Connect-ExplorerGraph -Sources Entra,Intune -ForRemoval -ForBitLocker -GraphAuthentication $auth -ProgressQueue $queue
        $connection=$script:CertificateTest.Connections[0]
        if ($connection.Tenant -ne $tenant -or $connection.Client -ne $client -or $connection.Scope -ne 'Process' -or $connection.Environment -ne 'Global' -or -not [object]::ReferenceEquals($connection.Certificate,$script:CertificateTest.Certificate) -or $queue.Count -ne 0 -or $script:CloudCache.Count -ne 0 -or $script:CertificateTest.Paths[0] -cne ('Cert:\CurrentUser\My\'+$thumb)) { throw 'Certificate auth changed identity, opened a login UI, kept stale cache or selected an ambiguous certificate.' }
        'PASS: certificate mode uses the exact app, tenant and store certificate without scopes, interactive login events or persisted user-session context.'
        Connect-ExplorerGraph -Sources Entra -GraphAuthentication $auth
        if ($script:CertificateTest.Connections.Count -ne 1 -or $script:CertificateTest.Disconnects -ne 0) { throw 'A matching certificate context was not reused.' }
        'PASS: the SDK context with a Certificate object is recognized and reused without signing in again.'
        $script:CertificateTest.Context.ClientId='33333333-3333-4333-8333-333333333333'
        Connect-ExplorerGraph -Sources Entra -GraphAuthentication $auth
        if ($script:CertificateTest.Connections.Count -ne 2 -or $script:CertificateTest.Disconnects -ne 1) { throw 'Another application was silently reused.' }
        $local=$auth | Select-Object *;$local.CertificateStore='LocalMachine';$local.CertificateThumbprint=('CD'*20)
        $script:CertificateTest.Certificate=$script:CertificateTest.Certificate | Select-Object *;$script:CertificateTest.Certificate.Thumbprint=$local.CertificateThumbprint
        Connect-ExplorerGraph -Sources Intune -GraphAuthentication $local
        if ($script:CertificateTest.Connections.Count -ne 3 -or $script:CertificateTest.Paths[$script:CertificateTest.Paths.Count-1] -cne ('Cert:\LocalMachine\My\'+$local.CertificateThumbprint)) { throw 'Certificate rotation or the LocalMachine store was ignored.' }
        'PASS: a different application or rotated certificate is reconnected explicitly, including the LocalMachine store.'
        foreach ($mode in @('MissingCertificate','NoPrivateKey','Expired','NotYetValid','LoginFailure','WrongClient')) {
            $script:CertificateTest.Mode=$mode;$script:CertificateTest.Context=$null
            $cert=$script:CertificateTest.Certificate;$cert.HasPrivateKey=$true;$cert.NotBefore=[datetime]::UtcNow.AddDays(-1);$cert.NotAfter=[datetime]::UtcNow.AddDays(30)
            if ($mode -eq 'NoPrivateKey') { $cert.HasPrivateKey=$false }
            if ($mode -eq 'Expired') { $cert.NotAfter=[datetime]::UtcNow.AddSeconds(-1) }
            if ($mode -eq 'NotYetValid') { $cert.NotBefore=[datetime]::UtcNow.AddDays(1) }
            $rejected=$false;try { Connect-ExplorerGraph -Sources Entra -GraphAuthentication $local -ProgressQueue $queue } catch { $rejected=$true }
            if (-not $rejected -or $queue.Count -ne 0) { throw ('Invalid certificate authentication opened an interactive fallback or succeeded: '+$mode) }
        }
        'PASS: missing, public-only, expired and future certificates, failed authentication and wrong SDK identities stop without interactive fallback.'
    }
}
finally { Remove-Module -ModuleInfo $module -Force -ErrorAction SilentlyContinue }

if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
    $certificate=$null;$module=Import-Module $corePath -Force -PassThru
    try {
        $certificate=New-SelfSignedCertificate -Subject ('CN=AssistenteIT-CI-'+[guid]::NewGuid().ToString('N')) -CertStoreLocation 'Cert:\CurrentUser\My' -KeyExportPolicy NonExportable -NotAfter ([datetime]::Now.AddDays(1)) -ErrorAction Stop
        $actual=& $module { param($Thumb) Get-ExplorerGraphCertificate ([pscustomobject]@{CertificateStore='CurrentUser';CertificateThumbprint=$Thumb}) } $certificate.Thumbprint
        if ($actual.Thumbprint -cne $certificate.Thumbprint -or -not $actual.HasPrivateKey) { throw 'The real Windows store certificate was not resolved with its private key.' }
        'PASS: a real non-exportable Windows CurrentUser certificate is resolved from the exact store with its private key.'
    }
    finally {
        if ($null -ne $certificate) { Remove-Item -LiteralPath ('Cert:\CurrentUser\My\'+$certificate.Thumbprint) -DeleteKey -Force -ErrorAction Stop }
        Remove-Module -ModuleInfo $module -Force -ErrorAction SilentlyContinue
    }
}
