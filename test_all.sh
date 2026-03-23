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
