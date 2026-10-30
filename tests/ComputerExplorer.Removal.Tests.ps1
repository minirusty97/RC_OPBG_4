#requires -version 5.1
[CmdletBinding()]
param([string]$ModulePath = (Join-Path $PSScriptRoot '../ComputerExplorer.Removal.psm1'))
$ErrorActionPreference = 'Stop'
$module = Import-Module $ModulePath -Force -PassThru
try {
    & $module {
        $script:Fixture = @{}
        function script:New-TestId { param([int]$Number) return ('{0:x8}-0000-4000-8000-000000000001' -f $Number) }
        function script:Reset-Fixture {
            $script:RemovalPlans.Clear()
            $script:Fixture = @{
                Mode = ''; Context = 'tenant|account'; Writes = (New-Object 'System.Collections.Generic.List[object]')
                Children = @(); ChildReads = (New-Object 'System.Collections.Generic.List[object]')
                Reads = (New-Object 'System.Collections.Generic.List[object]'); CacheCleared = 0; Cancellation = $null
                Ad = @(
                    [pscustomobject]@{Name='PC-ONE';ObjectGUID=(New-TestId 11);DistinguishedName='CN=PC-ONE,OU=Lab,DC=example,DC=invalid';ObjectClass='computer';ProtectedFromAccidentalDeletion=$false},
                    [pscustomobject]@{Name='PC-TWO';ObjectGUID=(New-TestId 12);DistinguishedName='CN=PC-TWO,OU=Lab,DC=example,DC=invalid';ObjectClass='computer';ProtectedFromAccidentalDeletion=$false}
                )
                Entra = @(
                    [pscustomobject]@{id=(New-TestId 21);displayName='PC-ONE';deviceId=(New-TestId 31)},
                    [pscustomobject]@{id=(New-TestId 22);displayName='PC-ONE';deviceId=(New-TestId 32)},
                    [pscustomobject]@{id=(New-TestId 23);displayName='PC-TWO';deviceId=(New-TestId 33)},
                    [pscustomobject]@{id=(New-TestId 24);displayName='PC-ONE-EXTRA';deviceId=(New-TestId 34)}
                )
                Intune = @(
                    [pscustomobject]@{id=(New-TestId 41);deviceName='PC-ONE';azureADDeviceId=(New-TestId 31);serialNumber='SERIAL-ONE';operatingSystem='Windows'},
                    [pscustomobject]@{id=(New-TestId 42);deviceName='PC-TWO';azureADDeviceId=(New-TestId 33);serialNumber='SERIAL-TWO';operatingSystem='Windows'},
                    [pscustomobject]@{id=(New-TestId 43);deviceName='PC-ONE';azureADDeviceId=(New-TestId 34);serialNumber='MOBILE';operatingSystem='Android'}
                )
            }
        }
        function script:Initialize-RemovalSources { param([string[]]$Sources,$ProgressQueue) }
        function script:Get-RemovalContextKey { param([string[]]$Sources) return $script:Fixture.Context }
        function script:Get-RemovalBitLockerPreview {
            param($Name,$Targets,$Settings,$Credentials)
            if ($script:Fixture.Mode -eq 'BackupPreviewFailure') { throw 'Synthetic backup preview failure.' }
            [pscustomobject]@{ComputerId=900;Name=$Name;Serial='SYNTHETIC';EntityId=0;RequiresMappingConfirmation=($script:Fixture.Mode -eq 'MappingRequired');Keys=@()}
        }
        function script:Save-RemovalBitLockerBackup {
            param($Preview,$Targets,$Plan,$Password,$ProgressQueue)
            if ($script:Fixture.Mode -eq 'BackupSaveFailure') { throw 'Synthetic backup save failure.' }
            if (@($script:Fixture.Writes | Where-Object Name -eq $Preview.Name).Count -ne 0) { throw 'Backup ran after deletion.' }
            [pscustomobject]@{ComputerId=900;Count=0;Keys=@()}
        }
        function script:Test-RemovalBitLockerCoverage {
            param($Target,$Receipt)
            if ($script:Fixture.Mode -eq 'CoverageFailure') { throw 'Synthetic key not covered by backup.' }
        }
        function script:Clear-ExplorerCloudCache { $script:Fixture.CacheCleared++ }
        function script:Throw-GraphMissing {
            $exception = New-Object Exception('Synthetic not found.')
            $exception | Add-Member NoteProperty Response ([pscustomobject]@{StatusCode=404})
            throw $exception
        }
        function script:Get-ADComputer {
            [CmdletBinding()]
            param([string]$Server, [string]$LDAPFilter, [guid]$Identity, [string[]]$Properties)
            [void]$script:Fixture.Reads.Add([pscustomobject]@{Source='AD';Server=$Server;Filter=$LDAPFilter;Id=$Identity})
            if ($script:Fixture.Mode -eq 'AdReadFailure' -and $Server -like 'dc5.*') { throw 'Synthetic unavailable DC.' }
            if ($PSBoundParameters.ContainsKey('Identity')) {
                $record = @($script:Fixture.Ad | Where-Object { [guid]$_.ObjectGUID -eq $Identity })
                if ($record.Count -eq 0 -or ($script:Fixture.Mode -eq 'Replicated' -and @($script:Fixture.Writes | Where-Object { $_.Source -eq 'AD' -and $_.Id -eq $Identity.ToString() }).Count -gt 0)) {
                    Write-Error -Message 'Synthetic AD object absent.' -ErrorId 'ADIdentityNotFoundException' -Category ObjectNotFound -ErrorAction Stop
                }
                if ($script:Fixture.Mode -eq 'RenameAdById') {
                    return [pscustomobject]@{Name='RENAMED-AD';ObjectGUID=$record[0].ObjectGUID;DistinguishedName=$record[0].DistinguishedName}
                }
                return $record[0]
            }
            if (-not $LDAPFilter.StartsWith('(name=') -or -not $LDAPFilter.EndsWith(')')) { throw 'Unexpected AD query.' }
            $name = $LDAPFilter.Substring(6, $LDAPFilter.Length - 7)
            $name = $name.Replace('\2a','*').Replace('\28','(').Replace('\29',')').Replace('\00',[string][char]0).Replace('\5c','\')
            return @($script:Fixture.Ad | Where-Object { $_.Name -eq $name })
        }

        function script:Set-TestAdChildren {
            $dn=$script:Fixture.Ad[0].DistinguishedName
            $script:Fixture.Children=@(
                [pscustomobject]@{Name='Recovery';ObjectGUID=(New-TestId 61);DistinguishedName=('CN=Recovery,'+$dn);ObjectClass='msFVE-RecoveryInformation';ProtectedFromAccidentalDeletion=$false},
                [pscustomobject]@{Name='Services';ObjectGUID=(New-TestId 62);DistinguishedName=('CN=Services,'+$dn);ObjectClass='container';ProtectedFromAccidentalDeletion=$false},
                [pscustomobject]@{Name='Nested';ObjectGUID=(New-TestId 63);DistinguishedName=('CN=Nested,CN=Services,'+$dn);ObjectClass='serviceConnectionPoint';ProtectedFromAccidentalDeletion=$false}
            )
        }
        function script:Get-ADObject {
            [CmdletBinding()]
            param([string]$Server,[string]$LDAPFilter,[string]$SearchBase,[string]$SearchScope,[guid]$Identity,[string[]]$Properties)
            [void]$script:Fixture.ChildReads.Add([pscustomobject]@{Server=$Server;Base=$SearchBase;Scope=$SearchScope;Id=$Identity;Properties=$Properties})
            if ($script:Fixture.Mode -eq 'ChildReadFailure') { throw 'Synthetic child enumeration failure.' }
            if ($PSBoundParameters.ContainsKey('Identity')) {
                $records=@($script:Fixture.Children | Where-Object { [guid]$_.ObjectGUID -eq $Identity })
                if ($records.Count -eq 0 -or @($script:Fixture.Writes | Where-Object { $_.Source -eq 'AD (figlio)' -and $_.Id -eq $Identity.ToString() -and $_.Server -eq $Server }).Count -gt 0) {
                    Write-Error -Message 'Synthetic AD child absent.' -ErrorId 'ADIdentityNotFoundException' -Category ObjectNotFound -ErrorAction Stop
                }
                $record=$records[0]
                if ($script:Fixture.Mode -in @('MovedChildById','MovedChildOutsideSearch')) {
                    return [pscustomobject]@{ObjectGUID=$record.ObjectGUID;DistinguishedName=('CN=Moved,'+$script:Fixture.Ad[1].DistinguishedName);ObjectClass=$record.ObjectClass;ProtectedFromAccidentalDeletion=$false}
                }
                if ($script:Fixture.Mode -eq 'ProtectedChildById') {
                    return [pscustomobject]@{ObjectGUID=$record.ObjectGUID;DistinguishedName=$record.DistinguishedName;ObjectClass=$record.ObjectClass;ProtectedFromAccidentalDeletion=$true}
                }
                return $record
            }
            if ($LDAPFilter -notin @('(objectClass=*)','(objectClass=msFVE-RecoveryInformation)') -or $SearchScope -ne 'Subtree') { throw 'Unexpected child search scope/filter.' }
            if ($Properties -contains '*' -or @($Properties | Where-Object { $_ -match 'password|recoveryguid|keypackage' }).Count) { throw 'Secret BitLocker attributes requested.' }
            $parents=@($script:Fixture.Ad | Where-Object { $_.DistinguishedName -eq $SearchBase })
            if ($parents.Count -ne 1) { throw 'Unexpected child search base.' }
            if ($LDAPFilter -eq '(objectClass=*)') { $parents[0] }
            foreach ($record in $script:Fixture.Children) {
                if ($LDAPFilter -eq '(objectClass=msFVE-RecoveryInformation)' -and $record.ObjectClass -ne 'msFVE-RecoveryInformation') { continue }
                if ($script:Fixture.Mode -eq 'MovedChildOutsideSearch' -and [string]$record.ObjectGUID -eq (New-TestId 61)) { continue }
                if (($record.DistinguishedName.EndsWith(','+$SearchBase,[StringComparison]::OrdinalIgnoreCase) -or $script:Fixture.Mode -eq 'ForeignChild') -and
                    @($script:Fixture.Writes | Where-Object { $_.Source -eq 'AD (figlio)' -and $_.Id -eq [string]$record.ObjectGUID -and $_.Server -eq $Server }).Count -eq 0) { $record }
            }
        }
        function script:Remove-ADObject {
            [CmdletBinding(SupportsShouldProcess=$true)]
            param([string]$Server,[guid]$Identity,[switch]$Recursive)
            if ($Recursive) { throw 'Recursive removal is forbidden in this test.' }
            if ($script:Fixture.Mode -eq 'LateNewChild' -and @($script:Fixture.Children | Where-Object { [string]$_.ObjectGUID -eq (New-TestId 64) }).Count -eq 0) {
                $script:Fixture.Children += @([pscustomobject]@{ObjectGUID=(New-TestId 64);DistinguishedName=('CN=LateNew,'+$script:Fixture.Ad[0].DistinguishedName);ObjectClass='serviceConnectionPoint';ProtectedFromAccidentalDeletion=$false})
            }
            if ($script:Fixture.Mode -eq 'ChildWriteFailure') { throw 'Synthetic child removal failure.' }
            [void]$script:Fixture.Writes.Add([pscustomobject]@{Source='AD (figlio)';Server=$Server;Id=$Identity.ToString();Name='PC-ONE'})
        }

        function script:Get-ExplorerGraphCollection {
            param([string]$Uri, [string]$ResourcePath)
            [void]$script:Fixture.Reads.Add([pscustomobject]@{Source='Graph';Uri=$Uri})
            if ($ResourcePath -eq '/v1.0/devices') { return $script:Fixture.Entra }
            if ($ResourcePath -eq '/v1.0/deviceManagement/managedDevices') { return $script:Fixture.Intune }
            throw 'Unexpected Graph collection.'
        }
        function script:Invoke-MgGraphRequest {
            [CmdletBinding()]
            param([string]$Method, [string]$Uri, [string]$OutputType)
            if ($Uri -notmatch '/(devices|managedDevices)/([0-9a-f-]+)(\?|$)') { throw 'Unexpected object endpoint.' }
            $source = 'Entra'; $records = $script:Fixture.Entra
            if ($Matches[1] -eq 'managedDevices') { $source='Intune'; $records=$script:Fixture.Intune }
            $id = $Matches[2]
            if ($Method -eq 'GET') {
                $record = @($records | Where-Object { $_.id -eq $id })
                if ($record.Count -eq 0 -or ($script:Fixture.Mode -eq 'GoneIntune' -and $source -eq 'Intune')) { Throw-GraphMissing }
                if ($script:Fixture.Mode -eq 'RenameById' -and $source -eq 'Intune') {
                    return [pscustomobject]@{id=$id;deviceName='RENAMED';azureADDeviceId=$record[0].azureADDeviceId;serialNumber=$record[0].serialNumber;operatingSystem='Windows'}
                }
                return $record[0]
            }
            if ($Method -ne 'DELETE') { throw 'Unexpected Graph write.' }
            [void]$script:Fixture.Writes.Add([pscustomobject]@{Source=$source;Id=$id;Name=$records.Where({$_.id -eq $id})[0].PSObject.Properties[($(if($source -eq 'Intune'){'deviceName'}else{'displayName'}))].Value})
            if ($script:Fixture.Mode -eq 'IntuneFailure' -and $source -eq 'Intune' -and $id -eq (New-TestId 41)) { throw 'Synthetic Intune deletion failure.' }
            if ($script:Fixture.Mode -eq 'CancelAfterFirstWrite' -and $script:Fixture.Writes.Count -eq 1) { $script:Fixture.Cancellation.Cancel() }
        }
        function script:Remove-ADComputer {
            [CmdletBinding(SupportsShouldProcess=$true)]
            param([string]$Server, [guid]$Identity)
            $parent=@($script:Fixture.Ad | Where-Object { [guid]$_.ObjectGUID -eq $Identity })[0]
            $remaining=@($script:Fixture.Children | Where-Object { $_.DistinguishedName.EndsWith(','+$parent.DistinguishedName,[StringComparison]::OrdinalIgnoreCase) -and @($script:Fixture.Writes | Where-Object Source -eq 'AD (figlio)' | Where-Object Server -eq $Server | Select-Object -ExpandProperty Id) -notcontains [string]$_.ObjectGUID })
            if ($remaining.Count -gt 0) { throw 'Synthetic leaf-only parent removal refused remaining children.' }
            [void]$script:Fixture.Writes.Add([pscustomobject]@{Source='AD';Server=$Server;Id=$Identity.ToString();Name=@($script:Fixture.Ad | Where-Object { [guid]$_.ObjectGUID -eq $Identity })[0].Name})
            if ($script:Fixture.Mode -eq 'AdWriteFailure' -and $Server -like 'dc2.*') { throw 'Synthetic AD delete failure.' }
        }

        $configPath = Join-Path ([IO.Path]::GetTempPath()) ('removal-' + [guid]::NewGuid().ToString('N') + '.json')
        try {
            @{DomainControllers=@(1..5 | ForEach-Object { "dc$_.example.invalid" });Search=@{MinimumCharacters=2}} | ConvertTo-Json -Depth 4 | Set-Content $configPath -Encoding UTF8
            Reset-Fixture
            $plan=New-ExplorerRemovalPlan -Names PC-ONE -Sources AD,Entra,Intune -ConfigPath $configPath
            if ($script:Fixture.Writes.Count -ne 0 -or $plan.Entries.Count -ne 1 -or $plan.Entries[0].Targets.Count -ne 8 -or
                @($plan.Entries[0].Targets | Where-Object { $_.Name -ne 'PC-ONE' -or ($_.Source -eq 'Intune' -and $_.OperatingSystem -ne 'Windows') }).Count -gt 0) { throw 'Preview changed data or widened exact-name targets.' }
            'PASS: preview is read-only, exact-name, paginated and Windows-only; duplicate Entra IDs remain visible.'
            $result=Invoke-ExplorerRemovalPlan -PlanId $plan.PlanId -Confirm:$false
            if ($script:Fixture.Writes.Count -ne 8 -or $script:Fixture.Writes[0].Source -ne 'Intune' -or
                ($script:Fixture.Writes.Source -join ',') -ne 'Intune,AD,AD,AD,AD,AD,Entra,Entra' -or $result.Deleted -ne 8 -or $script:Fixture.CacheCleared -ne 1) { throw 'Wrong execution order, target count or cache invalidation.' }
            'PASS: Intune -> all five DCs -> Entra; deletion uses correct source IDs and clears cloud cache.'
            $rejected=$false; try { Invoke-ExplorerRemovalPlan -PlanId $plan.PlanId -Confirm:$false | Out-Null } catch { $rejected=$true }
            if (-not $rejected -or $script:Fixture.Writes.Count -ne 8) { throw 'Consumed plan reused.' }
            'PASS: deletion plan is single-use.'

            Reset-Fixture
            $script:Fixture.Mode='IntuneFailure'
            $plan=New-ExplorerRemovalPlan -Names PC-ONE,PC-TWO -Sources AD,Entra,Intune -ConfigPath $configPath
            $result=Invoke-ExplorerRemovalPlan -PlanId $plan.PlanId -Confirm:$false
            if (@($script:Fixture.Writes | Where-Object { $_.Name -eq 'PC-ONE' -and $_.Source -ne 'Intune' }).Count -gt 0 -or
                @($script:Fixture.Writes | Where-Object { $_.Name -eq 'PC-TWO' }).Count -ne 7 -or $result.Failed -ne 1) { throw 'Intune failure did not isolate the computer.' }
            'PASS: Intune failure blocks subsequent sources for that computer; independent computers continue.'

            Reset-Fixture; $script:Fixture.Mode='AdReadFailure'
            $plan=New-ExplorerRemovalPlan -Names PC-ONE -Sources AD,Entra,Intune -ConfigPath $configPath
            $result=Invoke-ExplorerRemovalPlan -PlanId $plan.PlanId -Confirm:$false
            if ($script:Fixture.Writes.Count -ne 0 -or $result.Failed -ne 1) { throw 'Incomplete preflight permitted writes.' }
            'PASS: unavailable DC blocks the computer without partial deletion.'

            Reset-Fixture
            $plan=New-ExplorerRemovalPlan -Names PC-ONE -Sources AD,Entra,Intune -ConfigPath $configPath
            $script:Fixture.Entra += @([pscustomobject]@{id=(New-TestId 99);displayName='PC-ONE';deviceId=(New-TestId 39)})
            $result=Invoke-ExplorerRemovalPlan -PlanId $plan.PlanId -Confirm:$false
            if ($script:Fixture.Writes.Count -ne 0 -or $result.Failed -ne 1) { throw 'New unconfirmed object was deleted.' }
            'PASS: newly appearing IDs invalidate the computer preflight.'

            Reset-Fixture
            $plan=New-ExplorerRemovalPlan -Names PC-ONE -Sources AD,Entra,Intune -ConfigPath $configPath
            $script:Fixture.Intune[0].serialNumber='CHANGED'
            $result=Invoke-ExplorerRemovalPlan -PlanId $plan.PlanId -Confirm:$false
            if ($script:Fixture.Writes.Count -ne 0 -or $result.Failed -ne 1) { throw 'Changed serial permitted writes.' }
            'PASS: changed identity metadata invalidates the preview.'

            Reset-Fixture
            $plan=New-ExplorerRemovalPlan -Names PC-ONE -Sources AD,Entra,Intune -ConfigPath $configPath
            $script:Fixture.Mode='RenameById'
            $result=Invoke-ExplorerRemovalPlan -PlanId $plan.PlanId -Confirm:$false
            if ($script:Fixture.Writes.Count -ne 0 -or $result.Failed -ne 1) { throw 'By-ID race not detected.' }
            'PASS: immediate by-ID check blocks renamed or repurposed objects.'

            Reset-Fixture
            $plan=New-ExplorerRemovalPlan -Names PC-ONE -Sources AD,Entra,Intune -ConfigPath $configPath
            $script:Fixture.Mode='RenameAdById'
            $result=Invoke-ExplorerRemovalPlan -PlanId $plan.PlanId -Confirm:$false
            if ($script:Fixture.Writes.Count -ne 0 -or $result.Failed -ne 1) { throw 'Later-source identity change did not block Intune before writes.' }
            'PASS: all planned IDs are verified before the first write, including later AD/Entra sources.'

            Reset-Fixture
            $plan=New-ExplorerRemovalPlan -Names PC-ONE -Sources AD,Entra,Intune -ConfigPath $configPath
            $script:Fixture.Mode='Replicated'
            $result=Invoke-ExplorerRemovalPlan -PlanId $plan.PlanId -Confirm:$false
            if ($result.Failed -ne 0 -or $script:Fixture.Writes.Count -ne 4 -or
                @($result.Results | Where-Object { $_.State -eq 'Già assente' }).Count -ne 4) { throw 'AD replication treated as error.' }
            'PASS: AD objects already removed by replication are accepted as absent.'

            Reset-Fixture
            $plan=New-ExplorerRemovalPlan -Names PC-ONE -Sources AD,Entra,Intune -ConfigPath $configPath
            $script:Fixture.Mode='GoneIntune'
            $result=Invoke-ExplorerRemovalPlan -PlanId $plan.PlanId -Confirm:$false
            if ($result.Failed -ne 0 -or @($script:Fixture.Writes | Where-Object { $_.Source -eq 'Intune' }).Count -gt 0) { throw 'HTTP 404 blocked expected absence.' }
            'PASS: HTTP 404 during final by-ID read is handled as already absent.'

            Reset-Fixture
            $plan=New-ExplorerRemovalPlan -Names PC-ONE -Sources AD,Entra,Intune -ConfigPath $configPath
            $script:Fixture.Mode='AdWriteFailure'
            $result=Invoke-ExplorerRemovalPlan -PlanId $plan.PlanId -Confirm:$false
            if (@($script:Fixture.Writes | Where-Object { $_.Source -eq 'Entra' }).Count -gt 0 -or $result.Failed -ne 1) { throw 'AD failure did not block later source.' }
            'PASS: AD failure blocks subsequent Entra removal and reports skipped objects.'

            Reset-Fixture
            $plan=New-ExplorerRemovalPlan -Names PC-ONE -Sources AD -ConfigPath $configPath
            $result=Invoke-ExplorerRemovalPlan -PlanId $plan.PlanId -Confirm:$false
            if ($script:Fixture.Writes.Count -ne 5 -or @($script:Fixture.Reads | Where-Object { $_.Source -eq 'Graph' }).Count -gt 0) { throw 'Unselected sources were queried or deleted.' }
            'PASS: unchecked cloud origins are excluded.'

            Reset-Fixture
            $rejected=$false
            try { New-ExplorerRemovalPlan -Names PC-ONE -Sources GLPI -ConfigPath $configPath | Out-Null } catch { $rejected=$true }
            if (-not $rejected -or $script:Fixture.Writes.Count -ne 0) { throw 'GLPI removal allowed.' }
            'PASS: GLPI cannot be selected for deletion.'

            Reset-Fixture
            $plan=New-ExplorerRemovalPlan -Names PC-ONE -Sources AD,Entra,Intune -ConfigPath $configPath
            $result=Invoke-ExplorerRemovalPlan -PlanId $plan.PlanId -WhatIf
            if ($script:Fixture.Writes.Count -ne 0 -or $script:Fixture.CacheCleared -ne 0 -or @($result.Results | Where-Object { $_.State -eq 'Simulato' }).Count -ne 8) { throw 'WhatIf performed writes.' }
            'PASS: WhatIf performs no deletion.'

            foreach ($mode in @('Expired','ChangedContext')) {
                Reset-Fixture
                $plan=New-ExplorerRemovalPlan -Names PC-ONE -Sources AD,Entra,Intune -ConfigPath $configPath
                if ($mode -eq 'Expired') { $script:RemovalPlans[$plan.PlanId].CreatedAtUtc=[datetimeoffset]::UtcNow.AddMinutes(-6) }
                else { $script:Fixture.Context='other-tenant|other-account' }
                $rejected=$false; try { Invoke-ExplorerRemovalPlan -PlanId $plan.PlanId -Confirm:$false | Out-Null } catch { $rejected=$true }
                if (-not $rejected -or $script:Fixture.Writes.Count -ne 0) { throw 'Invalid preview context accepted.' }
                "PASS: invalid preview rejected / $mode."
            }

            Reset-Fixture
            $plan=New-ExplorerRemovalPlan -Names PC-ONE,PC-TWO -Sources AD,Entra,Intune -ConfigPath $configPath
            $cancellation=New-Object Threading.CancellationTokenSource
            try {
                $script:Fixture.Cancellation=$cancellation; $script:Fixture.Mode='CancelAfterFirstWrite'
                $result=Invoke-ExplorerRemovalPlan -PlanId $plan.PlanId -Cancellation $cancellation -Confirm:$false
                if (@($script:Fixture.Writes | Where-Object { $_.Name -eq 'PC-ONE' }).Count -ne 8 -or
                    @($script:Fixture.Writes | Where-Object { $_.Name -eq 'PC-TWO' }).Count -gt 0 -or
                    @($result.Results | Where-Object { $_.State -eq 'Annullato' }).Count -ne 1) { throw 'Cancellation interrupted a computer or processed later computers.' }
                'PASS: graceful cancellation finishes the current computer and skips the next.'
            }
            finally { $cancellation.Dispose() }

            Reset-Fixture
            $plan=New-ExplorerRemovalPlan -Names PC-ONE -Sources AD,Entra,Intune -ConfigPath $configPath
            $plan.Entries[0].Targets[0].Id=New-TestId 999
            $result=Invoke-ExplorerRemovalPlan -PlanId $plan.PlanId -Confirm:$false
            if ($result.Deleted -ne 8 -or @($script:Fixture.Writes | Where-Object { $_.Id -eq (New-TestId 999) }).Count -gt 0) { throw 'External preview mutation retargeted deletion.' }
            'PASS: preview DTO mutation cannot alter cached target IDs.'


            foreach ($mode in @('BackupPreviewFailure','BackupSaveFailure','CoverageFailure')) {
                Reset-Fixture
                if ($mode -eq 'BackupPreviewFailure') { $script:Fixture.Mode=$mode }
                $plan=New-ExplorerRemovalPlan -Names PC-ONE -Sources AD,Entra,Intune -ConfigPath $configPath
                $script:Fixture.Mode=$mode
                $result=Invoke-ExplorerRemovalPlan -PlanId $plan.PlanId -Confirm:$false
                if ($script:Fixture.Writes.Count -ne 0 -or $result.Failed -eq 0) { throw ('Failed BitLocker protection permitted deletion: '+$mode) }
            }
            'PASS: failed backup preview, failed verified save and uncovered keys block every origin before deletion.'
            Reset-Fixture; $script:Fixture.Mode='MappingRequired'
            $plan=New-ExplorerRemovalPlan -Names PC-ONE -Sources AD,Entra,Intune -ConfigPath $configPath
            $result=Invoke-ExplorerRemovalPlan -PlanId $plan.PlanId -Confirm:$false
            if ($script:Fixture.Writes.Count -ne 0 -or $result.Failed -ne 1) { throw 'Unconfirmed GLPI mapping permitted deletion.' }
            $plan=New-ExplorerRemovalPlan -Names PC-ONE -Sources AD,Entra,Intune -ConfigPath $configPath
            $result=Invoke-ExplorerRemovalPlan -PlanId $plan.PlanId -ConfirmGlpiMapping -Confirm:$false
            if ($result.Failed -or $result.Deleted -ne 8) { throw 'Explicitly confirmed unchanged GLPI mapping did not work.' }
            'PASS: name-only GLPI associations require an explicit confirmation enforced in the backend.'
            Reset-Fixture
            $plan=New-ExplorerRemovalPlan -Names PC-ONE -Sources AD,Entra,Intune -ConfigPath $configPath -ArchiveOnly
            $result=Invoke-ExplorerRemovalPlan -PlanId $plan.PlanId -Confirm:$false
            if ($script:Fixture.Writes.Count -ne 0 -or $result.Deleted -ne 0 -or $result.Failed -ne 0 -or -not $result.ArchiveOnly) { throw 'Archive-only operation removed a registration.' }
            'PASS: archive-only plans save and verify backups without deleting AD/Intune/Entra records.'

            # Use one DC for subtree scenarios so duplicate replicas cannot hide wrong counts.
            @{DomainControllers=@('dc1.example.invalid');Search=@{MinimumCharacters=2}} | ConvertTo-Json -Depth 4 | Set-Content $configPath -Encoding UTF8

            Reset-Fixture; Set-TestAdChildren
            $plan=New-ExplorerRemovalPlan -Names PC-ONE -Sources AD,Entra,Intune -ConfigPath $configPath
            $ad=@($plan.Entries[0].Targets | Where-Object Source -eq 'AD')[0]
            if ($ad.AdChildren.Count -ne 3 -or $script:Fixture.Writes.Count -ne 0 -or @($ad.AdChildren | Where-Object ObjectClass -eq 'msFVE-RecoveryInformation').Count -ne 1) { throw 'AD child preview is incomplete or destructive.' }
            $result=Invoke-ExplorerRemovalPlan -PlanId $plan.PlanId -Confirm:$false
            if ($script:Fixture.Writes.Count -ne 0 -or $result.Failed -ne 1) { throw 'Missing explicit child consent permitted writes.' }
            'PASS: subtree preview lists child GUID/class/DN without reading BitLocker secrets; missing consent blocks all origins before writes.'

            Reset-Fixture; Set-TestAdChildren
            $plan=New-ExplorerRemovalPlan -Names PC-ONE -Sources AD,Entra,Intune -ConfigPath $configPath
            $result=Invoke-ExplorerRemovalPlan -PlanId $plan.PlanId -IncludeAdChildren -Confirm:$false
            $childWrites=@($script:Fixture.Writes | Where-Object Source -eq 'AD (figlio)')
            if ($result.Failed -ne 0 -or $result.Deleted -ne 7 -or $childWrites.Count -ne 3 -or
                ($script:Fixture.Writes.Source -join ',') -ne 'Intune,AD (figlio),AD (figlio),AD (figlio),AD,Entra,Entra' -or
                $childWrites[0].Id -ne (New-TestId 63) -or @($result.Results | Where-Object Source -eq 'AD (figlio)').Count -ne 3) { throw 'AD children were not removed before their parents with per-child reporting.' }
            'PASS: explicit child consent deletes only confirmed GUIDs, deepest children before parents, with separate result rows and no recursive command.'

            foreach ($kind in @('Parent','Child')) {
                Reset-Fixture; Set-TestAdChildren
                if ($kind -eq 'Parent') { $script:Fixture.Ad[0].ProtectedFromAccidentalDeletion=$true }
                else { $script:Fixture.Children[0].ProtectedFromAccidentalDeletion=$true }
                $plan=New-ExplorerRemovalPlan -Names PC-ONE -Sources AD,Entra,Intune -ConfigPath $configPath
                $result=Invoke-ExplorerRemovalPlan -PlanId $plan.PlanId -IncludeAdChildren -Confirm:$false
                if ($script:Fixture.Writes.Count -ne 0 -or $result.Failed -ne 1 -or $plan.Entries[0].Error -notlike '*protetto*') { throw ('Accidental deletion protection bypassed: '+$kind) }
            }
            'PASS: protected computers and protected descendants block every selected origin and their protection is never changed.'

            Reset-Fixture;Set-TestAdChildren
            $script:Fixture.Ad[0].ProtectedFromAccidentalDeletion=$true;$script:Fixture.Children[0].ProtectedFromAccidentalDeletion=$true
            $plan=New-ExplorerRemovalPlan -Names PC-ONE -Sources AD,Entra,Intune -ConfigPath $configPath -ArchiveOnly
            $ad=@($plan.Entries[0].Targets | Where-Object Source -eq 'AD')[0]
            if ($plan.Entries[0].Error -or -not $ad.RecoveryOnly -or $ad.AdChildren.Count -ne 1 -or $ad.AdChildren[0].ObjectClass -ne 'msFVE-RecoveryInformation') { throw 'Archive-only mode used full deletion enumeration or blocked protected recovery objects.' }
            $result=Invoke-ExplorerRemovalPlan -PlanId $plan.PlanId -Confirm:$false
            if (@($script:Fixture.ChildReads | Where-Object { $_.Properties -contains 'ProtectedFromAccidentalDeletion' }).Count) { throw 'Archive-only mode still reads deletion protection ACL metadata.' }
            if ($result.Failed -or $result.Deleted -or $script:Fixture.Writes.Count -or -not $script:Fixture.Ad[0].ProtectedFromAccidentalDeletion -or -not $script:Fixture.Children[0].ProtectedFromAccidentalDeletion) { throw 'Read-only archive path deleted, unprotected or failed to reread AD objects.' }
            Reset-Fixture;Set-TestAdChildren;$script:Fixture.Children[1].ObjectGUID='invalid-unrelated-guid'
            $targets=@(Get-RemovalTargets -Name PC-ONE -Sources AD -Controllers @('dc1.example.invalid') -ArchiveOnly)
            if ($targets.Count -ne 1 -or $targets[0].AdChildren.Count -ne 1) { throw 'An unrelated service child still blocked archive metadata.' }
            $failed=$false;try { $null=Get-RemovalTargets -Name PC-ONE -Sources AD -Controllers @('dc1.example.invalid') } catch { $failed=$_.Exception.Message -like '*Identificativo oggetto non valido*dc1.example.invalid*container*CN=Services*' }
            if (-not $failed) { throw 'Deletion accepted an invalid child ID or lost source/DC/DN diagnostics.' }
            $binary=([guid](New-TestId 11)).ToByteArray()
            if ((ConvertTo-RemovalId $binary) -ne (New-TestId 11) -or (ConvertTo-RemovalId @((New-TestId 11))) -ne (New-TestId 11)) { throw 'Valid binary or single-value AD identifiers were rejected.' }
            'PASS: archive-only mode reads only BitLocker children, supports protected objects through final rereads and never changes protections; deletion retains full strict enumeration and contextual invalid-ID errors.'


            Reset-Fixture; Set-TestAdChildren
            $plan=New-ExplorerRemovalPlan -Names PC-ONE -Sources AD,Entra,Intune -ConfigPath $configPath
            $script:Fixture.Children += @([pscustomobject]@{ObjectGUID=(New-TestId 64);DistinguishedName=('CN=New,'+$script:Fixture.Ad[0].DistinguishedName);ObjectClass='serviceConnectionPoint';ProtectedFromAccidentalDeletion=$false})
            $result=Invoke-ExplorerRemovalPlan -PlanId $plan.PlanId -IncludeAdChildren -Confirm:$false
            if ($script:Fixture.Writes.Count -ne 0 -or $result.Failed -ne 1) { throw 'New unconfirmed AD child was deleted.' }
            'PASS: a newly appearing child invalidates the computer before any Intune/AD/Entra writes.'

            foreach ($mode in @('MovedChildById','MovedChildOutsideSearch','ProtectedChildById','ChildReadFailure')) {
                Reset-Fixture; Set-TestAdChildren
                $plan=New-ExplorerRemovalPlan -Names PC-ONE -Sources AD,Entra,Intune -ConfigPath $configPath
                $script:Fixture.Mode=$mode
                $result=Invoke-ExplorerRemovalPlan -PlanId $plan.PlanId -IncludeAdChildren -Confirm:$false
                if ($script:Fixture.Writes.Count -ne 0 -or $result.Failed -ne 1) { throw ('Unsafe child change permitted writes: '+$mode) }
            }
            'PASS: moved child GUIDs, new protection and incomplete enumeration block all origins before the first write.'

            Reset-Fixture; Set-TestAdChildren
            $plan=New-ExplorerRemovalPlan -Names PC-ONE -Sources AD,Entra,Intune -ConfigPath $configPath
            $script:Fixture.Children=@($script:Fixture.Children | Where-Object { [string]$_.ObjectGUID -ne (New-TestId 61) })
            $result=Invoke-ExplorerRemovalPlan -PlanId $plan.PlanId -IncludeAdChildren -Confirm:$false
            if ($result.Failed -ne 0 -or $result.Deleted -ne 6 -or @($result.Results | Where-Object { $_.Id -eq (New-TestId 61) -and $_.State -eq 'Già assente' }).Count -ne 1) { throw 'Already-absent child blocked valid deletion or was counted as removed.' }
            'PASS: a child already removed by another operation is reported absent without retargeting.'

            Reset-Fixture; Set-TestAdChildren
            $plan=New-ExplorerRemovalPlan -Names PC-ONE -Sources AD,Entra,Intune -ConfigPath $configPath
            $script:Fixture.Mode='ChildWriteFailure'
            $result=Invoke-ExplorerRemovalPlan -PlanId $plan.PlanId -IncludeAdChildren -Confirm:$false
            if ($script:Fixture.Writes.Count -ne 1 -or $script:Fixture.Writes[0].Source -ne 'Intune' -or $result.Failed -lt 1 -or @($result.Results | Where-Object { $_.Source -eq 'AD (figlio)' -and $_.State -eq 'Errore' }).Count -ne 1) { throw 'Child failure did not preserve parent and later Entra origins.' }
            'PASS: failed child removal is reported separately and prevents removal of its computer and subsequent Entra objects.'


            Reset-Fixture; Set-TestAdChildren
            $plan=New-ExplorerRemovalPlan -Names PC-ONE -Sources AD,Entra,Intune -ConfigPath $configPath
            $script:Fixture.Mode='LateNewChild'
            $result=Invoke-ExplorerRemovalPlan -PlanId $plan.PlanId -IncludeAdChildren -Confirm:$false
            if (@($script:Fixture.Writes | Where-Object { $_.Id -eq (New-TestId 64) -or $_.Source -in @('AD','Entra') }).Count -gt 0 -or
                @($script:Fixture.Writes | Where-Object Source -eq 'AD (figlio)').Count -ne 3 -or $result.Failed -ne 1) { throw 'Late unconfirmed child was removed by a recursive operation or parent/later sources were deleted.' }
            'PASS: a child appearing after the final snapshot is preserved; leaf-only computer deletion fails and later sources stop, with prior child results retained.'

            Reset-Fixture; Set-TestAdChildren
            $plan=New-ExplorerRemovalPlan -Names PC-ONE -Sources AD -ConfigPath $configPath
            $plan.Entries[0].Targets[0].AdChildren[0].Id=New-TestId 999
            $plan.Entries[0].Targets[0].AdChildren[0].DistinguishedName='CN=Other,OU=Foreign,DC=example,DC=invalid'
            $result=Invoke-ExplorerRemovalPlan -PlanId $plan.PlanId -IncludeAdChildren -Confirm:$false
            if ($result.Failed -ne 0 -or $result.Deleted -ne 4 -or @($script:Fixture.Writes | Where-Object { $_.Id -eq (New-TestId 999) }).Count -gt 0) { throw 'Preview mutation retargeted AD child deletion.' }
            'PASS: modifying child preview data cannot alter the internal confirmed GUIDs or paths.'

            Reset-Fixture; Set-TestAdChildren
            $script:Fixture.Mode='ForeignChild'; $script:Fixture.Children[0].DistinguishedName='CN=Foreign,OU=Other,DC=example,DC=invalid'
            $plan=New-ExplorerRemovalPlan -Names PC-ONE -Sources AD -ConfigPath $configPath
            if ($plan.Entries[0].Error -notlike '*esterno*' -or $script:Fixture.Writes.Count -ne 0) { throw 'AD enumeration escaped the confirmed computer subtree.' }
            'PASS: an AD response outside the computer DN is rejected.'

            Reset-Fixture; Set-TestAdChildren
            $plan=New-ExplorerRemovalPlan -Names PC-ONE -Sources AD,Entra,Intune -ConfigPath $configPath
            $result=Invoke-ExplorerRemovalPlan -PlanId $plan.PlanId -IncludeAdChildren -WhatIf
            if ($script:Fixture.Writes.Count -ne 0 -or $script:Fixture.CacheCleared -ne 0 -or $result.Failed -ne 0) { throw 'WhatIf deleted AD children or cleared caches.' }
            'PASS: WhatIf with explicit child consent remains read-only.'

            Reset-Fixture
            $plan=New-ExplorerRemovalPlan -Names 'PC*(ONE)' -Sources AD -ConfigPath $configPath
            if (@($script:Fixture.Reads | Where-Object { $_.Filter -ne '(name=PC\2a\28ONE\29)' }).Count -gt 0 -or $plan.Entries[0].Targets.Count -ne 0) { throw 'Literal name widened LDAP filter.' }
            'PASS: exact AD filters escape wildcard input.'
        }
        finally { Remove-Item -LiteralPath $configPath -Force -ErrorAction SilentlyContinue }
    }
}
finally { Remove-Module -ModuleInfo $module -Force -ErrorAction SilentlyContinue }
