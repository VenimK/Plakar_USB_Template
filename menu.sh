#!/bin/bash

#####################################################
# CONFIG & SETUP
#####################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$SCRIPT_DIR/plakar_repo"
PLAKAR_EXE="$(command -v plakar || echo "$SCRIPT_DIR/plakar")"

# Color codes for better UX
COLOR_RESET="\033[0m"
COLOR_RED="\033[0;31m"
COLOR_GREEN="\033[0;32m"
COLOR_YELLOW="\033[0;33m"
COLOR_CYAN="\033[0;36m"
COLOR_GRAY="\033[0;90m"

# Parallel processing settings (portable)
THREADS=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)  # CPU core count (macOS/BSD)
PARALLEL_JOBS=4  # Max concurrent user backups (option 1)
PARALLEL_ENABLED=true  # Enable per-user parallel backups
MAX_LOG_SIZE_MB=10  # Max log file size in MB
MAX_LOGS=5          # Max number of compressed logs to keep
EXCLUDE_PATTERNS=("*.tmp" "*.log" "*.cache" "*.temp" "~*" "Thumbs.db" ".DS_Store" "*.swp" "*~" "*.bak")

if [ -z "$PLAKAR_EXE" ] || [ ! -x "$PLAKAR_EXE" ]; then
    echo -e "${COLOR_RED}ERROR: Plakar executable not found!${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}Please ensure plakar is in the same directory as this script or in your PATH.${COLOR_RESET}"
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
    echo -e "${COLOR_CYAN}Creating Plakar repository at $REPO...${COLOR_RESET}"
    $PLAKAR_EXE $KEYOPTION at "$REPO" create
    if [ $? -ne 0 ]; then
        echo -e "${COLOR_RED}ERROR: Failed to create Plakar repository. Exit code: $?${COLOR_RESET}"
        exit 1
    fi
    echo -e "${COLOR_GREEN}Repository created successfully.${COLOR_RESET}"
fi

#####################################################
# HELPER FUNCTIONS
#####################################################

# Colored message function
write_message() {
    local message="$1"
    local type="${2:-Info}"
    
    case "$type" in
        Success)
            echo -e "${COLOR_GREEN}${message}${COLOR_RESET}"
            ;;
        Error)
            echo -e "${COLOR_RED}${message}${COLOR_RESET}"
            ;;
        Warning)
            echo -e "${COLOR_YELLOW}${message}${COLOR_RESET}"
            ;;
        Info)
            echo -e "${COLOR_CYAN}${message}${COLOR_RESET}"
            ;;
        *)
            echo "$message"
            ;;
    esac
}

# Confirmation prompt
confirm_action() {
    local message="$1"
    read -p "$message (y/n): " response
    [[ "$response" =~ ^[Yy]$ ]]
}

# Validate path exists
validate_path() {
    local path="$1"
    if [ -z "$path" ]; then
        write_message "ERROR: Path cannot be empty." "Error"
        return 1
    fi
    if [ ! -e "$path" ]; then
        write_message "ERROR: Path not found: $path" "Error"
        return 1
    fi
    return 0
}

# Get repository info (snapshot count and size)
get_repo_info() {
    local snapshot_count=0
    local repo_size_gb=0
    
    if [ -d "$REPO" ]; then
        # Count snapshots
        snapshot_count=$($PLAKAR_EXE $KEYOPTION at "$REPO" ls -tags 2>/dev/null | grep -c "^" || echo 0)
        
        # Calculate repo size in GB
        if command -v du >/dev/null 2>&1; then
            local size_kb=$(du -sk "$REPO" 2>/dev/null | awk '{print $1}')
            repo_size_gb=$(echo "scale=2; $size_kb / 1024 / 1024" | bc 2>/dev/null || echo "0")
        fi
    fi
    
    echo "${snapshot_count}|${repo_size_gb}"
}

# Function to check disk space (portable: BSD/macOS df)
check_disk_space() {
    local required_mb=$1
    # Available 1K blocks in the filesystem hosting REPO
    local available_k=$(df -k "$REPO" 2>/dev/null | awk 'NR==2{print $4}')
    [ -z "$available_k" ] && available_k=0
    # Compare in MB
    local available_mb=$((available_k / 1024))
    if [ "$available_mb" -lt "$required_mb" ]; then
        write_message "Not enough disk space! Need at least ${required_mb}MB free (have ${available_mb}MB)." "Warning"
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

# Launch a single directory backup in background, with simple concurrency control
backup_dir_bg() {
    local src_dir="$1"
    local tag="$2"
    local log_file="$3"
    {
        echo "[Backup] $src_dir → tag=$tag" | tee -a "$log_file"
        "$PLAKAR_EXE" $KEYOPTION at "$REPO" backup --tag "$tag" "$src_dir" 2>&1 | tee -a "$log_file"
        echo "[Backup] Completed $src_dir" | tee -a "$log_file"
    } &
}

# Throttle background jobs to PARALLEL_JOBS
throttle_jobs() {
    while [ "$(jobs -p | wc -l | tr -d ' ')" -ge "$PARALLEL_JOBS" ]; do
        sleep 0.5
    done
}

#####################################################
# MENU LOOP
#####################################################
while true; do
    clear
    
    # Get repository info
    repo_info=$(get_repo_info)
    snap_count=$(echo "$repo_info" | cut -d'|' -f1)
    repo_size=$(echo "$repo_info" | cut -d'|' -f2)
    
    echo -e "${COLOR_CYAN}=========================================${COLOR_RESET}"
    echo -e "     Plakar Technician Menu"
    echo -e "${COLOR_CYAN}=========================================${COLOR_RESET}"
    echo -e "${COLOR_GRAY}Repository: ${COLOR_RESET}${COLOR_YELLOW}${snap_count} snapshots, ${repo_size} GB${COLOR_RESET}"
    echo -e "${COLOR_CYAN}=========================================${COLOR_RESET}"
    echo
    echo "1. Backup user profiles"
    echo "2. Backup custom folder"
    echo "3. Restore snapshot"
    echo "4. List snapshots"
    echo "5. View snapshot details"
    echo "6. Start Plakar UI"
    echo "7. Delete snapshot"
    echo "8. Exit"
    echo

    read -p "Choose an option (1-8): " CHOICE

    case $CHOICE in
        1)
            write_message "Backup User Profiles" "Info"
            echo -e "${COLOR_GRAY}Example: ClientName or MachineName${COLOR_RESET}"
            read -p "Enter snapshot name: " SNAP_NAME
            [ -z "$SNAP_NAME" ] && SNAP_NAME="Unnamed"
            SNAP_TAG="${SNAP_NAME}_$(date +%Y%m%d_%H%M%S)"
            SNAP_LOG="$SCRIPT_DIR/logs/backup_users_${SNAP_TAG}.log"
            
            write_message "Starting backup with tag prefix: $SNAP_TAG" "Info"
            
            if ! check_disk_space 1024; then
                write_message "WARNING: Low disk space detected" "Warning"
                if ! confirm_action "Continue anyway?"; then
                    continue
                fi
            fi
            
            start_time=$(date +%s)
            
            if [ "$PARALLEL_ENABLED" = true ]; then
                write_message "Running up to $PARALLEL_JOBS backups in parallel..." "Info" | tee -a "$SNAP_LOG"
                for USER_DIR in /Users/*; do
                    USERNAME=$(basename "$USER_DIR")
                    [ "$USERNAME" != "Shared" ] || continue
                    [ -d "$USER_DIR" ] || continue
                    throttle_jobs
                    backup_dir_bg "$USER_DIR" "${SNAP_TAG}_${USERNAME}" "$SNAP_LOG"
                done
                wait
            else
                for USER_DIR in /Users/*; do
                    USERNAME=$(basename "$USER_DIR")
                    [ "$USERNAME" != "Shared" ] || continue
                    [ -d "$USER_DIR" ] || continue
                    "$PLAKAR_EXE" $KEYOPTION at "$REPO" backup --tag "${SNAP_TAG}_${USERNAME}" "$USER_DIR" 2>&1 | tee -a "$SNAP_LOG"
                done
            fi
            
            end_time=$(date +%s)
            elapsed=$((end_time - start_time))
            elapsed_min=$(echo "scale=1; $elapsed / 60" | bc 2>/dev/null || echo "0")
            
            write_message "[SUCCESS] Backup complete!" "Success"
            write_message "Time elapsed: ${elapsed_min} minutes" "Info"
            write_message "Tag prefix: $SNAP_TAG" "Info"
            read -p "Press enter..."
        ;;
        2)
            write_message "Backup Custom Folder" "Info"
            echo -e "${COLOR_GRAY}Example: /Users/username/Documents${COLOR_RESET}"
            read -p "Enter full path of folder to backup: " CUSTOM_FOLDER
            
            if ! validate_path "$CUSTOM_FOLDER"; then
                read -p "Press enter..."
                continue
            fi
            
            if [ ! -d "$CUSTOM_FOLDER" ]; then
                write_message "ERROR: Path exists but is not a directory!" "Error"
                read -p "Press enter..."
                continue
            fi
            
            read -p "Enter snapshot name (e.g., MyDocuments): " SNAP_NAME
            [ -z "$SNAP_NAME" ] && SNAP_NAME="Unnamed"
            SNAP_TAG="${SNAP_NAME}_$(date +%Y%m%d_%H%M%S)"
            SNAP_LOG="$SCRIPT_DIR/logs/backup_custom_${SNAP_TAG}.log"
            
            write_message "Backing up: $CUSTOM_FOLDER" "Info"
            write_message "Tag: $SNAP_TAG" "Info"
            
            if ! check_disk_space 1024; then
                write_message "WARNING: Low disk space detected" "Warning"
                if ! confirm_action "Continue anyway?"; then
                    continue
                fi
            fi
            
            start_time=$(date +%s)
            
            $PLAKAR_EXE $KEYOPTION at "$REPO" backup --tag "$SNAP_TAG" "$CUSTOM_FOLDER" 2>&1 | tee -a "$SNAP_LOG"
            result=$?
            
            end_time=$(date +%s)
            elapsed=$((end_time - start_time))
            elapsed_min=$(echo "scale=1; $elapsed / 60" | bc 2>/dev/null || echo "0")
            
            if [ $result -eq 0 ]; then
                write_message "[SUCCESS] Backup completed successfully!" "Success"
                write_message "Time elapsed: ${elapsed_min} minutes" "Info"
            else
                write_message "[FAILED] Backup failed! Exit code: $result" "Error"
                write_message "Check log: $SNAP_LOG" "Warning"
            fi
            read -p "Press enter..."
        ;;
        3)
            write_message "Restore Snapshot" "Info"
            $PLAKAR_EXE $KEYOPTION at "$REPO" ls -tags
            echo
            read -p "Enter snapshot tag to restore: " SNAP_TAG
            
            if [ -z "$SNAP_TAG" ]; then
                write_message "ERROR: Snapshot tag cannot be empty." "Error"
                read -p "Press enter..."
                continue
            fi
            
            echo -e "${COLOR_GRAY}Example: /Users/username/Restored${COLOR_RESET}"
            read -p "Enter restore target folder: " RESTORE_TO
            
            if [ -z "$RESTORE_TO" ]; then
                write_message "ERROR: Restore path cannot be empty." "Error"
                read -p "Press enter..."
                continue
            fi
            
            mkdir -p "$RESTORE_TO"
            
            write_message "Restoring snapshot $SNAP_TAG to $RESTORE_TO ..." "Info"
            
            start_time=$(date +%s)
            
            $PLAKAR_EXE $KEYOPTION at "$REPO" restore -tag "$SNAP_TAG" -to "$RESTORE_TO"
            result=$?
            
            end_time=$(date +%s)
            elapsed=$((end_time - start_time))
            elapsed_min=$(echo "scale=1; $elapsed / 60" | bc 2>/dev/null || echo "0")
            
            if [ $result -eq 0 ]; then
                write_message "[SUCCESS] Restore completed successfully!" "Success"
                write_message "Time elapsed: ${elapsed_min} minutes" "Info"
                write_message "Files restored to: $RESTORE_TO" "Info"
            else
                write_message "[FAILED] Restore failed! Exit code: $result" "Error"
            fi
            read -p "Press enter..."
        ;;
        4)
            write_message "Listing all snapshots..." "Info"
            $PLAKAR_EXE $KEYOPTION at "$REPO" ls -tags
            read -p "Press enter..."
        ;;
        5)
            write_message "Listing snapshots..." "Info"
            $PLAKAR_EXE $KEYOPTION at "$REPO" ls -tags
            echo
            read -p "Enter snapshot tag to view details: " SNAP_TAG
            if [ ! -z "$SNAP_TAG" ]; then
                echo
                write_message "Snapshot Details:" "Info"
                $PLAKAR_EXE $KEYOPTION at "$REPO" ls -snapshot "$SNAP_TAG"
            fi
            read -p "Press enter..."
        ;;
        6)
            write_message "Starting Plakar UI..." "Info"
            $PLAKAR_EXE $KEYOPTION at "$REPO" ui &
            read -p "Press enter..."
        ;;
        7)
            write_message "Listing snapshots..." "Info"
            $PLAKAR_EXE $KEYOPTION at "$REPO" ls -tags
            echo
            read -p "Enter tag to delete: " SNAP_TAG
            
            if [ ! -z "$SNAP_TAG" ]; then
                if confirm_action "Are you sure you want to DELETE snapshot '$SNAP_TAG'?"; then
                    write_message "Deleting snapshot..." "Warning"
                    $PLAKAR_EXE $KEYOPTION at "$REPO" rm -tag "$SNAP_TAG" -apply
                    result=$?
                    if [ $result -eq 0 ]; then
                        write_message "Snapshot deleted successfully." "Success"
                    else
                        write_message "Failed to delete snapshot. Exit code: $result" "Error"
                    fi
                else
                    write_message "Delete operation cancelled." "Info"
                fi
            else
                write_message "No tag entered. Operation cancelled." "Warning"
            fi
            read -p "Press enter..."
        ;;
        8)
            write_message "Goodbye!" "Info"
            exit 0
        ;;
        *)
            write_message "Invalid option. Please choose 1-8." "Warning"
            read -p "Press enter..."
        ;;
    esac
done

