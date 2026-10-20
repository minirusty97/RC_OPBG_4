#requires -version 5.1
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'ComputerExplorer.Core.psm1') -ErrorAction Stop
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
    param([string[]]$Sources,$ProgressQueue)
    if ($Sources -contains 'AD') { Import-Module ActiveDirectory -ErrorAction Stop }
    $cloud = @($Sources | Where-Object { $_ -in @('Entra', 'Intune') })
    if ($cloud.Count -gt 0) { Connect-ExplorerGraph -Sources $cloud -ForRemoval -ProgressQueue $ProgressQueue }
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

function Get-RemovalTargets {
    param([string]$Name, [string[]]$Sources, [string[]]$Controllers)
    $targets = New-Object 'System.Collections.Generic.List[object]'
    if ($Sources -contains 'AD') {
        if ($Controllers.Count -eq 0) { throw 'Nessun DC configurato.' }
        $escaped = $Name.Replace('\', '\5c').Replace('*', '\2a').Replace('(', '\28').Replace(')', '\29').Replace([string][char]0, '\00')
        foreach ($dc in $Controllers) {
            $found = @(Get-ADComputer -Server $dc -LDAPFilter ('(name={0})' -f $escaped) -Properties @('DistinguishedName', 'ObjectGUID') -ErrorAction Stop)
            foreach ($computer in $found) {
                if (-not [string]::Equals([string]$computer.Name, $Name, [StringComparison]::OrdinalIgnoreCase)) { throw 'Risposta AD estranea al nome esatto richiesto.' }
                [void]$targets.Add([pscustomobject]@{
                    Source = 'AD'; Name = [string]$computer.Name; Id = ConvertTo-RemovalId $computer.ObjectGUID; DomainController = $dc
                    DistinguishedName = [string]$computer.DistinguishedName; LinkId = ''; SerialNumber = ''; OperatingSystem = ''
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
    foreach ($field in @('Source', 'Name', 'Id', 'DomainController', 'LinkId', 'SerialNumber', 'OperatingSystem')) {
        if (-not [string]::Equals([string]$Expected.$field, [string]$Current.$field, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    return $true
}

function Send-RemovalProgress {
    param($Queue, [string]$Message, $Result = $null)
    if ($null -ne $Queue) { $Queue.Enqueue([pscustomobject]@{ Kind = 'RemovalProgress'; Message = $Message; Result = $Result }) }
}

function New-ExplorerRemovalPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$Names,
        [Parameter(Mandatory = $true)][ValidateSet('AD', 'Entra', 'Intune')][string[]]$Sources,
        [Parameter(Mandatory = $true)][string]$ConfigPath,
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
    Initialize-RemovalSources $selectedSources $ProgressQueue
    $contextKey = Get-RemovalContextKey $selectedSources
    $entries = New-Object 'System.Collections.Generic.List[object]'
    foreach ($name in $namesToRead) {
        Send-RemovalProgress $ProgressQueue ("Verifica oggetti: $name")
        $targets = @(); $errorText = $null
        try { $targets = @(Get-RemovalTargets -Name $name -Sources $selectedSources -Controllers $controllers) }
        catch { $errorText = $_.Exception.Message }
        [void]$entries.Add([pscustomobject]@{ Name = $name; Targets = $targets; Error = $errorText })
    }
    if ((Get-RemovalContextKey $selectedSources) -ne $contextKey) { throw 'La sessione Graph è cambiata durante la verifica. Ripetere la preparazione.' }
    $planId = [guid]::NewGuid().ToString()
    $created = [datetimeoffset]::UtcNow
    $script:RemovalPlans[$planId] = [pscustomobject]@{
        Id = $planId; CreatedAtUtc = $created; Sources = $selectedSources; Controllers = $controllers
        ContextKey = $contextKey; Entries = $entries.ToArray()
    }
    # La vista passata alla UI non contiene gli oggetti interni del piano.
    $view = @($entries | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Error = $_.Error; Targets = @($_.Targets | Select-Object Source, Name, Id, DomainController, DistinguishedName, LinkId, SerialNumber, OperatingSystem) }
    })
    [pscustomobject]@{ PlanId = $planId; CreatedAtUtc = $created; Sources = $selectedSources.Clone(); Entries = $view }
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
            $record = Get-ADComputer -Server $Target.DomainController -Identity ([guid]$Target.Id) -Properties @('DistinguishedName', 'ObjectGUID') -ErrorAction Stop
            return [pscustomobject]@{
                Source = 'AD'; Name = [string]$record.Name; Id = ConvertTo-RemovalId $record.ObjectGUID; DomainController = $Target.DomainController
                DistinguishedName = [string]$record.DistinguishedName; LinkId = ''; SerialNumber = ''; OperatingSystem = ''
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
    param($Target)
    if ($Target.Source -eq 'AD') {
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
        [Threading.CancellationTokenSource]$Cancellation
    )
    if (-not $script:RemovalPlans.ContainsKey($PlanId)) { throw 'Anteprima non valida o già utilizzata. Ripetere la verifica.' }
    $plan = $script:RemovalPlans[$PlanId]
    $script:RemovalPlans.Remove($PlanId)
    if (([datetimeoffset]::UtcNow - $plan.CreatedAtUtc).TotalMinutes -gt 5) { throw 'Anteprima scaduta. Ripetere la verifica.' }
    Initialize-RemovalSources $plan.Sources $ProgressQueue
    if ((Get-RemovalContextKey $plan.Sources) -ne $plan.ContextKey) { throw 'Account o tenant Graph cambiato. Ripetere la verifica.' }
    $results = New-Object 'System.Collections.Generic.List[object]'
    $writesAttempted = $false
    $order = @{ Intune = 0; AD = 1; Entra = 2 }
    try {
        foreach ($entry in $plan.Entries) {
            $reason = $entry.Error
            $state = 'Bloccato'
            if ($null -ne $Cancellation -and $Cancellation.IsCancellationRequested) { $reason = 'Interruzione richiesta prima di questo computer.'; $state = 'Annullato' }
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
                            throw 'Un oggetto verificato per ID ha cambiato identita. Ripetere la verifica.'
                        }
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
                            $writesAttempted = $true
                            try { Remove-RemovalTarget $target }
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
        Results = $results.ToArray(); WritesAttempted = $writesAttempted
        Deleted = @($results | Where-Object { $_.State -eq 'Eliminato' }).Count
        Failed = @($results | Where-Object { $_.State -in @('Errore', 'Bloccato') }).Count
    }
}

Export-ModuleMember -Function New-ExplorerRemovalPlan, Invoke-ExplorerRemovalPlan
