#Requires -Version 5.1
#Requires -RunAsAdministrator
# =============================================================
# Repair the ACLs on the plakar objects this token cannot open
# =============================================================
# 451 objects (450 packfiles + the 41 MB main state, 30.3 GB) carry explicit
# DACLs for the account that created the repository on the original machine
# (S-1-5-21-2300767342-3742809180-3703134235-1001 - not resolvable here, so this
# is a repository copied from another machine). This token gets nothing from
# those DACLs, not even READ_CONTROL.
#
# The safe order is: record the original security descriptor, then ADD an access
# rule, never replace one. TakeOwnership is only used if you ask for it, and the
# original owner is recorded first so it can be put back.
#
# SeBackupPrivilege lets an elevated token read a DACL that denies it;
# SeRestorePrivilege lets it write the DACL. Both are present in an elevated
# token but disabled, so the script enables them.
#
# Usage (elevated PowerShell):
#   .\fix_acls.ps1                          -> dry run: record + report only
#   .\fix_acls.ps1 -Apply                   -> add Administrators:F on blocked objects
#   .\fix_acls.ps1 -Apply -Right R          -> read only
#   .\fix_acls.ps1 -Apply -TakeOwnership    -> also take ownership (records owner first)
#   .\fix_acls.ps1 -Restore <csv>           -> reapply the recorded original SDDLs
# =============================================================

[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$TakeOwnership,
    [string]$Right = 'F',
    [string]$GrantTo = 'BUILTIN\Administrators',
    [string]$Restore
)

$ErrorActionPreference = 'Continue'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$Repo      = Join-Path $ScriptDir 'plakar_repo'
$PlakarExe = Join-Path $ScriptDir 'plakar.exe'
$KeyFile   = Join-Path $ScriptDir '.plakar_key'
$Report    = Join-Path $ScriptDir '_acl_report'

if (!(Test-Path $Repo)) { Write-Host "ERROR: repository not found at: $Repo"; exit 1 }
if (!(Test-Path $Report)) { New-Item -ItemType Directory -Path $Report -Force | Out-Null }

# ---- enable the backup / restore / ownership privileges ----------------------
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: run this from an elevated PowerShell." -ForegroundColor Red
    exit 1
}

try {
    Add-Type -Language CSharp @'
using System;
using System.Runtime.InteropServices;
public static class Priv {
    const uint TOKEN_ADJUST = 0x20, TOKEN_QUERY = 0x08, SE_ENABLED = 0x02;
    [StructLayout(LayoutKind.Sequential)] public struct LAA { public long Luid; public int Attr; }
    [StructLayout(LayoutKind.Sequential)] public struct TP { public int Count; public LAA Tp0; }
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr h, uint a, out IntPtr t);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool LookupPrivilegeValue(string lp, string name, out long luid);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool AdjustTokenPrivileges(IntPtr t, bool disableAll, ref TP np, int len, IntPtr prev, IntPtr rem);
    public static string Enable(string name) {
        IntPtr tok;
        if (!OpenProcessToken(System.Diagnostics.Process.GetCurrentProcess().Handle, TOKEN_ADJUST | TOKEN_QUERY, out tok))
            return "OpenProcessToken failed: " + Marshal.GetLastWin32Error();
        long luid;
        if (!LookupPrivilegeValue(null, name, out luid)) return "LookupPrivilegeValue failed for " + name;
        TP tp = new TP(); tp.Count = 1; tp.Tp0.Luid = luid; tp.Tp0.Attr = (int)SE_ENABLED;
        if (!AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero))
            return "AdjustTokenPrivileges failed for " + name + ": " + Marshal.GetLastWin32Error();
        int err = Marshal.GetLastWin32Error();
        if (err == 1300) return name + " is not held in this token";
        return name + " enabled";
    }
}
'@
    foreach ($p in 'SeBackupPrivilege','SeRestorePrivilege','SeTakeOwnershipPrivilege') {
        Write-Host ("privilege: " + [Priv]::Enable($p))
    }
} catch {
    Write-Host "Could not enable privileges (Add-Type blocked): $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "Continuing; icacls may still work if the elevated token already has them enabled." -ForegroundColor Yellow
}

# ---- which objects do we actually need to fix? -------------------------------
$objects = Get-ChildItem -LiteralPath (Join-Path $Repo 'states'), (Join-Path $Repo 'packfiles') -Recurse -File
$blocked = @()
foreach ($o in $objects) {
    try { [System.IO.File]::OpenRead($o.FullName).Close() } catch { $blocked += $o }
}
Write-Host "`nObjects this token can already open: $($objects.Count - $blocked.Count)"
Write-Host "Objects to repair: $($blocked.Count)"
if ($blocked.Count -eq 0) { Write-Host "Nothing to repair."; exit 0 }

# ---- 1. record the original security descriptors -----------------------------
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$csv = Join-Path $Report "acl_original_$stamp.csv"
$rows = @()
foreach ($o in $blocked) {
    $owner = ''; $sddl = ''; $note = ''
    try {
        $acl = Get-Acl -LiteralPath $o.FullName
        $owner = $acl.Owner
        $sddl  = $acl.Sddl
    } catch {
        $note = 'SDDL not readable even with SeBackupPrivilege'
    }
    $rows += [pscustomobject]@{ Path = $o.FullName; Size = $o.Length; Owner = $owner; Sddl = $sddl; Note = $note }
}
$rows | Export-Csv -LiteralPath $csv -Encoding UTF8 -NoTypeInformation
Write-Host "Original security descriptors recorded to: $csv"
$unreadable = ($rows | Where-Object { $_.Sddl -eq '' }).Count
Write-Host "  readable DACLs: $($rows.Count - $unreadable) / $($rows.Count)"

if ($Restore) {
    Write-Host "`nRestoring recorded SDDLs from: $Restore" -ForegroundColor Yellow
    $src = Import-Csv -LiteralPath $Restore
    $n = 0
    foreach ($r in $src) {
        if (-not $r.Sddl) { continue }
        & icacls $r.Path /setowner $r.Owner /quiet
        & icacls $r.Path /setsecurity "`"$($r.Sddl)`"" /quiet
        if ($LASTEXITCODE -eq 0) { $n++ } else { Write-Host "  failed: $($r.Path)" -ForegroundColor Red }
    }
    Write-Host "Restored $n entries."
    exit 0
}

if (-not $Apply) {
    Write-Host "`nDry run - nothing was changed. Re-run with -Apply to add an access rule."
    Write-Host "Example: .\fix_acls.ps1 -Apply   (adds $GrantTo : $Right on the $($blocked.Count) blocked objects)"
    exit 0
}

# ---- 2. add an access rule, preserving what is already there -----------------
Write-Host "`nApplying: $GrantTo : $Right on $($blocked.Count) objects"
$ok = 0
foreach ($o in $blocked) {
    if ($TakeOwnership) { & icacls $o.FullName /setowner $GrantTo /quiet }
    & icacls $o.FullName /grant "${GrantTo}:${Right}" /quiet
    if ($LASTEXITCODE -eq 0) { $ok++ } else { Write-Host "  failed: $($o.FullName)" -ForegroundColor Red }
}
Write-Host "Processed $ok / $($blocked.Count) objects."

# ---- 3. verify ---------------------------------------------------------------
$still = 0
foreach ($o in $blocked) {
    try { [System.IO.File]::OpenRead($o.FullName).Close() } catch { $still++ }
}
Write-Host "Still unreadable after the change: $still"

if ($PlakarExe -and $KeyFile) {
    Write-Host "`nplakar's view now:"
    & $PlakarExe -keyfile $KeyFile at "$Repo" info | Select-Object -Last 3
    Write-Host "`nSnapshots plakar can see:"
    & $PlakarExe -keyfile $KeyFile at "$Repo" ls
}
