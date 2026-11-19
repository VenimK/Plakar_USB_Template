#Requires -Version 5.1
# =============================================================
# Plakar maintenance - guarded version
# =============================================================
# plakar colours packfiles that no snapshot references any more and only deletes
# them on a later run, after the grace period (PLAKAR_GRACEPERIOD, default 7d;
# 0 sweeps in the same run).
#
# The guard matters: maintenance decides what is garbage by walking the snapshot
# list in the state index. If the index cannot be read, plakar sees 0 snapshots
# and would treat every packfile as unreferenced - deleting live data, not
# garbage. This script therefore refuses to sweep unless it can open every object
# in states/ and packfiles/. A snapshot count of 0 is reported as a warning,
# because in this repository it is legitimate: snapshot 1234 was deleted on
# purpose and 352 packfiles were already coloured for deletion.
# It also copies CONFIG and every state to a backup folder before sweeping.
#
# Usage (elevated PowerShell):
#   .\reclaim.ps1 -DryRun               -> check only, nothing is deleted
#   .\reclaim.ps1                       -> guard + backup + sweep now
#   .\reclaim.ps1 -GracePeriod 1h       -> keep a small safety margin
#   .\reclaim.ps1 -Force                -> skip the snapshot guard (not advised)
# =============================================================

[CmdletBinding()]
param(
    [string]$GracePeriod = '',
    [switch]$DryRun,
    [switch]$Force
)

$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $IsAdmin) {
    Write-Host "Elevating privileges..."
    $PSexe = (Get-Process -Id $PID).Path
    $args = "-ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($GracePeriod) { $args += " -GracePeriod `"$GracePeriod`"" }
    if ($DryRun) { $args += ' -DryRun' }
    if ($Force)  { $args += ' -Force' }
    Start-Process -FilePath $PSexe -ArgumentList $args -Verb RunAs
    exit
}

$ErrorActionPreference = 'Continue'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$PlakarExe = Join-Path $ScriptDir 'plakar.exe'
$KeyFile   = Join-Path $ScriptDir '.plakar_key'
$Repo      = Join-Path $ScriptDir 'plakar_repo'

if (!(Test-Path $PlakarExe)) { Write-Host "ERROR: plakar.exe not found at: $PlakarExe"; exit 1 }
if (!(Test-Path $KeyFile))    { Write-Host "ERROR: keyfile not found at: $KeyFile"; exit 1 }
if (!(Test-Path $Repo))       { Write-Host "ERROR: repository not found at: $Repo"; exit 1 }

# ---- 1. can this token open every object? ------------------------------------
Write-Host "Checking access to every object..."
$objects = Get-ChildItem -LiteralPath (Join-Path $Repo 'states'), (Join-Path $Repo 'packfiles') -Recurse -File
$blocked = @()
foreach ($o in $objects) {
    try { [System.IO.File]::OpenRead($o.FullName).Close() } catch { $blocked += $o }
}
if ($blocked.Count -gt 0) {
    Write-Host "BLOCKED: $($blocked.Count) objects cannot be opened by this token." -ForegroundColor Red
    Write-Host "Maintenance would then work from an incomplete reference graph. Aborting." -ForegroundColor Red
    Write-Host "Fix the ACLs first (these files are owned by another account and do not grant this token even READ_CONTROL)." -ForegroundColor Yellow
    exit 1
}
Write-Host "All $($objects.Count) objects are readable. ($($objects | Measure-Object -Property Length -Sum | ForEach-Object { '{0:N0} bytes' -f $_.Sum }))"

# ---- 2. what does plakar see? -------------------------------------------------
Write-Host "`nplakar's view of the repository:"
& $PlakarExe -keyfile $KeyFile at "$Repo" info | Select-Object -Last 4
$snapLine = (& $PlakarExe -keyfile $KeyFile at "$Repo" info | Select-String -Pattern 'Snapshots:')
$snapCount = 0
if ($snapLine) { $snapCount = [int]((($snapLine -split ':')[-1]).Trim() -replace '[^\d]', '') }
Write-Host "Snapshots counted: $snapCount"

if ($snapCount -eq 0) {
    Write-Host "`nSnapshots: 0. That is legitimate here - snapshot 1234 was deleted on purpose (logs\b22b75f2_plakar_delete.log, 14/10/2026 04:23), and plakar coloured 352 packfiles for deletion in that same run." -ForegroundColor Yellow
    Write-Host "It is only dangerous if the 0 comes from plakar being unable to read the index. Check the access report above: if plakar can open every object, the sweep is reclaiming what plakar already decided to reclaim." -ForegroundColor Yellow
    if (-not $Force) {
        Write-Host "Re-run with -Force to proceed, or check first from an elevated prompt." -ForegroundColor Red
        exit 1
    }
}

if ($DryRun) { Write-Host "`nDryRun: nothing was deleted."; exit 0 }

# ---- 3. backup the index -------------------------------------------------------
$Backup = Join-Path $ScriptDir ("state_backup_" + (Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Path $Backup -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $Repo 'CONFIG') -Destination $Backup
Copy-Item -LiteralPath (Join-Path $Repo 'states') -Destination $Backup -Recurse
Write-Host "Index backed up to: $Backup"

# ---- 4. sweep -----------------------------------------------------------------
$holders = @(Get-Process -Name plakar -ErrorAction SilentlyContinue)
if ($holders.Count -gt 0) {
    Write-Host "WARNING: a plakar process is still running (PID $($holders[0].Id)). Maintenance needs the exclusive lock." -ForegroundColor Yellow
    $answer = Read-Host 'Continue anyway? (y/N)'
    if ($answer -notin @('y', 'Y')) { exit 1 }
}

if ($GracePeriod) { $env:PLAKAR_GRACEPERIOD = $GracePeriod }
if ($GracePeriod) {
    Write-Host "`nGrace period override: $GracePeriod - coloured packfiles are deleted in this run." -ForegroundColor Yellow
} else {
    Write-Host "`nGrace period: plakar default (7 days) - coloured packfiles are deleted on a later run, not now." -ForegroundColor Yellow
}
Write-Host "This is irreversible." -ForegroundColor Yellow

& $PlakarExe -keyfile $KeyFile at "$Repo" maintenance
$code = $LASTEXITCODE
Write-Host "EXITCODE: $code"
exit $code
