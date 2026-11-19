#!/bin/bash
# Launch the reduced macOS web UI. Python 3 standard library only; nothing installed
# beyond what Git on macOS already needs (Command Line Tools).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1
if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 not found. Install the macOS Command Line Tools or Homebrew Python 3." >&2
    exit 1
fi
exec python3 "$SCRIPT_DIR/webui_mac.py" "$@"
