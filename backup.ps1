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

# Detect keyfile (-keyfile and path as separate argv elements)
$keyFile = "$repoDrive\.plakar_key"
$plakarArgs = @()
if (Test-Path -LiteralPath $keyFile) {
    $plakarArgs += "-keyfile"
    $plakarArgs += $keyFile
}

# Verified after the repository exists (see below): a repository that does not
# exist yet cannot unlock.
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

# Start Plakar agent if not running
& "$plakarExe" agent status 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Starting Plakar agent..."
    & "$plakarExe" @plakarArgs agent start
}

# Create repository if not exists
$configPath = Join-Path $repoPath "CONFIG"
if (!(Test-Path -LiteralPath $configPath)) {
    Write-Host "Creating Plakar repository at $repoPath..."
    & "$plakarExe" @plakarArgs at "$repoPath" create
    if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create Plakar repository."; exit }
}

# Verify the keyfile actually unlocks this repository before anything runs. Without
# this check a stale or placeholder keyfile only shows up as an interactive
# passphrase prompt in the middle of the backup. Checked after create, because a
# repository that does not exist yet cannot unlock.
if ($plakarArgs.Count -gt 0) {
    $keyContent = Get-Content -LiteralPath $keyFile -Raw -ErrorAction SilentlyContinue
    if ($keyContent -match 'CHANGE_THIS_PASSPHRASE') {
        Write-Warning ".plakar_key still holds the placeholder passphrase. Run menu.ps1 once to set a real one."
    }
    elseif (!(Test-PlakarRepoUnlock $plakarArgs)) {
        Write-Warning ".plakar_key did not unlock this repository. Run menu.ps1 once to fix its encoding, or enter the passphrase when prompted."
    }
}

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
        & "$plakarExe" @plakarArgs at "$repoPath" backup $profilePath | Tee-Object -FilePath $logFile
    }
}

Write-Host "`nBackup complete. Log saved to $logFile"

