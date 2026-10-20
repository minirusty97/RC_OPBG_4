#requires -version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$AssetDirectory)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
if ($env:GITHUB_EVENT_NAME -ne 'push' -or $env:GITHUB_REF -ne 'refs/heads/main') { throw 'La pubblicazione richiede un push su main.' }
$root=Split-Path $PSScriptRoot -Parent
$manifest=Get-Content -LiteralPath (Join-Path $root 'assistente-it.json') -Raw | ConvertFrom-Json
$version=[string]$manifest.Version
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'Versione di rilascio non valida.' }
$tag='v'+$version
$notes=Join-Path $root ('docs/releases/'+$version+'.md')
$setup=Join-Path $AssetDirectory ('Assistente-IT-Setup-'+$version+'.exe')
$checksum=Join-Path $AssetDirectory ('Assistente-IT-'+$version+'-SHA256.txt')
$feedPath=Join-Path $AssetDirectory 'update.json'
foreach($path in @($notes,$setup,$checksum,$feedPath)){if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw ('File di rilascio assente: '+[IO.Path]::GetFileName($path))}}
$expected=(([IO.File]::ReadAllText((Resolve-Path $checksum).ProviderPath)).Trim() -split '\s+')[0]
if((Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash -ne $expected){throw 'Checksum del setup non valido.'}
$feed=Get-Content -LiteralPath $feedPath -Raw -Encoding UTF8 | ConvertFrom-Json
$prefix='https://github.com/'+$env:GITHUB_REPOSITORY+'/releases/download/'+$tag+'/'
if ($feed.SchemaVersion -ne 1 -or $feed.Product -cne $manifest.Product -or $feed.Repository -cne $env:GITHUB_REPOSITORY -or
    $feed.Channel -cne 'stable' -or $feed.Version -cne $version -or $feed.SetupName -cne [IO.Path]::GetFileName($setup) -or
    $feed.SetupUri -cne ($prefix+[IO.Path]::GetFileName($setup)) -or $feed.ChecksumUri -cne ($prefix+[IO.Path]::GetFileName($checksum)) -or
    $feed.SHA256 -ine $expected -or $feed.Size -ne (Get-Item -LiteralPath $setup).Length) { throw 'Manifest aggiornamenti incoerente con gli asset verificati.' }
$api='https://api.github.com/repos/'+$env:GITHUB_REPOSITORY
$headers=@{Authorization=('Bearer '+$env:GH_TOKEN);Accept='application/vnd.github+json'}
function Get-ReleaseResource {
    param([string]$Path)
    try { return Invoke-RestMethod -Uri ($api+$Path) -Headers $headers }
    catch { if($null -ne $_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404){return $null};throw }
}
$existing=Get-ReleaseResource ('/releases/tags/'+$tag)
if($null -ne $existing -and -not $existing.draft){Write-Host ('Release '+$tag+' già pubblicata: nessun asset viene sostituito. Incrementare Version per un nuovo rilascio.');exit 0}
$reference=Get-ReleaseResource ('/git/ref/tags/'+$tag)
if($null -ne $reference){
    $target=$reference.object
    if($target.type -eq 'tag'){$target=(Get-ReleaseResource ('/git/tags/'+$target.sha)).object}
    if($target.sha -ne $env:GITHUB_SHA){throw 'Il tag esistente appartiene a un altro commit. Incrementare la versione.'}
}
if($null -ne $existing -and $existing.target_commitish -ne $env:GITHUB_SHA){throw 'La bozza esistente appartiene a un altro commit.'}
if($null -eq $existing){
    & gh release create $tag $setup $checksum $feedPath --repo $env:GITHUB_REPOSITORY --target $env:GITHUB_SHA --draft --title ($manifest.Product+' '+$version) --notes-file $notes
    if($LASTEXITCODE -ne 0){throw 'Creazione della release non riuscita.'}
}
else {
    & gh release upload $tag $setup $checksum $feedPath --repo $env:GITHUB_REPOSITORY --clobber
    if($LASTEXITCODE -ne 0){throw 'Caricamento degli asset non riuscito.'}
}
& gh release edit $tag --repo $env:GITHUB_REPOSITORY --draft=false --latest
if($LASTEXITCODE -ne 0){throw 'Pubblicazione della release non riuscita.'}
