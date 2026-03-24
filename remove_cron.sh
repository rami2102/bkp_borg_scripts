#!/usr/bin/env bash
# remove_cron.sh — Remove the borg backup cron job.
# Run as the user whose crontab contains the backup job.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $EUID -eq 0 ]]; then
    echo "ERROR: Do not run this script as root." >&2
    echo "Run as the user whose crontab you want to clean." >&2
    exit 1
fi

# Show current crontab
CURRENT="$(crontab -l 2>/dev/null || true)"
if [[ -z "$CURRENT" ]]; then
    echo "No crontab found for $(whoami)."
    exit 0
fi

MATCH="${SCRIPT_DIR}/backup.sh"
if ! echo "$CURRENT" | grep -q "$MATCH"; then
    echo "No borg backup cron job found for $(whoami)."
    echo "Current crontab:"
    echo "$CURRENT"
    exit 0
fi

echo "Found borg backup cron entry:"
echo "$CURRENT" | grep "$MATCH"
echo ""

# Remove the backup.sh line and orphaned MAILTO if no other jobs remain
NEW_CRONTAB="$(echo "$CURRENT" | grep -v "$MATCH")"

# If only MAILTO= lines remain (no actual jobs), clear entirely
JOBS_LEFT="$(echo "$NEW_CRONTAB" | grep -v "^MAILTO=" | grep -v "^[[:space:]]*$" || true)"
if [[ -z "$JOBS_LEFT" ]]; then
    crontab -r 2>/dev/null || true
    echo "Cron job removed. Crontab is now empty."
else
    echo "$NEW_CRONTAB" | crontab -
    echo "Cron job removed. Remaining crontab:"
    crontab -l
fi
