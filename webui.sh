#!/bin/bash
# Launch the reduced macOS/Linux web UI. Python 3 standard library only; nothing
# installed beyond what Git on macOS already needs (Command Line Tools).
#
# Every start reports the plakar version in use and the latest release, and updates
# the binary when it is behind. The build is chosen from `uname -s`/`uname -m`
# (Darwin/Linux x86_64/arm64) from the latest PlakarKorp/plakar release, verified
# against that release's SHA-256 checksums, and installed as ./plakar next to these
# scripts - the layout the README asks for and what sync_tools.ps1 syncs between
# drives. `/plakar` is gitignored; a replaced binary is kept in `_known_good/`.
# A plakar that comes from PATH (for example Homebrew) is never overwritten: the
# local copy simply takes precedence.
#
#   ./webui.sh                  report versions, update automatically when behind
#   ./webui.sh --update-plakar  install the latest release now, even if not behind
#   ./webui.sh --no-update      report only, never fetch anything
#   ./webui.sh --no-download    never fetch: if nothing is installed, say so and exit
#   ./webui.sh --install-plakar fetch the first binary without asking
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" 2>/dev/null)" && pwd)"
cd "$SCRIPT_DIR" || exit 1

UPDATE_MODE="auto"
FETCH_MODE="ask"
FORWARD=()
CHECK_LATEST=""
for arg in "$@"; do
    case "$arg" in
        --update-plakar)  UPDATE_MODE="force" ;;
        --install-plakar) UPDATE_MODE="force"; FETCH_MODE="auto" ;;
        --no-update|--check-plakar) UPDATE_MODE="off"; FETCH_MODE="off" ;;
        --no-download)    UPDATE_MODE="off"; FETCH_MODE="off" ;;
        *)                FORWARD+=("$arg") ;;
    esac
done

if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 not found. Install the macOS Command Line Tools or Homebrew Python 3." >&2
    exit 1
fi

# Same lookup order as webui_mac.py: the binary next to the script wins.
find_plakar() {
    if [ -x "$SCRIPT_DIR/plakar" ]; then
        echo "$SCRIPT_DIR/plakar"
        return 0
    fi
    command -v plakar 2>/dev/null
}

source_of() {
    if [ "$1" = "$SCRIPT_DIR/plakar" ]; then
        echo "next to the scripts"
    else
        echo "from PATH, not touched by this template"
    fi
}

# Release asset naming is plakar_<ver>_<os>_<arch>.tar.gz.
os_name() {
    case "$(uname -s)" in
        Darwin) echo darwin ;;
        Linux)  echo linux ;;
        *)      echo "" ;;
    esac
}

arch_name() {
    case "$(uname -m)" in
        x86_64|amd64)   echo amd64 ;;
        arm64|aarch64)  echo arm64 ;;
        *)              echo "" ;;
    esac
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
    else return 1; fi
}

latest_tag() {
    curl -fsSL -m 20 -H 'User-Agent: webui.sh' \
        'https://api.github.com/repos/PlakarKorp/plakar/releases/latest' \
        2>/dev/null | sed -n 's/.*"tag_name"[ ]*:[ ]*"\([^"]*\)".*/\1/p' | head -n 1
}

tool_version() {
    "$1" version 2>/dev/null | head -n 1 | grep -oE 'v[0-9]+(\.[0-9]+)*' | head -n 1
}

# True when $1 is strictly older than $2.
is_older() {
    [ -n "$1" ] && [ "$1" != "$2" ] && \
        [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" = "$1" ]
}

install_plakar() {
    local os arch tag ver asset url tmp bin want got kept
    os="$(os_name)"
    arch="$(arch_name)"
    if [ -z "$os" ] || [ -z "$arch" ]; then
        echo "ERROR: no plakar release for $(uname -s) $(uname -m). Copy a binary into $SCRIPT_DIR yourself." >&2
        return 1
    fi
    if ! command -v curl >/dev/null 2>&1; then
        echo "ERROR: curl not found, so the binary cannot be downloaded." >&2
        return 1
    fi
    tag="$(latest_tag)"
    if [ -z "$tag" ]; then
        echo "ERROR: could not read the latest release from GitHub. Check the network, or copy a plakar binary into $SCRIPT_DIR." >&2
        return 1
    fi
    ver="${tag#v}"
    asset="plakar_${ver}_${os}_${arch}.tar.gz"
    url="https://github.com/PlakarKorp/plakar/releases/download/${tag}/${asset}"

    tmp="$(mktemp -d)" || { echo "ERROR: cannot create a temporary directory." >&2; return 1; }
    echo "Downloading $asset ..."
    if ! curl -fsSL -m 300 -o "$tmp/$asset" "$url"; then
        echo "ERROR: download failed: $url" >&2
        rm -rf "$tmp"
        return 1
    fi
    if ! curl -fsSL -m 30 -o "$tmp/checksums.txt" \
        "https://github.com/PlakarKorp/plakar/releases/download/${tag}/plakar_${ver}_checksums.txt"; then
        echo "ERROR: the checksums file could not be fetched; refusing to install an unverified binary." >&2
        rm -rf "$tmp"
        return 1
    fi
    want="$(awk -v a="$asset" '$2 == a {print $1}' "$tmp/checksums.txt")"
    got="$(sha256_of "$tmp/$asset")" || { rm -rf "$tmp"; return 1; }
    if [ -z "$want" ] || [ "$want" != "$got" ]; then
        echo "ERROR: SHA-256 mismatch for $asset (expected ${want:-not listed}, got ${got:-none}). Nothing was installed." >&2
        rm -rf "$tmp"
        return 1
    fi
    if ! tar -xzf "$tmp/$asset" -C "$tmp"; then
        echo "ERROR: could not unpack $asset." >&2
        rm -rf "$tmp"
        return 1
    fi
    bin="$(find "$tmp" -type f -name plakar | head -n 1)"
    if [ -z "$bin" ]; then
        echo "ERROR: no plakar binary inside $asset." >&2
        rm -rf "$tmp"
        return 1
    fi
    # The same convention sync_tools.ps1 uses on a drive: the copy that was here
    # before this install is one file deep in _known_good, so a bad install is undone.
    if [ -f "$SCRIPT_DIR/plakar" ]; then
        mkdir -p "$SCRIPT_DIR/_known_good"
        cp -p "$SCRIPT_DIR/plakar" "$SCRIPT_DIR/_known_good/plakar" && \
            kept="$SCRIPT_DIR/_known_good/plakar"
    fi
    mv "$bin" "$SCRIPT_DIR/plakar" || { rm -rf "$tmp"; return 1; }
    chmod 755 "$SCRIPT_DIR/plakar"
    # curl does not set the quarantine flag, but a file that arrived another way must run.
    command -v xattr >/dev/null 2>&1 && xattr -d com.apple.quarantine "$SCRIPT_DIR/plakar" 2>/dev/null
    rm -rf "$tmp"
    echo "Installed $SCRIPT_DIR/plakar ($(tool_version "$SCRIPT_DIR/plakar"))"
    [ -n "$kept" ] && echo "Previous copy kept in $kept"
    return 0
}

exe="$(find_plakar)"
cur=""
[ -n "$exe" ] && cur="$(tool_version "$exe")"
tag=""
asked=""
if [ "$UPDATE_MODE" != "off" ] || [ -z "$exe" ]; then
    asked=1
    tag="$(latest_tag)"
fi

not_checked() {
    if [ -n "$asked" ]; then
        echo "WARNING: GitHub not reachable, the latest release could not be read." >&2
    else
        echo "Latest release: not checked (--no-update/--no-download fetch nothing)."
    fi
}

if [ -z "$exe" ]; then
    echo "plakar: not present (looked for $SCRIPT_DIR/plakar, then plakar in PATH)."
    if [ -n "$tag" ]; then echo "Latest release: $tag ($(uname -s) $(uname -m) build)."; else not_checked; fi
elif [ -z "$cur" ]; then
    echo "plakar at $exe ($(source_of "$exe")); its version could not be read."
    if [ -n "$tag" ]; then echo "Latest release: $tag."; else not_checked; fi
else
    echo "plakar $cur at $exe ($(source_of "$exe"))."
    if [ -z "$tag" ]; then
        not_checked
    elif is_older "$cur" "$tag"; then
        echo "Latest release: $tag - behind."
    else
        echo "Latest release: $tag - up to date."
    fi
fi

if [ -z "$exe" ]; then
    case "$FETCH_MODE" in
        off)
            echo "ERROR: no plakar binary, and --no-download forbids fetching one." >&2
            echo "Copy a plakar binary into $SCRIPT_DIR, or run ./webui.sh without --no-download to fetch the build for $(uname -s) $(uname -m)." >&2
            exit 1
            ;;
        auto)
            install_plakar || exit 1
            ;;
        ask)
            printf 'Download the %s %s build from the latest Plakar release into %s? [y/N] ' "$(uname -s)" "$(uname -m)" "$SCRIPT_DIR"
            read -r reply
            case "$reply" in
                [Yy]*) install_plakar || exit 1 ;;
                *)
                    echo "Not downloaded. Copy a plakar binary into $SCRIPT_DIR and run ./webui.sh again." >&2
                    exit 1
                    ;;
            esac
            ;;
    esac
elif [ "$UPDATE_MODE" = "force" ]; then
    install_plakar || exit 1
elif [ "$UPDATE_MODE" = "auto" ] && [ -n "$tag" ] && is_older "$cur" "$tag"; then
    echo "Updating plakar $cur -> $tag ..."
    install_plakar || echo "WARNING: update failed; starting with the version already present." >&2
fi

exec python3 "$SCRIPT_DIR/webui_mac.py" "${FORWARD[@]}"
