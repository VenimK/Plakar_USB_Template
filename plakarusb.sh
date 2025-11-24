#!/bin/bash
# ================================================
# Plakar USB Template Generator – macOS/Linux
# Fully automated for scripts in home folder
# ================================================

# === Paths to your working scripts (assume in home folder) ===
SCRIPT_SRC_DIR="$HOME"
MENU_SH_SRC="$SCRIPT_SRC_DIR/menu.sh"
BACKUP_SH_SRC="$SCRIPT_SRC_DIR/backup.sh"
RESTORE_SH_SRC="$SCRIPT_SRC_DIR/restore.sh"
MENU_PS1_SRC="$SCRIPT_SRC_DIR/menu.ps1"
BACKUP_PS1_SRC="$SCRIPT_SRC_DIR/backup.ps1"
RESTORE_PS1_SRC="$SCRIPT_SRC_DIR/restore.ps1"

# Check that all files exist
for f in "$MENU_SH_SRC" "$BACKUP_SH_SRC" "$RESTORE_SH_SRC" "$MENU_PS1_SRC" "$BACKUP_PS1_SRC" "$RESTORE_PS1_SRC"; do
    if [ ! -f "$f" ]; then
        echo "❌ Required script not found: $f"
        exit 1
    fi
done

# === Destination template ===
USB_TEMPLATE="$HOME/Plakar_USB_Template"
ZIP_FILE="$HOME/Plakar_USB_Template.zip"

# === Clean previous template ===
rm -rf "$USB_TEMPLATE"
mkdir -p "$USB_TEMPLATE"

# === Create folder structure ===
mkdir -p "$USB_TEMPLATE/plakar_repo"
mkdir -p "$USB_TEMPLATE/logs"
mkdir -p "$USB_TEMPLATE/custom_folders"

# === Copy working scripts ===
cp "$MENU_SH_SRC" "$USB_TEMPLATE/menu.sh"
cp "$BACKUP_SH_SRC" "$USB_TEMPLATE/backup.sh"
cp "$RESTORE_SH_SRC" "$USB_TEMPLATE/restore.sh"
cp "$MENU_PS1_SRC" "$USB_TEMPLATE/menu.ps1"
cp "$BACKUP_PS1_SRC" "$USB_TEMPLATE/backup.ps1"
cp "$RESTORE_PS1_SRC" "$USB_TEMPLATE/restore.ps1"

# Make macOS/Linux scripts executable
chmod +x "$USB_TEMPLATE/menu.sh" "$USB_TEMPLATE/backup.sh" "$USB_TEMPLATE/restore.sh"

# === Create placeholder keyfile ===
KEYFILE="$USB_TEMPLATE/.plakar_key"
echo "CHANGE_THIS_PASSPHRASE" > "$KEYFILE"
chmod 600 "$KEYFILE"

# === Create README ===
cat > "$USB_TEMPLATE/README.txt" <<EOL
Plakar Technician USB Template (Cross-Platform)

- Place plakar.exe (Windows) and plakar (macOS/Linux) in the root
- Use menu.ps1 on Windows or menu.sh on macOS/Linux
- plakar_repo will be used/created automatically inside this USB folder
- Logs are stored in the logs/ folder
- Optional .plakar_key stores your repository passphrase
  (edit this file and replace 'CHANGE_THIS_PASSPHRASE' with your real passphrase)
EOL

# === Create ZIP archive ===
rm -f "$ZIP_FILE"
zip -r "$ZIP_FILE" "$USB_TEMPLATE" >/dev/null

echo "✅ Cross-platform USB template with working scripts created: $ZIP_FILE"
