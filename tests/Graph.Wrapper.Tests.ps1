#requires -version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('wrapper-session-'+[guid]::NewGuid().ToString('N'))
$sdk=Join-Path $fixture 'Microsoft.Graph.Authentication';[void][IO.Directory]::CreateDirectory($sdk)
@'
$script:Context=$null
$script:Connections=0
function Get-MgContext { [CmdletBinding()]param() return $script:Context }
function Disconnect-MgGraph { [CmdletBinding()]param() $script:Context=$null }
function Connect-MgGraph {
 [CmdletBinding()]param($Scopes,$TenantId,$ClientId,$ContextScope,$Environment,[switch]$NoWelcome)
 if ($ClientId) { if (($Scopes -join ',') -ne 'https://graph.microsoft.com/.default') { throw 'Wrapper expanded app consent.' } }
 else { if (@($Scopes).Count -ne 3 -or $Scopes -contains 'Device.Read.All' -or $Scopes -contains 'DeviceManagementManagedDevices.Read.All') { throw 'Legacy wrapper requested redundant read consents despite sufficient write scopes.' };$TenantId='11111111-1111-4111-8111-111111111111';$ClientId='22222222-2222-4222-8222-222222222222' }
 $script:Connections++
 $script:Context=[pscustomobject]@{AuthType='Delegated';TenantId=$TenantId;ClientId=$ClientId;ContextScope=$ContextScope;Environment='Global';Account='synthetic@example.invalid';Scopes=@('Device.Read.All','DeviceManagementManagedDevices.ReadWrite.All','BitlockerKey.Read.All')}
}
function Invoke-MgGraphRequest { [CmdletBinding()]param($Method,$Uri,$OutputType) if ($Method -ne 'GET') { throw 'Unexpected write.' };[pscustomobject]@{value=@()} }
function Get-FixtureConnections { return $script:Connections }
Export-ModuleMember -Function Get-MgContext,Disconnect-MgGraph,Connect-MgGraph,Invoke-MgGraphRequest,Get-FixtureConnections
'@ | Set-Content (Join-Path $sdk 'Microsoft.Graph.Authentication.psm1') -Encoding UTF8
$config=Join-Path $fixture 'config.json'
@{Graph=@{AuthenticationMode='Delegated';TenantId='11111111-1111-4111-8111-111111111111';ClientId='22222222-2222-4222-8222-222222222222'}} | ConvertTo-Json -Depth 4 | Set-Content $config -Encoding UTF8
$previous=$env:PSModulePath;$env:PSModulePath=$fixture+[IO.Path]::PathSeparator+$previous
$ps=[PowerShell]::Create()
try {
 [void]$ps.AddScript({param($Root,$Config)
  $ErrorActionPreference='Stop'
  Import-Module (Join-Path $Root 'AssistenteIT/AssistenteIT.Core.psm1') -ErrorAction Stop
  $module=(Read-AssistenteITManifest $Root).Modules[0]
  $report=Initialize-AssistenteITModuleAccess -Module $module -ConfigPath $Config
  if ($report.Permissions.Count -ne 5 -or $report.ClientId -ne $report.AppName) { throw 'Generic wrapper returned incomplete access metadata or failed its app-name fallback.' }
  # Only after wrapper verification is the first module imported.
  Import-Module (Join-Path $Root 'ComputerExplorer.Core.psm1') -ErrorAction Stop
  Connect-ExplorerGraph -Sources Entra,Intune -ForBitLocker -GraphAuthentication @{AuthenticationMode='Delegated';TenantId=$report.TenantId;ClientId=$report.ClientId}
  Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
  if ((Get-FixtureConnections) -ne 1) { throw 'Module repeated authentication after generic wrapper verification.' }
  @{Graph=@{AuthenticationMode='Interactive'}} | ConvertTo-Json -Depth 3 | Set-Content $Config -Encoding UTF8
  $null=Initialize-AssistenteITModuleAccess -Module $module -ConfigPath $Config
  if ((Get-FixtureConnections) -ne 2) { throw 'Initial Microsoft app login was repeated unexpectedly.' }
  $report
 }.ToString()).AddArgument($root).AddArgument($config)
 $result=@($ps.Invoke())
 if ($ps.Streams.Error.Count -ne 0 -or $result.Count -ne 1) { throw ('Generic wrapper polluted the error stream or lost its session: '+($ps.Streams.Error | Out-String)) }
 'PASS: the generic suite wrapper authenticates before importing Computer Explorer, returns the permission report with a client-name fallback and keeps a single shared session with a clean error stream; the Microsoft app avoids redundant read-consent requests when its write scopes already cover them.'
}
finally { $ps.Dispose();$env:PSModulePath=$previous;Remove-Item $fixture -Recurse -Force }
