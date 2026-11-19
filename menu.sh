#!/bin/bash

# USMT note: scanstate.exe / loadstate.exe only run on Windows and need the ADK.
# There is no USMT section in this script - use menu.ps1 on the target PC.
# The only thing this script can do with a USMT store is list or restore it as a
# normal folder, once menu.ps1 has added it to the repository as a snapshot.

#####################################################
# CONFIG & SETUP
#####################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$SCRIPT_DIR/plakar_repo"
# Prefer the plakar copied on the USB stick over anything in PATH. A technician's
# machine may have an older or newer plakar installed, and this repository was built
# with the USB binary (backup.sh and menu.ps1 both use the USB copy), so PATH is only
# a fallback here.
PLAKAR_EXE="$SCRIPT_DIR/plakar"
if [ ! -x "$PLAKAR_EXE" ]; then
    PLAKAR_EXE="$(command -v plakar || true)"
fi

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
# Junk patterns, mirrored from menu.ps1 so both engines behave the same. plakar uses
# gitignore semantics: a pattern containing a slash is anchored to the snapshot root,
# so 'AppData/Local/Temp/' does NOT match. A bare name matches at any depth, which is
# what these are. They are NOT applied automatically - the backup prompt asks first,
# because a technician sometimes wants Temp for forensics and a cache is only
# regenerable if the machine is still running.
JUNK_PATTERNS=("Temp/" "Cache/" "INetCache/" "Thumbnails/" "Explorer/" "NuGet/" "npm-cache/" "pkg-npm-caches/" "*.tmp")

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
    KEYOPTION=(-keyfile "$KEYFILE")
else
    KEYOPTION=()
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
    "$PLAKAR_EXE" "${KEYOPTION[@]}" at "$REPO" create
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
        # plakar info reports the authoritative snapshot count. ls -tags also prints
        # header and summary lines, which grep -c would count as snapshots.
        snapshot_count=$("$PLAKAR_EXE" "${KEYOPTION[@]}" at "$REPO" info 2>/dev/null | awk '/Snapshots:/ {print $2; exit}')
        [ -z "$snapshot_count" ] && snapshot_count=0
        
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

    # Keep the newest MAX_LOGS compressed logs. xargs -d is GNU-only and fails on
    # macOS/BSD, so read the list one line at a time.
    local kept=0
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        if [ "$kept" -lt "$MAX_LOGS" ]; then
            kept=$((kept + 1))
        else
            rm -- "$f"
        fi
    done <<< "$(ls -tp "$log_dir"/*.log.gz 2>/dev/null)"
}

# Build the -ignore arguments for one backup. Default answer is yes: on a typical
# profile these patterns are about half the bytes and a third of the file count, which
# is roughly half the backup work.
IGNORE_ARGS=()
ask_exclude_junk() {
    IGNORE_ARGS=()
    echo -e "${COLOR_CYAN}Junk patterns (${#JUNK_PATTERNS[@]}): ${JUNK_PATTERNS[*]}${COLOR_RESET}"
    echo -e "${COLOR_GRAY}Bare names match at any depth, so a user folder named Cache or Explorer is skipped too.${COLOR_RESET}"
    read -p "Exclude them from this backup? (Y/n) " response
    case "$response" in
        [Nn]*) return 1 ;;
    esac
    for pattern in "${JUNK_PATTERNS[@]}"; do
        IGNORE_ARGS+=(-ignore "$pattern")
    done
    return 0
}

# plakar marks what it could not read with KO. A file that is in use (an Outlook OST, a
# browser cache, the NTFS journal) is skipped and the run still exits 0, so the count is
# printed at the end: without it a live profile backup quietly misses whatever was locked.
# The count alone does not say which files were missed, so the KO lines are also written to
# logs/skipped_<tag>.txt, the same file name the Windows host uses.
#
# -name, -environment and -category are stored in the snapshot metadata. They are what
# make prune and locate filterable once the stick holds profiles from several machines;
# the tag alone is not enough.
run_backup() {
    local src_dir="$1"
    local tag="$2"
    local name="$3"
    local category="$4"
    local log_file="$5"
    # Same file name as menu.ps1 so a technician finds the same list on either host.
    local skip_file="$SCRIPT_DIR/logs/skipped_${tag}.txt"

    echo "[Backup] $src_dir → tag=$tag" | tee -a "$log_file"
    "$PLAKAR_EXE" "${KEYOPTION[@]}" at "$REPO" backup "${IGNORE_ARGS[@]}" \
        -name "$name" -environment "$(hostname)" -category "$category" --tag "$tag" "$src_dir" 2>&1 \
        | tee -a "$log_file" \
        | awk -v log="$log_file" -v skip="$skip_file" '
            /KO / { c++; print > skip }
            { print }
            END {
                if (c > 0) {
                    msg = "SKIPPED: " c " entries could not be read"
                    print msg
                    print msg >> log
                    print "Skipped paths written to: " skip
                }
            }'

    # The pipeline ends with awk, so $? here would be awk's status. Return plakar's own
    # exit code so the caller can tell a clean backup from one that failed.
    return ${PIPESTATUS[0]}
}

# Launch a single directory backup in background, with simple concurrency control
backup_dir_bg() {
    local src_dir="$1"
    local tag="$2"
    local name="$3"
    local category="$4"
    local log_file="$5"
    {
        run_backup "$src_dir" "$tag" "$name" "$category" "$log_file"
    } &
}

# Throttle background jobs to PARALLEL_JOBS
throttle_jobs() {
    while [ "$(jobs -p | wc -l | tr -d ' ')" -ge "$PARALLEL_JOBS" ]; do
        sleep 0.5
    done
}

# Run Plakar maintenance (garbage collection / cleanup)
run_maintenance() {
    write_message "Running Plakar maintenance (cleanup)..." "Info"
    "$PLAKAR_EXE" "${KEYOPTION[@]}" at "$REPO" maintenance
    result=$?
    if [ $result -eq 0 ]; then
        write_message "Maintenance completed successfully." "Success"
    else
        write_message "Maintenance failed! Exit code: $result" "Error"
    fi
}

# plakar keeps every snapshot and has no retention of its own, so a technician USB fills
# up over time. prune is the policy engine: keep the last N days, cap how many snapshots
# survive per bucket, group by name so each profile gets its own allowance. Without -apply
# prune only reports, so the plan is shown before anything is removed. Prune does not
# reclaim space by itself - maintenance does, after the grace period.
run_prune() {
    write_message "Prune snapshots (retention policy)" "Info"
    echo -e "${COLOR_GRAY}Example: 30 days with a cap of 1 per day keeps one snapshot per day for a month.${COLOR_RESET}"

    read -p "Days to keep (30): " prune_days
    [ -z "$prune_days" ] && prune_days=30
    read -p "Max snapshots kept per day (1): " prune_cap
    [ -z "$prune_cap" ] && prune_cap=1
    read -p "Category to apply the policy to (profile, empty for all): " prune_category

    case "$prune_days" in
        *[!0-9]*) write_message "ERROR: days must be a number." "Error"; return ;;
    esac
    case "$prune_cap" in
        *[!0-9]*) write_message "ERROR: the per-day cap must be a number." "Error"; return ;;
    esac
    if [ "$prune_days" -lt 1 ] || [ "$prune_cap" -lt 1 ]; then
        write_message "ERROR: both values must be at least 1." "Error"
        return
    fi

    argv=(at "$REPO" prune -days "$prune_days" -per-day "$prune_cap" -group-by name)
    [ -n "$prune_category" ] && argv+=(-category "$prune_category")

    echo
    write_message "Plan:" "Info"
    "$PLAKAR_EXE" "${KEYOPTION[@]}" "${argv[@]}"
    result=$?
    if [ $result -ne 0 ]; then
        write_message "Prune failed! Exit code: $result" "Error"
        return
    fi

    if ! confirm_action "Apply this policy and delete the snapshots listed above?"; then
        return
    fi

    "$PLAKAR_EXE" "${KEYOPTION[@]}" "${argv[@]}" -apply
    result=$?
    if [ $result -eq 0 ]; then
        write_message "Policy applied." "Success"
        echo -e "${COLOR_GRAY}The space is reclaimed by maintenance after the grace period, not by prune itself.${COLOR_RESET}"
    else
        write_message "Prune failed! Exit code: $result" "Error"
    fi
}

# Search every snapshot, not just the last one. Useful when you no longer know which
# backup a file came from. plakar has no size cap, so this is also how you find the one
# huge file that made a profile backup slow.
run_locate() {
    write_message "Locate a file across snapshots" "Info"
    echo -e "${COLOR_GRAY}Searches all snapshots. Example: invoice.pdf${COLOR_RESET}"
    read -p "File name or pattern: " locate_pattern
    [ -z "$locate_pattern" ] && return

    out=$("$PLAKAR_EXE" "${KEYOPTION[@]}" at "$REPO" locate "$locate_pattern")
    result=$?
    [ -n "$out" ] && printf '%s\n' "$out"
    hits=$(printf '%s\n' "$out" | grep -c '^[0-9a-f]\{8\}:/')

    if [ $result -ne 0 ]; then
        write_message "Locate failed! Exit code: $result" "Error"
    elif [ "$hits" -gt 0 ]; then
        write_message "$hits match(es)." "Success"
    else
        write_message "No matches." "Info"
    fi
    echo -e "${COLOR_GRAY}To read one: plakar at <repo> cat <snapshotID>:<path>${COLOR_RESET}"
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
    echo "8. Run maintenance (cleanup)"
    echo "9. Prune snapshots (retention policy)"
    echo "10. Locate a file across snapshots"
    echo "11. Exit"
    echo
    echo -e "${COLOR_GRAY}USMT (ScanState / LoadState) is Windows-only and lives in menu.ps1.${COLOR_RESET}"
    echo -e "${COLOR_GRAY}A USMT store can only be handled here as an ordinary folder, after it has${COLOR_RESET}"
    echo -e "${COLOR_GRAY}been added to the repository as a snapshot by menu.ps1.${COLOR_RESET}"
    echo

    read -p "Choose an option (1-11): " CHOICE

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

            ask_exclude_junk

            start_time=$(date +%s)
            
            if [ "$PARALLEL_ENABLED" = true ]; then
                write_message "Running up to $PARALLEL_JOBS backups in parallel..." "Info" | tee -a "$SNAP_LOG"
                for USER_DIR in /Users/*; do
                    USERNAME=$(basename "$USER_DIR")
                    [ "$USERNAME" != "Shared" ] || continue
                    [ -d "$USER_DIR" ] || continue
                    throttle_jobs
                    backup_dir_bg "$USER_DIR" "${SNAP_TAG}_${USERNAME}" "$USERNAME" "profile" "$SNAP_LOG"
                done
                wait
            else
                for USER_DIR in /Users/*; do
                    USERNAME=$(basename "$USER_DIR")
                    [ "$USERNAME" != "Shared" ] || continue
                    [ -d "$USER_DIR" ] || continue
                    run_backup "$USER_DIR" "${SNAP_TAG}_${USERNAME}" "$USERNAME" "profile" "$SNAP_LOG"
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

            ask_exclude_junk

            start_time=$(date +%s)
            
            run_backup "$CUSTOM_FOLDER" "$SNAP_TAG" "$SNAP_NAME" "custom" "$SNAP_LOG"
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
            "$PLAKAR_EXE" "${KEYOPTION[@]}" at "$REPO" ls -tags
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
            
            # Measured on Windows: skipping the per-file ACL work makes a profile-shaped
            # restore about 2x faster, and the stored ACLs reference SIDs from the machine
            # the backup was made on, which are meaningless on this one. Files inherit
            # permissions from the destination instead. On macOS/Linux this also means the
            # stored file mode is not reapplied - drop the option if that matters.
            "$PLAKAR_EXE" "${KEYOPTION[@]}" at "$REPO" restore -tag "$SNAP_TAG" -to "$RESTORE_TO" -o skip_permissions=1
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
            "$PLAKAR_EXE" "${KEYOPTION[@]}" at "$REPO" ls -tags
            read -p "Press enter..."
        ;;
        5)
            write_message "Listing snapshots..." "Info"
            "$PLAKAR_EXE" "${KEYOPTION[@]}" at "$REPO" ls -tags
            echo
            read -p "Enter snapshot tag to view details: " SNAP_TAG
            if [ ! -z "$SNAP_TAG" ]; then
                echo
                write_message "Snapshot Details:" "Info"
                "$PLAKAR_EXE" "${KEYOPTION[@]}" at "$REPO" ls "$SNAP_TAG"
            fi
            read -p "Press enter..."
        ;;
        6)
            write_message "Starting Plakar UI..." "Info"
            "$PLAKAR_EXE" "${KEYOPTION[@]}" at "$REPO" ui &
            read -p "Press enter..."
        ;;
        7)
            write_message "Listing snapshots..." "Info"
            "$PLAKAR_EXE" "${KEYOPTION[@]}" at "$REPO" ls -tags
            echo
            read -p "Enter tag to delete: " SNAP_TAG
            
            if [ ! -z "$SNAP_TAG" ]; then
                if confirm_action "Are you sure you want to DELETE snapshot '$SNAP_TAG'?"; then
                    write_message "Deleting snapshot..." "Warning"
                    "$PLAKAR_EXE" "${KEYOPTION[@]}" at "$REPO" rm -tag "$SNAP_TAG" -apply
                    result=$?
                    if [ $result -eq 0 ]; then
                        write_message "Snapshot deleted successfully." "Success"
                        if confirm_action "Run maintenance now to reclaim space?"; then
                            run_maintenance
                        fi
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
            if confirm_action "Run maintenance now?"; then
                run_maintenance
            fi
            read -p "Press enter..."
        ;;
        9)
            run_prune
            read -p "Press enter..."
        ;;
        10)
            run_locate
            read -p "Press enter..."
        ;;
        11)
            write_message "Goodbye!" "Info"
            exit 0
        ;;
        *)
            write_message "Invalid option. Please choose 1-11." "Warning"
            read -p "Press enter..."
        ;;
    esac
done

