#requires -version 5.1
[CmdletBinding()]
param([string]$ToolPath = (Join-Path $PSScriptRoot '../Test-AdLookup.ps1'))
$ErrorActionPreference = 'Stop'
$fixture = @{ Mode = 'Full'; Requests = (New-Object 'System.Collections.Generic.List[object]') }

# Le funzioni nello scope di questo test sostituiscono soltanto le letture AD.
function Import-Module {
    [CmdletBinding()]
    param([string]$Name)
    if ($Name -ne 'ActiveDirectory') { throw 'Unexpected module import.' }
}

function Get-ADComputer {
    [CmdletBinding()]
    param([string]$Server, [string]$LDAPFilter, [string[]]$Properties)
    [void]$fixture.Requests.Add([pscustomobject]@{Server=$Server;Filter=$LDAPFilter;Properties=$Properties})
    if ($fixture.Mode -eq 'Failure' -and $Server -eq 'dc5.example.invalid') { throw 'Synthetic unavailable DC.' }
    if ($fixture.Mode -eq 'None') { return }
    if ($fixture.Mode -eq 'Partial' -and $Server -notin @('dc1.example.invalid','dc2.example.invalid')) { return }
    $name = 'PC-TEST'
    $canonical = 'example.invalid/Lab, A/PC-TEST'
    $guid = '11111111-1111-4111-8111-111111111111'
    if ($fixture.Mode -eq 'Case' -and $Server -eq 'dc5.example.invalid') { $name = 'pc-test' }
    if ($fixture.Mode -eq 'Identity' -and $Server -eq 'dc5.example.invalid') { $guid = '22222222-2222-4222-8222-222222222222' }
    if ($fixture.Mode -eq 'Path' -and $Server -eq 'dc5.example.invalid') { $canonical = 'example.invalid/Other/PC-TEST' }
    if ($fixture.Mode -eq 'EscapedPath') { $name = 'PC/A'; $canonical = 'example.invalid/Lab/PC\/A' }
    [pscustomobject]@{
        Name=$name;CanonicalName=$canonical;ObjectGUID=[guid]$guid;Enabled=$true
        DistinguishedName='CN=PC-TEST,OU=Lab\, A,DC=example,DC=invalid'
        DNSHostName='PC-TEST.example.invalid';SamAccountName='PC-TEST$'
    }
    if ($fixture.Mode -eq 'Invalid' -and $Server -eq 'dc1.example.invalid') {
        [pscustomobject]@{Name='PC-BAD';ObjectGUID=[guid]::Empty}
    }
}

Set-Item -Path Function:Get-ADComputer -Value ((Get-Item -Path Function:Get-ADComputer).ScriptBlock.GetNewClosure())

$configPath = Join-Path ([IO.Path]::GetTempPath()) ('ad-lookup-' + [guid]::NewGuid().ToString('N') + '.json')
try {
    @{
        DomainControllers=@(1..5 | ForEach-Object { 'dc{0}.example.invalid' -f $_ })
        Search=@{MinimumCharacters=2}
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath -Encoding UTF8
    foreach ($mode in @('Full','Partial','Failure','None','Case','Identity','Path','EscapedPath','Invalid')) {
        $fixture.Mode = $mode
        $fixture.Requests.Clear()
        $result = & $ToolPath -NameFragment 'PC-' -ConfigPath $configPath -PassThru
        if ($result.Sources.Count -ne 5 -or $fixture.Requests.Count -ne 5) { throw "Missing DC query: $mode" }
        if ($mode -eq 'None') {
            if ($result.Summary.Count -ne 0 -or @($result.Sources | Where-Object { -not $_.Verificato }).Count -ne 0) { throw 'Incorrect empty result.' }
        }
        else {
            if ($result.Summary.Count -ne 1) { throw "Incorrect name grouping: $mode" }
            $row = $result.Summary[0]
            if ($mode -eq 'Partial') {
                if ($row.AD -ne '2/5' -or $row.Verificati -ne '5/5' -or $row.Colore -ne 'Giallo') { throw 'Incorrect partial presence.' }
            }
            elseif ($mode -in @('Failure','Invalid')) {
                if ($row.AD -ne '4/5' -or $row.Verificati -ne '4/5' -or $row.Colore -ne 'Grigio') { throw 'Failed DC shown as verified.' }
                if ($result.Computers.Count -ne 4) { throw 'Partial failed-DC records escaped.' }
            }
            elseif ($row.AD -ne '5/5' -or $row.Colore -ne 'Verde') { throw "Incorrect complete presence: $mode" }
            if ($mode -eq 'Identity' -and -not $row.IdentitaDiverse) { throw 'Different GUIDs not reported.' }
            if ($mode -eq 'Path' -and -not $row.PercorsiDiversi) { throw 'Different paths not reported.' }
            if ($mode -eq 'EscapedPath' -and $row.PercorsoAD -ne 'example.invalid/Lab') { throw 'Escaped slash interpreted as a separator.' }
            if ($mode -eq 'Full' -and $row.PercorsoAD -ne 'example.invalid/Lab, A') { throw 'Incorrect canonical parent.' }
        }
        "PASS: AD simulated / $mode."
    }
    $fixture.Mode = 'Full'
    $fixture.Requests.Clear()
    $null = & $ToolPath -NameFragment 'PC*(X)\Z' -ConfigPath $configPath -PassThru
    $expected = '(|(name=*PC\2a\28X\29\5cZ*)(dNSHostName=*PC\2a\28X\29\5cZ*)(sAMAccountName=*PC\2a\28X\29\5cZ*))'
    if (@($fixture.Requests | Where-Object { $_.Filter -ne $expected }).Count -ne 0) { throw 'LDAP input escaping failed.' }
    'PASS: literal input escaped in every LDAP field.'
    $fixture.Requests.Clear()
    $rejected = $false
    try { & $ToolPath -NameFragment 'P' -ConfigPath $configPath -PassThru | Out-Null }
    catch { $rejected = $_.Exception.Message -like '*almeno 2*' }
    if (-not $rejected -or $fixture.Requests.Count -ne 0) { throw 'Short input queried AD.' }
    'PASS: short input stopped before AD queries.'
}
finally {
    Remove-Item -LiteralPath $configPath -Force -ErrorAction SilentlyContinue
}
