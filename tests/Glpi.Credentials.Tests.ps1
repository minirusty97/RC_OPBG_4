#requires -version 5.1
[CmdletBinding()]
param([string]$ModulePath = (Join-Path $PSScriptRoot '../ComputerExplorer.Core.psm1'))
$ErrorActionPreference = 'Stop'
Import-Module $ModulePath -Force -ErrorAction Stop
$directory = Join-Path ([IO.Path]::GetTempPath()) ('glpi-env-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($directory)
$envFile = Join-Path $directory '.env'

function Assert-Credentials {
    param($Credentials, [string]$User, $App)
    if ($null -eq $Credentials -or $Credentials.User -isnot [Security.SecureString]) { throw 'Credentials not returned as SecureString.' }
    foreach ($field in @('User', 'App')) {
        $expected = $User
        if ($field -eq 'App') { $expected = $App }
        if ($null -eq $expected) {
            if ($null -ne $Credentials.$field) { throw 'Unexpected app token.' }
            continue
        }
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Credentials.$field)
        try {
            if ([Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) -cne $expected) { throw 'Token value changed.' }
        }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer); $Credentials.$field.Dispose() }
    }
}

try {
    if ($null -ne (Read-ExplorerGlpiCredentials -Path $envFile)) { throw 'Missing file did not allow fallback.' }
    'PASS: missing .env allows prompt fallback.'
    [IO.File]::WriteAllText($envFile, "GLPI_USER_TOKEN=user-token`nGLPI_APP_TOKEN=app-token", [Text.Encoding]::UTF8)
    Assert-Credentials (Read-ExplorerGlpiCredentials -Path $envFile) 'user-token' 'app-token'
    'PASS: unquoted tokens loaded as SecureString.'
    $lines = @('# comment', '', " export GLPI_USER_TOKEN = 'user=a#b' # comment", ' GLPI_APP_TOKEN = "app # = value" # comment', 'UNRELATED_SETTING=ignored')
    [IO.File]::WriteAllLines($envFile, $lines, [Text.Encoding]::UTF8)
    Assert-Credentials (Read-ExplorerGlpiCredentials -Path $envFile) 'user=a#b' 'app # = value'
    'PASS: BOM, CRLF, comments, export, quotes and embedded delimiters.'
    [IO.File]::WriteAllLines($envFile, @('GLPI_USER_TOKEN=''$(throw "must-not-run")''', 'GLPI_APP_TOKEN=literal$VALUE#suffix'), [Text.Encoding]::UTF8)
    Assert-Credentials (Read-ExplorerGlpiCredentials -Path $envFile) '$(throw "must-not-run")' 'literal$VALUE#suffix'
    'PASS: expressions and variable markers remain literal data.'
    [IO.File]::WriteAllText($envFile, 'GLPI_USER_TOKEN=user-only', [Text.Encoding]::UTF8)
    if ($null -ne (Read-ExplorerGlpiCredentials -Path $envFile)) { throw 'Missing required app token accepted.' }
    Assert-Credentials (Read-ExplorerGlpiCredentials -Path $envFile -UseAppToken $false) 'user-only' $null
    'PASS: app token optional only when configured.'
    [IO.File]::WriteAllText($envFile, "GLPI_USER_TOKEN= `nGLPI_APP_TOKEN=", [Text.Encoding]::UTF8)
    if ($null -ne (Read-ExplorerGlpiCredentials -Path $envFile)) { throw 'Empty template treated as credentials.' }
    'PASS: empty template allows prompt fallback.'
    $invalidCases = @(
        @('GLPI_USER_TOKEN=synthetic-secret', 'GLPI_USER_TOKEN=other', 'GLPI_APP_TOKEN=app'),
        @('GLPI_USER_TOKEN="synthetic-secret', 'GLPI_APP_TOKEN=app'),
        @('synthetic-secret-invalid-line', 'GLPI_APP_TOKEN=app')
    )
    foreach ($lines in $invalidCases) {
        [IO.File]::WriteAllLines($envFile, [string[]]$lines, [Text.Encoding]::UTF8)
        $rejected = $false
        try { Read-ExplorerGlpiCredentials -Path $envFile | Out-Null }
        catch {
            if ($_.Exception.Message -like '*synthetic-secret*') { throw 'Parser error exposed token content.' }
            $rejected = $_.Exception.Message -like '*riga*'
        }
        if (-not $rejected) { throw 'Invalid .env not rejected safely.' }
    }
    'PASS: duplicates and malformed lines rejected without exposing values.'
}
finally { Remove-Item -LiteralPath $directory -Recurse -Force }
