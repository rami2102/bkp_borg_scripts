# Borg Backup Scripts

Bash scripts to back up an entire server to a [Hetzner Storage Box](https://www.hetzner.com/storage/storage-box/) (BX11) using [BorgBackup](https://borgbackup.readthedocs.io/). Designed for RAID 1+1 servers with daily cron scheduling, delta (deduplicated) backups, smart rotation, and point-in-time restore.

## Scripts

| Script | Run as | Purpose |
|--------|--------|---------|
| `install.sh` | root | Install BorgBackup and dependencies |
| `setup_permissions.sh` | root | Grant borg read-only access to all files + sudoers rule for auto-restore after upgrades |
| `setup_cron.sh` | non-root | Initialize remote borg repo, set up SSH key, install daily cron job |
| `backup.sh` | non-root (cron) | Create backup, smart rotation, space safety checks |
| `list_backups.sh` | non-root | List all backup archives with details |
| `restore.sh` | non-root | Restore from any archive (full or partial) |
| `test_all.sh` | non-root | Run end-to-end test suite (uses local temp repo, safe to run anytime) |

Shared functions live in `common.sh` (sourced by all scripts, not run directly).

## Quick Start

```bash
# 1. Install BorgBackup
sudo ./install.sh

# 2. Grant borg read access to all files (recommended for full system backup)
sudo ./setup_permissions.sh

# 3. Configure
cp .env.example .env
nano .env  # fill in your Hetzner Storage Box credentials

# 4. Initialize repo and schedule daily backups (2:00 AM)
./setup_cron.sh

# 5. Verify everything works
./test_all.sh
```

## Configuration

Copy `.env.example` to `.env` and edit it. Key settings:

| Variable | Description |
|----------|-------------|
| `STORAGE_BOX_USER` | Hetzner Storage Box username (e.g. `u123456`) |
| `STORAGE_BOX_HOST` | Storage Box hostname (e.g. `u123456.your-storagebox.de`) |
| `STORAGE_BOX_PORT` | SSH port (`23` for Hetzner) |
| `BORG_PASSPHRASE` | Encryption passphrase for the borg repo |
| `SSH_KEY_PATH` | Path to SSH private key |
| `BACKUP_PATHS` | What to back up (default: `/`) |
| `BACKUP_EXCLUDE` | Space-separated paths to exclude |
| `RETENTION_DAYS` | Minimum days of backups to keep (default: `7`) |
| `RETENTION_MAX_GB` | Max repo size before pruning (default: `100`) |
| `SPACE_SAFETY_MULTIPLIER` | Require this much free space vs last backup size (default: `3`) |
| `MAILTO` | Email for cron failure notifications |

## Rotation Policy

Keeps whichever allows **more** archives:

- At least **7 days** of daily backups, OR
- All archives as long as total repo size stays under **100 GB**

When the repo exceeds the size limit, it prunes down to the daily retention count. A space safety check warns if free space is less than 3x the last backup's deduplicated size.

## Listing and Restoring Backups

```bash
# List all archives
./list_backups.sh

# Restore entire archive to a directory
./restore.sh myhost-2026-03-24_02-00-00 /tmp/restore

# Restore a specific path
./restore.sh myhost-2026-03-24_02-00-00 /tmp/restore home/user/documents
```

## Permissions (Full System Backup as Non-Root)

To back up `/` (the entire system) without running as root:

```bash
# Run as the backup user — sudo auto-detects your username
sudo ./setup_permissions.sh

# Or specify a different user explicitly
sudo ./setup_permissions.sh backupuser
```

This does two things:
1. Sets `CAP_DAC_READ_SEARCH` on the borg binary — **read-only** access to all files (no write, no execute)
2. Installs a sudoers rule (`/etc/sudoers.d/borg-backup-setcap`) so `backup.sh` can automatically re-apply the capability if `apt upgrade` strips it

The cron job is fully automatic after this — no manual steps needed after package upgrades.

## Error Handling

- `backup.sh` uses an ERR trap that logs failures with timestamps
- Borg exit code 1 (warnings, e.g. permission denied on a file) is handled gracefully without aborting
- Cron stdout/stderr is emailed via `MAILTO` if configured
- All output is logged to `$LOG_FILE` (default: `~/.local/log/borg_backup.log`)

## Requirements

- Linux (Debian/Ubuntu, Fedora/RHEL, or Arch)
- BorgBackup (installed via `install.sh`)
- Python 3 (for JSON parsing of borg output)
- SSH access to a Hetzner Storage Box (or any borg-compatible SSH target)
