#requires -version 5.1

function Get-ExplorerGraphSetting {
    param($Object,[string]$Name,$Default=$null)
    if ($null -ne $Object) {
        if ($Object -is [Collections.IDictionary]) {
            if ($Object.Contains($Name)) { return ,$Object[$Name] }
        }
        else {
            $property=$Object.PSObject.Properties[$Name]
            if ($null -ne $property) { return ,$property.Value }
        }
    }
    return ,$Default
}

function ConvertTo-ExplorerGraphAuthentication {
    param($Settings)
    $mode=[string](Get-ExplorerGraphSetting $Settings 'AuthenticationMode' 'Interactive')
    if ($mode -notin @('Interactive','Certificate')) { throw 'Modalita Graph non valida: scegliere Interactive o Certificate.' }
    $tenant=([string](Get-ExplorerGraphSetting $Settings 'TenantId' '')).Trim()
    $client=([string](Get-ExplorerGraphSetting $Settings 'ClientId' '')).Trim()
    $thumb=([string](Get-ExplorerGraphSetting $Settings 'CertificateThumbprint' '') -replace '[\s\u200e\u200f]','').ToUpperInvariant()
    $location=[string](Get-ExplorerGraphSetting $Settings 'CertificateStore' 'CurrentUser')
    if ($location -notin @('CurrentUser','LocalMachine')) { throw 'Archivio certificati non valido: scegliere CurrentUser o LocalMachine.' }
    foreach ($value in @(@{Name='Tenant ID';Value=$tenant},@{Name='Client ID';Value=$client})) {
        $id=[guid]::Empty
        if ($value.Value -and (-not [guid]::TryParse($value.Value,[ref]$id) -or $id -eq [guid]::Empty)) { throw ($value.Name+' deve essere un GUID valido.') }
    }
    if ($tenant) { $tenant=([guid]$tenant).ToString() };if ($client) { $client=([guid]$client).ToString() }
    if ($mode -eq 'Certificate') { $mode='Certificate' } else { $mode='Interactive' }
    if ($location -eq 'LocalMachine') { $location='LocalMachine' } else { $location='CurrentUser' }
    if ($thumb -and $thumb -notmatch '^[A-F0-9]{40}$') { throw 'L''impronta del certificato deve contenere 40 caratteri esadecimali.' }
    if ($mode -eq 'Certificate' -and (-not $tenant -or -not $client -or -not $thumb)) {
        throw 'Per attivare il certificato servono Tenant ID, Client ID e impronta del certificato.'
    }
    [pscustomobject]@{AuthenticationMode=$mode;TenantId=$tenant;ClientId=$client;CertificateThumbprint=$thumb;CertificateStore=$location}
}

function Get-ExplorerGraphCertificate {
    param($Authentication)
    $path='Cert:\'+$Authentication.CertificateStore+'\My\'+$Authentication.CertificateThumbprint
    try { $certificate=Get-Item -LiteralPath $path -ErrorAction Stop }
    catch { throw ('Certificato Graph non disponibile in '+$path+'. Installarlo con la chiave privata e verificare i permessi dell''utente Windows.') }
    if ($null -eq $certificate -or [string]$certificate.Thumbprint -ine $Authentication.CertificateThumbprint) { throw 'Il certificato trovato non corrisponde all''impronta configurata.' }
    if (-not $certificate.HasPrivateKey) { throw 'Il certificato Graph non contiene la chiave privata. Il solo file CER pubblico non e sufficiente.' }
    $now=[datetime]::UtcNow
    if ($certificate.NotBefore.ToUniversalTime() -gt $now -or $certificate.NotAfter.ToUniversalTime() -le $now) { throw 'Il certificato Graph e scaduto o non ancora valido. Richiedere il certificato aggiornato al sistemista.' }
    return $certificate
}

function Get-ExplorerGraphContextThumbprint {
    param($Context)
    $thumb=[string](Get-ExplorerGraphSetting $Context 'CertificateThumbprint' '')
    if (-not $thumb) { $thumb=[string](Get-ExplorerGraphSetting (Get-ExplorerGraphSetting $Context 'Certificate') 'Thumbprint' '') }
    return ($thumb -replace '[\s\u200e\u200f]','').ToUpperInvariant()
}

function Test-ExplorerGraphCertificateContext {
    param($Context,$Authentication)
    return ($null -ne $Context -and
        [string](Get-ExplorerGraphSetting $Context 'AuthType') -eq 'AppOnly' -and
        [string](Get-ExplorerGraphSetting $Context 'Environment') -eq 'Global' -and
        [string](Get-ExplorerGraphSetting $Context 'ContextScope') -eq 'Process' -and
        [string](Get-ExplorerGraphSetting $Context 'TenantId') -ieq $Authentication.TenantId -and
        [string](Get-ExplorerGraphSetting $Context 'ClientId') -ieq $Authentication.ClientId -and
        (Get-ExplorerGraphContextThumbprint $Context) -ceq $Authentication.CertificateThumbprint)
}

function Connect-ExplorerGraphCertificate {
    param($Authentication,$Context)
    # Explicit store lookup prevents silently selecting another certificate.
    $certificate=Get-ExplorerGraphCertificate $Authentication
    if (Test-ExplorerGraphCertificateContext $Context $Authentication) { return }
    if ($null -ne $Context) { Disconnect-MgGraph -ErrorAction Stop | Out-Null }
    $script:CloudCache.Clear()
    try {
        Connect-MgGraph -TenantId $Authentication.TenantId -ClientId $Authentication.ClientId -Certificate $certificate -Environment Global -ContextScope Process -NoWelcome -ErrorAction Stop | Out-Null
    }
    catch { throw 'Autenticazione Graph con certificato non riuscita. Verificare Tenant ID, Client ID, certificato registrato nell''app e accesso alla chiave privata. Non viene avviato un login interattivo.' }
    $connected=Get-MgContext -ErrorAction Stop
    if (-not (Test-ExplorerGraphCertificateContext $connected $Authentication)) { throw 'La sessione Graph non corrisponde all''applicazione e al certificato configurati. Operazione interrotta.' }
}
