#requires -version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '../ComputerExplorer.Core.psm1') -Force -PassThru
try {
    & $module {
        function New-TestRow {
            param([object[]]$IntuneSerials=@('ABC-123'),[object[]]$GlpiSerials=@('abc-123'),[string[]]$Groups=@('CENSITO'),[bool]$Verified=$true,[string]$GlpiState='OK')
            $sources=[ordered]@{}
            foreach ($name in @('AD','Entra','Intune','GLPI')) { $sources[$name]=New-ExplorerSource $name 'OK' }
            $sources.GLPI.State=$GlpiState
            $i=0
            $sources.Intune.Records=@(foreach ($serial in $IntuneSerials) { $i++; [pscustomobject]@{Name='PC-TEST';ManagedDeviceId="intune-$i";SerialNumber=$serial;AzureADDeviceId=''} })
            $i=0
            $sources.GLPI.Records=@(foreach ($serial in $GlpiSerials) {
                $g=$Groups[[Math]::Min($i,$Groups.Count-1)]; $i++
                [pscustomobject]@{Name='PC-TEST';GlpiId=$i;SerialNumber=$serial;State='Assegnato';GroupName=$g;GroupVerified=$Verified;GroupError=''}
            })
            @(Merge-ExplorerResults $sources @('dc.example.invalid'))[0]
        }
        $row=New-TestRow
        if ($row.SerialCheck -ne 'Coerente' -or $row.SerialConflict -or $row.Censito -ne '✓' -or $row.CensitoColor -ne 'Verde') { throw 'Matching serials and assigned CENSITO group not confirmed.' }
        'PASS: case-insensitive hardware serial match and exact assigned group yield a green census check.'
        $row=New-TestRow -GlpiSerials @('DIFFERENT')
        if (-not $row.SerialConflict -or $row.SerialCheck -ne 'Conflitto' -or $row.Censito -eq '✓' -or $row.Note -notlike '*Eliminazione bloccata*') { throw 'Different hardware merged as verified census.' }
        'PASS: different hardware under the same name is exposed as a conflict and cannot gain a census check.'
        $row=New-TestRow -IntuneSerials @('ABC-123','OLD-456')
        if (-not $row.SerialConflict -or $row.IntuneSerial -notlike '*OLD-456*' -or $row.Intune -ne '2') { throw 'Old Intune hardware silently picked or discarded.' }
        'PASS: conflicting instances within one source retain every ID and serial.'
        foreach ($placeholder in @('', 'To be filled by O.E.M.', 'Default string', '000000', 'Unknown', 'N/A')) {
            $row=New-TestRow -IntuneSerials @($placeholder) -GlpiSerials @($placeholder)
            if ($row.SerialCheck -eq 'Coerente' -or $row.SerialConflict) { throw 'Placeholder treated as hardware identity.' }
        }
        $row=New-TestRow -IntuneSerials @('ABC-123','')
        if ($row.SerialCheck -eq 'Coerente') { throw 'Missing serial on duplicate instance hidden.' }
        $row=New-TestRow -GlpiSerials @()
        if ($row.SerialCheck -eq 'Coerente' -or $row.Censito -eq '✓') { throw 'Absent GLPI treated as matching hardware.' }
        'PASS: missing, placeholder and partially missing serials remain non-verifiable.'
        foreach ($group in @('NON CENSITO','CENSITO OLD','Altro > CENSITO','')) {
            if ((New-TestRow -Groups @($group)).Censito -eq '✓') { throw 'Substring or empty group falsely confirmed census.' }
        }
        if ((New-TestRow -Groups @('censito')).Censito -ne '✓') { throw 'Group case normalization failed.' }
        if ((New-TestRow -GlpiSerials @('ABC-123','ABC-123') -Groups @('CENSITO','ALTRO')).Censito -ne '?') { throw 'Mixed GLPI groups falsely confirmed census.' }
        'PASS: census uses exact group name and never hides conflicting groups behind a single check.'
        if ((New-TestRow -Verified $false).Censito -ne '?' -or (New-TestRow -GlpiState 'Errore').Censito -ne '?') { throw 'Unavailable group or inventory returned false certainty.' }
        'PASS: group and source failures keep census explicitly unknown.'
        $row=New-TestRow -IntuneSerials @('ABC123') -GlpiSerials @('ABC-123')
        if (-not $row.SerialConflict) { throw 'Normalization removed significant serial characters.' }
        'PASS: serial punctuation remains significant to avoid merging different hardware.'
    }
}
finally { Remove-Module -ModuleInfo $module -Force }
