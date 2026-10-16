#requires -version 5.1
# Shared by suite settings and standalone explorer. Never uses a portable key.
function Read-ExplorerGlpiEnvValues {
    [CmdletBinding()]
    param(
        [string]$Path = (Join-Path $PSScriptRoot '.env'),
        [bool]$UseAppToken = $true
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @{} }
    $values = @{}
    $lineNumber = 0
    # Il file viene letto come dati: nessuna espansione e nessuna esecuzione.
    foreach ($line in [IO.File]::ReadAllLines((Resolve-Path -LiteralPath $Path).ProviderPath, [Text.Encoding]::UTF8)) {
        $lineNumber++
        $text = $line.Trim()
        if ($text.Length -eq 0 -or $text.StartsWith('#')) { continue }
        if ($text -notmatch '^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
            throw "Formato .env non valido alla riga $lineNumber. Usare NOME=valore."
        }
        $key = $Matches[1]
        $value = $Matches[2].Trim()
        if ($key -cnotin @('GLPI_USER_TOKEN', 'GLPI_APP_TOKEN')) { continue }
        if ($values.ContainsKey($key)) { throw "Chiave $key duplicata nel .env alla riga $lineNumber." }
        if ($value.StartsWith('"') -or $value.StartsWith("'")) {
            $quote = [regex]::Escape($value.Substring(0, 1))
            if ($value -notmatch ('^{0}(.*?){0}\s*(?:#.*)?$' -f $quote)) {
                throw "Virgolette .env non valide alla riga $lineNumber."
            }
            $value = $Matches[1]
        }
        else { $value = ($value -replace '\s+#.*$', '').TrimEnd() }
        $values[$key] = $value
    }
    return $values
}


function Get-ExplorerGlpiStorePath {
    param([string]$Path)
    Join-Path (Split-Path ([IO.Path]::GetFullPath($Path)) -Parent) 'glpi-credentials.dpapi.json'
}

function Close-ExplorerGlpiSecrets {
    param($Secrets)
    if ($null -ne $Secrets) {
        foreach ($field in @('User','App')) { if ($null -ne $Secrets.$field) { $Secrets.$field.Dispose() } }
    }
}

function Read-ExplorerGlpiStore {
    param([string]$Path)
    $result=[pscustomobject]@{User=$null;App=$null}
    if (-not [IO.File]::Exists($Path)) { return $result }
    try {
        $data=[IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
        if ($data.SchemaVersion -ne 1 -or $data.Protection -ne 'Windows-DPAPI-CurrentUser') { throw 'Invalid store.' }
        foreach ($field in @('User','App')) {
            $value=$data.PSObject.Properties[$field]
            if ($null -eq $value) { throw 'Missing field.' }
            if ($null -ne $value.Value -and [string]$value.Value -ne '') {
                $result.$field=ConvertTo-SecureString -String ([string]$value.Value) -ErrorAction Stop
                if ($result.$field.Length -eq 0) { throw 'Empty secret.' }
            }
        }
        return $result
    }
    catch {
        Close-ExplorerGlpiSecrets $result
        throw 'Credenziali GLPI cifrate non leggibili. Usare lo stesso account Windows sul PC originale; non copiare il file tra colleghi. Il file esistente non e stato modificato.'
    }
}

function Test-ExplorerGlpiSecretEqual {
    param([Security.SecureString]$Left,[Security.SecureString]$Right)
    if ($null -eq $Left -or $null -eq $Right) { return $null -eq $Left -and $null -eq $Right }
    if ($Left.Length -ne $Right.Length) { return $false }
    $a=[IntPtr]::Zero; $b=[IntPtr]::Zero
    try {
        $a=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($Left)
        $b=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($Right)
        for ($i=0;$i -lt $Left.Length;$i++) {
            if ([Runtime.InteropServices.Marshal]::ReadInt16($a,$i*2) -ne [Runtime.InteropServices.Marshal]::ReadInt16($b,$i*2)) { return $false }
        }
        return $true
    }
    finally {
        if ($a -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($a) }
        if ($b -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
    }
}

function Write-ExplorerGlpiPrivateFile {
    param([string]$Path,[string]$Text,[switch]$Private,$Expected)
    $temporary=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        # Create private encrypted temp before writing content.
        if ($Private) {
            $acl=New-Object Security.AccessControl.FileSecurity
            $acl.SetAccessRuleProtection($true,$false)
            $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
            $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid,'FullControl','Allow')))
            $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier('S-1-5-18')),'FullControl','Allow')))
            $stream=New-Object IO.FileStream($temporary,[IO.FileMode]::CreateNew,[Security.AccessControl.FileSystemRights]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::None,$acl)
            $stream.Dispose()
        }
        [IO.File]::WriteAllText($temporary,$Text,(New-Object Text.UTF8Encoding($true)))
        if ($Private) {
            $verified=Read-ExplorerGlpiStore $temporary
            try {
                foreach ($field in @('User','App')) { if (-not (Test-ExplorerGlpiSecretEqual $Expected.$field $verified.$field)) { throw 'Verifica delle credenziali cifrate fallita prima del salvataggio.' } }
            }
            finally { Close-ExplorerGlpiSecrets $verified }
        }
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary,$Path,[Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temporary,$Path) }
        if ($Private) { Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop }
    }
    finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function Update-ExplorerGlpiStore {
    param([string]$Path,[hashtable]$Updates=@{})
    $store=Get-ExplorerGlpiStorePath $Path
    # Windows is mandatory: PowerShell on Linux must never silently persist plaintext.
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Il salvataggio sicuro dei token GLPI richiede Windows DPAPI.' }
    $hash=[Security.Cryptography.SHA256]::Create()
    try { $name=([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($store.ToUpperInvariant())))).Replace('-','') }
    finally { $hash.Dispose() }
    $mutex=New-Object Threading.Mutex($false,('Local\AssistenteIT.Glpi.'+$name))
    $locked=$false; $secrets=$null
    try {
        try { $locked=$mutex.WaitOne(15000) } catch [Threading.AbandonedMutexException] { $locked=$true }
        if (-not $locked) { throw 'Credenziali GLPI occupate da un altro processo. Riprovare.' }
        $secrets=Read-ExplorerGlpiStore $store
        $values=Read-ExplorerGlpiEnvValues -Path $Path
        $changed=$false; $hasLegacy=$false
        foreach ($pair in @(@('GLPI_USER_TOKEN','User'),@('GLPI_APP_TOKEN','App'))) {
            $key=$pair[0]; $field=$pair[1]
            if ($values.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace($values[$key])) {
                $hasLegacy=$true
                $legacy=ConvertTo-SecureString $values[$key] -AsPlainText -Force
                try {
                    if ($null -eq $secrets.$field) { $secrets.$field=$legacy.Copy(); $changed=$true }
                    elseif (-not $Updates.ContainsKey($field) -and -not (Test-ExplorerGlpiSecretEqual $secrets.$field $legacy)) {
                        throw 'Token GLPI diversi tra .env e archivio cifrato. Reinserire entrambi dalle impostazioni per risolvere il conflitto. Nessun file e stato rimosso.'
                    }
                }
                finally { $legacy.Dispose() }
            }
            if ($Updates.ContainsKey($field)) {
                if ($null -ne $secrets.$field) { $secrets.$field.Dispose() }
                $secrets.$field=$Updates[$field].Copy(); $changed=$true
            }
        }
        $values.Clear()
        if ($changed) {
            $data=[ordered]@{SchemaVersion=1;Protection='Windows-DPAPI-CurrentUser';User=$null;App=$null}
            foreach ($field in @('User','App')) { if ($null -ne $secrets.$field) { $data[$field]=ConvertFrom-SecureString $secrets.$field -ErrorAction Stop } }
            Write-ExplorerGlpiPrivateFile -Path $store -Text ($data | ConvertTo-Json) -Private -Expected $secrets
        }
        if ($hasLegacy -or $changed) {
            # Reopen the committed file and compare every token before removing plaintext.
            $verified=Read-ExplorerGlpiStore $store
            try {
                foreach ($field in @('User','App')) { if (-not (Test-ExplorerGlpiSecretEqual $secrets.$field $verified.$field)) { throw 'Verifica delle credenziali GLPI cifrate fallita. Il .env non e stato ripulito.' } }
            }
            finally { Close-ExplorerGlpiSecrets $verified }
            if ([IO.File]::Exists($Path)) {
                $lines=@([IO.File]::ReadAllLines($Path,[Text.Encoding]::UTF8) | Where-Object { $_ -notmatch '^\s*(?:export\s+)?(?:GLPI_USER_TOKEN|GLPI_APP_TOKEN)\s*=' })
                Write-ExplorerGlpiPrivateFile -Path $Path -Text (($lines -join [Environment]::NewLine)+[Environment]::NewLine)
            }
        }
        $result=$secrets; $secrets=$null; return $result
    }
    finally {
        Close-ExplorerGlpiSecrets $secrets
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Read-ExplorerGlpiCredentials {
    [CmdletBinding()]
    param([string]$Path=(Join-Path $PSScriptRoot '.env'),[bool]$UseAppToken=$true)
    if (-not [IO.File]::Exists($Path) -and -not [IO.File]::Exists((Get-ExplorerGlpiStorePath $Path))) { return $null }
    $credentials=Update-ExplorerGlpiStore -Path $Path
    if ($null -eq $credentials.User -or ($UseAppToken -and $null -eq $credentials.App)) { Close-ExplorerGlpiSecrets $credentials; return $null }
    if (-not $UseAppToken -and $null -ne $credentials.App) { $credentials.App.Dispose(); $credentials.App=$null }
    return $credentials
}

function Save-ExplorerGlpiCredentials {
    [CmdletBinding()]
    param([string]$Path=(Join-Path $PSScriptRoot '.env'),[Security.SecureString]$User,[Security.SecureString]$App)
    $updates=@{}
    foreach ($field in @('User','App')) {
        $secret=Get-Variable -Name $field -ValueOnly
        if ($null -ne $secret -and $secret.Length -gt 0) { $updates[$field]=$secret }
    }
    $saved=Update-ExplorerGlpiStore -Path $Path -Updates $updates
    Close-ExplorerGlpiSecrets $saved
}
