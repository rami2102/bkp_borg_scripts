#!/usr/bin/env bash
# backup.sh — Create a borg backup and prune old archives.
# Called by cron or run manually. Non-root.

# Note: we do NOT use set -e / pipefail here because borg returns exit code 1
# for warnings (e.g. permission denied on a file), which we handle gracefully.
# Instead we check exit codes manually after each borg command.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
load_env
setup_logging
enable_error_trap

# ── SSH config ─────────────────────────────────────────────
export BORG_RSH="ssh -p ${STORAGE_BOX_PORT} -i ${SSH_KEY_PATH} -o BatchMode=yes -o ServerAliveInterval=60 -o ServerAliveCountMax=3"

log_info "=== Starting backup ==="

# ── Re-apply read capability (survives apt upgrades) ──────
CAPS_FILE="${SCRIPT_DIR}/.borg_cap_target"
if [[ -f "$CAPS_FILE" ]]; then
    TARGET_BIN="$(cat "$CAPS_FILE")"
    if [[ -f "$TARGET_BIN" ]] && ! getcap "$TARGET_BIN" 2>/dev/null | grep -q "cap_dac_read_search"; then
        log_info "Re-applying CAP_DAC_READ_SEARCH on ${TARGET_BIN}..."
        if sudo setcap cap_dac_read_search+ep "$TARGET_BIN" 2>/dev/null; then
            log_info "Capability restored."
        else
            log_error "WARNING: Failed to restore capability. Some files may be unreadable."
        fi
    fi
fi

# ── Space check ────────────────────────────────────────────
if ! check_space; then
    log_error "Space check failed. Backup will attempt anyway but may fail."
fi

# ── Build archive name ─────────────────────────────────────
ARCHIVE_NAME="$(hostname)-$(date +%Y-%m-%d_%H-%M-%S)"

# ── Build exclude list ─────────────────────────────────────
EXCLUDE_ARGS=()
for path in $BACKUP_EXCLUDE; do
    EXCLUDE_ARGS+=("--exclude" "$path")
done

# ── Create backup ──────────────────────────────────────────
log_info "Creating archive: ${ARCHIVE_NAME}"

# Read BACKUP_PATHS into an array
read -ra BACKUP_PATHS_ARR <<< "$BACKUP_PATHS"

borg create \
    --stats \
    --show-rc \
    --compression "${BORG_COMPRESSION}" \
    "${EXCLUDE_ARGS[@]}" \
    --exclude-caches \
    --exclude '*.pyc' \
    --exclude '__pycache__' \
    "${BORG_REPO}::${ARCHIVE_NAME}" \
    "${BACKUP_PATHS_ARR[@]}" \
    2>&1 | tee -a "$LOG_FILE"

backup_rc=${PIPESTATUS[0]}

if [[ $backup_rc -eq 0 ]]; then
    log_info "Backup completed successfully."
elif [[ $backup_rc -eq 1 ]]; then
    log_error "Backup completed with warnings (exit code 1)."
else
    log_error "Backup failed with exit code ${backup_rc}."
    exit "$backup_rc"
fi

# ── Smart rotation ─────────────────────────────────────────
# Policy: keep whichever allows MORE archives:
#   Option A: keep at least RETENTION_DAYS daily backups
#   Option B: keep all archives as long as total repo < RETENTION_MAX_GB
# If repo is under the size limit, skip pruning entirely (archives can
# accumulate beyond RETENTION_DAYS). Only prune when over the size limit,
# enforcing the RETENTION_DAYS minimum.

log_info "Rotation policy: keep ${RETENTION_DAYS} daily OR up to ${RETENTION_MAX_GB}GB (whichever keeps more)"

repo_size_bytes="$(get_repo_size_bytes)"
max_bytes=$(( RETENTION_MAX_GB * 1024 * 1024 * 1024 ))

if (( repo_size_bytes <= max_bytes )); then
    # Under size limit — do NOT prune. Let archives accumulate.
    log_info "Repo size ($(( repo_size_bytes / 1024 / 1024 ))MB) is under ${RETENTION_MAX_GB}GB limit — skipping prune"
else
    # Over size limit — prune to RETENTION_DAYS daily (the guaranteed minimum)
    log_error "WARNING: Repo size ($(( repo_size_bytes / 1024 / 1024 / 1024 ))GB) exceeds ${RETENTION_MAX_GB}GB limit!"
    log_info "Pruning to ${RETENTION_DAYS} daily archives..."
    borg prune \
        --stats \
        --show-rc \
        --keep-daily "${RETENTION_DAYS}" \
        --glob-archives "$(hostname)-*" \
        "$BORG_REPO" \
        2>&1 | tee -a "$LOG_FILE"

    prune_rc=${PIPESTATUS[0]}
    if [[ $prune_rc -ne 0 ]]; then
        log_error "Prune failed with exit code ${prune_rc}."
    fi
fi

# ── Compact repo ──────────────────────────────────────────
log_info "Compacting repository..."
borg compact "$BORG_REPO" 2>&1 | tee -a "$LOG_FILE"

# ── Post-backup space check ──────────────────────────────
log_info "Post-backup space report:"
check_space || true

log_info "=== Backup finished ==="
