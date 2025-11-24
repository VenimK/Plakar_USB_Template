# =============================================================
# Self-Elevating PowerShell Wrapper (Safe)
# =============================================================
$IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $IsAdmin) {
    Write-Host "Elevating privileges..."
    $PSexe = (Get-Process -Id $PID).Path
    Start-Process -FilePath $PSexe -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# =============================================================
# Plakar + USMT Technician Menu – USB Version
# =============================================================

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# ------------------------------
# Plakar setup
# ------------------------------
$Repo = Join-Path $ScriptDir "plakar_repo"
$PlakarExe = Join-Path $ScriptDir "plakar.exe"
$KeyFile = Join-Path $ScriptDir ".plakar_key"

# Ensure Plakar repo exists
if (!(Test-Path $Repo)) {
    Write-Host "Creating Plakar repository at $Repo..." -ForegroundColor Cyan
    & $PlakarExe at "$Repo" create
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: Failed to create Plakar repository." -ForegroundColor Red
        exit
    }
}

# Keyfile support
$KeyOption = if (Test-Path $KeyFile) { "--keyfile=`"$KeyFile`"" } else { "" }

# ------------------------------
# USMT setup (all in D:\USMT\X64)
# ------------------------------
$USMTPath = "E:\USMT\X64"
$ScanState = Join-Path $USMTPath "scanstate.exe"
$LoadState = Join-Path $USMTPath "loadstate.exe"
$USMTStore = Join-Path $USMTPath "USMT_Store"
$ScanLog = Join-Path $USMTPath "scanstate.log"
$LoadLog = Join-Path $USMTPath "loadstate.log"
$MigUserXML = Join-Path $USMTPath "miguser.xml"
$MigAppXML = Join-Path $USMTPath "migapp.xml"

# ------------------------------
# Check USMT prerequisites
# ------------------------------
function Require-USMTCheck {
    if (-not (Test-Path $ScanState) -or -not (Test-Path $LoadState)) {
        Write-Host "ERROR: scanstate.exe or loadstate.exe not found in $USMTPath" -ForegroundColor Red
        Pause
        return $false
    }
    if (-not (Test-Path $MigUserXML) -or -not (Test-Path $MigAppXML)) {
        Write-Host "ERROR: miguser.xml or migapp.xml missing in $USMTPath" -ForegroundColor Red
        Pause
        return $false
    }
    return $true
}

# ------------------------------
# Menu functions
# ------------------------------
function ShowMenu {
    Clear-Host
    Write-Host "======================================="
    Write-Host "     Plakar + USMT Technician Menu"
    Write-Host "======================================="
    Write-Host "1. Backup user profile"
    Write-Host "2. Backup custom folder"
    Write-Host "3. Restore snapshot"
    Write-Host "4. List snapshots"
    Write-Host "5. Start Plakar UI"
    Write-Host "6. Delete snapshot"
    Write-Host "7. USMT Backup (ScanState)"
    Write-Host "8. USMT Restore (LoadState)"
    Write-Host "9. Exit"
}

function PlakarBackup($Folder, $TagName) {
    if ([string]::IsNullOrWhiteSpace($Folder)) { Write-Host "ERROR: Folder cannot be empty." -ForegroundColor Red; Pause; return }
    if (!(Test-Path $Folder)) { Write-Host "ERROR: Folder not found: $Folder" -ForegroundColor Red; Pause; return }

    $SnapTag = "${TagName}_$(Get-Date -Format yyyyMMdd_HHmmss)"
    Write-Host "Starting backup: $SnapTag ..." -ForegroundColor Cyan
    & $PlakarExe $KeyOption at "$Repo" backup -tag "$SnapTag" "$Folder"
    if ($LASTEXITCODE -eq 0) { Write-Host "Backup completed." -ForegroundColor Green }
    else { Write-Host "Backup FAILED." -ForegroundColor Red }
    Pause
}

function PlakarRestore($SnapTag, $RestoreTo) {
    if ([string]::IsNullOrWhiteSpace($SnapTag)) { Write-Host "ERROR: Snapshot tag cannot be empty." -ForegroundColor Red; Pause; return }
    if (!(Test-Path $RestoreTo)) { Write-Host "Creating restore folder: $RestoreTo" -ForegroundColor Cyan; New-Item -ItemType Directory -Path "$RestoreTo" | Out-Null }

    Write-Host "Restoring snapshot $SnapTag ..." -ForegroundColor Cyan
    & $PlakarExe $KeyOption at "$Repo" restore -tag "$SnapTag" -to "$RestoreTo"
    if ($LASTEXITCODE -eq 0) { Write-Host "Restore completed." -ForegroundColor Green }
    else { Write-Host "Restore FAILED." -ForegroundColor Red }
    Pause
}

# ------------------------------
# Main Menu Loop
# ------------------------------
do {
    ShowMenu
    $Choice = Read-Host "Choose option"

    switch ($Choice) {

        "1" {
            $Folder = Read-Host "Enter profile path"
            $Tag = Read-Host "Enter snapshot name"
            PlakarBackup $Folder $Tag
        }

        "2" {
            $Folder = Read-Host "Enter folder path"
            $Tag = Read-Host "Enter snapshot name"
            PlakarBackup $Folder $Tag
        }

        "3" {
            & $PlakarExe $KeyOption at "$Repo" ls -tags
            $SnapTag = Read-Host "Enter snapshot tag"
            $RestoreTo = Read-Host "Enter restore folder"
            PlakarRestore $SnapTag $RestoreTo
        }

        "4" {
            & $PlakarExe $KeyOption at "$Repo" ls -tags
            Pause
        }

        "5" {
            Start-Process $PlakarExe -ArgumentList "$KeyOption at `"$Repo`" ui"
            Pause
        }

        "6" {
            & $PlakarExe $KeyOption at "$Repo" ls -tags
            $SnapTag = Read-Host "Enter tag to delete"
            & $PlakarExe $KeyOption at "$Repo" rm -tag "$SnapTag" -apply
            Pause
        }

        # USMT Backup
        "7" {
            if (-not (Require-USMTCheck)) { break }
            if (!(Test-Path $USMTStore)) { New-Item -ItemType Directory -Path $USMTStore | Out-Null }

            Write-Host "Running USMT ScanState..." -ForegroundColor Cyan
            & $ScanState "$USMTStore" "/i:$MigUserXML" "/i:$MigAppXML" /o /c /v:5 "/l:$ScanLog"

            if ($LASTEXITCODE -eq 0) { Write-Host "USMT Backup completed successfully." -ForegroundColor Green }
            else { Write-Host "USMT Backup FAILED. Check log: $ScanLog" -ForegroundColor Red }

            Pause
        }

        # USMT Restore
        "8" {
            if (-not (Require-USMTCheck)) { break }

            Write-Host "Running USMT LoadState..." -ForegroundColor Cyan
            & $LoadState "$USMTStore" "/i:$MigUserXML" "/i:$MigAppXML" /c /lac /lae /v:5 "/l:$LoadLog"

            if ($LASTEXITCODE -eq 0) { Write-Host "USMT Restore completed successfully." -ForegroundColor Green }
            else { Write-Host "USMT Restore FAILED. Check log: $LoadLog" -ForegroundColor Red }

            Pause
        }

        "9" { break }

        default {
            Write-Host "Invalid option." -ForegroundColor Yellow
            Pause
        }
    }

} while ($true)
