#!/usr/bin/env bash
# install.sh — Install BorgBackup and dependencies.
# Must be run as root (or with sudo).
#
# Two install modes:
#   sudo ./install.sh           — install via package manager (may be a Python wrapper)
#   sudo ./install.sh standalone — install standalone binary (recommended for setcap)

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (or with sudo)." >&2
    echo "Usage: sudo ./install.sh [standalone]" >&2
    exit 1
fi

MODE="${1:-}"

echo "=== Borg Backup Installation ==="

# ── Standalone binary install ─────────────────────────────
install_standalone() {
    echo "Installing standalone borg binary..."
    echo ""

    # Detect architecture
    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64)  ARCH_SUFFIX="x86_64" ;;
        aarch64) ARCH_SUFFIX="arm64" ;;
        *)
            echo "ERROR: Unsupported architecture: ${ARCH}" >&2
            echo "Use package manager install instead: sudo ./install.sh" >&2
            exit 1
            ;;
    esac

    # Ensure dependencies
    if command -v apt-get &>/dev/null; then
        apt-get update -qq
        apt-get install -y -qq python3 openssh-client curl libacl1 2>/dev/null
    elif command -v dnf &>/dev/null; then
        dnf install -y -q python3 openssh-clients curl libacl 2>/dev/null
    fi

    # Fetch latest release tag from GitHub API
    echo "Fetching latest borg release..."
    if command -v curl &>/dev/null; then
        LATEST_TAG="$(curl -s https://api.github.com/repos/borgbackup/borg/releases/latest | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])")"
    else
        echo "ERROR: curl is required for standalone install." >&2
        exit 1
    fi
    echo "Latest release: ${LATEST_TAG}"

    # Download binary
    DOWNLOAD_URL="https://github.com/borgbackup/borg/releases/download/${LATEST_TAG}/borg-linux-glibc235-${ARCH_SUFFIX}-gh"
    BORG_DEST="/usr/local/bin/borg"

    echo "Downloading from: ${DOWNLOAD_URL}"
    curl -L -o "$BORG_DEST" "$DOWNLOAD_URL"
    chmod 755 "$BORG_DEST"

    # Verify it's a real binary (not a Python script)
    if head -c2 "$BORG_DEST" | grep -q '^#!'; then
        echo "WARNING: Downloaded file appears to be a script, not a binary." >&2
        echo "Check the download URL and try again." >&2
        exit 1
    fi

    echo "Installed standalone binary to ${BORG_DEST}"
}

# ── Package manager install ───────────────────────────────
install_package() {
    if command -v apt-get &>/dev/null; then
        echo "Detected Debian/Ubuntu..."
        apt-get update
        apt-get install -y borgbackup python3 openssh-client
    elif command -v dnf &>/dev/null; then
        echo "Detected Fedora/RHEL..."
        dnf install -y borgbackup python3 openssh-clients
    elif command -v pacman &>/dev/null; then
        echo "Detected Arch..."
        pacman -Sy --noconfirm borg python openssh
    else
        echo "ERROR: Unsupported package manager. Use standalone install:" >&2
        echo "  sudo ./install.sh standalone" >&2
        exit 1
    fi
}

# ── Run install ───────────────────────────────────────────
if [[ "$MODE" == "standalone" ]]; then
    install_standalone
else
    install_package
fi

# ── Verify installation ───────────────────────────────────
if command -v borg &>/dev/null; then
    BORG_PATH="$(readlink -f "$(command -v borg)")"
    echo ""
    echo "BorgBackup installed successfully!"
    borg --version
    echo "Binary: ${BORG_PATH}"

    # Check if it's a script wrapper and warn
    if head -c2 "$BORG_PATH" 2>/dev/null | grep -q '^#!'; then
        echo ""
        echo "NOTE: This is a Python script wrapper. If you plan to use"
        echo "setup_permissions.sh for full system backup, reinstall as standalone:"
        echo "  sudo ./install.sh standalone"
    fi

    echo ""
    echo "Next steps:"
    echo "  1. sudo ./setup_permissions.sh  — grant borg read access to all files (optional but recommended)"
    echo "  2. Copy .env.example to .env and configure it"
    echo "  3. Run ./setup_cron.sh as a non-root user to initialize the repo and schedule backups"
else
    echo "ERROR: borg command not found after installation." >&2
    exit 1
fi
