#requires -version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '../ComputerExplorer.Core.psm1') -Force -PassThru
try {
    & $module {
        $auth=ConvertTo-ExplorerGraphAuthentication @{AuthenticationMode='Delegated';TenantId='{11111111-1111-4111-8111-111111111111}';ClientId='22222222-2222-4222-8222-222222222222';CertificateThumbprint='obsolete-invalid-data';CertificateStore='obsolete-store'}
        if ($auth.TenantId -ne '11111111-1111-4111-8111-111111111111' -or $auth.AuthenticationMode -ne 'Delegated' -or @($auth.PSObject.Properties).Count -ne 3) { throw 'Obsolete certificate fields affected delegated configuration or were kept in the normalized settings.' }
        if ((ConvertTo-ExplorerGraphAuthentication $null).AuthenticationMode -ne 'Interactive') { throw 'The default user login was changed.' }
        foreach ($bad in @(@{AuthenticationMode='Certificate'},@{AuthenticationMode='Unknown'},@{AuthenticationMode='Delegated'},@{TenantId='invalid'},@{ClientId=[guid]::Empty.ToString()})) {
            $rejected=$false;try { $null=ConvertTo-ExplorerGraphAuthentication $bad } catch { $rejected=$true }
            if (-not $rejected) { throw 'Invalid or removed authentication configuration was accepted.' }
        }
        'PASS: only user authentication modes are accepted; tenant/client validation remains strict and obsolete certificate fields are discarded.'
        $script:AuthenticationBoundaryCalls=0
        function script:Import-Module { [CmdletBinding()]param($Name) $script:AuthenticationBoundaryCalls++;throw 'Authentication should have stopped before loading the SDK.' }
        function script:Get-Item { [CmdletBinding()]param($LiteralPath) throw 'The Windows certificate store must not be consulted.' }
        $rejected=$false
        try { Initialize-ExplorerGraphSession -Scopes @('Device.Read.All') -GraphAuthentication @{AuthenticationMode='Certificate'} } catch { $rejected=$true }
        if (-not $rejected -or $script:AuthenticationBoundaryCalls -ne 0) { throw 'Removed certificate authentication reached the SDK.' }
        'PASS: certificate authentication stops before SDK import or certificate-store access.'
        foreach ($name in @('Get-ExplorerGraphCertificate','Connect-ExplorerGraphCertificate','Test-ExplorerGraphCertificateContext')) {
            if (Get-Command $name -ErrorAction SilentlyContinue) { throw 'Removed certificate authentication helper is still callable.' }
        }
        'PASS: certificate lookup and application authentication helpers are absent.'
    }
}
finally { Remove-Module -ModuleInfo $module -Force -ErrorAction SilentlyContinue }
