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
    if ($mode -eq 'Certificate') { throw 'Autenticazione Graph con certificato rimossa. Aprire Impostazioni > Microsoft Graph e selezionare Accesso delegato (app dedicata).' }
    if ($mode -notin @('Interactive','Delegated')) { throw 'Modalita Graph non valida: scegliere Interactive o Delegated.' }
    $tenant=([string](Get-ExplorerGraphSetting $Settings 'TenantId' '')).Trim()
    $client=([string](Get-ExplorerGraphSetting $Settings 'ClientId' '')).Trim()
    foreach ($value in @(@{Name='Tenant ID';Value=$tenant},@{Name='Client ID';Value=$client})) {
        $id=[guid]::Empty
        if ($value.Value -and (-not [guid]::TryParse($value.Value,[ref]$id) -or $id -eq [guid]::Empty)) { throw ($value.Name+' deve essere un GUID valido.') }
    }
    if ($tenant) { $tenant=([guid]$tenant).ToString() };if ($client) { $client=([guid]$client).ToString() }
    if ($mode -eq 'Delegated') { $mode='Delegated' } else { $mode='Interactive' }
    if ($mode -eq 'Delegated' -and (-not $tenant -or -not $client)) {
        throw 'Per l''accesso delegato con app dedicata servono Tenant ID e Client ID. Non occorre un certificato.'
    }
    [pscustomobject]@{AuthenticationMode=$mode;TenantId=$tenant;ClientId=$client}
}

function Test-ExplorerGraphDelegatedContext {
    param($Context,$Authentication)
    return ($null -ne $Context -and
        [string](Get-ExplorerGraphSetting $Context 'AuthType') -eq 'Delegated' -and
        [string](Get-ExplorerGraphSetting $Context 'Environment') -eq 'Global' -and
        [string](Get-ExplorerGraphSetting $Context 'ContextScope') -eq 'CurrentUser' -and
        [string](Get-ExplorerGraphSetting $Context 'TenantId') -ieq $Authentication.TenantId -and
        [string](Get-ExplorerGraphSetting $Context 'ClientId') -ieq $Authentication.ClientId)
}


function Initialize-ExplorerGraphSession {
    [CmdletBinding()]
    param([string[]]$Scopes,$GraphAuthentication,$ProgressQueue)
    $authentication=ConvertTo-ExplorerGraphAuthentication $GraphAuthentication
    try { Import-Module Microsoft.Graph.Authentication -ErrorAction Stop }
    catch { throw ('Modulo Microsoft.Graph.Authentication non caricabile: '+$_.Exception.Message) }
    $context=Get-MgContext -ErrorAction SilentlyContinue
    if ($null -ne $context) { Disconnect-MgGraph -ErrorAction Stop | Out-Null }
    $cacheVariable=$ExecutionContext.SessionState.PSVariable.Get('CloudCache')
    if ($null -ne $cacheVariable -and $null -ne $cacheVariable.Value) { $cacheVariable.Value.Clear() }
    $arguments=@{Scopes=@($Scopes);ContextScope='CurrentUser';NoWelcome=$true;ErrorAction='Stop'}
    if ($authentication.AuthenticationMode -eq 'Delegated') {
        # .default returns the permissions already consented to this app. Never
        # expand them on behalf of a feature or silently switch to another app.
        $arguments.Scopes=@('https://graph.microsoft.com/.default')
        $arguments.TenantId=$authentication.TenantId;$arguments.ClientId=$authentication.ClientId;$arguments.Environment='Global'
    }
    $capture=$null; $authWindow=$null; $loginError=$null
    if ($null -ne $ProgressQueue) {
        if (-not ('AssistenteIT.GraphLoginBridge' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'Graph.LoginBridge.cs') -ErrorAction Stop }
        $ProgressQueue.Enqueue([pscustomobject]@{Kind='GraphLoginStarting';Message='Apertura dell''accesso interattivo Microsoft. Completa il login nella finestra Microsoft.';Code=''})
    }
    try {
        # Observe success, information and warning streams, plus the SDK's
        # Console.WriteLine fallback. The UI is already open while networking waits.
        if ($null -ne $ProgressQueue) {
            # The native owner is required by the compiled SDK cmdlet.
            # A caller-provided wrapper owns its authentication UI itself.
            if ((Get-Command Connect-MgGraph -ErrorAction Stop).CommandType -eq 'Cmdlet') { $authWindow=[AssistenteIT.GraphAuthConsole]::Open() }
            $capture=[AssistenteIT.GraphLoginBridge]::Capture($ProgressQueue)
        }
        Connect-MgGraph @arguments 6>&1 3>&1 | ForEach-Object {
            $message=[string]$_
            if ($null -ne $capture) { [void]$capture.TryPublish($message) }
            elseif ($message -match 'https://(?:www\.)?microsoft\.com/devicelogin') {
                Write-Host $message
                if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
                    try { $browser=New-Object Diagnostics.ProcessStartInfo; $browser.FileName='https://microsoft.com/devicelogin'; $browser.UseShellExecute=$true; [void][Diagnostics.Process]::Start($browser) }
                    catch { Write-Warning 'Aprire https://microsoft.com/devicelogin e usare il codice mostrato.' }
                }
            }
            if ($_ -is [Management.Automation.WarningRecord]) { Write-Warning $_.Message }
        }
        $connected=Get-MgContext -ErrorAction Stop
        if ($null -eq $connected -or (Get-ExplorerGraphSetting $connected 'AuthType') -ne 'Delegated' -or
            (Get-ExplorerGraphSetting $connected 'Environment' 'Global') -ne 'Global' -or
            ($authentication.AuthenticationMode -eq 'Delegated' -and -not (Test-ExplorerGraphDelegatedContext $connected $authentication))) {
            throw 'La sessione Graph non corrisponde all''accesso utente configurato. Modulo non aperto.'
        }
        return $connected
    }
    catch { $loginError=$_.Exception.Message; throw }
    finally {
        if ($null -ne $authWindow) { $authWindow.Dispose() }
        if ($null -ne $capture) { $capture.Dispose() }
        if ($null -ne $ProgressQueue) { $ProgressQueue.Enqueue([pscustomobject]@{Kind='GraphLoginComplete';Message='Accesso Graph concluso.';Error=$loginError}) }
    }
}

function Connect-ExplorerGraph {
    [CmdletBinding()]
    param([string[]]$Sources,[switch]$ForRemoval,[switch]$ForBitLocker,$ProgressQueue,$GraphAuthentication)
    # Operation-time checks are deliberately read-only: only the suite wrapper
    # is allowed to authenticate, request consent or select a different identity.
    $authentication=ConvertTo-ExplorerGraphAuthentication $GraphAuthentication
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    $context=Get-MgContext -ErrorAction SilentlyContinue
    if ($null -eq $context -or (Get-ExplorerGraphSetting $context 'AuthType') -ne 'Delegated' -or
        (Get-ExplorerGraphSetting $context 'Environment' 'Global') -ne 'Global' -or
        ($authentication.AuthenticationMode -eq 'Delegated' -and -not (Test-ExplorerGraphDelegatedContext $context $authentication))) {
        throw 'Sessione Graph assente o diversa dalla configurazione. Chiudere il modulo e usare Accesso e verifica nel wrapper Assistente IT.'
    }
    $scopes=Get-ExplorerGraphSetting $context 'Scopes' @()
    $missing=New-Object 'Collections.Generic.List[string]'
    $entraScopes=@('Device.Read.All','Device.ReadWrite.All','Directory.Read.All','Directory.ReadWrite.All','Directory.AccessAsUser.All')
    $intuneScopes=@('DeviceManagementManagedDevices.Read.All','DeviceManagementManagedDevices.ReadWrite.All')
    if ($ForRemoval) { $entraScopes=@('Directory.AccessAsUser.All');$intuneScopes=@('DeviceManagementManagedDevices.ReadWrite.All') }
    if ($Sources -contains 'Entra' -and @($scopes | Where-Object { $_ -in $entraScopes }).Count -eq 0) { [void]$missing.Add($entraScopes[0]) }
    if ($Sources -contains 'Intune' -and @($scopes | Where-Object { $_ -in $intuneScopes }).Count -eq 0) { [void]$missing.Add($intuneScopes[0]) }
    if ($ForBitLocker -and $scopes -notcontains 'BitlockerKey.Read.All') { [void]$missing.Add('BitlockerKey.Read.All') }
    if ($missing.Count) { throw ('Permessi non disponibili nella verifica iniziale: '+($missing.ToArray() -join ', ')+'. Tornare al wrapper per verificare accesso e consensi. Nessuna nuova richiesta viene avviata dal modulo.') }
}

function New-ExplorerGraphOperationError {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Failure,[ValidateSet('InitialRead','IntuneLookup','IntuneIdentity','BitLockerMetadata','BitLockerSecret','BitLockerResponse','Timeout')][string]$Stage='InitialRead')
    # Keep only diagnostic identifiers. Never copy Graph messages, bodies,
    # authorization headers or recovery passwords into the public error.
    $http=0;$code='';$requestId='';$savedStage=''
    $nodes=New-Object 'Collections.Generic.Queue[object]';$nodes.Enqueue($Failure)
    for ($i=0;$i -lt 16 -and $nodes.Count -gt 0;$i++) {
        $node=$nodes.Dequeue()
        if ($null -eq $node) { continue }
        $data=Get-ExplorerGraphSetting $node 'Data'
        foreach ($candidate in @((Get-ExplorerGraphSetting $data 'AssistenteIT.HttpStatus' 0),(Get-ExplorerGraphSetting $node 'ResponseStatusCode' 0),(Get-ExplorerGraphSetting $node 'StatusCode' 0),(Get-ExplorerGraphSetting (Get-ExplorerGraphSetting $node 'Response') 'StatusCode' 0))) {
            try { $value=[int]$candidate;if ($value -ge 400 -and $value -le 599) { $http=$value } } catch { }
        }
        $saved=Get-ExplorerGraphSetting $data 'AssistenteIT.GraphStage' ''
        if ($saved -in @('InitialRead','IntuneLookup','IntuneIdentity','BitLockerMetadata','BitLockerSecret','BitLockerResponse','Timeout')) { $savedStage=[string]$saved }
        if ($node -is [TimeoutException] -or [string](Get-ExplorerGraphSetting $node 'Message' '') -match '^Tempo massimo di lettura BitLocker') { $savedStage='Timeout' }
        $diagnostic=Get-ExplorerGraphSetting $data 'AssistenteIT.GraphCode' ''
        if ([string]$diagnostic -cmatch '^[A-Za-z][A-Za-z0-9_.]{0,79}$') { $code=[string]$diagnostic }
        $correlation=[string](Get-ExplorerGraphSetting $data 'AssistenteIT.RequestId' '')
        $details=Get-ExplorerGraphSetting (Get-ExplorerGraphSetting $node 'ErrorDetails') 'Message' ''
        if ($details -and ([string]$details).Length -le 65536) {
            try {
                $body=ConvertFrom-Json -InputObject ([string]$details) -ErrorAction Stop
                $errorBody=Get-ExplorerGraphSetting $body 'error'
                $diagnostic=[string](Get-ExplorerGraphSetting $errorBody 'code' '')
                if ($diagnostic -cmatch '^[A-Za-z][A-Za-z0-9_.]{0,79}$') { $code=$diagnostic }
                $correlation=[string](Get-ExplorerGraphSetting (Get-ExplorerGraphSetting $errorBody 'innerError') 'request-id' $correlation)
            } catch { }
        }
        $id=[guid]::Empty
        if ([guid]::TryParse($correlation,[ref]$id) -and $id -ne [guid]::Empty) { $requestId=$id.ToString() }
        foreach ($name in @('Exception','InnerException','ErrorRecord')) {
            $child=Get-ExplorerGraphSetting $node $name
            if ($null -ne $child) { $nodes.Enqueue($child) }
        }
    }
    if ($savedStage) { $Stage=$savedStage }
    $stages=@{InitialRead='Verifica accesso';IntuneLookup='Ricerca dispositivo Intune';IntuneIdentity='Verifica Azure AD Device ID';BitLockerMetadata='Elenco metadati BitLocker';BitLockerSecret='Lettura password BitLocker';BitLockerResponse='Verifica risposta BitLocker';Timeout='Tempo massimo di lettura BitLocker superato'}
    $parts=New-Object 'Collections.Generic.List[string]';[void]$parts.Add($stages[$Stage])
    if ($http) { [void]$parts.Add('HTTP '+$http) }
    if ($code) { [void]$parts.Add('Graph '+$code) }
    if ($http -eq 401) { [void]$parts.Add('Sessione non autorizzata o scaduta') }
    elseif ($http -eq 403) { [void]$parts.Add('Accesso negato dal servizio; verificare consenso, ruolo e ambito sul dispositivo') }
    elseif ($http -eq 400) { [void]$parts.Add('Richiesta rifiutata dal servizio') }
    elseif ($http -eq 404) { [void]$parts.Add('Risorsa non trovata') }
    elseif ($http -eq 429) { [void]$parts.Add('Limite richieste raggiunto; riprovare piu tardi') }
    elseif ($http -ge 500) { [void]$parts.Add('Errore del servizio Microsoft') }
    elseif (-not $http -and $Stage -ne 'Timeout') { [void]$parts.Add('Verifica connessione, sessione, identificativi o risposta del servizio necessaria') }
    if ($requestId) { [void]$parts.Add('request-id '+$requestId) }
    $exception=New-Object InvalidOperationException(($parts.ToArray() -join '; '))
    $exception.Data['AssistenteIT.HttpStatus']=$http;$exception.Data['AssistenteIT.GraphCode']=$code
    $exception.Data['AssistenteIT.RequestId']=$requestId;$exception.Data['AssistenteIT.GraphStage']=$Stage
    return $exception
}

function Get-ExplorerGraphPermissionStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Definitions,$Context,$ProgressQueue,[switch]$Probe)
    if ($null -eq $Context) { $Context=Get-MgContext -ErrorAction Stop }
    $scopes=Get-ExplorerGraphSetting $Context 'Scopes' @()
    $statuses=New-Object 'Collections.Generic.List[object]'
    foreach ($definition in @($Definitions)) {
        $alternatives=Get-ExplorerGraphSetting $definition 'AnyOf' @()
        $available=@($alternatives | Where-Object { $scopes -contains $_ }).Count -gt 0
        $detail='Ambito concesso; fattibilita dell''operazione non verificata.'
        $verification='ScopeOnly';$checkStatus='Solo ambito'
        if ([string]$definition.Id -in @('entra-remove','intune-remove')) { $verification='NotTestable';$checkStatus='Non verificabile';$detail='Ambito concesso. Cancellazione non provata: ruolo e diritti sul dispositivo non verificati.' }
        if (-not $available) { $detail='Consenso mancante: '+($alternatives -join ' oppure ');$verification='MissingScope';$checkStatus='Non disponibile' }
        [void]$statuses.Add([pscustomobject]@{Id=[string]$definition.Id;Name=[string]$definition.Name;Available=$available;ScopeGranted=$available;Verification=$verification;OperationVerified=$false;CheckStatus=$checkStatus;Detail=$detail})
    }
    if ($Probe) {
        foreach ($readProbe in @(@{Id='entra-read';Uri='https://graph.microsoft.com/v1.0/devices?$top=1&$select=id'},@{Id='intune-read';Uri='https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?$top=1&$select=id'},@{Id='bitlocker-read';Uri='https://graph.microsoft.com/v1.0/informationProtection/bitlocker/recoveryKeys'})) {
            $status=@($statuses | Where-Object Id -eq $readProbe.Id)
            if ($status.Count -ne 1 -or -not $status[0].Available) { continue }
            if ($null -ne $ProgressQueue) { $ProgressQueue.Enqueue([pscustomobject]@{Kind='Verification';Message=('Verifica lettura: '+$status[0].Name)}) }
            try {
                $arguments=@{Method='GET';Uri=$readProbe.Uri;OutputType='PSObject';ErrorAction='Stop'}
                if ($readProbe.Id -eq 'bitlocker-read') { $arguments.Headers=@{'User-Agent'='AssistenteIT-AccessCheck'} }
                # One metadata page only. No /{keyId}, $select=key, $top or paging.
                $page=Invoke-MgGraphRequest @arguments
                $values=Get-ExplorerGraphSetting $page 'value'
                if ($null -eq $values -or -not ($values -is [Array] -or $values -is [Collections.IList])) { throw 'Risposta Graph non valida.' }
                $status[0].Verification='ReadVerified';$status[0].OperationVerified=$true;$status[0].CheckStatus='Verificata'
                $status[0].Detail='Ambito concesso; GET di lettura riuscita. Accesso limitato agli oggetti autorizzati.'
                if ($readProbe.Id -eq 'bitlocker-read') {
                    $status[0].Verification='MetadataVerified';$status[0].OperationVerified=$false;$status[0].CheckStatus='Parziale'
                    $status[0].Detail='Elenco metadati accessibile. Password non richiesta; lettura della chiave sul dispositivo non verificata.'
                }
            }
            catch {
                $stage='InitialRead';if ($readProbe.Id -eq 'bitlocker-read') { $stage='BitLockerMetadata' }
                $safeError=New-ExplorerGraphOperationError -Failure $_ -Stage $stage
                $status[0].Available=$false;$status[0].Verification='ProbeFailed';$status[0].CheckStatus='Non disponibile';$status[0].OperationVerified=$false
                $status[0].Detail='Ambito concesso, ma verifica non riuscita: '+$safeError.Message
            }
        }
    }
    foreach ($pair in @(@{Read='entra-read';Remove='entra-remove'},@{Read='intune-read';Remove='intune-remove'})) {
        $readStatus=@($statuses | Where-Object Id -eq $pair.Read)
        $removeStatus=@($statuses | Where-Object Id -eq $pair.Remove)
        if ($readStatus.Count -eq 1 -and -not $readStatus[0].Available -and $removeStatus.Count -eq 1 -and $removeStatus[0].Available) {
            $removeStatus[0].Available=$false;$removeStatus[0].Verification='PrerequisiteFailed';$removeStatus[0].CheckStatus='Non disponibile';$removeStatus[0].Detail='Lettura della fonte non disponibile nella verifica iniziale: ripetere la verifica prima delle eliminazioni.'
        }
    }
    return @($statuses.ToArray())
}

