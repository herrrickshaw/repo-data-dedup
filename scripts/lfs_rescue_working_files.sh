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

# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

USAGE="Usage: scripts/lfs_rescue_working_files.sh
Probes working-files' LFS; once readable, fetches every payload into
branch-archives and writes state/wf_lfs_rescued.done. No arguments.
Exit 0: done-marker present, still blocked, or rescued. Exit 1: clone/fetch/rsync failed."

# ── constants ────────────────────────────────────────────────────────────────
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MARKER="$REPO_DIR/state/wf_lfs_rescued.done"
LOG="$REPO_DIR/state/wf_lfs_rescue.log"
CLONE="$REPO_DIR/state/wf-lfs-rescue-clone"
SOURCE_REPO="https://github.com/$GH_OWNER/working-files.git"
DEST="$HOME/repos/branch-archives/working-files-rescue-inventory-2026-07-23/lfs-objects"
PROBE_FILE="market-pipeline-data/cache_seed/circuit_breaker_backtest_IN.parquet"

log() { log_to "$LOG" "[$(now_ts)] $*"; }

ensure_clone() {  # pointer-only clone; exit 1 on failure
  [ -d "$CLONE/.git" ] && return 0
  GIT_LFS_SKIP_SMUDGE=1 git clone --quiet "$SOURCE_REPO" "$CLONE" \
    || { log "clone failed"; exit 1; }
}

# Cheap probe: one small file. Blocked -> non-zero (caller exits quietly, cron noise-free).
reads_unblocked() {
  git lfs pull --include="$PROBE_FILE" >/dev/null 2>&1 \
    && ! head -c 20 "$PROBE_FILE" | grep -q "version https"
}

fetch_all_payloads() {
  if ! git lfs fetch --all >> "$LOG" 2>&1; then
    log "fetch --all failed (partial?) — will retry next run"
    exit 1
  fi
}

archive_payloads() {
  local got
  mkdir -p "$DEST"
  rsync -a .git/lfs/objects/ "$DEST/" || { log "rsync failed"; exit 1; }
  got=$(find "$DEST" -type f | wc -l | tr -d ' ')
  log "rescued $got LFS objects -> $DEST"
}

main() {
  usage_if_requested "$USAGE" "$@"
  [ -f "$MARKER" ] && exit 0
  mkdir -p "$REPO_DIR/state"
  ensure_clone
  cd "$CLONE" || { log "cannot cd into $CLONE"; exit 1; }
  if ! reads_unblocked; then
    log "still blocked"
    exit 0
  fi
  log "READS UNBLOCKED — fetching all LFS payloads"
  fetch_all_payloads
  archive_payloads
  touch "$MARKER"
  log "DONE — working-files deletion is now zero-loss (frees 1.32GB LFS). Remove the cron line for this script."
  exit 0
}

main "$@"
