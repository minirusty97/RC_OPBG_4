#requires -version 5.1
[CmdletBinding()]
param([string]$ModulePath=(Join-Path $PSScriptRoot '../BitLocker.Archive.psm1'))
$ErrorActionPreference='Stop'
$module=Import-Module $ModulePath -Force -PassThru
try {
    & $module {
        function New-TestBlId { param([int]$Number) return ('{0:x8}-0000-4000-8000-000000000001' -f $Number) }
        function New-TestBlKey { param([int]$Number=1) return (@(1..8 | ForEach-Object { '{0:d6}' -f ($Number*11) }) -join '-') }
        $script:BlFixture=@{Mode='';Lookups=0}
        $key1=New-TestBlId 71; $key2=New-TestBlId 72; $key3=New-TestBlId 73; $device=New-TestBlId 41
        $root=New-TestBlId 11; $child=New-TestBlId 21; $volume=New-TestBlId 81
        $script:BlFixture.Ad=[pscustomobject]@{ObjectGUID=$child;DistinguishedName='CN=Recovery,CN=PC-ONE,OU=Lab,DC=example,DC=invalid';'msFVE-RecoveryPassword'=(New-TestBlKey);'msFVE-RecoveryGuid'=([guid]$key1).ToByteArray();'msFVE-VolumeGuid'=([guid]$volume).ToByteArray();whenCreated='2026-10-01T10:00:00Z'}
        function script:Get-ADObject {
            [CmdletBinding()]param($Server,$Identity,$Properties)
            if ($script:BlFixture.Mode -eq 'AdDenied') { throw 'Synthetic AD read denied.' }
            if ($script:BlFixture.Mode -eq 'AdMissingPassword') { return [pscustomobject]@{ObjectGUID=$Identity;DistinguishedName=$script:BlFixture.Ad.DistinguishedName} }
            return $script:BlFixture.Ad
        }
        function script:Get-ExplorerGraphCollection {
            param($Uri,$ResourcePath)
            $script:BlFixture.Lookups++
            if ($ResourcePath -ne '/v1.0/informationProtection/bitlocker/recoveryKeys' -or $Uri -notlike '*deviceId*') { throw 'Incorrect BitLocker endpoint or unfiltered tenant read.' }
            if ($script:BlFixture.Mode -eq 'GraphDenied') { throw 'Synthetic Graph 403.' }
            $device=New-TestBlId 41
            if ($script:BlFixture.Mode -eq 'ForeignDevice') { $device=New-TestBlId 99 }
            @([pscustomobject]@{id=(New-TestBlId 71);deviceId=$device},[pscustomobject]@{id=(New-TestBlId 73);deviceId=$device})
        }
        function script:Invoke-MgGraphRequest {
            [CmdletBinding()]param($Method,$Uri,$OutputType,$Headers)
            if ($Method -ne 'GET' -or $Uri -notlike '*$select=id,deviceId,key*' -or -not $Headers['User-Agent']) { throw 'Secret read was not explicit and identified.' }
            if ($script:BlFixture.Mode -eq 'MissingCloudPassword') { return [pscustomobject]@{id=(New-TestBlId 71);deviceId=(New-TestBlId 41)} }
            $id=New-TestBlId 71; $number=1
            if ($Uri -like ('*/'+(New-TestBlId 73)+'?*')) { $id=New-TestBlId 73; $number=3 }
            if ($script:BlFixture.Mode -eq 'ConflictingPassword') { $number=9 }
            [pscustomobject]@{id=$id;deviceId=(New-TestBlId 41);key=(New-TestBlKey $number);createdDateTime='2026-10-01T10:00:00Z';volumeType='operatingSystemVolume'}
        }
        $ad=[pscustomobject]@{Source='AD';Name='PC-ONE';Id=$root;DomainController='dc1.example.invalid';AdChildren=@([pscustomobject]@{Id=$child;DistinguishedName=$script:BlFixture.Ad.DistinguishedName;ObjectClass='msFVE-RecoveryInformation'})}
        $targets=@($ad,$ad,[pscustomobject]@{Source='Entra';LinkId=$device},[pscustomobject]@{Source='Intune';LinkId=$device})
        $keys=@(Get-ExplorerBitLockerKeys $targets)
        if ($keys.Count -ne 2 -or $script:BlFixture.Lookups -ne 1 -or @($keys | Where-Object { $_.KeyId -eq $key1 -and $_.Origins.Count -eq 2 }).Count -ne 1) { throw 'Replicated AD/cloud keys were not deduplicated without loss.' }
        'PASS: AD recovery GUIDs and cloud device IDs collect all selected keys, deduplicate replicas and merge identical AD/Entra keys.'
        foreach ($mode in @('AdDenied','AdMissingPassword','GraphDenied','ForeignDevice','MissingCloudPassword','ConflictingPassword')) {
            $script:BlFixture.Mode=$mode; $rejected=$false
            try { [void](Get-ExplorerBitLockerKeys $targets) } catch { $rejected=$true; if ($_.Exception.Message -like ('*'+(New-TestBlKey)+'*')) { throw 'Recovery password leaked into a failure message.' } }
            if (-not $rejected) { throw ('Incomplete or unsafe key retrieval accepted: '+$mode) }
        }
        'PASS: AD/Graph access failures, unreadable passwords, foreign device IDs and conflicting secrets fail closed without exposing the password.'
        $script:BlFixture.Mode=''

        function script:Reset-BlStorage {
            $script:BlFixture=@{Mode='';Notes=(New-Object 'Collections.Generic.List[object]');Posts=0;Closes=0;Keys=@();LegacyContent='<p>Nota precedente: ticket 123. Conservare questo testo.</p>'}
            [void]$script:BlFixture.Notes.Add([pscustomobject]@{id=900;itemtype='Computer';items_id=901;content=$script:BlFixture.LegacyContent})
            $value=New-TestBlKey
            $script:BlFixture.Keys=@([pscustomobject]@{KeyId=(New-TestBlId 71);Password=$value;Volume='operatingSystemVolume';CreatedAt='2026-10-01T10:00:00Z';Origins=@('AD:'+(New-TestBlId 11));Fingerprint=(Get-BlFingerprint $value)})
        }
        function script:Get-ExplorerBitLockerKeys { param($Targets) return $script:BlFixture.Keys }
        function script:Open-BlGlpiSession { param($Settings,$UserToken,$AppToken) return @{Headers=@{}} }
        function script:Close-BlGlpiSession { param($Session) $script:BlFixture.Closes++ }
        function script:Find-GlpiComputer { param($BaseUri,$NameFragment,$UserToken,$AppToken,$TimeoutSeconds)
            $row=[pscustomobject]@{GlpiId=901;Name='PC-ONE';SerialNumber='SERIAL-ONE';EntityId=0;IsDeleted='0'}
            if ($script:BlFixture.Mode -eq 'AmbiguousAsset') { return @($row,$row) }
            return $row
        }
        function script:Invoke-BlGlpiRequest {
            param($Session,$Method,$Path,$Body,$Query)
            if ($Path -eq 'Computer/901') {
                $serial='SERIAL-ONE'; if ($script:BlFixture.Mode -eq 'ChangedAsset') { $serial='OTHER' }
                return [pscustomobject]@{Data=[pscustomobject]@{id=901;name='PC-ONE';serial=$serial;entities_id=0;is_deleted='0'};Headers=@{};Status=200}
            }
            if ($Path -eq 'Computer/901/Notepad') {
                $headers=@{'Content-Range'=('0-'+[Math]::Max(0,$script:BlFixture.Notes.Count-1)+'/'+$script:BlFixture.Notes.Count)}
                if ($script:BlFixture.Mode -eq 'MissingRange') { $headers=@{} }
                return [pscustomobject]@{Data=@($script:BlFixture.Notes.ToArray());Headers=$headers;Status=200}
            }
            if ($Method -eq 'POST' -and $Path -eq 'Notepad') {
                if ($script:BlFixture.Mode -eq 'PostDenied') { throw 'Synthetic note write denied.' }
                if ($Body.input.itemtype -ne 'Computer' -or $Body.input.items_id -ne 901 -or @($script:BlFixture.Keys | Where-Object { $Body.input.content -like ('*'+$_.Password+'*') }).Count -ne 1 -or $Body.input.content -notlike '*AIT-BITLOCKER-V1*') { throw 'Wrong computer or missing readable recovery password in the native note.' }
                $script:BlFixture.Posts++; $id=1000+$script:BlFixture.Posts
                [void]$script:BlFixture.Notes.Add([pscustomobject]@{id=$id;itemtype='Computer';items_id=901;content=$Body.input.content})
                return [pscustomobject]@{Data=[pscustomobject]@{id=$id};Headers=@{};Status=201}
            }
            if ($Path -match '^Notepad/(\d+)$') {
                if ($script:BlFixture.Mode -eq 'ReadBackDenied') { throw 'Synthetic read-back denied.' }
                return [pscustomobject]@{Data=@($script:BlFixture.Notes | Where-Object id -eq ([int]$Matches[1]))[0];Headers=@{};Status=200}
            }
            throw 'Unexpected GLPI request in archive fixture.'
        }
        Reset-BlStorage
        $settings=[pscustomobject]@{Enabled=$true;BaseUri='https://glpi.example.invalid/apirest.php';UseAppToken=$false}
        $token=ConvertTo-SecureString 'synthetic-token' -AsPlainText -Force
        $bindingTargets=@([pscustomobject]@{Source='Intune';SerialNumber='SERIAL-ONE';LinkId=(New-TestBlId 41)})
        try {
            $preview=Get-ExplorerBitLockerPreview -Name PC-ONE -Targets $bindingTargets -Settings $settings -UserToken $token
            if ($preview.RequiresMappingConfirmation -or $preview.ComputerId -ne 901 -or ($preview | ConvertTo-Json -Depth 8) -like ('*'+(New-TestBlKey)+'*')) { throw 'Preview leaked a secret or failed serial binding.' }
            $manual=Get-ExplorerBitLockerPreview -Name PC-ONE -Targets @([pscustomobject]@{Source='AD'}) -Settings $settings -UserToken $token
            if (-not $manual.RequiresMappingConfirmation) { throw 'AD-only name binding was treated as verified hardware.' }
            'PASS: preview contains key metadata without passwords; serial-verified and name-only GLPI bindings remain distinct.'
            foreach ($mode in @('AmbiguousAsset','ChangedAsset')) {
                $script:BlFixture.Mode=$mode; $rejected=$false
                try { [void](Get-ExplorerBitLockerPreview -Name PC-ONE -Targets $bindingTargets -Settings $settings -UserToken $token) } catch { $rejected=$true }
                if (-not $rejected -or $script:BlFixture.Posts) { throw ('Unsafe GLPI binding accepted: '+$mode) }
            }
            $script:BlFixture.Mode=''; $rejected=$false
            try { [void](Get-ExplorerBitLockerPreview -Name PC-ONE -Targets @([pscustomobject]@{Source='Intune';SerialNumber='OTHER';LinkId=(New-TestBlId 41)}) -Settings $settings -UserToken $token) } catch { $rejected=$true }
            if (-not $rejected) { throw 'Serial conflict accepted by archive backend.' }
            'PASS: duplicate GLPI computers, changing asset identity and serial mismatches block backup.'

            $receipt=Save-ExplorerBitLockerArchive -Preview $preview -Targets $bindingTargets -Settings $settings -UserToken $token
            if ($receipt.Count -ne 1 -or $script:BlFixture.Posts -ne 1 -or ($script:BlFixture.Notes | ConvertTo-Json -Depth 8) -notlike ('*'+(New-TestBlKey)+'*') -or $script:BlFixture.Notes[0].content -cne $script:BlFixture.LegacyContent) { throw 'Readable backup not created or the pre-existing note was changed.' }
            $records=@(Read-ExplorerBitLockerArchive -ComputerId 901 -Settings $settings -UserToken $token)
            if ($records.Count -ne 1 -or $records[0].Password -cne (New-TestBlKey)) { throw 'Archived recovery password cannot be read from the native note.' }
            $receipt=Save-ExplorerBitLockerArchive -Preview $preview -Targets $bindingTargets -Settings $settings -UserToken $token
            if ($script:BlFixture.Posts -ne 1 -or $receipt.Count -ne 1) { throw 'Repeated archive overwrote or duplicated an existing key.' }
            'PASS: new native GLPI notes contain readable recovery keys and are verified after saving; existing notes remain unchanged and identical keys are not duplicated.'

            $appNote=$script:BlFixture.Notes[1]; $original=$appNote.content
            $appNote.content=$appNote.content.Replace((New-TestBlKey),(New-TestBlKey 9))
            $rejected=$false; try { [void](Save-ExplorerBitLockerArchive -Preview $preview -Targets $bindingTargets -Settings $settings -UserToken $token) } catch { $rejected=$true }
            if (-not $rejected -or $script:BlFixture.Posts -ne 1 -or $appNote.content -cne $original.Replace((New-TestBlKey),(New-TestBlKey 9)) -or $script:BlFixture.Notes[0].content -cne $script:BlFixture.LegacyContent) { throw 'A conflicting existing key was overwritten or a previous note changed.' }
            $appNote.content=$original
            $script:BlFixture.Mode='MissingRange'; $rejected=$false
            try { [void](Read-ExplorerBitLockerArchive -ComputerId 901 -Settings $settings -UserToken $token) } catch { $rejected=$true }
            if (-not $rejected) { throw 'Unverifiable pagination accepted.' }
            'PASS: conflicting existing recovery keys and incomplete note pagination stop the operation without changing any stored note.'

            $script:BlFixture.Mode=''; $key=New-TestBlKey 2
            $script:BlFixture.Keys+=@([pscustomobject]@{KeyId=(New-TestBlId 72);Password=$key;Volume='fixedDataVolume';CreatedAt='2026-10-02T10:00:00Z';Origins=@('AD:'+(New-TestBlId 11));Fingerprint=(Get-BlFingerprint $key)})
            $preview=Get-ExplorerBitLockerPreview -Name PC-ONE -Targets $bindingTargets -Settings $settings -UserToken $token
            $script:BlFixture.Mode='ReadBackDenied'; $rejected=$false
            try { [void](Save-ExplorerBitLockerArchive -Preview $preview -Targets $bindingTargets -Settings $settings -UserToken $token) } catch { $rejected=$true }
            if (-not $rejected -or $script:BlFixture.Posts -ne 2) { throw 'Unverified GLPI write was accepted as a backup.' }
            $script:BlFixture.Mode=''
            $receipt=Save-ExplorerBitLockerArchive -Preview $preview -Targets $bindingTargets -Settings $settings -UserToken $token
            if ($receipt.Count -ne 2 -or $script:BlFixture.Posts -ne 2) { throw 'Retry duplicated or lost a key after failed read-back.' }
            'PASS: failed read-back blocks success while a retry recovers and verifies the already-written key without duplication.'
        }
        finally { $token.Dispose() }
    }
}
finally { Remove-Module -ModuleInfo $module -Force -ErrorAction SilentlyContinue }
