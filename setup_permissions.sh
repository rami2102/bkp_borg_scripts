#!/usr/bin/env bash
# setup_permissions.sh — Grant borg read-only access to all files.
# Must be run as root (or with sudo).
#
# Uses Linux capabilities to give the borg binary CAP_DAC_READ_SEARCH,
# which allows it to read any file on the system without write or execute.
# This is the minimal privilege needed for a full system backup.
#
# Also installs a sudoers rule so the backup user can re-apply the
# capability automatically (e.g. after apt upgrades strip it).
# This means backup.sh in cron is fully automatic — no manual re-run needed.

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
    # Verify user exists
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

# Resolve symlinks to get the real binary
BORG_BIN="$(readlink -f "$BORG_BIN")"
echo "Borg binary: ${BORG_BIN}"

# ── Check if it's a script wrapper ─────────────────────────
# Some distros install borg as a Python script; capabilities only work on ELF binaries.
# In that case we need to set the capability on the Python interpreter instead.
FILE_TYPE="$(file -b "$BORG_BIN")"
if [[ "$FILE_TYPE" == *"script"* || "$FILE_TYPE" == *"text"* ]]; then
    # It's a script — find the interpreter
    INTERPRETER="$(head -1 "$BORG_BIN" | sed 's/^#!//' | awk '{print $1}')"
    INTERPRETER="$(readlink -f "$INTERPRETER")"
    echo "Borg is a script wrapper. Setting capability on interpreter: ${INTERPRETER}"
    echo ""
    echo "WARNING: Setting CAP_DAC_READ_SEARCH on ${INTERPRETER} means ALL scripts"
    echo "using this interpreter will have read access to all files."
    echo "This is less secure than setting it on a standalone borg binary."
    echo ""
    read -rp "Continue? (y/N) " confirm
    if [[ "$confirm" != [yY] ]]; then
        echo "Aborted."
        echo ""
        echo "Alternative: Install borg as a standalone binary instead:"
        echo "  pip install --user borgbackup"
        echo "  or download from https://github.com/borgbackup/borg/releases"
        exit 1
    fi
    TARGET_BIN="$INTERPRETER"
else
    TARGET_BIN="$BORG_BIN"
fi

# ── Set capability ─────────────────────────────────────────
echo "Setting CAP_DAC_READ_SEARCH on ${TARGET_BIN}..."
setcap cap_dac_read_search+ep "$TARGET_BIN"

# ── Verify capability ─────────────────────────────────────
CAPS="$(getcap "$TARGET_BIN")"
if ! echo "$CAPS" | grep -q "cap_dac_read_search"; then
    echo "ERROR: Failed to set capability." >&2
    echo "Verify that your filesystem supports extended attributes." >&2
    exit 1
fi

echo "Capability set: ${CAPS}"

# ── Install sudoers rule ──────────────────────────────────
# Allows the backup user to run ONLY this specific setcap command
# without a password. This lets backup.sh re-apply the capability
# automatically before each backup (survives apt upgrades).
SUDOERS_FILE="/etc/sudoers.d/borg-backup-setcap"
SETCAP_BIN="$(command -v setcap)"
SUDOERS_LINE="${BACKUP_USER} ALL=(root) NOPASSWD: ${SETCAP_BIN} cap_dac_read_search+ep ${TARGET_BIN}"

echo ""
echo "Installing sudoers rule for automatic capability restore..."
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

# ── Save target binary path for backup.sh ─────────────────
# Write the resolved path so backup.sh doesn't need to re-detect
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAPS_FILE="${SCRIPT_DIR}/.borg_cap_target"
echo "$TARGET_BIN" > "$CAPS_FILE"
chown "${BACKUP_USER}:" "$CAPS_FILE"
echo "Target binary path saved to: ${CAPS_FILE}"

echo ""
echo "=== Setup Complete ==="
echo ""
echo "  Borg can now read all files without root."
echo "  backup.sh will re-apply the capability automatically before each run."
echo "  No manual intervention needed after apt upgrades."
