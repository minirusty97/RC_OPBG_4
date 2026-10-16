#requires -version 5.1
$ErrorActionPreference='Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { Write-Host 'SKIP: restricted Windows token test requires Windows.'; return }
. (Join-Path $PSScriptRoot '../Glpi.Credentials.ps1')
if (-not ('GlpiRestrictedTokenProbe' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;
public static class GlpiRestrictedTokenProbe {
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentThread();
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenThreadToken(IntPtr thread, uint access, bool openAsSelf, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool CreateRestrictedToken(IntPtr token, uint flags, uint disableCount, IntPtr disable, uint deleteCount, IntPtr delete, uint restrictCount, IntPtr restrict, out IntPtr result);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool GetTokenInformation(IntPtr token, int type, IntPtr data, int length, out int needed);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool LookupPrivilegeValue(string system, string name, out Luid luid);
    [StructLayout(LayoutKind.Sequential)] struct Luid { public uint Low; public int High; }
    public static WindowsImpersonationContext Begin() {
        IntPtr original=IntPtr.Zero, restricted=IntPtr.Zero;
        try {
            if (!OpenProcessToken(GetCurrentProcess(), 0x000E, out original)) throw new Win32Exception();
            if (!CreateRestrictedToken(original, 1, 0, IntPtr.Zero, 0, IntPtr.Zero, 0, IntPtr.Zero, out restricted)) throw new Win32Exception();
            using (var identity=new WindowsIdentity(restricted)) { return identity.Impersonate(); }
        }
        finally { if (restricted!=IntPtr.Zero) CloseHandle(restricted); if (original!=IntPtr.Zero) CloseHandle(original); }
    }
    public static bool HasSecurityPrivilege() {
        IntPtr token=IntPtr.Zero, data=IntPtr.Zero;
        try {
            if (!OpenThreadToken(GetCurrentThread(), 8, true, out token)) throw new Win32Exception();
            int needed; GetTokenInformation(token, 3, IntPtr.Zero, 0, out needed);
            data=Marshal.AllocHGlobal(needed);
            if (!GetTokenInformation(token, 3, data, needed, out needed)) throw new Win32Exception();
            Luid security; if (!LookupPrivilegeValue(null, "SeSecurityPrivilege", out security)) throw new Win32Exception();
            int count=Marshal.ReadInt32(data);
            for(int i=0;i<count;i++) {
                int offset=4+i*12;
                if ((uint)Marshal.ReadInt32(data,offset)==security.Low && Marshal.ReadInt32(data,offset+4)==security.High) return true;
            }
            return false;
        }
        finally { if(data!=IntPtr.Zero) Marshal.FreeHGlobal(data); if(token!=IntPtr.Zero) CloseHandle(token); }
    }
}
'@
}
$directory=Join-Path ([IO.Path]::GetTempPath()) ('glpi-no-privilege-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($directory)
$path=Join-Path $directory '.env'; $store=Get-ExplorerGlpiStorePath $path
$context=$null
try {
    $context=[GlpiRestrictedTokenProbe]::Begin()
    if ([GlpiRestrictedTokenProbe]::HasSecurityPrivilege()) { throw 'Test still has SeSecurityPrivilege.' }
    [IO.File]::WriteAllText($path,"GLPI_USER_TOKEN=restricted-user`r`nGLPI_APP_TOKEN=restricted-app`r`n")
    $credentials=Read-ExplorerGlpiCredentials -Path $path
    try {
        if ($null -eq $credentials.User -or $null -eq $credentials.App) { throw 'Migration failed under restricted token.' }
    }
    finally { Close-ExplorerGlpiSecrets $credentials }
    if ([IO.File]::ReadAllText($path) -match 'restricted-|GLPI_') { throw 'Migration left plaintext tokens.' }
    $acl=[IO.File]::GetAccessControl($store,[Security.AccessControl.AccessControlSections]::Access)
    if (-not $acl.AreAccessRulesProtected -or $acl.Access.Count -ne 2) { throw 'Restricted migration weakened private ACL.' }
    'PASS: real DPAPI migration and private DACL succeed with SeSecurityPrivilege removed from the Windows token.'
    $newUser=ConvertTo-SecureString 'restricted-updated' -AsPlainText -Force
    try { Save-ExplorerGlpiCredentials -Path $path -User $newUser } finally { $newUser.Dispose() }
    $credentials=Read-ExplorerGlpiCredentials -Path $path
    try {
        $expected=ConvertTo-SecureString 'restricted-updated' -AsPlainText -Force
        try { if (-not (Test-ExplorerGlpiSecretEqual $expected $credentials.User) -or $null -eq $credentials.App) { throw 'Restricted update failed or erased app token.' } }
        finally { $expected.Dispose() }
    }
    finally { Close-ExplorerGlpiSecrets $credentials }
    if ([GlpiRestrictedTokenProbe]::HasSecurityPrivilege()) { throw 'Credential operation restored an administrative privilege.' }
    'PASS: encrypted-file replacement and reread need no audit privilege and preserve the other token.'
}
finally {
    if ($null -ne $context) { $context.Undo(); $context.Dispose() }
    Remove-Item -LiteralPath $directory -Recurse -Force
}
