#!/bin/bash
# backup.sh – Mac technician backup script with Plakar
# Supports user profile selection OR custom folder
# Auto-detect USB/local test folder, external/NAS destinations, logs

# ================= Auto-detect repository =================
TEST_FOLDER="$HOME/plakar_test"

if [ -d "$TEST_FOLDER" ]; then
    USB_DRIVE="$TEST_FOLDER"
    echo "Using local test folder: $USB_DRIVE"
else
    USB_DRIVE=$(df | awk '{print $6}' | grep -E "/Volumes/.+" | head -n 1)
    if [ -z "$USB_DRIVE" ]; then
        echo "Error: No USB drive found!"
        exit 1
    fi
    echo "Using USB drive: $USB_DRIVE"
fi

REPO="$USB_DRIVE/plakar_repo"
PLAKAR_EXE="$USB_DRIVE/plakar"
KEYFILE="$USB_DRIVE/.plakar_key"
KEYOPTION=""

if [ ! -f "$PLAKAR_EXE" ]; then
    echo "Error: plakar executable not found at $PLAKAR_EXE"
    exit 1
fi

if [ -f "$KEYFILE" ]; then
    KEYOPTION="-keyfile $KEYFILE"
fi

# ================= Start Plakar agent =================
$PLAKAR_EXE agent status &>/dev/null
if [ $? -ne 0 ]; then
    echo "Starting Plakar agent..."
    $PLAKAR_EXE $KEYOPTION agent start
fi

# ================= Create repository if not exists =================
$PLAKAR_EXE $KEYOPTION at "$REPO" create

# ================= Logs =================
LOG_DIR="$USB_DRIVE/logs"
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_FILE="$LOG_DIR/backup_$TIMESTAMP.log"

# ================= Prompt for destination =================
read -p "Enter backup destination (leave empty to use repository): " DEST
DEST=${DEST:-$REPO}

# ================= Prompt for custom folder =================
read -p "Enter full path of folder to backup (leave empty to select user profiles): " CUSTOM_FOLDER

if [ -n "$CUSTOM_FOLDER" ] && [ -d "$CUSTOM_FOLDER" ]; then
    echo "Backing up folder $CUSTOM_FOLDER..."
    $PLAKAR_EXE $KEYOPTION at "$REPO" backup "$CUSTOM_FOLDER" --destination "$DEST" | tee -a "$LOG_FILE"
else
    # ================= User profile selection =================
    SKIP=("Shared" "Guest" "Deleted Users")
    PROFILES=()
    i=1
    echo "Available user profiles:"
    for DIR in /Users/*; do
        NAME=$(basename "$DIR")
        if [[ ! " ${SKIP[@]} " =~ " ${NAME} " ]]; then
            echo "$i. $NAME"
            PROFILES+=("$DIR")
            i=$((i+1))
        fi
    done

    read -p "Enter numbers of profiles to backup (comma-separated, e.g. 1,3): " SELECTION
    IFS=',' read -ra SELECTED <<< "$SELECTION"

    for IDX in "${SELECTED[@]}"; do
        IDX=$((IDX-1))
        if [ $IDX -ge 0 ] && [ $IDX -lt ${#PROFILES[@]} ]; then
            PROFILE_PATH="${PROFILES[$IDX]}"
            echo "Backing up $PROFILE_PATH..."
            $PLAKAR_EXE $KEYOPTION at "$REPO" backup "$PROFILE_PATH" --destination "$DEST" | tee -a "$LOG_FILE"
        fi
    done
fi

echo "Backup complete. Log saved to $LOG_FILE"

