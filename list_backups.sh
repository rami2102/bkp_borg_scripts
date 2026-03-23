#!/usr/bin/env bash
# list_backups.sh — List all borg backup archives.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
load_env

export BORG_RSH="ssh -p ${STORAGE_BOX_PORT} -i ${SSH_KEY_PATH} -o BatchMode=yes -o ServerAliveInterval=60 -o ServerAliveCountMax=3"

echo "=== Backup Archives ==="
echo ""

# ── List all archives with details ─────────────────────────
borg list --format '{archive:<40} {time} {username:<10} {NEWLINE}' "$BORG_REPO"

echo ""
echo "=== Repository Info ==="
borg info "$BORG_REPO"

echo ""
echo "To see files in a specific archive:"
echo "  borg list ${BORG_REPO}::<archive-name>"
echo ""
echo "To restore from an archive:"
echo "  ./restore.sh <archive-name> [target-directory]"
