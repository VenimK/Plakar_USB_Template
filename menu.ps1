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

# ------------------------------
# Helper Functions
# ------------------------------
function Write-ColorMessage {
    param(
        [string]$Message,
        [string]$Type = "Info"
    )
    switch ($Type) {
        "Success" { Write-Host $Message -ForegroundColor Green }
        "Error"   { Write-Host $Message -ForegroundColor Red }
        "Warning" { Write-Host $Message -ForegroundColor Yellow }
        "Info"    { Write-Host $Message -ForegroundColor Cyan }
        default   { Write-Host $Message }
    }
}

function Test-DiskSpace {
    param([string]$Path, [long]$RequiredGB = 5)
    try {
        $Drive = (Get-Item $Path).PSDrive.Name
        $FreeSpace = (Get-PSDrive $Drive).Free / 1GB
        if ($FreeSpace -lt $RequiredGB) {
            Write-ColorMessage "WARNING: Low disk space on drive $Drive`: $([math]::Round($FreeSpace,2)) GB free" "Warning"
            return $false
        }
        return $true
    } catch {
        return $true  # Continue if check fails
    }
}

function Get-RepositoryInfo {
    try {
        $output = & $PlakarExe $KeyOption at "$Repo" ls -tags 2>&1 | Out-String
        $snapshotCount = ($output -split "`n" | Where-Object { $_ -match "\S" }).Count - 1
        if ($snapshotCount -lt 0) { $snapshotCount = 0 }
        
        $repoSize = 0
        if (Test-Path $Repo) {
            $repoSize = (Get-ChildItem $Repo -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1GB
        }
        
        return @{
            SnapshotCount = $snapshotCount
            SizeGB = [math]::Round($repoSize, 2)
        }
    } catch {
        return @{ SnapshotCount = 0; SizeGB = 0 }
    }
}

function Confirm-Action {
    param([string]$Message)
    $response = Read-Host "$Message (y/n)"
    return $response -match '^[Yy]'
}

function Test-ValidPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        Write-ColorMessage "ERROR: Path cannot be empty." "Error"
        return $false
    }
    if (!(Test-Path $Path)) {
        Write-ColorMessage "ERROR: Path not found: $Path" "Error"
        return $false
    }
    return $true
}

function Get-USMTStoreInfo {
    param([string]$StorePath)
    try {
        if (!(Test-Path $StorePath)) {
            return @{ Exists = $false; SizeGB = 0; FileCount = 0 }
        }
        $files = Get-ChildItem $StorePath -Recurse -File -ErrorAction SilentlyContinue
        $size = ($files | Measure-Object -Property Length -Sum).Sum / 1GB
        return @{
            Exists = $true
            SizeGB = [math]::Round($size, 2)
            FileCount = $files.Count
        }
    } catch {
        return @{ Exists = $false; SizeGB = 0; FileCount = 0 }
    }
}

function Open-LogFile {
    param([string]$LogPath)
    if (Test-Path $LogPath) {
        Write-ColorMessage "Opening log file..." "Info"
        Start-Process notepad.exe -ArgumentList "$LogPath"
    } else {
        Write-ColorMessage "Log file not found: $LogPath" "Warning"
    }
}

# ------------------------------
# USMT user selection helpers
# ------------------------------
function Get-UserProfileNames {
    $systemProfiles = @('All Users','Default','Default User','Public','WDAGUtilityAccount')
    try {
        Get-ChildItem 'C:\Users' -Directory -ErrorAction Stop |
            Where-Object { $systemProfiles -notcontains $_.Name } |
            Select-Object -ExpandProperty Name
    } catch {
        @()
    }
}

function Select-USMTUsers {
    $names = Get-UserProfileNames
    if (-not $names -or $names.Count -eq 0) {
        Write-ColorMessage "No user profiles found under C:\\Users" "Warning"
        return @()
    }
    Write-ColorMessage "Available user profiles:" "Info"
    for ($i = 0; $i -lt $names.Count; $i++) {
        Write-Host ("  {0}. {1}" -f ($i+1), $names[$i])
    }
    $choice = Read-Host "Enter numbers to include (e.g. 1,3,5) or * for all"
    if ($choice -eq '*') { $selected = $names }
    else {
        $indexes = $choice -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^[0-9]+$' } | ForEach-Object { [int]$_ - 1 }
        $selected = @()
        foreach ($idx in $indexes) {
            if ($idx -ge 0 -and $idx -lt $names.Count) { $selected += $names[$idx] }
        }
    }
    if (-not $selected -or $selected.Count -eq 0) {
        Write-ColorMessage "No users selected." "Warning"
        return @()
    }
    # Return fully-qualified local accounts for USMT /ui
    return $selected | ForEach-Object { "$env:COMPUTERNAME\$_" }
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

# Check if plakar.exe exists
if (!(Test-Path $PlakarExe)) {
    Write-ColorMessage "ERROR: plakar.exe not found at: $PlakarExe" "Error"
    Write-ColorMessage "Please ensure plakar.exe is in the same directory as this script." "Warning"
    Pause
    exit
}

# Handle keyfile setup before creating repository
$NeedsPassphrase = $false
if (!(Test-Path $KeyFile)) {
    $NeedsPassphrase = $true
} else {
    # Check if keyfile contains placeholder text
    $KeyContent = Get-Content $KeyFile -Raw -ErrorAction SilentlyContinue
    if ($KeyContent -match 'CHANGE_THIS_PASSPHRASE' -or [string]::IsNullOrWhiteSpace($KeyContent)) {
        $NeedsPassphrase = $true
        Write-ColorMessage "Placeholder passphrase detected in .plakar_key" "Warning"
    }
}

if ($NeedsPassphrase) {
    Write-ColorMessage "Setting up passphrase for Plakar repository..." "Warning"
    Write-ColorMessage "" "Info"
    Write-ColorMessage "SECURITY WARNING: Passphrase will be stored in PLAINTEXT in .plakar_key" "Warning"
    Write-ColorMessage "For maximum security, store this USB drive in a secure location." "Warning"
    Write-ColorMessage "" "Info"
    Write-ColorMessage "Enter a passphrase (or press Enter for no passphrase):" "Info"
    $Passphrase = Read-Host -AsSecureString
    $PlainPassphrase = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($Passphrase))
    
    if ($PlainPassphrase -ne "") {
        # Save passphrase to .plakar_key with UTF8 encoding
        $PlainPassphrase | Out-File -FilePath $KeyFile -Encoding UTF8 -NoNewline
        Write-ColorMessage "Passphrase saved to .plakar_key" "Success"
    } else {
        Write-ColorMessage "No passphrase set. Repository will be unencrypted." "Warning"
        # Remove keyfile if user wants no passphrase
        if (Test-Path $KeyFile) { Remove-Item $KeyFile -Force }
    }
}

# Keyfile support
$KeyOption = if (Test-Path $KeyFile) { "--keyfile=`"$KeyFile`"" } else { "" }

# Ensure Plakar repo exists
if (!(Test-Path $Repo)) {
    Write-ColorMessage "Creating Plakar repository at $Repo..." "Info"
    try {
        & $PlakarExe $KeyOption at "$Repo" create
        if ($LASTEXITCODE -ne 0) {
            Write-ColorMessage "ERROR: Failed to create Plakar repository. Exit code: $LASTEXITCODE" "Error"
            exit
        }
        Write-ColorMessage "Repository created successfully." "Success"
    } catch {
        Write-ColorMessage "ERROR: $($_.Exception.Message)" "Error"
        exit
    }
}

# ------------------------------
# USMT setup (dynamic USB path detection + architecture detection)
# ------------------------------
# Detect system architecture
$Arch = if ([Environment]::Is64BitOperatingSystem) { "amd64" } else { "x86" }

# Try to find USMT in script directory first, then drive root
$USMTPath = $null
$PossiblePaths = @(
    (Join-Path $ScriptDir "USMT\$Arch"),         # Architecture-specific folder
    (Join-Path $ScriptDir "USMT\X64"),           # Legacy X64 folder
    (Join-Path $ScriptDir "USMT\amd64"),         # Standard amd64 folder
    (Join-Path $ScriptDir "..\USMT\$Arch"),      # Parent folder
    (Join-Path $ScriptDir "..\USMT\amd64")       # Parent folder (amd64)
)

# Add drive root path if on Windows
$ScriptDrive = Split-Path -Qualifier $ScriptDir
if (-not [string]::IsNullOrEmpty($ScriptDrive)) {
    $PossiblePaths += (Join-Path $ScriptDrive "USMT\$Arch")
    $PossiblePaths += (Join-Path $ScriptDrive "USMT\amd64")
    $PossiblePaths += (Join-Path $ScriptDrive "USMT\X64")
}

# Find first valid USMT path
foreach ($Path in $PossiblePaths) {
    if (Test-Path (Join-Path $Path "scanstate.exe")) {
        $USMTPath = $Path
        Write-Host "Found USMT ($Arch) at: $USMTPath" -ForegroundColor Green
        break
    }
}

# Fallback to script directory if not found
if ([string]::IsNullOrEmpty($USMTPath)) {
    $USMTPath = Join-Path $ScriptDir "USMT\$Arch"
}
$ScanState = Join-Path $USMTPath "scanstate.exe"
$LoadState = Join-Path $USMTPath "loadstate.exe"
$USMTStore = Join-Path $USMTPath "USMT_Store"
$ScanLog = Join-Path $USMTPath "scanstate.log"
$LoadLog = Join-Path $USMTPath "loadstate.log"
$MigUserXML = Join-Path $USMTPath "miguser.xml"
$MigAppXML = Join-Path $USMTPath "migapp.xml"
$MigDocsXML = Join-Path $USMTPath "migdocs.xml"
# ------------------------------
# Check USMT prerequisites
# ------------------------------
function Require-USMTCheck {
    if (-not (Test-Path $ScanState) -or -not (Test-Path $LoadState)) {
        Write-ColorMessage "ERROR: USMT files not found!" "Error"
        Write-ColorMessage "Searched in: $USMTPath" "Warning"
        Write-Host "" 
        Write-ColorMessage "=== How to get USMT ===" "Info"
        Write-Host "1. Download Windows ADK from:" -ForegroundColor White
        Write-Host "   https://go.microsoft.com/fwlink/?linkid=2243390" -ForegroundColor Gray
        Write-Host "2. Install and select only 'User State Migration Tool (USMT)'" -ForegroundColor White
        Write-Host "3. Copy files from installation folder to USB:" -ForegroundColor White
        Write-Host "   From: C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\USMT\$Arch\" -ForegroundColor Gray
        Write-Host "   To:   $ScriptDir\USMT\$Arch\" -ForegroundColor Gray
        Write-Host ""
        Write-ColorMessage "Supported architectures: amd64 (64-bit), x86 (32-bit)" "Warning"
        Write-ColorMessage "Detected system: $Arch" "Warning"
        Pause
        return $false
    }
    if (-not (Test-Path $MigUserXML) -or -not (Test-Path $MigAppXML)) {
        Write-ColorMessage "ERROR: miguser.xml or migapp.xml missing in $USMTPath" "Error"
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
    
    # Get repository info
    $repoInfo = Get-RepositoryInfo
    $snapCount = $repoInfo.SnapshotCount
    $repoSize = $repoInfo.SizeGB
    
    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host "     Plakar + USMT Technician Menu" -ForegroundColor White
    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host "Repository: " -NoNewline -ForegroundColor Gray
    Write-Host "$snapCount snapshots, $repoSize GB" -ForegroundColor Yellow
    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "1. Backup user profile"
    Write-Host "2. Backup custom folder"
    Write-Host "3. Restore snapshot"
    Write-Host "4. List snapshots"
    Write-Host "5. View snapshot details"
    Write-Host "6. Start Plakar UI"
    Write-Host "7. Delete snapshot"
    Write-Host "8. USMT Backup (ScanState)"
    Write-Host "9. USMT Restore (LoadState)"
    Write-Host "10. Exit"
    Write-Host ""
}

function PlakarBackup($Folder, $TagName) {
    # Validate inputs
    if (!(Test-ValidPath $Folder)) { Pause; return }
    if ([string]::IsNullOrWhiteSpace($TagName)) {
        Write-ColorMessage "ERROR: Tag name cannot be empty." "Error"
        Pause
        return
    }

    # Check disk space
    Test-DiskSpace -Path $Repo | Out-Null

    $SnapTag = "${TagName}_$(Get-Date -Format yyyyMMdd_HHmmss)"
    Write-ColorMessage "Starting backup: $SnapTag ..." "Info"
    
    try {
        & $PlakarExe $KeyOption at "$Repo" backup -tag "$SnapTag" "$Folder"
        if ($LASTEXITCODE -eq 0) { 
            Write-ColorMessage "Backup completed successfully." "Success"
        } else { 
            Write-ColorMessage "Backup FAILED. Exit code: $LASTEXITCODE" "Error"
        }
    } catch {
        Write-ColorMessage "ERROR: $($_.Exception.Message)" "Error"
    }
    Pause
}

function PlakarRestore($SnapTag, $RestoreTo) {
    # Validate inputs
    if ([string]::IsNullOrWhiteSpace($SnapTag)) { 
        Write-ColorMessage "ERROR: Snapshot tag cannot be empty." "Error"
        Pause
        return
    }
    if ([string]::IsNullOrWhiteSpace($RestoreTo)) { 
        Write-ColorMessage "ERROR: Restore path cannot be empty." "Error"
        Pause
        return
    }

    # Check disk space
    Test-DiskSpace -Path (Split-Path $RestoreTo -Parent) | Out-Null

    # Create restore folder if needed
    if (!(Test-Path $RestoreTo)) { 
        Write-ColorMessage "Creating restore folder: $RestoreTo" "Info"
        try {
            New-Item -ItemType Directory -Path "$RestoreTo" -ErrorAction Stop | Out-Null
        } catch {
            Write-ColorMessage "ERROR: Failed to create restore folder: $($_.Exception.Message)" "Error"
            Pause
            return
        }
    }

    Write-ColorMessage "Restoring snapshot $SnapTag to $RestoreTo ..." "Info"
    try {
        & $PlakarExe $KeyOption at "$Repo" restore -tag "$SnapTag" -to "$RestoreTo"
        if ($LASTEXITCODE -eq 0) { 
            Write-ColorMessage "Restore completed successfully." "Success"
            Write-ColorMessage "Files restored to: $RestoreTo" "Info"
        } else { 
            Write-ColorMessage "Restore FAILED. Exit code: $LASTEXITCODE" "Error"
        }
    } catch {
        Write-ColorMessage "ERROR: $($_.Exception.Message)" "Error"
    }
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
            Write-ColorMessage "Backup User Profile" "Info"
            Write-Host "Example: C:\Users\JohnDoe" -ForegroundColor Gray
            $Folder = Read-Host "Enter profile path"
            $Tag = Read-Host "Enter snapshot name (e.g., UserProfile_JohnDoe)"
            PlakarBackup $Folder $Tag
        }

        "2" {
            Write-ColorMessage "Backup Custom Folder" "Info"
            Write-Host "Example: C:\Important\Documents" -ForegroundColor Gray
            $Folder = Read-Host "Enter folder path"
            $Tag = Read-Host "Enter snapshot name (e.g., MyDocuments)"
            PlakarBackup $Folder $Tag
        }

        "3" {
            Write-ColorMessage "Restore Snapshot" "Info"
            & $PlakarExe $KeyOption at "$Repo" ls -tags
            Write-Host "" 
            $SnapTag = Read-Host "Enter snapshot tag to restore"
            Write-Host "Example: C:\Restored" -ForegroundColor Gray
            $RestoreTo = Read-Host "Enter restore folder path"
            PlakarRestore $SnapTag $RestoreTo
        }

        "4" {
            Write-ColorMessage "Listing all snapshots..." "Info"
            & $PlakarExe $KeyOption at "$Repo" ls -tags
            Pause
        }

        "5" {
            Write-ColorMessage "Listing snapshots..." "Info"
            & $PlakarExe $KeyOption at "$Repo" ls -tags
            $SnapTag = Read-Host "Enter snapshot tag to view details"
            if (![string]::IsNullOrWhiteSpace($SnapTag)) {
                Write-ColorMessage "`nSnapshot Details:" "Info"
                & $PlakarExe $KeyOption at "$Repo" ls -snapshot $SnapTag
            }
            Pause
        }

        "6" {
            Write-ColorMessage "Starting Plakar UI..." "Info"
            Start-Process $PlakarExe -ArgumentList "$KeyOption at `"$Repo`" ui"
            Pause
        }

        "7" {
            Write-ColorMessage "Listing snapshots..." "Info"
            & $PlakarExe $KeyOption at "$Repo" ls -tags
            $SnapTag = Read-Host "Enter tag to delete"
            
            if (![string]::IsNullOrWhiteSpace($SnapTag)) {
                if (Confirm-Action "Are you sure you want to DELETE snapshot '$SnapTag'?") {
                    Write-ColorMessage "Deleting snapshot..." "Warning"
                    & $PlakarExe $KeyOption at "$Repo" rm -tag "$SnapTag" -apply
                    if ($LASTEXITCODE -eq 0) {
                        Write-ColorMessage "Snapshot deleted successfully." "Success"
                    } else {
                        Write-ColorMessage "Failed to delete snapshot. Exit code: $LASTEXITCODE" "Error"
                    }
                } else {
                    Write-ColorMessage "Delete operation cancelled." "Info"
                }
            } else {
                Write-ColorMessage "No tag entered. Operation cancelled." "Warning"
            }
            Pause
        }

        # USMT Backup
        "8" {
            if (-not (Require-USMTCheck)) { break }
            
            Write-ColorMessage "=== USMT Backup (ScanState) ===" "Info"
            Write-Host ""
            
            # Check if store already exists
            $storeInfo = Get-USMTStoreInfo -StorePath $USMTStore
            if ($storeInfo.Exists) {
                Write-ColorMessage "WARNING: USMT store already exists!" "Warning"
                Write-ColorMessage "Location: $USMTStore" "Info"
                $existingSizeGB = $storeInfo.SizeGB
                $existingFileCount = $storeInfo.FileCount
                Write-ColorMessage "Size: $existingSizeGB GB, Files: $existingFileCount" "Info"
                Write-Host ""
                if (!(Confirm-Action "This will OVERWRITE the existing backup. Continue?")) {
                    Write-ColorMessage "Backup cancelled." "Info"
                    Pause
                    break
                }
                # Clean old store
                Write-ColorMessage "Removing old USMT store..." "Warning"
                Remove-Item -Path $USMTStore -Recurse -Force -ErrorAction SilentlyContinue
            }
            
            # Check disk space
            if (!(Test-DiskSpace -Path $USMTPath -RequiredGB 10)) {
                if (!(Confirm-Action "Low disk space detected. Continue anyway?")) {
                    Pause
                    break
                }
            }
            
            # Create store directory
            if (!(Test-Path $USMTStore)) { 
                Write-ColorMessage "Creating USMT store directory..." "Info"
                New-Item -ItemType Directory -Path $USMTStore | Out-Null 
            }

            # Ask which user profiles to include
            $uiUsers = Select-USMTUsers
            if (-not $uiUsers -or $uiUsers.Count -eq 0) { Pause; break }

            # Build arguments
            $args = @()
            $args += "$USMTStore"
            $args += "/i:$MigUserXML"
            $args += "/i:$MigAppXML"
            $args += "/i:$MigDocsXML"
            foreach ($u in $uiUsers) { $args += "/ui:$u" }
            $args += "/o"
            $args += "/c"
            $args += "/v:5"
            $args += "/l:$ScanLog"

            Write-Host ""
            Write-ColorMessage "Starting USMT Backup..." "Info"
            Write-ColorMessage "Users: $($uiUsers -join ', ')" "Info"
            Write-ColorMessage "This may take several minutes..." "Warning"
            Write-Host ""
            
            $startTime = Get-Date
            
            try {
                & $ScanState @args
                $elapsed = (Get-Date) - $startTime
                Write-Host ""
                
                if ($LASTEXITCODE -eq 0) { 
                    Write-ColorMessage "✓ USMT Backup completed successfully!" "Success"
                    Write-ColorMessage "Time elapsed: $([math]::Round($elapsed.TotalMinutes, 1)) minutes" "Info"
                    
                    # Show store info
                    $newStoreInfo = Get-USMTStoreInfo -StorePath $USMTStore
                    $sizeGB = $newStoreInfo.SizeGB
                    $fileCount = $newStoreInfo.FileCount
                    Write-ColorMessage "Backup size: $sizeGB GB ($fileCount files)" "Info"
                    Write-ColorMessage "Location: $USMTStore" "Info"
                    Write-Host ""
                    
                    # Offer to backup USMT store to Plakar
                    if (Confirm-Action "Would you like to backup the USMT store to Plakar for extra safety?") {
                        Write-ColorMessage "Backing up USMT store to Plakar..." "Info"
                        $plakarTag = "USMT_Store_$(Get-Date -Format yyyyMMdd_HHmmss)"
                        & $PlakarExe $KeyOption at "$Repo" backup -tag "$plakarTag" "$USMTStore"
                        if ($LASTEXITCODE -eq 0) {
                            Write-ColorMessage "USMT store backed up to Plakar successfully!" "Success"
                        } else {
                            Write-ColorMessage "Failed to backup USMT store to Plakar." "Error"
                        }
                    }
                } else { 
                    Write-ColorMessage "✗ USMT Backup FAILED!" "Error"
                    Write-ColorMessage "Exit code: $LASTEXITCODE" "Error"
                    Write-ColorMessage "Time elapsed: $([math]::Round($elapsed.TotalMinutes, 1)) minutes" "Info"
                    Write-Host ""
                    
                    if (Confirm-Action "Would you like to view the log file?") {
                        Open-LogFile -LogPath $ScanLog
                    }
                }
            } catch {
                Write-ColorMessage "ERROR: $($_.Exception.Message)" "Error"
            }

            Pause
        }

        # USMT Restore
        "9" {
            if (-not (Require-USMTCheck)) { break }
            
            Write-ColorMessage "=== USMT Restore (LoadState) ===" "Info"
            Write-Host ""
            
            # Validate USMT store exists
            if (!(Test-Path $USMTStore)) {
                Write-ColorMessage "ERROR: USMT store not found at $USMTStore" "Error"
                Write-ColorMessage "Please run USMT Backup (option 8) first." "Warning"
                Pause
                break
            }
            
            # Show store information
            $storeInfo = Get-USMTStoreInfo -StorePath $USMTStore
            Write-ColorMessage "USMT Store Information:" "Info"
            Write-ColorMessage "Location: $USMTStore" "Info"
            $storeSizeGB = $storeInfo.SizeGB
            $storeFileCount = $storeInfo.FileCount
            Write-ColorMessage "Size: $storeSizeGB GB" "Info"
            Write-ColorMessage "Files: $storeFileCount" "Info"
            Write-Host ""
            
            # Validate store integrity
            if ($storeInfo.FileCount -eq 0) {
                Write-ColorMessage "ERROR: USMT store appears to be empty or corrupted!" "Error"
                Pause
                break
            }

            Write-ColorMessage "WARNING: This will restore user profiles and settings to THIS machine!" "Warning"
            Write-ColorMessage "This operation will:" "Warning"
            Write-Host "  - Restore user profiles, documents, and settings" -ForegroundColor Yellow
            Write-Host "  - May require a system reboot to complete" -ForegroundColor Yellow
            Write-Host "  - Take several minutes to complete" -ForegroundColor Yellow
            Write-Host ""
            
            if (!(Confirm-Action "Are you sure you want to continue with USMT restore?")) {
                Write-ColorMessage "USMT restore cancelled." "Info"
                Pause
                break
            }
            
            Write-Host ""
            Write-ColorMessage "Starting USMT Restore..." "Info"
            Write-ColorMessage "This may take several minutes..." "Warning"
            Write-Host ""
            
            $startTime = Get-Date
            
            try {
                & $LoadState "$USMTStore" "/i:$MigUserXML" "/i:$MigAppXML" "/i:$MigDocsXML" /c /lac /lae /v:5 "/l:$LoadLog"
                $elapsed = (Get-Date) - $startTime
                Write-Host ""
                
                if ($LASTEXITCODE -eq 0) { 
                    Write-ColorMessage "✓ USMT Restore completed successfully!" "Success"
                    Write-ColorMessage "Time elapsed: $([math]::Round($elapsed.TotalMinutes, 1)) minutes" "Info"
                    Write-Host ""
                    Write-ColorMessage "=== Post-Restore Instructions ===" "Info"
                    Write-ColorMessage "1. Verify that user profiles are present" "Info"
                    Write-ColorMessage "2. Check that user documents and settings were restored" "Info"
                    Write-ColorMessage "3. REBOOT the system to complete the restore process" "Warning"
                    Write-ColorMessage "4. Test user logins after reboot" "Info"
                    Write-Host ""
                    
                    if (Confirm-Action "Would you like to reboot now?") {
                        Write-ColorMessage "Rebooting in 10 seconds... (Press Ctrl+C to cancel)" "Warning"
                        Start-Sleep -Seconds 10
                        Restart-Computer -Force
                    }
                } else { 
                    Write-ColorMessage "✗ USMT Restore FAILED!" "Error"
                    Write-ColorMessage "Exit code: $LASTEXITCODE" "Error"
                    Write-ColorMessage "Time elapsed: $([math]::Round($elapsed.TotalMinutes, 1)) minutes" "Info"
                    Write-Host ""
                    Write-ColorMessage "Common issues:" "Warning"
                    Write-Host "  - User accounts may not exist on this system" -ForegroundColor Yellow
                    Write-Host "  - Insufficient permissions (run as Administrator)" -ForegroundColor Yellow
                    Write-Host "  - Disk space issues" -ForegroundColor Yellow
                    Write-Host "  - Corrupted USMT store" -ForegroundColor Yellow
                    Write-Host ""
                    
                    if (Confirm-Action "Would you like to view the log file?") {
                        Open-LogFile -LogPath $LoadLog
                    }
                }
            } catch {
                Write-ColorMessage "ERROR: $($_.Exception.Message)" "Error"
            }

            Pause
        }

        "10" { exit }

        default {
            Write-ColorMessage "Invalid option. Please choose 1-10." "Warning"
            Pause
        }
    }

} while ($true)
