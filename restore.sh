#!/bin/bash
# restore.sh – Mac technician restore script

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

# ================= List snapshots =================
echo "Available snapshots:"
$PLAKAR_EXE $KEYOPTION at "$REPO" ls

# ================= Prompt snapshot and restore path =================
read -p "Enter snapshot ID to restore: " SNAPSHOT
read -p "Enter restore path (default: /Users): " RESTORE_PATH
RESTORE_PATH=${RESTORE_PATH:-/Users}

# ================= Logs =================
LOG_DIR="$USB_DRIVE/logs"
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_FILE="$LOG_DIR/restore_$TIMESTAMP.log"

# ================= Restore =================
echo "Restoring snapshot $SNAPSHOT to $RESTORE_PATH..."
$PLAKAR_EXE $KEYOPTION at "$REPO" restore -to "$RESTORE_PATH" "$SNAPSHOT" | tee -a "$LOG_FILE"

echo "Restore complete. Log saved to $LOG_FILE"

