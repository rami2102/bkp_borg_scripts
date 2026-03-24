#!/usr/bin/env bash
# setup_permissions.sh — Allow backup user to run borg as root (for full system backup).
# Must be run as root (or with sudo).
#
# Installs a sudoers rule that lets the backup user run ONLY /usr/bin/borg
# as root without a password. This allows backup.sh (running via cron as a
# non-root user) to read all files on the system.
#
# Run once. Survives apt upgrades — no re-run needed.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (or with sudo)." >&2
    echo "Usage: sudo ./setup_permissions.sh [backup-username]" >&2
    echo "  backup-username: the non-root user who runs backups (default: \$SUDO_USER)" >&2
    exit 1
fi

BACKUP_USER="${1:-${SUDO_USER:-}}"
if [[ -z "$BACKUP_USER" ]]; then
    echo "Cannot detect backup user (running as root directly)."
    read -rp "Enter the non-root username who will run backups: " BACKUP_USER
    if [[ -z "$BACKUP_USER" ]]; then
        echo "ERROR: Username is required." >&2
        exit 1
    fi
    if ! id "$BACKUP_USER" &>/dev/null; then
        echo "ERROR: User '${BACKUP_USER}' does not exist." >&2
        exit 1
    fi
fi

echo "=== Borg Backup Permissions Setup ==="
echo "Backup user: ${BACKUP_USER}"

# ── Find borg binary ──────────────────────────────────────
BORG_BIN="$(command -v borg 2>/dev/null || true)"
if [[ -z "$BORG_BIN" ]]; then
    echo "ERROR: borg not found. Run ./install.sh first." >&2
    exit 1
fi

BORG_BIN="$(readlink -f "$BORG_BIN")"
echo "Borg binary: ${BORG_BIN}"

# ── Install sudoers rule ──────────────────────────────────
# NOPASSWD: no password prompt (works in cron)
# SETENV: allows passing BORG_PASSPHRASE, BORG_REPO, BORG_RSH through sudo
SUDOERS_FILE="/etc/sudoers.d/borg-backup"
SUDOERS_LINE="${BACKUP_USER} ALL=(root) NOPASSWD:SETENV: ${BORG_BIN}"

echo ""
echo "Installing sudoers rule..."
echo "$SUDOERS_LINE" > "$SUDOERS_FILE"
chmod 0440 "$SUDOERS_FILE"

# Validate sudoers syntax
if visudo -c -f "$SUDOERS_FILE" &>/dev/null; then
    echo "Sudoers rule installed: ${SUDOERS_FILE}"
    echo "  ${SUDOERS_LINE}"
else
    echo "ERROR: Invalid sudoers syntax. Removing file." >&2
    rm -f "$SUDOERS_FILE"
    exit 1
fi

# ── Verify it works ───────────────────────────────────────
echo ""
echo "=== Setup Complete ==="
echo ""
echo "  User '${BACKUP_USER}' can now run borg as root without a password."
echo "  backup.sh will use 'sudo -E borg create ...' to read all files."
echo "  This survives apt upgrades — no re-run needed."
echo ""
echo "  What this allows:"
echo "    sudo -E borg create ...   (read all files for backup)"
echo "    sudo -E borg prune ...    (prune old archives)"
echo "    sudo -E borg compact ...  (reclaim space)"
echo ""
echo "  What this does NOT allow:"
echo "    Any other command as root"
