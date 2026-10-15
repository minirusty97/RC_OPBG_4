#requires -version 5.1
# Legacy names are used only here to find and migrate existing personal data.
function Move-AssistenteITUserData {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$DataRoot, [string]$LegacyRoot)
    $defaultLegacy = [string]::IsNullOrWhiteSpace($LegacyRoot)
    if ($defaultLegacy) {
        $local = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
        if ([string]::IsNullOrWhiteSpace($local)) { throw 'Cartella dati utente non disponibile.' }
        $LegacyRoot = Join-Path (Join-Path $local 'OPBG') 'ITSuite'
    }
    $source = [IO.Path]::GetFullPath($LegacyRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $target = [IO.Path]::GetFullPath($DataRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if ($source.Equals($target, [StringComparison]::OrdinalIgnoreCase)) { return }
    if ($target.StartsWith($source + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
        $source.StartsWith($target + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Le cartelle di migrazione devono essere separate.' }
    if (-not [IO.Directory]::Exists($source)) { return }
    if (-not [IO.Directory]::Exists($target)) {
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
        [IO.Directory]::Move($source, $target)
    }
    else {
        # Keep current files when both versions have data. Copy missing files
        # atomically, then retain the complete previous tree in an archive.
        foreach ($file in Get-ChildItem -LiteralPath $source -File -Recurse -Force -ErrorAction Stop) {
            $relative = $file.FullName.Substring($source.Length + 1)
            $destination = Join-Path $target $relative
            if (-not (Test-Path -LiteralPath $destination)) {
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
                $temporary = $destination + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
                try {
                    [IO.File]::Copy($file.FullName, $temporary, $false)
                    [IO.File]::Move($temporary, $destination)
                }
                finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
            }
        }
        $archive = Join-Path $target 'Importazione-precedente'
        [void][IO.Directory]::CreateDirectory($archive)
        [IO.Directory]::Move($source, (Join-Path $archive ([guid]::NewGuid().ToString('N'))))
    }
    if ($defaultLegacy) {
        # Remove only the now-empty legacy parent, never other applications.
        try { [IO.Directory]::Delete([IO.Path]::GetDirectoryName($source), $false) }
        catch [IO.IOException] { }
    }
}
