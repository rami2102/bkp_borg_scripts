#!/usr/bin/env bash
# common.sh — Shared functions for borg backup scripts.
# Source this file, do not execute it directly.
# NOTE: Each calling script sets its own shell options (set -euo pipefail etc.)
# before sourcing this file. We do NOT set shell options here because some
# scripts (backup.sh) intentionally omit -e to handle borg exit codes manually.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Load .env ──────────────────────────────────────────────
load_env() {
    local env_file="${SCRIPT_DIR}/.env"
    if [[ ! -f "$env_file" ]]; then
        echo "ERROR: .env file not found at ${env_file}" >&2
        echo "Copy .env.example to .env and configure it." >&2
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$env_file"

    # Recompute BORG_REPO if not explicitly overridden in .env
    export BORG_REPO="${BORG_REPO:-ssh://${STORAGE_BOX_USER}@${STORAGE_BOX_HOST}:${STORAGE_BOX_PORT}/./backups}"
    export BORG_PASSPHRASE="${BORG_PASSPHRASE}"

    # Defaults
    RETENTION_DAYS="${RETENTION_DAYS:-7}"
    RETENTION_MAX_GB="${RETENTION_MAX_GB:-100}"
    SPACE_SAFETY_MULTIPLIER="${SPACE_SAFETY_MULTIPLIER:-3}"
    LOG_FILE="${LOG_FILE:-$HOME/.local/log/borg_backup.log}"
    BORG_COMPRESSION="${BORG_COMPRESSION:-zstd,3}"
    BACKUP_PATHS="${BACKUP_PATHS:-/}"
    BACKUP_EXCLUDE="${BACKUP_EXCLUDE:-/dev /proc /sys /tmp /run /mnt /media /swapfile /lost+found /var/cache /var/tmp}"
    STORAGE_BOX_SIZE_GB="${STORAGE_BOX_SIZE_GB:-1000}"
    MAILTO="${MAILTO:-}"
}

# ── Logging ────────────────────────────────────────────────
setup_logging() {
    local log_dir
    log_dir="$(dirname "$LOG_FILE")"
    mkdir -p "$log_dir"
}

log_info() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*"
    echo "$msg" | tee -a "$LOG_FILE"
}

log_error() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*"
    echo "$msg" | tee -a "$LOG_FILE" >&2
}

# ── Error trap for cron ────────────────────────────────────
on_error() {
    local exit_code=$?
    log_error "Script failed with exit code ${exit_code}"
    log_error "Check log at ${LOG_FILE}"
    exit "$exit_code"
}

enable_error_trap() {
    trap on_error ERR
}

# ── Space check ────────────────────────────────────────────
# Gets the total size of the borg repo in bytes
get_repo_size_bytes() {
    borg info --json "$BORG_REPO" 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['cache']['stats']['unique_csize'])" \
        2>/dev/null || echo "0"
}

# Gets the size of the last archive in bytes
get_last_archive_size_bytes() {
    local last_archive
    last_archive="$(borg list --json "$BORG_REPO" 2>/dev/null \
        | python3 -c "
import sys, json
data = json.load(sys.stdin)
archives = data.get('archives', [])
if archives:
    print(archives[-1]['name'])
" 2>/dev/null || true)"

    if [[ -z "$last_archive" ]]; then
        echo "0"
        return
    fi

    borg info --json "${BORG_REPO}::${last_archive}" 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['archives'][0]['stats']['deduplicated_size'])" \
        2>/dev/null || echo "0"
}

# Checks that there is enough space for a new backup.
# Warns if repo exceeds RETENTION_MAX_GB or if free space < SPACE_SAFETY_MULTIPLIER * last backup size.
check_space() {
    local repo_size_bytes last_size_bytes max_bytes needed_bytes
    repo_size_bytes="$(get_repo_size_bytes)"
    last_size_bytes="$(get_last_archive_size_bytes)"

    max_bytes=$(( RETENTION_MAX_GB * 1024 * 1024 * 1024 ))
    needed_bytes=$(( last_size_bytes * SPACE_SAFETY_MULTIPLIER ))

    local storage_box_total_bytes=$(( STORAGE_BOX_SIZE_GB * 1024 * 1024 * 1024 ))
    local free_bytes=$(( storage_box_total_bytes - repo_size_bytes ))

    if (( repo_size_bytes > max_bytes )); then
        log_error "WARNING: Repo size ($(( repo_size_bytes / 1024 / 1024 / 1024 ))GB) exceeds retention limit (${RETENTION_MAX_GB}GB)"
    fi

    if (( last_size_bytes > 0 && free_bytes < needed_bytes )); then
        log_error "WARNING: Free space ($(( free_bytes / 1024 / 1024 / 1024 ))GB) is less than ${SPACE_SAFETY_MULTIPLIER}x last backup size ($(( last_size_bytes / 1024 / 1024 ))MB)"
        log_error "Backup may fail due to insufficient space. Consider pruning or increasing storage."
        return 1
    fi

    log_info "Space check passed: repo=$(( repo_size_bytes / 1024 / 1024 ))MB, free=$(( free_bytes / 1024 / 1024 / 1024 ))GB"
    return 0
}
