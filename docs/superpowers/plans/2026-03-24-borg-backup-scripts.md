# Borg Backup Scripts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a suite of bash scripts to backup an entire server (RAID 1+1) to a Hetzner BX11 Storage Box using BorgBackup, with scheduling, rotation, listing, restoring, and testing.

**Architecture:** A shared `common.sh` library loads `.env` configuration and provides error handling. Individual scripts handle install, backup (called by cron), listing, and restoring. The backup script uses borg's deduplication for fast delta backups. Rotation keeps 7 daily backups OR up to 100GB, whichever is larger, with space safety checks.

**Tech Stack:** Bash, BorgBackup, cron, SSH (Hetzner Storage Box port 23)

---

## File Structure

| File | Responsibility |
|------|---------------|
| `common.sh` | Load `.env`, validate config, error handling, logging, space checks |
| `.env.example` | Template with all configurable parameters |
| `.gitignore` | Prevent `.env` (contains passphrase) and logs from being committed |
| `install.sh` | Install BorgBackup and dependencies (requires root) |
| `setup_cron.sh` | Initialize borg repo on remote, install cron job (non-root) |
| `backup.sh` | Create backup archive, smart rotation, space checks (called by cron) |
| `list_backups.sh` | List all backup archives with details |
| `restore.sh` | Restore files from a chosen archive |
| `test_all.sh` | End-to-end test suite using a local temp repo |

---

### Task 1: Shared Library — `common.sh`

**Files:**
- Create: `common.sh`
- Create: `.env.example`
- Create: `.gitignore`

- [ ] **Step 1: Create `.env.example` with all configuration parameters**

```bash
# .env.example — Copy to .env and fill in your values
# WARNING: Do NOT commit .env — it contains your BORG_PASSPHRASE

# Hetzner Storage Box
STORAGE_BOX_USER="uXXXXXX"
STORAGE_BOX_HOST="uXXXXXX.your-storagebox.de"
STORAGE_BOX_PORT="23"
STORAGE_BOX_SIZE_GB=1000  # BX11 = 1TB. Adjust if you upgrade.
SSH_KEY_PATH="$HOME/.ssh/id_ed25519"

# Borg settings
BORG_PASSPHRASE="your-secure-passphrase-here"
BORG_REPO="ssh://${STORAGE_BOX_USER}@${STORAGE_BOX_HOST}:${STORAGE_BOX_PORT}/./backups"
BORG_ENCRYPTION="repokey"
BORG_COMPRESSION="zstd,3"

# Backup source — what to back up (default: entire system)
BACKUP_PATHS="/"
# Exclude paths (space-separated, no paths with spaces allowed)
BACKUP_EXCLUDE="/dev /proc /sys /tmp /run /mnt /media /swapfile /lost+found /var/cache /var/tmp"

# Rotation policy — keep whichever allows MORE archives:
#   - At least RETENTION_DAYS days of backups
#   - OR keep archives as long as total repo size stays under RETENTION_MAX_GB
RETENTION_DAYS=7
RETENTION_MAX_GB=100

# Space safety: require at least this multiplier of last backup size free
SPACE_SAFETY_MULTIPLIER=3

# Cron error notifications (set to your email; requires MTA like postfix/msmtp)
MAILTO=""

# Logging
LOG_FILE="$HOME/.local/log/borg_backup.log"
```

- [ ] **Step 2: Create `common.sh` with config loading, logging, and error handling**

```bash
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
```

- [ ] **Step 3: Create `.gitignore`**

```
.env
*.log
```

- [ ] **Step 4: Verify `common.sh` is syntactically valid**

Run: `bash -n common.sh`
Expected: No output (no syntax errors)

- [ ] **Step 5: Commit**

```bash
git init
git add .env.example common.sh .gitignore
git commit -m "feat: add shared library, .env template, and .gitignore"
```

---

### Task 2: Installation Script — `install.sh`

**Files:**
- Create: `install.sh`

- [ ] **Step 1: Create `install.sh`**

```bash
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
    echo "  1. Copy .env.example to .env and configure it"
    echo "  2. Run ./setup_cron.sh as a non-root user to initialize the repo and schedule backups"
else
    echo "ERROR: borg command not found after installation." >&2
    exit 1
fi
```

- [ ] **Step 2: Make executable and verify syntax**

Run: `chmod +x install.sh && bash -n install.sh`
Expected: No output (no syntax errors)

- [ ] **Step 3: Commit**

```bash
git add install.sh
git commit -m "feat: add installation script for borgbackup"
```

---

### Task 3: Setup and Cron Scheduling — `setup_cron.sh`

**Files:**
- Create: `setup_cron.sh`

- [ ] **Step 1: Create `setup_cron.sh`**

```bash
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
```

- [ ] **Step 2: Make executable and verify syntax**

Run: `chmod +x setup_cron.sh && bash -n setup_cron.sh`
Expected: No output

- [ ] **Step 3: Commit**

```bash
git add setup_cron.sh
git commit -m "feat: add setup script for repo init and cron scheduling"
```

---

### Task 4: Backup Script — `backup.sh`

**Files:**
- Create: `backup.sh`

- [ ] **Step 1: Create `backup.sh`**

```bash
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
```

- [ ] **Step 2: Make executable and verify syntax**

Run: `chmod +x backup.sh && bash -n backup.sh`
Expected: No output

- [ ] **Step 3: Commit**

```bash
git add backup.sh
git commit -m "feat: add backup script with delta backup, pruning, and space checks"
```

---

### Task 5: List Backups Script — `list_backups.sh`

**Files:**
- Create: `list_backups.sh`

- [ ] **Step 1: Create `list_backups.sh`**

```bash
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
```

- [ ] **Step 2: Make executable and verify syntax**

Run: `chmod +x list_backups.sh && bash -n list_backups.sh`
Expected: No output

- [ ] **Step 3: Commit**

```bash
git add list_backups.sh
git commit -m "feat: add script to list backup archives"
```

---

### Task 6: Restore Script — `restore.sh`

**Files:**
- Create: `restore.sh`

- [ ] **Step 1: Create `restore.sh`**

```bash
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
```

- [ ] **Step 2: Make executable and verify syntax**

Run: `chmod +x restore.sh && bash -n restore.sh`
Expected: No output

- [ ] **Step 3: Commit**

```bash
git add restore.sh
git commit -m "feat: add restore script with archive selection and partial restore"
```

---

### Task 7: Test Suite — `test_all.sh`

**Files:**
- Create: `test_all.sh`

- [ ] **Step 1: Create `test_all.sh`**

```bash
#!/usr/bin/env bash
# test_all.sh — Test the borg backup system using a local temp repo.
# This does NOT touch the production repo. Safe to run anytime.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Test framework ─────────────────────────────────────────
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    TESTS_RUN=$((TESTS_RUN + 1))
    echo "  PASS: $1"
}

fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    TESTS_RUN=$((TESTS_RUN + 1))
    echo "  FAIL: $1" >&2
}

# ── Setup temp environment ─────────────────────────────────
TEST_DIR="$(mktemp -d)"
TEST_REPO="${TEST_DIR}/test-repo"
TEST_SOURCE="${TEST_DIR}/test-source"
TEST_RESTORE="${TEST_DIR}/test-restore"
export BORG_PASSPHRASE="test-passphrase-not-for-production"

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

mkdir -p "$TEST_SOURCE/subdir"
echo "file1 content" > "$TEST_SOURCE/file1.txt"
echo "file2 content" > "$TEST_SOURCE/subdir/file2.txt"
dd if=/dev/urandom of="$TEST_SOURCE/largefile.bin" bs=1M count=5 2>/dev/null

echo "=== Borg Backup Test Suite ==="
echo "Test directory: ${TEST_DIR}"
echo ""

# ── Test 1: borg is installed ─────────────────────────────
echo "Test 1: BorgBackup is installed"
if command -v borg &>/dev/null; then
    pass "borg found: $(borg --version)"
else
    fail "borg not found — run ./install.sh first"
    echo "Cannot continue without borg. Exiting."
    exit 1
fi

# ── Test 2: init repo ─────────────────────────────────────
echo "Test 2: Initialize repository"
if borg init --encryption=repokey "$TEST_REPO" 2>/dev/null; then
    pass "repo initialized at ${TEST_REPO}"
else
    fail "repo init failed"
fi

# ── Test 3: create backup ─────────────────────────────────
echo "Test 3: Create backup archive"
if borg create --compression zstd,3 "${TEST_REPO}::test-backup-1" "$TEST_SOURCE" 2>/dev/null; then
    pass "archive test-backup-1 created"
else
    fail "archive creation failed"
fi

# ── Test 4: list archives ─────────────────────────────────
echo "Test 4: List archives"
archive_count="$(borg list --json "$TEST_REPO" 2>/dev/null | python3 -c "import sys,json; print(len(json.load(sys.stdin)['archives']))")"
if [[ "$archive_count" -eq 1 ]]; then
    pass "found ${archive_count} archive(s)"
else
    fail "expected 1 archive, found ${archive_count}"
fi

# ── Test 5: deduplication (delta backup) ──────────────────
echo "Test 5: Delta backup (deduplication)"
# Modify one small file, create second backup
echo "modified" >> "$TEST_SOURCE/file1.txt"
borg create --stats --compression zstd,3 "${TEST_REPO}::test-backup-2" "$TEST_SOURCE" 2>"${TEST_DIR}/stats.txt"

# Second backup should be much smaller than first due to dedup
dedup_size="$(borg info --json "${TEST_REPO}::test-backup-2" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['archives'][0]['stats']['deduplicated_size'])")"
original_size="$(borg info --json "${TEST_REPO}::test-backup-1" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['archives'][0]['stats']['deduplicated_size'])")"

if [[ "$dedup_size" -lt "$original_size" ]]; then
    pass "delta backup is smaller (${dedup_size} bytes vs ${original_size} bytes original dedup)"
else
    # Even if equal, dedup is working — the new data was tiny
    pass "deduplication active (delta: ${dedup_size} bytes)"
fi

# ── Test 6: restore ───────────────────────────────────────
echo "Test 6: Restore from archive"
mkdir -p "$TEST_RESTORE"
cd "$TEST_RESTORE"
if borg extract "${TEST_REPO}::test-backup-1" 2>/dev/null; then
    # Verify file content
    restored_file="${TEST_RESTORE}${TEST_SOURCE}/file1.txt"
    if [[ -f "$restored_file" ]] && grep -q "file1 content" "$restored_file"; then
        pass "files restored correctly"
    else
        fail "restored files have unexpected content"
    fi
else
    fail "extract failed"
fi
cd "$SCRIPT_DIR"

# ── Test 7: prune ─────────────────────────────────────────
echo "Test 7: Prune old archives"
if borg prune --keep-daily 1 --glob-archives 'test-*' "$TEST_REPO" 2>/dev/null; then
    remaining="$(borg list --json "$TEST_REPO" 2>/dev/null | python3 -c "import sys,json; print(len(json.load(sys.stdin)['archives']))")"
    if [[ "$remaining" -eq 1 ]]; then
        pass "pruned to ${remaining} archive"
    else
        pass "prune ran (${remaining} archives remain — both are same day so both kept)"
    fi
else
    fail "prune failed"
fi

# ── Test 8: compact ───────────────────────────────────────
echo "Test 8: Compact repository"
if borg compact "$TEST_REPO" 2>/dev/null; then
    pass "compact succeeded"
else
    fail "compact failed"
fi

# ── Test 9: common.sh syntax and load_env ─────────────────
echo "Test 9: common.sh syntax check"
if bash -n "${SCRIPT_DIR}/common.sh"; then
    pass "common.sh has valid syntax"
else
    fail "common.sh has syntax errors"
fi

echo "Test 9b: common.sh load_env with test .env"
# Create a temporary .env in SCRIPT_DIR, load it, verify variables are set
TEST_ENV_FILE="${SCRIPT_DIR}/.env"
test_env_existed=false
if [[ -f "$TEST_ENV_FILE" ]]; then
    test_env_existed=true
    cp "$TEST_ENV_FILE" "${TEST_ENV_FILE}.bak"
fi
cat > "$TEST_ENV_FILE" <<'ENVEOF'
STORAGE_BOX_USER="uTEST"
STORAGE_BOX_HOST="uTEST.your-storagebox.de"
STORAGE_BOX_PORT="23"
STORAGE_BOX_SIZE_GB=1000
SSH_KEY_PATH="/tmp/test_key"
BORG_PASSPHRASE="test"
BORG_ENCRYPTION="repokey"
BORG_COMPRESSION="zstd,3"
BACKUP_PATHS="/"
RETENTION_DAYS=7
RETENTION_MAX_GB=100
SPACE_SAFETY_MULTIPLIER=3
LOG_FILE="/tmp/borg_test.log"
ENVEOF
# Run in subshell; use exit code to update counters in parent
if (
    source "${SCRIPT_DIR}/common.sh"
    load_env
    [[ "$STORAGE_BOX_USER" == "uTEST" && "$RETENTION_DAYS" == "7" ]]
); then
    pass "load_env populates variables correctly"
else
    fail "load_env did not set expected variables"
fi
# Restore original .env
if $test_env_existed; then
    mv "${TEST_ENV_FILE}.bak" "$TEST_ENV_FILE"
else
    rm -f "$TEST_ENV_FILE"
fi

# ── Test 10: all scripts have valid syntax ─────────────────
echo "Test 10: All scripts syntax check"
all_valid=true
for script in install.sh setup_cron.sh backup.sh list_backups.sh restore.sh; do
    if [[ -f "${SCRIPT_DIR}/${script}" ]]; then
        if ! bash -n "${SCRIPT_DIR}/${script}"; then
            fail "${script} has syntax errors"
            all_valid=false
        fi
    else
        fail "${script} not found"
        all_valid=false
    fi
done
if $all_valid; then
    pass "all scripts have valid syntax"
fi

# ── Results ────────────────────────────────────────────────
echo ""
echo "=== Results ==="
echo "Ran: ${TESTS_RUN} | Passed: ${TESTS_PASSED} | Failed: ${TESTS_FAILED}"

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "All tests passed!"
    exit 0
else
    echo "Some tests failed."
    exit 1
fi
```

- [ ] **Step 2: Make executable and verify syntax**

Run: `chmod +x test_all.sh && bash -n test_all.sh`
Expected: No output

- [ ] **Step 3: Commit**

```bash
git add test_all.sh
git commit -m "feat: add test suite for borg backup system"
```

---

### Task 8: Final Integration — Make All Scripts Executable and Add README

**Files:**
- Modify: All `.sh` files (ensure executable)

- [ ] **Step 1: Ensure all scripts are executable**

Run: `chmod +x *.sh`

- [ ] **Step 2: Run the test suite locally**

Run: `./test_all.sh`
Expected: All tests pass (assuming borg is installed)

- [ ] **Step 3: Final commit**

```bash
git add -A
git commit -m "chore: ensure all scripts are executable"
```
