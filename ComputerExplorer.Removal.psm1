#requires -version 5.1
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'ComputerExplorer.Core.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'BitLocker.Archive.psm1') -ErrorAction Stop
$script:RemovalPlans = @{}

function Get-RemovalValue {
    param($Object, [string]$Name, $Default = $null)
    if ($null -ne $Object) {
        $property = $Object.PSObject.Properties[$Name]
        if ($null -ne $property) { return ,$property.Value }
    }
    return ,$Default
}

function Initialize-RemovalSources {
    param([string[]]$Sources,$ProgressQueue,[switch]$ArchiveOnly)
    if ($Sources -contains 'AD') { Import-Module ActiveDirectory -ErrorAction Stop }
    $cloud = @($Sources | Where-Object { $_ -in @('Entra', 'Intune') })
    if ($cloud.Count -gt 0) { Connect-ExplorerGraph -Sources $cloud -ForRemoval:(-not $ArchiveOnly) -ForBitLocker -ProgressQueue $ProgressQueue }
}

function Get-RemovalContextKey {
    param([string[]]$Sources)
    if (@($Sources | Where-Object { $_ -in @('Entra', 'Intune') }).Count -eq 0) { return 'AD' }
    $context = Get-MgContext -ErrorAction Stop
    if ($null -eq $context) { throw 'Sessione Graph assente.' }
    return (@('TenantId', 'ClientId', 'Account', 'AuthType', 'Environment') | ForEach-Object { [string](Get-RemovalValue $context $_) }) -join '|'
}

function ConvertTo-RemovalId {
    param($Value)
    $id = [guid]::Empty
    if (-not [guid]::TryParse([string]$Value, [ref]$id) -or $id -eq [guid]::Empty) { throw 'Identificativo oggetto non valido.' }
    return $id.ToString()
}

function Get-RemovalAdChildren {
    param($Computer, [string]$Server)
    if ([bool](Get-RemovalValue $Computer 'ProtectedFromAccidentalDeletion' $false)) {
        throw ('Computer AD protetto da eliminazione accidentale: ' + $Computer.DistinguishedName)
    }
    $rootId = ConvertTo-RemovalId $Computer.ObjectGUID
    $rootDn = [string]$Computer.DistinguishedName
    if ([string]::IsNullOrWhiteSpace($rootDn)) { throw 'Percorso del computer AD assente.' }
    # Leggere solo metadati: nessuna password o chiave di recupero BitLocker.
    $records = @(Get-ADObject -Server $Server -SearchBase $rootDn -SearchScope Subtree -LDAPFilter '(objectClass=*)' -Properties @('ObjectGUID', 'ProtectedFromAccidentalDeletion') -ErrorAction Stop)
    $baseSeen = $false
    $children = New-Object 'System.Collections.Generic.List[object]'
    foreach ($record in $records) {
        $id = ConvertTo-RemovalId $record.ObjectGUID
        $dn = [string]$record.DistinguishedName
        if ($id -eq $rootId) {
            if (-not [string]::Equals($dn, $rootDn, [StringComparison]::OrdinalIgnoreCase) -or $record.ObjectClass -ne 'computer') {
                throw 'La base della ricerca AD non corrisponde al computer verificato.'
            }
            if ([bool]$record.ProtectedFromAccidentalDeletion) { throw ('Computer AD protetto da eliminazione accidentale: ' + $rootDn) }
            $baseSeen = $true
            continue
        }
        if (-not $dn.EndsWith(',' + $rootDn, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'La lettura AD contiene un oggetto esterno al computer selezionato.'
        }
        if ([bool]$record.ProtectedFromAccidentalDeletion) { throw ('Oggetto figlio AD protetto da eliminazione accidentale: ' + $dn) }
        [void]$children.Add([pscustomobject]@{
            Id = $id; DistinguishedName = $dn; ObjectClass = [string]$record.ObjectClass
        })
    }
    if (-not $baseSeen) { throw 'Impossibile verificare la base della ricerca degli oggetti figli AD. Ripetere la verifica.' }
    return @($children.ToArray() | Sort-Object Id -Unique)
}

function Test-RemovalSameAdChild {
    param($Expected, $Current)
    foreach ($field in @('Id', 'DistinguishedName', 'ObjectClass')) {
        if (-not [string]::Equals([string]$Expected.$field, [string]$Current.$field, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    return $true
}

function Read-RemovalAdChildById {
    param($Child, $Target)
    try {
        $record = Get-ADObject -Server $Target.DomainController -Identity ([guid](ConvertTo-RemovalId $Child.Id)) -Properties @('ObjectGUID', 'ProtectedFromAccidentalDeletion') -ErrorAction Stop
        if ([bool]$record.ProtectedFromAccidentalDeletion) { throw ('Oggetto figlio AD protetto da eliminazione accidentale: ' + $record.DistinguishedName) }
        $current = [pscustomobject]@{ Id = ConvertTo-RemovalId $record.ObjectGUID; DistinguishedName = [string]$record.DistinguishedName; ObjectClass = [string]$record.ObjectClass }
        if (-not (Test-RemovalSameAdChild $Child $current) -or
            -not $current.DistinguishedName.EndsWith(',' + $Target.DistinguishedName, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Un oggetto figlio AD ha cambiato identità o percorso. Ripetere la verifica.'
        }
        return $current
    }
    catch { if (Test-RemovalNotFound $_) { return $null }; throw }
}

function Get-RemovalTargets {
    param([string]$Name, [string[]]$Sources, [string[]]$Controllers)
    $targets = New-Object 'System.Collections.Generic.List[object]'
    if ($Sources -contains 'AD') {
        if ($Controllers.Count -eq 0) { throw 'Nessun DC configurato.' }
        $escaped = $Name.Replace('\', '\5c').Replace('*', '\2a').Replace('(', '\28').Replace(')', '\29').Replace([string][char]0, '\00')
        foreach ($dc in $Controllers) {
            $found = @(Get-ADComputer -Server $dc -LDAPFilter ('(name={0})' -f $escaped) -Properties @('DistinguishedName', 'ObjectGUID', 'ProtectedFromAccidentalDeletion') -ErrorAction Stop)
            foreach ($computer in $found) {
                if (-not [string]::Equals([string]$computer.Name, $Name, [StringComparison]::OrdinalIgnoreCase)) { throw 'Risposta AD estranea al nome esatto richiesto.' }
                [void]$targets.Add([pscustomobject]@{
                    Source = 'AD'; Name = [string]$computer.Name; Id = ConvertTo-RemovalId $computer.ObjectGUID; DomainController = $dc
                    DistinguishedName = [string]$computer.DistinguishedName; LinkId = ''; SerialNumber = ''; OperatingSystem = ''
                    AdChildren = @(Get-RemovalAdChildren -Computer $computer -Server $dc)
                })
            }
        }
    }
    foreach ($source in @($Sources | Where-Object { $_ -in @('Entra', 'Intune') })) {
        $safeName = $Name.Replace("'", "''")
        if ($source -eq 'Entra') {
            $path = '/v1.0/devices'; $nameProperty = 'displayName'
            $select = 'id,displayName,deviceId'
        }
        else {
            $path = '/v1.0/deviceManagement/managedDevices'; $nameProperty = 'deviceName'
            $select = 'id,deviceName,azureADDeviceId,serialNumber,operatingSystem'
        }
        $filter = [Uri]::EscapeDataString(("{0} eq '{1}'" -f $nameProperty, $safeName))
        $uri = 'https://graph.microsoft.com{0}?$filter={1}&$select={2}' -f $path, $filter, $select
        $records = @(Get-ExplorerGraphCollection -Uri $uri -ResourcePath $path)
        foreach ($record in $records) {
            $recordName = [string](Get-RemovalValue $record $nameProperty)
            if (-not [string]::Equals($recordName, $Name, [StringComparison]::OrdinalIgnoreCase)) { continue }
            $link = [string](Get-RemovalValue $record 'deviceId')
            $os = ''; $serial = ''
            if ($source -eq 'Intune') {
                $os = [string](Get-RemovalValue $record 'operatingSystem')
                if ($os -ne 'Windows') { continue }
                $link = [string](Get-RemovalValue $record 'azureADDeviceId')
                $serial = [string](Get-RemovalValue $record 'serialNumber')
            }
            [void]$targets.Add([pscustomobject]@{
                Source = $source; Name = $recordName; Id = ConvertTo-RemovalId (Get-RemovalValue $record 'id'); DomainController = ''
                DistinguishedName = ''; LinkId = $link; SerialNumber = $serial; OperatingSystem = $os
            })
        }
    }
    # Emettere dati solo al termine di tutte le letture per questa macchina.
    return @($targets.ToArray() | Sort-Object Source, DomainController, Id -Unique)
}

function Get-RemovalTargetKey {
    param($Target)
    return '{0}|{1}|{2}' -f $Target.Source, $Target.DomainController.ToUpperInvariant(), $Target.Id.ToLowerInvariant()
}

function Test-RemovalSameTarget {
    param($Expected, $Current)
    foreach ($field in @('Source', 'Name', 'Id', 'DomainController', 'DistinguishedName', 'LinkId', 'SerialNumber', 'OperatingSystem')) {
        if (-not [string]::Equals([string]$Expected.$field, [string]$Current.$field, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    if ($Expected.Source -eq 'AD') {
        $expectedChildren = @{}
        foreach ($child in $Expected.AdChildren) { $expectedChildren[$child.Id] = $child }
        # Figli già assenti sono ammessi; aggiunte, spostamenti e nuove protezioni bloccano il piano.
        foreach ($child in $Current.AdChildren) {
            if (-not $expectedChildren.ContainsKey($child.Id) -or -not (Test-RemovalSameAdChild $expectedChildren[$child.Id] $child)) { return $false }
        }
    }
    return $true
}

function Send-RemovalProgress {
    param($Queue, [string]$Message, $Result = $null)
    if ($null -ne $Queue) { $Queue.Enqueue([pscustomobject]@{ Kind = 'RemovalProgress'; Message = $Message; Result = $Result }) }
}

function Get-RemovalBitLockerPreview {
    param([string]$Name,$Targets,$Settings,$Credentials)
    Get-ExplorerBitLockerPreview -Name $Name -Targets $Targets -Settings $Settings -UserToken (Get-RemovalValue $Credentials 'User') -AppToken (Get-RemovalValue $Credentials 'App')
}

function Save-RemovalBitLockerBackup {
    param($Preview,$Targets,$Plan,$ProgressQueue)
    Save-ExplorerBitLockerArchive -Preview $Preview -Targets $Targets -Settings $Plan.GlpiSettings -UserToken (Get-RemovalValue $Plan.Credentials 'User') -AppToken (Get-RemovalValue $Plan.Credentials 'App') -ProgressQueue $ProgressQueue
}

function Test-RemovalBitLockerCoverage {
    param($Target,$Receipt)
    foreach ($key in @(Get-ExplorerBitLockerKeys -Targets @($Target))) {
        $saved=@($Receipt.Keys | Where-Object { $_.KeyId -eq $key.KeyId -and $_.Fingerprint -eq $key.Fingerprint })
        if ($saved.Count -ne 1) { throw 'Una chiave BitLocker non e coperta dal backup verificato. Ripetere archiviazione e anteprima.' }
    }
}

function New-ExplorerRemovalPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$Names,
        [Parameter(Mandatory = $true)][ValidateSet('AD', 'Entra', 'Intune')][string[]]$Sources,
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        $GlpiCredentials,
        [switch]$ArchiveOnly,
        $ProgressQueue
    )
    $script:RemovalPlans.Clear()
    $namesToRead = @($Names | ForEach-Object {
        $name = $_.Trim()
        if ($name.Length -eq 0 -or $name.Length -gt 255 -or $name -match '[\x00-\x1f]') { throw 'Nome completo non valido nella selezione.' }
        $name
    } | Sort-Object -Unique)
    $selectedSources = @($Sources | Sort-Object -Unique)
    if ($namesToRead.Count -eq 0 -or $selectedSources.Count -eq 0) { throw 'Selezionare computer e origini da eliminare.' }
    $config = Read-ExplorerConfiguration $ConfigPath
    $controllersProperty = $config.Settings.PSObject.Properties['DomainControllers']
    $controllers = @()
    if ($null -ne $controllersProperty) { $controllers = @($controllersProperty.Value | ForEach-Object { ([string]$_).Trim() } | Sort-Object -Unique) }
    if ($selectedSources -contains 'AD' -and ($controllers.Count -eq 0 -or $controllers -contains '')) { throw 'Domain Controller non configurati correttamente.' }
    Initialize-RemovalSources $selectedSources $ProgressQueue -ArchiveOnly:$ArchiveOnly
    $contextKey = Get-RemovalContextKey $selectedSources
    $entries = New-Object 'System.Collections.Generic.List[object]'
    foreach ($name in $namesToRead) {
        Send-RemovalProgress $ProgressQueue ("Verifica oggetti: $name")
        $targets = @(); $errorText = $null; $backup=$null
        try {
            $targets = @(Get-RemovalTargets -Name $name -Sources $selectedSources -Controllers $controllers)
            if ($targets.Count -gt 0) { $backup=Get-RemovalBitLockerPreview -Name $name -Targets $targets -Settings (Get-RemovalValue $config.Settings 'Glpi') -Credentials $GlpiCredentials }
        }
        catch { $errorText = $_.Exception.Message }
        [void]$entries.Add([pscustomobject]@{ Name = $name; Targets = $targets; Error = $errorText; Backup=$backup })
    }
    if ((Get-RemovalContextKey $selectedSources) -ne $contextKey) { throw 'La sessione Graph è cambiata durante la verifica. Ripetere la preparazione.' }
    $planId = [guid]::NewGuid().ToString()
    $created = [datetimeoffset]::UtcNow
    $script:RemovalPlans[$planId] = [pscustomobject]@{
        Id = $planId; CreatedAtUtc = $created; Sources = $selectedSources; Controllers = $controllers
        ContextKey = $contextKey; Entries = $entries.ToArray(); ArchiveOnly=[bool]$ArchiveOnly; GlpiSettings=(Get-RemovalValue $config.Settings 'Glpi'); Credentials=$GlpiCredentials
    }
    # La vista passata alla UI non contiene gli oggetti interni del piano.
    $view = @($entries | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Error = $_.Error; Backup=$_.Backup | Select-Object ComputerId,Name,Serial,EntityId,RequiresMappingConfirmation,@{Name='KeyCount';Expression={$_.Keys.Count}},@{Name='Keys';Expression={@($_.Keys | Select-Object KeyId,Volume,CreatedAt,@{Name='Origins';Expression={@($_.Origins | ForEach-Object {[string]$_})}})}}; Targets = @($_.Targets | ForEach-Object {
            $copy = $_ | Select-Object Source, Name, Id, DomainController, DistinguishedName, LinkId, SerialNumber, OperatingSystem
            $children = @((Get-RemovalValue $_ 'AdChildren' @()) | ForEach-Object { $_ | Select-Object Id, DistinguishedName, ObjectClass })
            $copy | Add-Member -NotePropertyName AdChildren -NotePropertyValue $children
            $copy
        }) }
    })
    [pscustomobject]@{ PlanId = $planId; CreatedAtUtc = $created; Sources = $selectedSources.Clone(); Entries = $view; ArchiveOnly=[bool]$ArchiveOnly }
}

function Test-RemovalNotFound {
    param($ErrorRecord)
    if ($ErrorRecord.Exception.GetType().FullName -like '*ADIdentityNotFoundException' -or
        $ErrorRecord.FullyQualifiedErrorId -like '*ADIdentityNotFoundException*') { return $true }
    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        $response = Get-RemovalValue $exception 'Response'
        foreach ($value in @((Get-RemovalValue $exception 'ResponseStatusCode'), (Get-RemovalValue $exception 'StatusCode'), (Get-RemovalValue $response 'StatusCode'))) {
            if ($null -ne $value) { try { if ([int]$value -eq 404) { return $true } } catch { } }
        }
        $exception = $exception.InnerException
    }
    return $false
}

function Read-RemovalTargetById {
    param($Target)
    try {
        if ($Target.Source -eq 'AD') {
            $record = Get-ADComputer -Server $Target.DomainController -Identity ([guid]$Target.Id) -Properties @('DistinguishedName', 'ObjectGUID', 'ProtectedFromAccidentalDeletion') -ErrorAction Stop
            return [pscustomobject]@{
                Source = 'AD'; Name = [string]$record.Name; Id = ConvertTo-RemovalId $record.ObjectGUID; DomainController = $Target.DomainController
                DistinguishedName = [string]$record.DistinguishedName; LinkId = ''; SerialNumber = ''; OperatingSystem = ''
                AdChildren = @(Get-RemovalAdChildren -Computer $record -Server $Target.DomainController)
            }
        }
        $path = '/v1.0/devices'; $nameField = 'displayName'; $linkField = 'deviceId'; $select = 'id,displayName,deviceId'
        if ($Target.Source -eq 'Intune') {
            $path = '/v1.0/deviceManagement/managedDevices'; $nameField = 'deviceName'; $linkField = 'azureADDeviceId'
            $select = 'id,deviceName,azureADDeviceId,serialNumber,operatingSystem'
        }
        $uri = 'https://graph.microsoft.com{0}/{1}?$select={2}' -f $path, (ConvertTo-RemovalId $Target.Id), $select
        $record = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject -ErrorAction Stop
        $os = ''; $serial = ''
        if ($Target.Source -eq 'Intune') { $os = [string](Get-RemovalValue $record 'operatingSystem'); $serial = [string](Get-RemovalValue $record 'serialNumber') }
        return [pscustomobject]@{
            Source = $Target.Source; Name = [string](Get-RemovalValue $record $nameField); Id = ConvertTo-RemovalId (Get-RemovalValue $record 'id')
            DomainController = ''; DistinguishedName = ''; LinkId = [string](Get-RemovalValue $record $linkField); SerialNumber = $serial; OperatingSystem = $os
        }
    }
    catch { if (Test-RemovalNotFound $_) { return $null }; throw }
}

function Remove-RemovalTarget {
    param($Target, $Results, $ProgressQueue)
    if ($Target.Source -eq 'AD') {
        # Niente cancellazione ricorsiva: eliminare esclusivamente i GUID confermati,
        # dai discendenti più profondi al computer. Eventuali nuovi figli restano intatti.
        foreach ($child in @($Target.AdChildren | Sort-Object @{Expression={$_.DistinguishedName.Length};Descending=$true}, Id)) {
            $state = 'Eliminato'; $errorText = ''
            try {
                $live = Read-RemovalAdChildById $child $Target
                if ($null -eq $live) { $state = 'Già assente' }
                else {
                    try { Remove-ADObject -Server $Target.DomainController -Identity ([guid]$child.Id) -Confirm:$false -ErrorAction Stop }
                    catch { if (Test-RemovalNotFound $_) { $state = 'Già assente' } else { throw } }
                }
            }
            catch { $state = 'Errore'; $errorText = $_.Exception.Message }
            $result = New-RemovalResult $Target.Name 'AD (figlio)' $Target.DomainController $child.Id $state $errorText
            [void]$Results.Add($result); Send-RemovalProgress $ProgressQueue ($Target.Name + ' - AD (figlio): ' + $state) $result
            if ($state -eq 'Errore') { throw ('Rimozione oggetto figlio AD interrotta: ' + $errorText) }
        }
        Remove-ADComputer -Server $Target.DomainController -Identity ([guid](ConvertTo-RemovalId $Target.Id)) -Confirm:$false -ErrorAction Stop
    }
    elseif ($Target.Source -eq 'Intune') {
        if ($Target.OperatingSystem -ne 'Windows') { throw 'Rimozione Intune consentita soltanto per Windows.' }
        $uri = 'https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/{0}' -f (ConvertTo-RemovalId $Target.Id)
        Invoke-MgGraphRequest -Method DELETE -Uri $uri -ErrorAction Stop | Out-Null
    }
    elseif ($Target.Source -eq 'Entra') {
        $uri = 'https://graph.microsoft.com/v1.0/devices/{0}' -f (ConvertTo-RemovalId $Target.Id)
        Invoke-MgGraphRequest -Method DELETE -Uri $uri -ErrorAction Stop | Out-Null
    }
    else { throw 'Origine di rimozione non consentita.' }
}

function New-RemovalResult {
    param([string]$Name, [string]$Source, [string]$Destination, [string]$Id, [string]$State, [string]$ErrorText)
    [pscustomobject]@{ Name = $Name; Source = $Source; Destination = $Destination; Id = $Id; State = $State; Error = $ErrorText }
}

function Invoke-ExplorerRemovalPlan {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)][string]$PlanId,
        $ProgressQueue,
        [Threading.CancellationTokenSource]$Cancellation,
        [switch]$IncludeAdChildren,
        [switch]$ConfirmGlpiMapping
    )
    if (-not $script:RemovalPlans.ContainsKey($PlanId)) { throw 'Anteprima non valida o già utilizzata. Ripetere la verifica.' }
    $plan = $script:RemovalPlans[$PlanId]
    $script:RemovalPlans.Remove($PlanId)
    if (([datetimeoffset]::UtcNow - $plan.CreatedAtUtc).TotalMinutes -gt 5) { throw 'Anteprima scaduta. Ripetere la verifica.' }
    Initialize-RemovalSources $plan.Sources $ProgressQueue -ArchiveOnly:$plan.ArchiveOnly
    if ((Get-RemovalContextKey $plan.Sources) -ne $plan.ContextKey) { throw 'Account o tenant Graph cambiato. Ripetere la verifica.' }
    $results = New-Object 'System.Collections.Generic.List[object]'
    $writesAttempted = $false; $archived=0
    $order = @{ Intune = 0; AD = 1; Entra = 2 }
    try {
        foreach ($entry in $plan.Entries) {
            $reason = $entry.Error
            $state = 'Bloccato'
            if ($null -ne $Cancellation -and $Cancellation.IsCancellationRequested) { $reason = 'Interruzione richiesta prima di questo computer.'; $state = 'Annullato' }
            if ([string]::IsNullOrWhiteSpace($reason) -and -not $IncludeAdChildren -and -not $plan.ArchiveOnly -and
                @($entry.Targets | Where-Object { $_.Source -eq 'AD' -and $_.AdChildren.Count -gt 0 }).Count -gt 0) {
                $reason = 'Il computer contiene oggetti figli AD. Confermare esplicitamente la loro eliminazione nell''anteprima, incluse eventuali informazioni di recupero BitLocker.'
            }
            if ([string]::IsNullOrWhiteSpace($reason) -and $null -ne $entry.Backup -and $entry.Backup.RequiresMappingConfirmation -and -not $ConfirmGlpiMapping) { $reason='Confermare esplicitamente l''abbinamento alla scheda GLPI: le fonti selezionate non consentono un confronto completo dei seriali.' }
            if ([string]::IsNullOrWhiteSpace($reason)) {
                try {
                    if ((Get-RemovalContextKey $plan.Sources) -ne $plan.ContextKey) { throw 'Sessione Graph cambiata.' }
                    Send-RemovalProgress $ProgressQueue ("Rilettura prima di eliminare: " + $entry.Name)
                    $current = @(Get-RemovalTargets -Name $entry.Name -Sources $plan.Sources -Controllers $plan.Controllers)
                    $expected = @{}
                    foreach ($target in $entry.Targets) { $expected[(Get-RemovalTargetKey $target)] = $target }
                    foreach ($target in $current) {
                        $key = Get-RemovalTargetKey $target
                        if (-not $expected.ContainsKey($key) -or -not (Test-RemovalSameTarget $expected[$key] $target)) {
                            throw 'Gli oggetti sono cambiati dopo la anteprima. Ripetere la verifica.'
                        }
                    }
                    foreach ($target in $entry.Targets) {
                        $live = Read-RemovalTargetById $target
                        if ($null -ne $live -and -not (Test-RemovalSameTarget $target $live)) {
                            throw 'Un oggetto verificato per ID o i suoi figli AD sono cambiati. Ripetere la verifica.'
                        }
                        if ($null -ne $live -and $target.Source -eq 'AD') {
                            foreach ($child in $target.AdChildren) { [void](Read-RemovalAdChildById $child $target) }
                        }
                    }
                    if ($null -ne $entry.Backup) {
                        $freshBackup=Get-RemovalBitLockerPreview -Name $entry.Name -Targets $current -Settings $plan.GlpiSettings -Credentials $plan.Credentials
                        if (-not (Test-ExplorerBitLockerSnapshot $entry.Backup $freshBackup)) { throw 'Identita GLPI o chiavi BitLocker cambiate dopo l''anteprima.' }
                    }
                    if ((Get-RemovalContextKey $plan.Sources) -ne $plan.ContextKey) { throw 'Sessione Graph cambiata durante la verifica.' }
                }
                catch { $reason = $_.Exception.Message }
            }
            if (-not [string]::IsNullOrWhiteSpace($reason)) {
                $result = New-RemovalResult $entry.Name 'Verifica' '' '' $state $reason
                [void]$results.Add($result); Send-RemovalProgress $ProgressQueue $entry.Name $result
                continue
            }
            if ($entry.Targets.Count -eq 0) {
                $result = New-RemovalResult $entry.Name 'Verifica' '' '' 'Già assente' ''
                [void]$results.Add($result); Send-RemovalProgress $ProgressQueue $entry.Name $result
                continue
            }
            if (-not $PSCmdlet.ShouldProcess(('GLPI: '+$entry.Name+' / '+$entry.Backup.ComputerId), 'Archivia e verifica le chiavi BitLocker')) {
                foreach ($target in $entry.Targets) { [void]$results.Add((New-RemovalResult $entry.Name $target.Source $target.DomainController $target.Id 'Simulato' '')) }
                continue
            }
            try {
                $receipt=Save-RemovalBitLockerBackup -Preview $entry.Backup -Targets $current -Plan $plan -ProgressQueue $ProgressQueue
                $archived+=$receipt.Count
                $backupResult=New-RemovalResult $entry.Name 'BitLocker' ('GLPI '+$entry.Backup.ComputerId) '' 'Archiviato' ($receipt.Count.ToString()+' chiavi verificate')
                [void]$results.Add($backupResult); Send-RemovalProgress $ProgressQueue $entry.Name $backupResult
            }
            catch {
                $backupResult=New-RemovalResult $entry.Name 'BitLocker' '' '' 'Bloccato' $_.Exception.Message
                [void]$results.Add($backupResult); Send-RemovalProgress $ProgressQueue $entry.Name $backupResult
                continue
            }
            if ($plan.ArchiveOnly) { continue }
            $blocked = $false
            foreach ($target in @($entry.Targets | Sort-Object @{ Expression = { $order[$_.Source] } }, DomainController, Id)) {
                $errorText = ''; $targetState = 'Eliminato'
                if ($blocked) { $targetState = 'Saltato'; $errorText = 'Interrotto per errore precedente su questo computer.' }
                else {
                    try {
                        $live = Read-RemovalTargetById $target
                        if ($null -eq $live) { $targetState = 'Già assente' }
                        elseif (-not (Test-RemovalSameTarget $target $live)) { throw 'Identità, nome o piattaforma cambiati dopo la verifica.' }
                        elseif ($PSCmdlet.ShouldProcess(('{0}: {1} / {2} / {3}' -f $target.Source, $target.Name, $target.DomainController, $target.Id), 'Elimina registrazione')) {
                            Test-RemovalBitLockerCoverage -Target $live -Receipt $receipt
                            $writesAttempted = $true
                            try { Remove-RemovalTarget -Target $target -Results $results -ProgressQueue $ProgressQueue }
                            catch { if (Test-RemovalNotFound $_) { $targetState = 'Già assente' } else { throw } }
                        }
                        else { $targetState = 'Simulato' }
                    }
                    catch { $targetState = 'Errore'; $errorText = $_.Exception.Message; $blocked = $true }
                }
                $result = New-RemovalResult $entry.Name $target.Source $target.DomainController $target.Id $targetState $errorText
                [void]$results.Add($result); Send-RemovalProgress $ProgressQueue ($entry.Name + ' - ' + $target.Source + ': ' + $targetState) $result
            }
        }
    }
    finally { if ($writesAttempted) { Clear-ExplorerCloudCache } }
    [pscustomobject]@{
        Results = $results.ToArray(); WritesAttempted = $writesAttempted; Archived=$archived; ArchiveOnly=$plan.ArchiveOnly
        Deleted = @($results | Where-Object { $_.State -eq 'Eliminato' }).Count
        Failed = @($results | Where-Object { $_.State -in @('Errore', 'Bloccato') }).Count
    }
}

Export-ModuleMember -Function New-ExplorerRemovalPlan, Invoke-ExplorerRemovalPlan
