#requires -version 5.1
$ErrorActionPreference='Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { Write-Host 'SKIP: real DPAPI requires Windows; no plaintext substitute is used.'; return }
. (Join-Path $PSScriptRoot '../Glpi.Credentials.ps1')
$directory=Join-Path ([IO.Path]::GetTempPath()) ('glpi-dpapi-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($directory)
$path=Join-Path $directory '.env'; $store=Get-ExplorerGlpiStorePath $path
function Assert-Secret {
    param([Security.SecureString]$Actual,[string]$Expected)
    $secure=ConvertTo-SecureString $Expected -AsPlainText -Force
    try { if (-not (Test-ExplorerGlpiSecretEqual $Actual $secure)) { throw 'Token roundtrip failed.' } }
    finally { $secure.Dispose() }
}
try {
    if ($null -ne (Read-ExplorerGlpiCredentials -Path $path)) { throw 'Missing credentials did not permit entry.' }
    [IO.File]::WriteAllText($path,"# keep comment`r`nOTHER=value`r`nexport GLPI_USER_TOKEN='literal#user`$x'`r`nGLPI_APP_TOKEN='literal-app'`r`n")
    $credentials=Read-ExplorerGlpiCredentials -Path $path
    try { Assert-Secret $credentials.User 'literal#user$x'; Assert-Secret $credentials.App 'literal-app' } finally { Close-ExplorerGlpiSecrets $credentials }
    $envText=[IO.File]::ReadAllText($path);$encrypted=[IO.File]::ReadAllText($store)
    if ($envText -match 'GLPI_(USER|APP)_TOKEN|literal' -or $encrypted -match 'literal' -or $envText -notmatch 'OTHER=value' -or $envText -notmatch '# keep comment') { throw 'Migration leaked tokens or removed unrelated data.' }
    $acl=Get-Acl -LiteralPath $store
    if (-not $acl.AreAccessRulesProtected -or @($acl.Access | Where-Object { $_.IsInherited }).Count) { throw 'Credential file has inherited access rules.' }
    'PASS: real Windows DPAPI roundtrip migrates both tokens, preserves unrelated env data and restricts file ACL.'
    $before=(Get-FileHash $store).Hash
    $credentials=Read-ExplorerGlpiCredentials -Path $path -UseAppToken $false
    try { Assert-Secret $credentials.User 'literal#user$x'; if ($null -ne $credentials.App) { throw 'Optional app token leaked into reader output.' } } finally { Close-ExplorerGlpiSecrets $credentials }
    if ((Get-FileHash $store).Hash -ne $before) { throw 'Repeated read rewrote credentials.' }
    $credentials=Read-ExplorerGlpiCredentials -Path $path
    try { Assert-Secret $credentials.App 'literal-app' } finally { Close-ExplorerGlpiSecrets $credentials }
    'PASS: repeated reads are idempotent; disabling app-token use does not erase the stored app token.'
    $newUser=ConvertTo-SecureString 'new-user' -AsPlainText -Force
    try { Save-ExplorerGlpiCredentials -Path $path -User $newUser } finally { $newUser.Dispose() }
    $credentials=Read-ExplorerGlpiCredentials -Path $path
    try { Assert-Secret $credentials.User 'new-user'; Assert-Secret $credentials.App 'literal-app' } finally { Close-ExplorerGlpiSecrets $credentials }
    'PASS: saving one token preserves the other and writes no plaintext.'
    $child=Join-Path $directory 'read.ps1'
    $helper=(Resolve-Path (Join-Path $PSScriptRoot '../Glpi.Credentials.ps1')).ProviderPath.Replace("'","''")
    [IO.File]::WriteAllText($child,("param([string]`$Path)`r`n. '"+$helper+"'`r`n`$ErrorActionPreference='Stop';`$c=Read-ExplorerGlpiCredentials -Path `$Path; if (`$null -eq `$c.User -or `$null -eq `$c.App) {exit 2}; Close-ExplorerGlpiSecrets `$c"))
    & (Join-Path $PSHOME 'powershell.exe') -NoProfile -File $child -Path $path
    if ($LASTEXITCODE -ne 0) { throw 'Credentials cannot be reopened in a fresh process.' }
    'PASS: persisted credentials reopen in a fresh Windows PowerShell process without a portable key.'
    [IO.File]::WriteAllText($path,"GLPI_USER_TOKEN='conflicting-user'`r`nGLPI_APP_TOKEN='conflicting-app'")
    $before=(Get-FileHash $store).Hash; $plainBefore=(Get-FileHash $path).Hash
    $failed=$false
    try { $c=Read-ExplorerGlpiCredentials -Path $path; Close-ExplorerGlpiSecrets $c } catch { $failed=$_.Exception.Message -like '*diversi*' }
    if (-not $failed -or (Get-FileHash $path).Hash -ne $plainBefore -or (Get-FileHash $store).Hash -ne $before) { throw 'Conflicting legacy tokens lost or overwrote valid credentials.' }
    'PASS: conflicting legacy and encrypted credentials fail safely without modifying either file.'
    $u=ConvertTo-SecureString 'resolved-user' -AsPlainText -Force; $a=ConvertTo-SecureString 'resolved-app' -AsPlainText -Force
    try { Save-ExplorerGlpiCredentials -Path $path -User $u -App $a } finally { $u.Dispose();$a.Dispose() }
    if ([IO.File]::ReadAllText($path) -match 'conflicting|GLPI_') { throw 'Explicit replacement did not resolve plaintext conflict.' }
    $valid=[IO.File]::ReadAllText($store)
    [IO.File]::WriteAllText($path,"GLPI_USER_TOKEN='must-survive'`r`n")
    foreach ($bad in @('{bad json}', '{"SchemaVersion":1,"Protection":"Windows-DPAPI-CurrentUser","User":"01000000deadbeef","App":null}')) {
        [IO.File]::WriteAllText($store,$bad)
        $plainBefore=(Get-FileHash $path).Hash; $failed=$false
        try { $c=Read-ExplorerGlpiCredentials -Path $path; Close-ExplorerGlpiSecrets $c } catch { $failed=$_.Exception.Message -like '*non leggibili*' }
        if (-not $failed -or (Get-FileHash $path).Hash -ne $plainBefore -or [IO.File]::ReadAllText($store) -ne $bad) { throw 'Invalid store caused fallback, overwrite or plaintext removal.' }
    }
    'PASS: malformed or undecryptable stores never fall back to plaintext or delete the legacy file.'
    [IO.File]::WriteAllText($store,$valid)
    Remove-Item -LiteralPath $store
    # Simulate an encrypted-file write failure before migration cleanup.
    $writeFunction=${function:Write-ExplorerGlpiPrivateFile}
    function Write-ExplorerGlpiPrivateFile { throw 'Synthetic write failure.' }
    $failed=$false
    try { $c=Read-ExplorerGlpiCredentials -Path $path; Close-ExplorerGlpiSecrets $c } catch { $failed=$_.Exception.Message -eq 'Synthetic write failure.' }
    Set-Item Function:Write-ExplorerGlpiPrivateFile $writeFunction
    if (-not $failed -or [IO.File]::ReadAllText($path) -notmatch 'must-survive' -or (Test-Path $store)) { throw 'Failed persistence destroyed plaintext credentials.' }
    $c=Read-ExplorerGlpiCredentials -Path $path -UseAppToken $false
    try { Assert-Secret $c.User 'must-survive' } finally { Close-ExplorerGlpiSecrets $c }
    if ([IO.File]::ReadAllText($path) -match 'must-survive') { throw 'Retry did not finish migration.' }
    'PASS: failed encrypted persistence retains plaintext and a later retry safely completes migration.'
    if (@(Get-ChildItem -LiteralPath $directory -Filter '*.tmp').Count) { throw 'Temporary credential files remain.' }
}
finally { Remove-Item -LiteralPath $directory -Recurse -Force }
