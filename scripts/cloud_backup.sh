#!/usr/bin/env bash
# Versioned cloud backup of all durable market data — the third copy.
# Target: DROPBOX (primary cloud copy; 1.6 TiB free, per user decision
# 2026-07-22 "move to dropbox"). Google Drive redundancy is handled
# separately by daily_pipeline step [16/16] -> googledrive:market-data-archive.
#
# Copy census for the jewels:
#   1. GitHub (regular git objects, post-LFS migration)
#   2. Local disk (~/repos clones + ~/repos/branch-archives bundles)
#   3. Dropbox (this script, weekly)
#   4. Google Drive (daily pipeline archive)
#
# Versioning: rclone sync --backup-dir means NOTHING is ever deleted in the
# cloud — files that change or disappear locally are moved to
# market-data-backup/versions/<YYYY-MM-DD>/ instead of being overwritten.
# Retrieval:  rclone copy dropbox:market-data-backup/current/<name> <dest>
# History:    rclone lsd dropbox:market-data-backup/versions
#
# Cron: weekly Sat 20:00. Manual run: just execute it.
set -uo pipefail

REMOTE="dropbox:market-data-backup"
STAMP=$(date +%Y-%m-%d)
LOG="$HOME/repos/repo-data-dedup/state/cloud_backup.log"
RC="/opt/homebrew/bin/rclone"
FLAGS=(--transfers 4 --timeout 60s --retries 3 --log-level NOTICE)

echo "===== cloud_backup $STAMP $(date +%H:%M) -> dropbox =====" >> "$LOG"

backup () {  # backup <local_dir> <name>
  local src=$1 name=$2
  [ -d "$src" ] || { echo "SKIP missing $src" >> "$LOG"; return; }
  $RC sync "$src" "$REMOTE/current/$name" \
      --backup-dir "$REMOTE/versions/$STAMP/$name" \
      "${FLAGS[@]}" >> "$LOG" 2>&1 \
    && $RC check "$src" "$REMOTE/current/$name" --one-way --size-only \
        >> "$LOG" 2>&1 \
    && echo "OK   $name" >> "$LOG" \
    || echo "FAIL $name" >> "$LOG"
}

backup "$HOME/repos/global-market-data/warehouse"            gmd-warehouse
backup "$HOME/repos/global-market-data/cache_seed"           gmd-cache_seed
backup "$HOME/market-pipeline/code/python_files/cache_seed"  pipeline-cache_seed
backup "$HOME/market-pipeline/code/python_files/reports"     pipeline-reports
backup "$HOME/repos/branch-archives"                         branch-archives

echo "done $(date +%H:%M)" >> "$LOG"
tail -8 "$LOG"
