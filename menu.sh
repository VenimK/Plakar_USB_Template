#!/bin/bash

#####################################################
# CONFIG & SETUP
#####################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$SCRIPT_DIR/plakar_repo"
PLAKAR_EXE="$(command -v plakar || echo "$SCRIPT_DIR/plakar")"

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
            for USER_DIR in /Users/*; do
                USERNAME=$(basename "$USER_DIR")
                [ "$USERNAME" != "Shared" ] || continue
                echo " - $USER_DIR" | tee -a "$SNAP_LOG"
                $PLAKAR_EXE $KEYOPTION at "$REPO" backup -tag "$SNAP_TAG" "$USER_DIR" 2>&1 | tee -a "$SNAP_LOG"
            done
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
            $PLAKAR_EXE $KEYOPTION at "$REPO" backup -tag "$SNAP_TAG" "$CUSTOM_FOLDER" 2>&1 | tee -a "$SNAP_LOG"
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

