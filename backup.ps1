# backup.ps1
# Technician backup script with USB-local Plakar.exe

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

# Start Plakar agent if not running
& "$plakarExe" agent status 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Starting Plakar agent..."
    & "$plakarExe" $keyOption agent start
}

# Create repository if not exists
& "$plakarExe" $keyOption at "$repoPath" create

# Create logs folder
$logFolder = "$repoDrive\logs"
if (!(Test-Path $logFolder)) { New-Item -ItemType Directory -Path $logFolder | Out-Null }
$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$logFile = "$logFolder\backup_$timestamp.log"

# List user profiles (skip system/default)
$skipProfiles = @("Default","Default User","Public","All Users","desktop.ini")
$userProfiles = Get-ChildItem C:\Users | Where-Object { $_.PSIsContainer -and $_.Name -notin $skipProfiles }

Write-Host "`nAvailable user profiles:"
for ($i=0; $i -lt $userProfiles.Count; $i++) {
    Write-Host "$($i+1). $($userProfiles[$i].Name)"
}

# Prompt technician to select profiles
$selection = Read-Host "`nEnter numbers of profiles to backup (comma-separated, e.g. 1,3)"
$selectedIndexes = $selection -split "," | ForEach-Object { ($_ -as [int]) - 1 }

foreach ($idx in $selectedIndexes) {
    if ($idx -ge 0 -and $idx -lt $userProfiles.Count) {
        $profilePath = $userProfiles[$idx].FullName
        Write-Host "`nBacking up $profilePath..."
        & "$plakarExe" $keyOption at "$repoPath" backup $profilePath | Tee-Object -FilePath $logFile
    }
}

Write-Host "`nBackup complete. Log saved to $logFile"

