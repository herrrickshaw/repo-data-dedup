#!/usr/bin/env bash
# Versioned cloud backup of all durable market data — the third copy.
#
# Copies:  1. GitHub (regular git objects, post-LFS migration)
#          2. Local disk (~/repos clones + ~/repos/branch-archives bundles)
#          3. Google Drive (this script)   + Dropbox second copy for jewels
#
# Versioning: rclone sync --backup-dir means NOTHING is ever deleted in the
# cloud — files that change or disappear locally are moved to
# market-data-backup/versions/<YYYY-MM-DD>/ instead of being overwritten.
# Retrieval:  rclone copy googledrive:market-data-backup/current/<name> <dest>
# History:    rclone lsd googledrive:market-data-backup/versions
#
# Cron: weekly Sat 20:00 (see crontab). Manual run: just execute it.
# NOTE: googledrive remote uses rclone's shared client_id (retiring 2026) —
# create your own client_id per https://rclone.org/drive/#making-your-own-client-id
set -uo pipefail

REMOTE="googledrive:market-data-backup"
REMOTE2="dropbox:market-data-backup"     # second cloud copy (jewels only)
STAMP=$(date +%Y-%m-%d)
LOG="$HOME/repos/repo-data-dedup/state/cloud_backup.log"
RC="/opt/homebrew/bin/rclone"
FLAGS=(--transfers 4 --timeout 60s --retries 3 --log-level NOTICE)

echo "===== cloud_backup $STAMP $(date +%H:%M) =====" >> "$LOG"

backup () {  # backup <local_dir> <name> [remote]
  local src=$1 name=$2 rem=${3:-$REMOTE}
  [ -d "$src" ] || { echo "SKIP missing $src" >> "$LOG"; return; }
  $RC sync "$src" "$rem/current/$name" \
      --backup-dir "$rem/versions/$STAMP/$name" \
      "${FLAGS[@]}" >> "$LOG" 2>&1 \
    && $RC check "$src" "$rem/current/$name" --one-way --size-only \
        >> "$LOG" 2>&1 \
    && echo "OK   $name -> $rem" >> "$LOG" \
    || echo "FAIL $name -> $rem" >> "$LOG"
}

# --- Google Drive: everything durable ---
backup "$HOME/repos/global-market-data/warehouse"            gmd-warehouse
backup "$HOME/repos/global-market-data/cache_seed"           gmd-cache_seed
backup "$HOME/market-pipeline/code/python_files/cache_seed"  pipeline-cache_seed
backup "$HOME/market-pipeline/code/python_files/reports"     pipeline-reports
backup "$HOME/repos/branch-archives"                         branch-archives

# --- Dropbox: second independent copy of the irreplaceables ---
backup "$HOME/repos/global-market-data/warehouse"  gmd-warehouse    "$REMOTE2"
backup "$HOME/repos/branch-archives"               branch-archives  "$REMOTE2"

echo "done $(date +%H:%M)" >> "$LOG"
tail -12 "$LOG"
