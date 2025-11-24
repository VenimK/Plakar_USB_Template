#!/bin/bash

#####################################################
# CONFIG & SETUP
#####################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$SCRIPT_DIR/plakar_repo"
PLAKAR_EXE="$(command -v plakar || echo "$SCRIPT_DIR/plakar")"

# Parallel processing settings
THREADS=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)  # Get CPU core count or default to 4
PARALLEL_JOBS=4  # Number of parallel backup jobs
PARALLEL_ENABLED=true  # Set to false to disable parallel processing
MAX_LOG_SIZE_MB=10  # Max log file size in MB
MAX_LOGS=5          # Max number of log files to keep
EXCLUDE_PATTERNS=("*.tmp" "*.log" "*.cache" "*.temp" "~*" "Thumbs.db" ".DS_Store" "*.swp" "*~" "*.bak")

if [ -z "$PLAKAR_EXE" ] || [ ! -x "$PLAKAR_EXE" ]; then
    echo "❌ Plakar executable not found!"
    exit 1
fi

mkdir -p "$REPO" "$SCRIPT_DIR/logs"

#####################################################
# KEY FILE SUPPORT
#####################################################
KEYFILE="$SCRIPT_DIR/.plakar_key"

if [ -f "$KEYFILE" ]; then
    KEYOPTION="-keyfile $KEYFILE"
else
    KEYOPTION=""
fi

#####################################################
# START AGENT IF NOT RUNNING
#####################################################
$PLAKAR_EXE agent status >/dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "Starting Plakar agent..."
    $PLAKAR_EXE agent start
fi

#####################################################
# AUTO-CREATE REPOSITORY IF MISSING
#####################################################
if [ ! -f "$REPO/CONFIG" ]; then
    echo "Plakar repository not found. Initializing at $REPO..."
    $PLAKAR_EXE $KEYOPTION at "$REPO" create
    if [ $? -ne 0 ]; then
        echo "❌ Failed to create repository. Check Plakar executable and permissions."
        exit 1
    fi
    echo "✔ Repository initialized at $REPO"
fi

#####################################################
# FUNCTIONS
#####################################################

# Function to check disk space
check_disk_space() {
    local required=$1
    local available=$(df -k --output=avail "$REPO" | tail -n1)
    if [ "$available" -lt $((required * 1024)) ]; then
        echo "❌ Not enough disk space! Need at least ${required}MB free."
        return 1
    fi
    return 0
}

# Function to rotate logs
rotate_logs() {
    local log_dir="$SCRIPT_DIR/logs"
    find "$log_dir" -type f -name "*.log" -size +${MAX_LOG_SIZE_MB}M -exec gzip {} \;
    ls -tp "$log_dir"/*.log.gz 2>/dev/null | tail -n +$((MAX_LOGS + 1)) | xargs -d '\n' -r rm --
}

# Function for parallel backup
parallel_backup() {
    local src_dir="$1"
    local tag="$2"
    local log_file="$3"
    local tmp_dir="/tmp/plakar_parallel_$$"
    
    echo "Starting parallel backup with $PARALLEL_JOBS jobs..." | tee -a "$log_file"
    
    # Create temporary directory for parallel processing
    mkdir -p "$tmp_dir"
    
    # Split directory listing into chunks
    echo "Scanning directory for files..." | tee -a "$log_file"
    find "$src_dir" -type f > "$tmp_dir/filelist.txt"
    local total_files=$(wc -l < "$tmp_dir/filelist.txt")
    echo "Found $total_files files to back up" | tee -a "$log_file"
    
    # Split into chunks for parallel processing
    split -n l/$PARALLEL_JOBS "$tmp_dir/filelist.txt" "$tmp_dir/chunk_"
    
    # Process chunks in parallel
    echo "Starting parallel backup processes..." | tee -a "$log_file"
    local i=0
    for chunk in "$tmp_dir/chunk_"*; do
        ((i++))
        {
            echo "[Job $i] Starting backup of $(wc -l < "$chunk") files" | tee -a "$log_file"
            while IFS= read -r file; do
                "$PLAKAR_EXE" $KEYOPTION at "$REPO" backup --tag "$tag" --no-scan "$file" 2>> "$log_file.$i"
            done < "$chunk"
            echo "[Job $i] Completed" | tee -a "$log_file"
        } &
    done
    
    # Wait for all background jobs to complete
    wait
    
    # Cleanup
    rm -rf "$tmp_dir"
    echo "Parallel backup completed" | tee -a "$log_file"
}

#####################################################
# MENU LOOP
#####################################################
while true; do
    clear
    echo "=== Plakar Technician Menu ==="
    echo "Repository: $REPO"
    echo
    echo "1. Backup user profiles"
    echo "2. Backup custom folder"
    echo "3. Restore snapshot"
    echo "4. List snapshots"
    echo "5. Start Plakar UI"
    echo "6. Delete snapshot"
    echo "7. Exit"
    echo

    read -p "Choose an option (1-7): " CHOICE

    case $CHOICE in
        1)
            read -p "Enter snapshot name (client/machine): " SNAP_NAME
            [ -z "$SNAP_NAME" ] && SNAP_NAME="Unnamed"
            SNAP_TAG="${SNAP_NAME}_$(date +%Y%m%d_%H%M%S)"
            SNAP_LOG="$SCRIPT_DIR/logs/backup_users_${SNAP_TAG}.log"
            echo "Backing up user profiles as tag '$SNAP_TAG'..."
            if [ "$PARALLEL_ENABLED" = true ]; then
                for USER_DIR in /Users/*; do
                    USERNAME=$(basename "$USER_DIR")
                    [ "$USERNAME" != "Shared" ] || continue
                    echo " - Processing $USER_DIR in parallel mode" | tee -a "$SNAP_LOG"
                    if ! check_disk_space 1024; then  # Check for at least 1GB free
                        echo "❌ Skipping $USER_DIR - not enough disk space" | tee -a "$SNAP_LOG"
                        continue
                    fi
                    parallel_backup "$USER_DIR" "${SNAP_TAG}_${USERNAME}" "$SNAP_LOG"
                done
            else
                for USER_DIR in /Users/*; do
                    USERNAME=$(basename "$USER_DIR")
                    [ "$USERNAME" != "Shared" ] || continue
                    echo " - $USER_DIR (sequential mode)" | tee -a "$SNAP_LOG"
                    if ! check_disk_space 1024; then  # Check for at least 1GB free
                        echo "❌ Skipping $USER_DIR - not enough disk space" | tee -a "$SNAP_LOG"
                        continue
                    fi
                    $PLAKAR_EXE $KEYOPTION at "$REPO" backup --tag "${SNAP_TAG}_${USERNAME}" "$USER_DIR" 2>&1 | tee -a "$SNAP_LOG"
                done
            fi
            echo "✔ Backup complete. Tag: $SNAP_TAG"
            read -p "Press enter..."
        ;;
        2)
            read -p "Enter full path of folder to backup: " CUSTOM_FOLDER
            if [ ! -d "$CUSTOM_FOLDER" ]; then
                echo "❌ Folder does not exist!"
                read -p "Press enter..."
                continue
            fi
            read -p "Enter snapshot name (client/job): " SNAP_NAME
            [ -z "$SNAP_NAME" ] && SNAP_NAME="Unnamed"
            SNAP_TAG="${SNAP_NAME}_$(date +%Y%m%d_%H%M%S)"
            SNAP_LOG="$SCRIPT_DIR/logs/backup_custom_${SNAP_TAG}.log"
            echo "Backing up '$CUSTOM_FOLDER' as tag '$SNAP_TAG'..."
            if [ "$PARALLEL_ENABLED" = true ]; then
                echo "Using parallel backup mode with $PARALLEL_JOBS jobs" | tee -a "$SNAP_LOG"
                if ! check_disk_space 1024; then  # Check for at least 1GB free
                    echo "❌ Not enough disk space for backup" | tee -a "$SNAP_LOG"
                    read -p "Press enter..."
                    continue
                fi
                parallel_backup "$CUSTOM_FOLDER" "$SNAP_TAG" "$SNAP_LOG"
            else
                echo "Using sequential backup mode" | tee -a "$SNAP_LOG"
                if ! check_disk_space 1024; then  # Check for at least 1GB free
                    echo "❌ Not enough disk space for backup" | tee -a "$SNAP_LOG"
                    read -p "Press enter..."
                    continue
                fi
                $PLAKAR_EXE $KEYOPTION at "$REPO" backup --tag "$SNAP_TAG" "$CUSTOM_FOLDER" 2>&1 | tee -a "$SNAP_LOG"
            fi
            echo "✔ Backup complete"
            read -p "Press enter..."
        ;;
        3)
            echo "Available snapshots (Tag → Size → Path):"
            $PLAKAR_EXE $KEYOPTION at "$REPO" ls -tags
            read -p "Enter exact snapshot tag to restore: " SNAP_TAG
            read -p "Enter restore target folder: " RESTORE_TO
            mkdir -p "$RESTORE_TO"
            echo "Restoring snapshot '$SNAP_TAG' to $RESTORE_TO..."
            $PLAKAR_EXE $KEYOPTION at "$REPO" restore -tag "$SNAP_TAG" -to "$RESTORE_TO"
            echo "✔ Restore complete"
            read -p "Press enter..."
        ;;
        4)
            $PLAKAR_EXE $KEYOPTION at "$REPO" ls -tags
            read -p "Press enter..."
        ;;
        5)
            echo "Starting Plakar UI..."
            $PLAKAR_EXE $KEYOPTION at "$REPO" ui &
            read -p "Press enter..."
        ;;
        6)
            echo "Available snapshots (Tag → Size → Path):"
            $PLAKAR_EXE $KEYOPTION at "$REPO" ls -tags
            read -p "Enter snapshot tag to delete: " SNAP_TAG
            echo "Deleting snapshot '$SNAP_TAG'..."
            $PLAKAR_EXE $KEYOPTION at "$REPO" rm -tag "$SNAP_TAG" -apply
            echo "✔ Snapshot deleted"
            read -p "Press enter..."
        ;;
        7)
            echo "Goodbye!"
            exit 0
        ;;
        *)
            echo "Invalid choice!"
            read -p "Press enter..."
        ;;
    esac
done

