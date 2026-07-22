#!/bin/bash
# lfs_rescue_working_files.sh — auto-retry rescue of working-files' LFS payloads.
#
# Context (C9, 2026-07-23): 98 LFS oids (1.04 GB) exist ONLY in working-files' LFS
# storage, which is read-blocked by the exhausted account budget. Deletions on
# 2026-07-23 freed 0.77 GB but GitHub recalculates lazily. This script probes on a
# cron; when reads unblock it fetches ALL payloads (~1.32 GB), archives them next to
# the rescue inventory in branch-archives (nightly backup relays them to Dropbox +
# GDrive), then writes a done-marker and never runs again.
#
# See: ~/repos/branch-archives/working-files-rescue-inventory-2026-07-23/README.md
set -u
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MARKER="$REPO_DIR/state/wf_lfs_rescued.done"
LOG="$REPO_DIR/state/wf_lfs_rescue.log"
CLONE="$REPO_DIR/state/wf-lfs-rescue-clone"
DEST="$HOME/repos/branch-archives/working-files-rescue-inventory-2026-07-23/lfs-objects"
PROBE_FILE="market-pipeline-data/cache_seed/circuit_breaker_backtest_IN.parquet"
STAMP() { date '+%Y-%m-%d %H:%M:%S'; }

[ -f "$MARKER" ] && exit 0
mkdir -p "$REPO_DIR/state"

if [ ! -d "$CLONE/.git" ]; then
  GIT_LFS_SKIP_SMUDGE=1 git clone --quiet \
    https://github.com/herrrickshaw/working-files.git "$CLONE" \
    || { echo "[$(STAMP)] clone failed" >> "$LOG"; exit 1; }
fi
cd "$CLONE"

# Cheap probe: one small file. Blocked -> quiet exit (cron noise-free).
if ! git lfs pull --include="$PROBE_FILE" >/dev/null 2>&1 \
   || head -c 20 "$PROBE_FILE" | grep -q "version https"; then
  echo "[$(STAMP)] still blocked" >> "$LOG"
  exit 0
fi

echo "[$(STAMP)] READS UNBLOCKED — fetching all LFS payloads" >> "$LOG"
if ! git lfs fetch --all >> "$LOG" 2>&1; then
  echo "[$(STAMP)] fetch --all failed (partial?) — will retry next run" >> "$LOG"
  exit 1
fi

mkdir -p "$DEST"
rsync -a .git/lfs/objects/ "$DEST/" || { echo "[$(STAMP)] rsync failed" >> "$LOG"; exit 1; }

got=$(find "$DEST" -type f | wc -l | tr -d ' ')
echo "[$(STAMP)] rescued $got LFS objects -> $DEST" >> "$LOG"
touch "$MARKER"
echo "[$(STAMP)] DONE — working-files deletion is now zero-loss (frees 1.32GB LFS). Remove the cron line for this script." >> "$LOG"
exit 0
