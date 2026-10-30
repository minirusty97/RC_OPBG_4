#requires -version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'DeviceModules.Core.psm1') -Force
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('module-settings-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temporary)
try {
    $config=Join-Path $temporary 'config.json'
    [IO.File]::WriteAllText($config,'{"DomainControllers":["dc.example.invalid"],"Glpi":{"Enabled":false}}')
    $before=[IO.File]::ReadAllText($config)
    $hybrid=Read-DmSettings $config HybridJoin;$ring=Read-DmSettings $config RingManager
    if ($hybrid.Options.TargetOus.Count -ne 0 -or $ring.Options.Groups.Count -ne 0 -or [IO.File]::ReadAllText($config) -cne $before) { throw 'Existing user settings gained automatic OU/group assignments or were overwritten.' }
    'PASS: existing installations retain their configuration; new modules start without automatic OU or group selections, including no Ring99.'
    $source=Join-Path $temporary 'source.ps1'
    [IO.File]::WriteAllText($source,"param([string]`$AdServer='dc.example.invalid',[string[]]`$TargetOuRelativeDistinguishedNames=@('OU=Lab','OU=Child,OU=Lab'))`r`nthrow 'This script must never run.'")
    $imported=Read-DmHybridScriptDefaults $source
    if ($imported.TargetOus.Count -ne 2 -or $imported.AdServer -ne 'dc.example.invalid') { throw 'Constant OU parameter defaults did not import.' }
    [IO.File]::WriteAllText($source,'param([string[]]$TargetOuRelativeDistinguishedNames=@(throw "do not evaluate"))')
    $failed=$false;try { $null=Read-DmHybridScriptDefaults $source } catch { $failed=$_.Exception.Message -like '*costanti*' }
    if (-not $failed) { throw 'Dynamic script defaults were evaluated instead of rejected.' }
    'PASS: OU import reads constant parameter syntax without executing the source script and rejects executable expressions.'
}
finally { Remove-Item $temporary -Recurse -Force }
