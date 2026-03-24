#!/usr/bin/env bash
# install.sh — Install BorgBackup and dependencies.
# Must be run as root (or with sudo).

set -euo pipefail

# ── Root check ─────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (or with sudo)." >&2
    echo "Usage: sudo ./install.sh" >&2
    exit 1
fi

echo "=== Borg Backup Installation ==="

# ── Detect package manager ─────────────────────────────────
install_borg() {
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
        echo "ERROR: Unsupported package manager. Install borgbackup manually:" >&2
        echo "  https://borgbackup.readthedocs.io/en/stable/installation.html" >&2
        exit 1
    fi
}

install_borg

# ── Verify installation ───────────────────────────────────
if command -v borg &>/dev/null; then
    echo ""
    echo "BorgBackup installed successfully!"
    borg --version
    echo ""
    echo "Next steps:"
    echo "  1. sudo ./setup_permissions.sh  — grant borg read access to all files (optional but recommended)"
    echo "  2. Copy .env.example to .env and configure it"
    echo "  3. Run ./setup_cron.sh as a non-root user to initialize the repo and schedule backups"
else
    echo "ERROR: borg command not found after installation." >&2
    exit 1
fi
