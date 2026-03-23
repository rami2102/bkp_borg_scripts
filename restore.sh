#!/usr/bin/env bash
# restore.sh — Restore files from a borg backup archive.
# Usage: ./restore.sh <archive-name> [target-directory] [path-to-extract]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
load_env

export BORG_RSH="ssh -p ${STORAGE_BOX_PORT} -i ${SSH_KEY_PATH} -o BatchMode=yes -o ServerAliveInterval=60 -o ServerAliveCountMax=3"

# ── Usage ──────────────────────────────────────────────────
usage() {
    echo "Usage: $0 <archive-name> [target-directory] [path-to-extract]"
    echo ""
    echo "Arguments:"
    echo "  archive-name      Name of the archive to restore from (required)"
    echo "  target-directory   Where to extract files (default: ./borg-restore-<timestamp>)"
    echo "  path-to-extract    Specific path within the archive (default: everything)"
    echo ""
    echo "Examples:"
    echo "  $0 myhost-2026-03-24_02-00-00"
    echo "  $0 myhost-2026-03-24_02-00-00 /tmp/restore"
    echo "  $0 myhost-2026-03-24_02-00-00 /tmp/restore home/user/documents"
    echo ""
    echo "Available archives:"
    borg list --format '{archive:<40} {time}{NEWLINE}' "$BORG_REPO"
    exit 1
}

if [[ $# -lt 1 ]]; then
    usage
fi

ARCHIVE_NAME="$1"
TARGET_DIR="${2:-./borg-restore-$(date +%Y%m%d_%H%M%S)}"
EXTRACT_PATH="${3:-}"

# ── Verify archive exists ─────────────────────────────────
if ! borg list "${BORG_REPO}::${ARCHIVE_NAME}" &>/dev/null; then
    echo "ERROR: Archive '${ARCHIVE_NAME}' not found." >&2
    echo ""
    echo "Available archives:"
    borg list --format '{archive:<40} {time}{NEWLINE}' "$BORG_REPO"
    exit 1
fi

# ── Show archive info ─────────────────────────────────────
echo "=== Archive Info ==="
borg info "${BORG_REPO}::${ARCHIVE_NAME}"
echo ""

# ── Confirm restore ───────────────────────────────────────
echo "Will restore to: ${TARGET_DIR}"
if [[ -n "$EXTRACT_PATH" ]]; then
    echo "Extracting only: ${EXTRACT_PATH}"
fi
echo ""
read -rp "Continue? (y/N) " confirm
if [[ "$confirm" != [yY] ]]; then
    echo "Restore cancelled."
    exit 0
fi

# ── Create target and restore ─────────────────────────────
mkdir -p "$TARGET_DIR"
cd "$TARGET_DIR"

echo "Restoring..."
if [[ -n "$EXTRACT_PATH" ]]; then
    borg extract --stats "${BORG_REPO}::${ARCHIVE_NAME}" "$EXTRACT_PATH"
else
    borg extract --stats "${BORG_REPO}::${ARCHIVE_NAME}"
fi

echo ""
echo "Restore complete! Files extracted to: ${TARGET_DIR}"
echo ""
echo "NOTE: If restoring system files, you may need to copy them to their"
echo "original locations with appropriate permissions. Use rsync:"
echo "  sudo rsync -aAX ${TARGET_DIR}/ /"
