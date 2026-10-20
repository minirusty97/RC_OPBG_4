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
                Reads = (New-Object 'System.Collections.Generic.List[object]'); CacheCleared = 0; Cancellation = $null
                Ad = @(
                    [pscustomobject]@{Name='PC-ONE';ObjectGUID=(New-TestId 11);DistinguishedName='CN=PC-ONE,OU=Lab,DC=example,DC=invalid'},
                    [pscustomobject]@{Name='PC-TWO';ObjectGUID=(New-TestId 12);DistinguishedName='CN=PC-TWO,OU=Lab,DC=example,DC=invalid'}
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
            [void]$script:Fixture.Writes.Add([pscustomobject]@{Source='AD';Id=$Identity.ToString();Name=@($script:Fixture.Ad | Where-Object { [guid]$_.ObjectGUID -eq $Identity })[0].Name})
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

            Reset-Fixture
            $plan=New-ExplorerRemovalPlan -Names 'PC*(ONE)' -Sources AD -ConfigPath $configPath
            if (@($script:Fixture.Reads | Where-Object { $_.Filter -ne '(name=PC\2a\28ONE\29)' }).Count -gt 0 -or $plan.Entries[0].Targets.Count -ne 0) { throw 'Literal name widened LDAP filter.' }
            'PASS: exact AD filters escape wildcard input.'
        }
        finally { Remove-Item -LiteralPath $configPath -Force -ErrorAction SilentlyContinue }
    }
}
finally { Remove-Module -ModuleInfo $module -Force -ErrorAction SilentlyContinue }
