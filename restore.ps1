# restore.ps1
# Technician restore script with USB-local Plakar.exe

# Auto-detect USB repository
$usbDrives = Get-PSDrive -PSProvider FileSystem | Where-Object { Test-Path "$($_.Root)plakar_repo" }
if ($usbDrives.Count -eq 0) { Write-Error "No Plakar repository found on any drive."; exit }
$repoDrive = $usbDrives[0].Root
$repoPath = "$repoDrive\plakar_repo"

# Set path to USB-local plakar.exe
$plakarExe = "$repoDrive\plakar.exe"
if (!(Test-Path $plakarExe)) { Write-Error "plakar.exe not found on USB!"; exit }

# Detect keyfile (-keyfile and path as separate argv elements)
$keyFile = "$repoDrive\.plakar_key"
$plakarArgs = @()
if (Test-Path -LiteralPath $keyFile) {
    $plakarArgs += "-keyfile"
    $plakarArgs += $keyFile
}

# A stale or placeholder keyfile otherwise only shows up as an interactive
# passphrase prompt mid-restore.
function Test-PlakarRepoUnlock {
    param([string[]]$KeyArgs)
    if ($KeyArgs.Count -eq 0) { return $true }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        & $plakarExe @KeyArgs -quiet at $repoPath ls 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    } finally { $ErrorActionPreference = $prev }
}

if ($plakarArgs.Count -gt 0) {
    $keyContent = Get-Content -LiteralPath $keyFile -Raw -ErrorAction SilentlyContinue
    if ($keyContent -match 'CHANGE_THIS_PASSPHRASE') {
        Write-Warning ".plakar_key still holds the placeholder passphrase. Run menu.ps1 once to set a real one."
    }
    elseif (!(Test-PlakarRepoUnlock $plakarArgs)) {
        Write-Warning ".plakar_key did not unlock this repository. Run menu.ps1 once to fix its encoding, or enter the passphrase when prompted."
    }
}

# Start agent if not running
& "$plakarExe" agent status 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Starting Plakar agent..."
    & "$plakarExe" @plakarArgs agent start
}

# List snapshots
Write-Host "Available snapshots:"
& "$plakarExe" @plakarArgs at "$repoPath" ls

# Prompt for snapshot ID
$snapshotID = Read-Host "Enter the snapshot ID to restore"

# Prompt for restore path (default C:\Users)
$restorePath = Read-Host "Enter restore path (default C:\Users)"
if ([string]::IsNullOrEmpty($restorePath)) { $restorePath = "C:\Users" }

# Create logs folder
$logFolder = "$repoDrive\logs"
if (!(Test-Path $logFolder)) { New-Item -ItemType Directory -Path $logFolder | Out-Null }
$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$logFile = "$logFolder\restore_$timestamp.log"

# Restore snapshot
Write-Host "Restoring snapshot $snapshotID to $restorePath..."
# skip_permissions: the source ACLs reference SIDs from the machine the backup was
# made on, which are meaningless here, and setting them per file is the single
# biggest cost on a profile restore (measured 2x faster on 20k small files).
# Files inherit permissions from the destination instead.
& "$plakarExe" @plakarArgs at "$repoPath" restore -to $restorePath -o skip_permissions=1 $snapshotID | Tee-Object -FilePath $logFile

Write-Host "Restore complete. Log saved to $logFile"

