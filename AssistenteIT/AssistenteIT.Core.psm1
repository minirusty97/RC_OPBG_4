#requires -version 5.1
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'LegacyMigration.ps1')
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'Graph.Authentication.ps1')
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'Glpi.Credentials.ps1')

function Read-AssistenteITManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$InstallRoot)
    $root = [IO.Path]::GetFullPath($InstallRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $manifest = Get-Content -LiteralPath (Join-Path $root 'assistente-it.json') -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
    if ($manifest.SchemaVersion -ne 1 -or $manifest.Version -notmatch '^\d+\.\d+\.\d+$' -or [string]::IsNullOrWhiteSpace($manifest.Product)) { throw 'Manifest della suite non valido.' }
    if (@($manifest.Modules).Count -eq 0) { throw 'Nessun modulo configurato nella suite.' }
    $ids = @{}
    foreach ($module in $manifest.Modules) {
        if ($module.Id -notmatch '^[a-z][a-z0-9-]{1,63}$' -or $ids.ContainsKey($module.Id)) { throw 'Identificativo di modulo non valido o duplicato.' }
        $ids[$module.Id] = $true
        $permissions=Get-ExplorerGraphSetting $module 'GraphPermissions' @()
        $permissionIds=@{}
        foreach ($permission in @($permissions)) {
            $id=[string](Get-ExplorerGraphSetting $permission 'Id')
            $name=[string](Get-ExplorerGraphSetting $permission 'Name')
            $alternatives=Get-ExplorerGraphSetting $permission 'AnyOf' @()
            if ($id -notmatch '^[a-z][a-z0-9-]{1,63}$' -or $permissionIds.ContainsKey($id) -or
                [string]::IsNullOrWhiteSpace($name) -or $name.Length -gt 120 -or -not ($alternatives -is [Array] -or $alternatives -is [Collections.IList]) -or $alternatives.Count -eq 0 -or $alternatives.Count -gt 16 -or
                @($alternatives | Where-Object { $_ -notmatch '^[A-Za-z][A-Za-z0-9.]{1,127}$' }).Count) { throw 'Requisiti Graph del modulo non validi.' }
            $permissionIds[$id]=$true
        }
        foreach ($groupList in @('ReadGroupIds','WriteGroupIds')) {
            $configuredGroups=Get-ExplorerGraphSetting $module $groupList @()
            foreach ($group in $configuredGroups) {
                $groupId=[guid]::Empty
                if (-not [guid]::TryParse([string]$group,[ref]$groupId) -or $groupId -eq [guid]::Empty) { throw 'Gruppi di autorizzazione del modulo non validi.' }
            }
        }
        foreach ($listName in @('ReadPermissionIds','WritePermissionIds')) {
            $listProperty=$module.PSObject.Properties[$listName]
            if ($null -ne $listProperty -and (@($listProperty.Value | Where-Object { -not $permissionIds.ContainsKey([string]$_) }).Count -gt 0)) { throw 'Requisiti di lettura/scrittura del modulo non validi.' }
        }
        if ([string]::IsNullOrWhiteSpace($module.EntryPoint) -or [IO.Path]::IsPathRooted($module.EntryPoint)) { throw 'Percorso del modulo non valido.' }
        $entry = [IO.Path]::GetFullPath((Join-Path $root $module.EntryPoint))
        if (-not $entry.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetExtension($entry) -ne '.ps1' -or -not (Test-Path -LiteralPath $entry -PathType Leaf)) { throw ('Modulo assente o esterno alla suite: ' + $module.Id) }
    }
    return $manifest
}

function Get-AssistenteITPaths {
    [CmdletBinding()]
    param([string]$DataRoot)
    if ([string]::IsNullOrWhiteSpace($DataRoot)) {
        $local = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
        if ([string]::IsNullOrWhiteSpace($local)) { throw 'Cartella dati utente non disponibile.' }
        $DataRoot = Join-Path $local 'AssistenteIT'
    }
    $data = [IO.Path]::GetFullPath($DataRoot)
    $config = Join-Path $data 'Config'
    return [pscustomobject]@{DataRoot=$data; ConfigDirectory=$config; ConfigPath=(Join-Path $config 'computer-explorer.config.local.json'); EnvPath=(Join-Path $config '.env')}
}

function Initialize-AssistenteIT {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$InstallRoot, [string]$DataRoot)
    $null = Read-AssistenteITManifest $InstallRoot
    $paths = Get-AssistenteITPaths $DataRoot
    if ([string]::IsNullOrWhiteSpace($DataRoot)) { Move-AssistenteITUserData -DataRoot $paths.DataRoot }
    [void][IO.Directory]::CreateDirectory($paths.ConfigDirectory)
    foreach ($item in @(
        @{Source='computer-explorer.config.example.json'; Target=$paths.ConfigPath},
        @{Source='.env.example'; Target=$paths.EnvPath}
    )) {
        if (-not (Test-Path -LiteralPath $item.Target)) {
            [IO.File]::Copy((Join-Path $InstallRoot $item.Source), $item.Target, $false)
        }
    }
    return $paths
}

function Write-AssistenteITAtomicFile {
    param([string]$Path, [string]$Text)
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, $Text, (New-Object Text.UTF8Encoding($true)))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, [System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    }
    finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function ConvertTo-AssistenteITEnvValue {
    param([string]$Value)
    if ($Value.IndexOfAny([char[]]@([char]0, [char]10, [char]13)) -ge 0) { throw 'Il token deve occupare una sola riga.' }
    if (-not $Value.Contains("'")) { return "'" + $Value + "'" }
    if (-not $Value.Contains('"')) { return '"' + $Value + '"' }
    throw 'Il formato del token non è supportato.'
}

function Save-AssistenteITSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$Paths,
        [Parameter(Mandatory=$true)][string[]]$DomainControllers,
        [string]$GlpiBaseUri='', [bool]$GlpiEnabled, [bool]$UseAppToken=$true,
        [string]$UserToken, [string]$AppToken, $GraphAuthentication, $HybridJoinSettings, $RingManagerSettings
    )
    $graph=$null
    if ($PSBoundParameters.ContainsKey('GraphAuthentication')) { $graph=ConvertTo-ExplorerGraphAuthentication $GraphAuthentication }
    $controllers = @($DomainControllers | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
    if ($controllers.Count -eq 0 -or @($controllers | Where-Object { $_ -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.-]*$' }).Count -gt 0) { throw 'Inserire almeno un DC valido, uno per riga.' }
    $uriText = $GlpiBaseUri.Trim().TrimEnd('/')
    if ($GlpiEnabled -and -not $uriText) { throw 'Specificare l''URL API di GLPI.' }
    if ($uriText) {
        $uri = $null
        if (-not [Uri]::TryCreate($uriText, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http','https') -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) { throw 'URL API GLPI non valido. Esempio: https://server/glpi/apirest.php' }
    }
    foreach ($value in @($UserToken,$AppToken)) {
        if ($null -ne $value -and $value.IndexOfAny([char[]]@([char]0,[char]10,[char]13)) -ge 0) { throw 'Il token deve occupare una sola riga.' }
    }
    if ($null -ne $HybridJoinSettings) {
        $ous=@($HybridJoinSettings.TargetOus | ForEach-Object { ([string]$_).Trim().TrimEnd(',') } | Sort-Object -Unique)
        if (@($ous | Where-Object { -not $_ -or $_ -notmatch '^OU=' -or $_ -match '[\r\n\x00]' }).Count -or $HybridJoinSettings.SearchScope -notin @('Base','OneLevel','Subtree')) { throw 'Configurazione OU Hybrid Join non valida.' }
        $server=([string]$HybridJoinSettings.AdServer).Trim()
        if ($server -and $server -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.-]*$') { throw 'Server AD Hybrid Join non valido.' }
        $HybridJoinSettings=[pscustomobject]@{AdServer=$server;SearchScope=$HybridJoinSettings.SearchScope;TargetOus=$ous}
    }
    if ($null -ne $RingManagerSettings) {
        $groups=Get-ExplorerGraphSetting $RingManagerSettings 'Groups' @();$ids=@{};$labels=@{}
        # An empty selection keeps this module unconfigured without blocking other settings.
        foreach ($group in $groups) {
            $id=([string]$group.Id).Trim();$name=([string]$group.Name).Trim();$label=([string]$group.Label).Trim()
            if (-not $name -or -not $label -or $label.Length -gt 120 -or $name -match '[\r\n\x00]' -or $label -match '[\r\n\x00]' -or $labels.ContainsKey($label)) { throw 'Nomi o etichette dei gruppi non validi o duplicati.' }
            if ($id) { $parsed=[guid]::Empty;if (-not [guid]::TryParse($id,[ref]$parsed) -or $parsed -eq [guid]::Empty -or $ids.ContainsKey($parsed.ToString())) { throw 'ID dei gruppi non validi o duplicati.' };$ids[$parsed.ToString()]=$true }
            $labels[$label]=$true
        }
        $RingManagerSettings=[pscustomobject]@{Groups=@($groups | Select-Object Id,Name,Label,CanAssign)}
    }
    $configuration = Get-Content -LiteralPath $Paths.ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -ne $graph) { $configuration | Add-Member -NotePropertyName Graph -NotePropertyValue $graph -Force }
    foreach ($section in @(@{Name='HybridJoin';Value=$HybridJoinSettings},@{Name='RingManager';Value=$RingManagerSettings})) {
        if ($null -ne $section.Value) {
            $existing=Get-ExplorerGraphSetting $configuration $section.Name ([pscustomobject]@{})
            foreach ($property in $section.Value.PSObject.Properties) { $existing | Add-Member -Force NoteProperty $property.Name $property.Value }
            $configuration | Add-Member -Force NoteProperty $section.Name $existing
        }
    }
    $configuration.DomainControllers = $controllers
    $configuration.Glpi.Enabled = $GlpiEnabled; $configuration.Glpi.BaseUri = $uriText; $configuration.Glpi.UseAppToken = $UseAppToken
    $user=$null; $app=$null
    try {
        if (-not [string]::IsNullOrWhiteSpace($UserToken)) { $user=ConvertTo-SecureString $UserToken.Trim() -AsPlainText -Force }
        if (-not [string]::IsNullOrWhiteSpace($AppToken)) { $app=ConvertTo-SecureString $AppToken.Trim() -AsPlainText -Force }
        Save-ExplorerGlpiCredentials -Path $Paths.EnvPath -User $user -App $app
    }
    finally { if ($null -ne $user) { $user.Dispose() }; if ($null -ne $app) { $app.Dispose() } }
    Write-AssistenteITAtomicFile $Paths.ConfigPath (($configuration | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
}

function Enable-AssistenteITDependencies {
    param([Parameter(Mandatory=$true)][string]$InstallRoot)
    $dependencies = Join-Path $InstallRoot 'Dependencies'
    if (Test-Path -LiteralPath $dependencies -PathType Container) {
        $parts = @($env:PSModulePath -split [IO.Path]::PathSeparator)
        if ($parts -notcontains $dependencies) { $env:PSModulePath = $dependencies + [IO.Path]::PathSeparator + $env:PSModulePath }
    }
}

function Get-AssistenteITPrerequisites {
    [CmdletBinding()]
    param()
    [pscustomobject]@{
        GraphAvailable = @(Get-Module -ListAvailable -Name Microsoft.Graph.Authentication -ErrorAction SilentlyContinue).Count -gt 0
        ActiveDirectoryAvailable = @(Get-Module -ListAvailable -Name ActiveDirectory -ErrorAction SilentlyContinue).Count -gt 0
    }
}

function Open-AssistenteITActivity {
    # All suite processes keep a handle open. Setup/uninstall refuses to run
    # while any handle exists; no running search or removal is killed.
    return New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, 'Local\AssistenteIT.Running')
}

function Initialize-AssistenteITModuleAccess {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Module,[Parameter(Mandatory=$true)][string]$ConfigPath,$ProgressQueue)
    $settings=Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $authentication=ConvertTo-ExplorerGraphAuthentication (Get-ExplorerGraphSetting $settings 'Graph')
    $definitions=Get-ExplorerGraphSetting $Module 'GraphPermissions' @()
    $scopes=@($definitions | ForEach-Object { $_.AnyOf[0] } | Sort-Object -Unique)
    # Request a scope only if removing it would leave a declared requirement
    # uncovered. For example Intune ReadWrite already covers its read requirement.
    foreach ($candidate in @($scopes)) {
        $remaining=@($scopes | Where-Object { $_ -ne $candidate })
        $uncovered=@($definitions | Where-Object { @($_.AnyOf | Where-Object { $remaining -contains $_ }).Count -eq 0 })
        if ($uncovered.Count -eq 0) { $scopes=$remaining }
    }
    if ($authentication.AuthenticationMode -eq 'Interactive' -and [bool](Get-ExplorerGraphSetting $Module 'NeedsGroupMembership' $false)) { $scopes=@($scopes+@('User.Read') | Sort-Object -Unique) }
    $context=Initialize-ExplorerGraphSession -Scopes $scopes -GraphAuthentication $authentication -ProgressQueue $ProgressQueue
    $permissions=@(Get-ExplorerGraphPermissionStatus -Definitions $definitions -Context $context -ProgressQueue $ProgressQueue -Probe)
    $appName=[string](Get-ExplorerGraphSetting $context 'AppName' '')
    if ([string]::IsNullOrWhiteSpace($appName)) { $appName=[string]$context.ClientId }
    $groups=@();$groupsVerified=$false;$groupError=''
    if ([bool](Get-ExplorerGraphSetting $Module 'NeedsGroupMembership' $false)) {
        try {
            $next='https://graph.microsoft.com/v1.0/me/transitiveMemberOf?$select=id';$visited=@{}
            while ($next) {
                $uri=[uri]$next
                if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'graph.microsoft.com' -or $uri.Port -ne 443 -or $uri.AbsolutePath -ne '/v1.0/me/transitiveMemberOf' -or $uri.UserInfo -or $uri.Fragment -or $visited.ContainsKey($next)) { throw 'Paginazione appartenenze non valida.' }
                $visited[$next]=$true
                $page=Invoke-MgGraphRequest -Method GET -Uri $next -OutputType PSObject -ErrorAction Stop
                $memberships=Get-ExplorerGraphSetting $page 'value'
                if ($null -eq $memberships -or -not ($memberships -is [Array] -or $memberships -is [Collections.IList])) { throw 'Risposta appartenenze non valida.' }
                foreach ($membership in $memberships) {
                    if ([string](Get-ExplorerGraphSetting $membership '@odata.type') -ne '#microsoft.graph.group') { continue }
                    $id=[guid]::Empty
                    if (-not [guid]::TryParse([string]$membership.id,[ref]$id) -or $id -eq [guid]::Empty) { throw 'Gruppo restituito non valido.' }
                    $groups+=@($id.ToString())
                }
                $next=[string](Get-ExplorerGraphSetting $page '@odata.nextLink' '')
            }
            $groups=@($groups | Sort-Object -Unique);$groupsVerified=$true
        }
        catch { $groups=@();$groupError=$_.Exception.Message }
    }
    [pscustomobject]@{Account=[string]$context.Account;AppName=$appName;ClientId=[string]$context.ClientId;TenantId=[string]$context.TenantId;Permissions=$permissions;GroupIds=$groups;GroupMembershipVerified=$groupsVerified;GroupError=$groupError}
}

function Initialize-AssistenteITWindowIdentity {
    param([Parameter(Mandatory=$true)][string]$InstallRoot,$Window)
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return }
    if (-not ('AssistenteIT.WindowIdentity' -as [type])) { Add-Type -Path (Join-Path $InstallRoot 'AssistenteIT/Window.Identity.cs') -ErrorAction Stop }
    [AssistenteIT.WindowIdentity]::Initialize()
    if ($null -ne $Window) { [AssistenteIT.WindowIdentity]::Apply($Window.Handle,(Join-Path (Split-Path $InstallRoot -Parent) 'AssistenteIT.exe')) }
    else {
        foreach ($shortcut in @((Join-Path ([Environment]::GetFolderPath('Programs')) 'Assistente IT/Assistente IT.lnk'),(Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'Assistente IT.lnk'))) {
            try { [AssistenteIT.WindowIdentity]::SetShortcut($shortcut) } catch { }
        }
    }
}

function Get-AssistenteITAccessDefinition {
    param([Parameter(Mandatory=$true)]$Modules)
    $definitions=New-Object 'Collections.Generic.List[object]';$ids=@{};$needsGroups=$false
    foreach ($entry in @($Modules)) {
        $entryReadGroups=Get-ExplorerGraphSetting $entry 'ReadGroupIds' @();$entryWriteGroups=Get-ExplorerGraphSetting $entry 'WriteGroupIds' @()
        if (@($entryReadGroups).Count -gt 0 -or @($entryWriteGroups).Count -gt 0) { $needsGroups=$true }
        $entryDefinitions=Get-ExplorerGraphSetting $entry 'GraphPermissions' @()
        foreach ($definition in $entryDefinitions) {
            if ($ids.ContainsKey($definition.Id)) {
                if (($ids[$definition.Id].AnyOf -join '|') -ne ($definition.AnyOf -join '|')) { throw 'Requisiti Graph incompatibili tra moduli.' }
            }
            else { $ids[$definition.Id]=$definition;[void]$definitions.Add($definition) }
        }
    }
    [pscustomobject]@{Id='suite-access';Name='Assistente IT';GraphPermissions=$definitions.ToArray();NeedsGroupMembership=$needsGroups}
}

function Get-AssistenteITModuleAccess {
    param([Parameter(Mandatory=$true)]$Module,$Access)
    $definitions=Get-ExplorerGraphSetting $Module 'GraphPermissions' @()
    $permissions=@()
    if ($null -ne $Access) { $permissions=@($Access.Permissions | Where-Object { $id=$_.Id;@($definitions | Where-Object Id -eq $id).Count -gt 0 }) }
    $readIds=Get-ExplorerGraphSetting $Module 'ReadPermissionIds' @($definitions | Where-Object { $_.Id -notmatch '-remove$' } | ForEach-Object { $_.Id })
    $writeIds=Get-ExplorerGraphSetting $Module 'WritePermissionIds' @($definitions | Where-Object { $_.Id -match '-remove$' } | ForEach-Object { $_.Id })
    $canOpen=$null -ne $Access -and (@($definitions).Count -eq 0 -or @($permissions | Where-Object { $_.Available -and $_.Id -in $readIds }).Count -gt 0)
    if ([bool](Get-ExplorerGraphSetting $Module 'RequireAllReadPermissions' $false)) { $canOpen=$canOpen -and @($readIds | Where-Object { $required=$_;@($permissions | Where-Object { $_.Id -eq $required -and $_.Available }).Count -ne 1 }).Count -eq 0 }
    $canWrite=$canOpen -and @($permissions | Where-Object { $_.Available -and $_.Id -in $writeIds }).Count -gt 0
    $reason='Eseguire Accesso';if ($null -ne $Access) { $reason='Permessi di lettura non disponibili' }
    $readGroups=Get-ExplorerGraphSetting $Module 'ReadGroupIds' @()
    $writeGroups=Get-ExplorerGraphSetting $Module 'WriteGroupIds' @()
    $readGroups=@($readGroups | ForEach-Object { ([guid]$_).ToString() });$writeGroups=@($writeGroups | ForEach-Object { ([guid]$_).ToString() })
    if (@($readGroups).Count -gt 0 -or @($writeGroups).Count -gt 0) {
        $verifiedGroups=[bool](Get-ExplorerGraphSetting $Access 'GroupMembershipVerified' $false)
        $memberships=Get-ExplorerGraphSetting $Access 'GroupIds' @()
        if (-not $verifiedGroups) { $reason='Appartenenze ai gruppi non verificate' } else { $reason='Utenza non assegnata al modulo' }
        $canOpen=$canOpen -and $verifiedGroups -and @(@($readGroups)+@($writeGroups) | Where-Object { $memberships -contains $_ }).Count -gt 0
        $canWrite=$canWrite -and $canOpen -and @($writeGroups | Where-Object { $memberships -contains $_ }).Count -gt 0
    }
    $mode='None';if ($canOpen) { $mode='ReadOnly';if ($canWrite) { $mode='ReadWrite' } }
    [pscustomobject]@{CanOpen=$canOpen;Reason=$reason;AccessMode=$mode;ReadOnly=($mode -eq 'ReadOnly');Account=(Get-ExplorerGraphSetting $Access 'Account' '');ClientId=(Get-ExplorerGraphSetting $Access 'ClientId' '');TenantId=(Get-ExplorerGraphSetting $Access 'TenantId' '');Permissions=$permissions}
}

function Start-AssistenteITModule {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$InstallRoot,[Parameter(Mandatory=$true)][string]$ModuleId,[Parameter(Mandatory=$true)]$Paths,$Access)
    $manifest=Read-AssistenteITManifest $InstallRoot
    $selected=@($manifest.Modules | Where-Object Id -eq $ModuleId)
    if ($selected.Count -ne 1) { throw 'Modulo non disponibile.' }
    $moduleAccess=Get-AssistenteITModuleAccess -Module $selected[0] -Access $Access
    if (-not $moduleAccess.CanOpen) { throw 'Eseguire Accesso prima di aprire il modulo. Permessi di lettura non disponibili.' }
    $worker=[RunspaceFactory]::CreateRunspace();$worker.ApartmentState='STA';$worker.ThreadOptions='ReuseThread'
    $pipeline=[PowerShell]::Create()
    try {
        $worker.Open();$pipeline.Runspace=$worker
        [void]$pipeline.AddScript({param($Runner,$Id,$Config,$Env,$Verified)
            $ErrorActionPreference='Stop'
            & $Runner -ModuleId $Id -ConfigPath $Config -EnvPath $Env -VerifiedAccess $Verified
        }.ToString()).AddArgument((Join-Path $InstallRoot 'AssistenteIT/Invoke-Module.ps1')).AddArgument($ModuleId).AddArgument($Paths.ConfigPath).AddArgument($Paths.EnvPath).AddArgument($moduleAccess)
        $invocation=$pipeline.BeginInvoke()
        [pscustomobject]@{ModuleId=$ModuleId;Pipeline=$pipeline;Runspace=$worker;Invocation=$invocation;AccessMode=$moduleAccess.AccessMode}
    }
    catch { $pipeline.Dispose();$worker.Close();$worker.Dispose();throw }
}

function Get-AssistenteITModuleStartInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$InstallRoot, [Parameter(Mandatory=$true)][string]$ModuleId, [Parameter(Mandatory=$true)]$Paths)
    $manifest = Read-AssistenteITManifest $InstallRoot
    if (@($manifest.Modules | Where-Object { $_.Id -eq $ModuleId }).Count -ne 1) { throw 'Modulo non disponibile.' }
    $runner = Join-Path $InstallRoot 'AssistenteIT/Invoke-Module.ps1'
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'WindowsPowerShell/v1.0/powershell.exe'
    $info.Arguments = '-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -ModuleId "{1}" -ConfigPath "{2}" -EnvPath "{3}"' -f $runner, $ModuleId, $Paths.ConfigPath, $Paths.EnvPath
    $info.WorkingDirectory = $InstallRoot; $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $info.EnvironmentVariables['PSModulePath'] = (Join-Path $InstallRoot 'Dependencies') + [IO.Path]::PathSeparator + $env:PSModulePath
    return $info
}

Export-ModuleMember -Function Initialize-AssistenteITWindowIdentity, Get-AssistenteITAccessDefinition, Get-AssistenteITModuleAccess, Start-AssistenteITModule, Initialize-AssistenteITModuleAccess, ConvertTo-ExplorerGraphAuthentication, Read-AssistenteITManifest, Get-AssistenteITPaths, Initialize-AssistenteIT, Save-AssistenteITSettings, Enable-AssistenteITDependencies, Get-AssistenteITPrerequisites, Open-AssistenteITActivity, Get-AssistenteITModuleStartInfo, Move-AssistenteITUserData
