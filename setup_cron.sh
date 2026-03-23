#!/usr/bin/env bash
# setup_cron.sh — Initialize borg repo on remote and install cron job.
# Run as a non-root user.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
load_env
setup_logging

# ── Refuse to run as root ──────────────────────────────────
if [[ $EUID -eq 0 ]]; then
    echo "ERROR: Do not run this script as root." >&2
    echo "Run as the user whose cron will execute backups." >&2
    exit 1
fi

echo "=== Borg Backup Setup ==="

# ── SSH key check ──────────────────────────────────────────
if [[ ! -f "$SSH_KEY_PATH" ]]; then
    echo "SSH key not found at ${SSH_KEY_PATH}."
    echo "Generating a new ed25519 key..."
    ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N "" -C "borg-backup-$(hostname)"
    echo ""
    echo "Public key (add this to your Hetzner Storage Box authorized_keys):"
    cat "${SSH_KEY_PATH}.pub"
    echo ""
    echo "To install on the storage box, run:"
    echo "  ssh-copy-id -p ${STORAGE_BOX_PORT} -i ${SSH_KEY_PATH}.pub ${STORAGE_BOX_USER}@${STORAGE_BOX_HOST}"
    echo ""
    read -rp "Press Enter after you've added the key to continue..."
fi

# ── Configure SSH for borg ─────────────────────────────────
export BORG_RSH="ssh -p ${STORAGE_BOX_PORT} -i ${SSH_KEY_PATH} -o BatchMode=yes -o ServerAliveInterval=60 -o ServerAliveCountMax=3"

# ── Test connection via borg ───────────────────────────────
# Note: Hetzner Storage Boxes don't provide a full shell, so we test
# via borg commands rather than raw SSH. If repo doesn't exist yet,
# a connection error will surface during borg init below.
echo "Testing connection to storage box..."

# ── Initialize borg repo ──────────────────────────────────
echo "Initializing borg repository at ${BORG_REPO}..."
if borg info "$BORG_REPO" &>/dev/null; then
    echo "Repository already exists. Skipping init."
else
    borg init --encryption="${BORG_ENCRYPTION}" "$BORG_REPO"
    echo "Repository initialized successfully."
    echo ""
    echo "IMPORTANT: Back up your borg encryption key!"
    echo "Run: borg key export ${BORG_REPO} ~/borg-key-backup.txt"
    echo "Store this key file safely — you cannot restore without it."
fi

# ── Install cron job ───────────────────────────────────────
# backup.sh handles its own logging internally via common.sh.
# Cron captures any stdout/stderr and emails it via MAILTO (if set).
CRON_SCHEDULE="0 2 * * *"  # Daily at 2:00 AM
CRON_CMD="${SCRIPT_DIR}/backup.sh"
CRON_LINE="${CRON_SCHEDULE} ${CRON_CMD}"

# Build crontab: set MAILTO if configured, remove old entry, add new
{
    if [[ -n "$MAILTO" ]]; then
        crontab -l 2>/dev/null | grep -v "^MAILTO=" | grep -v "${SCRIPT_DIR}/backup.sh" || true
        echo "MAILTO=${MAILTO}"
    else
        crontab -l 2>/dev/null | grep -v "${SCRIPT_DIR}/backup.sh" || true
    fi
    echo "$CRON_LINE"
} | crontab -

echo ""
echo "Cron job installed:"
echo "  ${CRON_LINE}"
if [[ -n "$MAILTO" ]]; then
    echo "  MAILTO=${MAILTO}"
else
    echo "  (No MAILTO set — configure in .env for email alerts on failure)"
fi
echo ""
echo "Setup complete! Backups will run daily at 2:00 AM."
echo "To run a backup now: ./backup.sh"
echo "To list backups: ./list_backups.sh"
