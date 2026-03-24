#!/usr/bin/env bash
# setup_permissions.sh — Grant borg read-only access to all files.
# Must be run as root (or with sudo).
#
# Uses Linux capabilities to give the borg binary CAP_DAC_READ_SEARCH,
# which allows it to read any file on the system without write or execute.
# This is the minimal privilege needed for a full system backup.
#
# NOTE: Package updates may strip the capability. Re-run this script
# after upgrading borgbackup.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (or with sudo)." >&2
    echo "Usage: sudo ./setup_permissions.sh" >&2
    exit 1
fi

echo "=== Borg Backup Permissions Setup ==="

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

# ── Verify ─────────────────────────────────────────────────
CAPS="$(getcap "$TARGET_BIN")"
if echo "$CAPS" | grep -q "cap_dac_read_search"; then
    echo ""
    echo "Success! Capability set:"
    echo "  ${CAPS}"
    echo ""
    echo "Borg can now read all files on the system without root."
    echo "No write or execute permissions were granted."
    echo ""
    echo "NOTE: Re-run this script after upgrading borgbackup (apt upgrade"
    echo "may strip capabilities from the binary)."
else
    echo "ERROR: Failed to set capability." >&2
    echo "Verify that your filesystem supports extended attributes." >&2
    exit 1
fi
