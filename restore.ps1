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

# Detect keyfile
$keyFile = "$repoDrive\.plakar_key"
$keyOption = if (Test-Path $keyFile) { "-keyfile `"$keyFile`"" } else { "" }

# Start agent if not running
& "$plakarExe" agent status 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Starting Plakar agent..."
    & "$plakarExe" $keyOption agent start
}

# List snapshots
Write-Host "Available snapshots:"
& "$plakarExe" $keyOption at "$repoPath" ls

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
& "$plakarExe" $keyOption at "$repoPath" restore -to $restorePath $snapshotID | Tee-Object -FilePath $logFile

Write-Host "Restore complete. Log saved to $logFile"

