#!/bin/bash
# restore_drill.sh — monthly tested-restore drill (3-2-1-1-0: the "0 errors on tested restores" leg).
#
# A backup you've never restored is a backup you can't trust. This drill:
#   1. samples N random files from dropbox:market-data-backup/current
#   2. restores each to a scratch dir and byte-verifies vs the Dropbox copy (rclone check --download)
#   3. cross-checks the same paths on the Google Drive mirror (provider divergence detection)
#   4. logs PASS/FAIL per file to state/restore_drill.log
#
# Exit non-zero on any failure so a wrapper/cron mail can catch it.
set -u

# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

USAGE="Usage: scripts/restore_drill.sh [N]
Sample N (default 3) random files from the Dropbox backup, restore + byte-verify
them against Dropbox and the Drive mirror, and check the latest pg dump's gzip
integrity. Logs to state/restore_drill.log. Exit 1 on any FAIL/WARN."

# ── constants ────────────────────────────────────────────────────────────────
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$REPO_DIR/state/restore_drill.log"
SCRATCH="$(mktemp -d /tmp/restore_drill.XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT
N="${1:-3}"
SRC="dropbox:market-data-backup/current"
SRC_ALT="dropbox:market-data-archive"
MIRROR="$GDRIVE_BACKUP/current"
MAX_SAMPLE_BYTES=52428800   # 50 MB cap so the drill stays fast
STAMP="$(now_ts)"
fail=0

log() { log_to "$LOG" "[$STAMP] $*"; }

# Sample N random files (skip zero-byte; cap at MAX_SAMPLE_BYTES)
sample_files() {
  rclone lsf --files-only -R --format sp "$SRC" 2>/dev/null \
    | awk -F';' -v max="$MAX_SAMPLE_BYTES" '$1 > 0 && $1 < max {print $2}' | sort -R | head -n "$N"
}

drill_file() {  # drill_file <relative path> — sets fail=1 on any problem
  local f=$1
  # 1) restore
  if ! rclone copyto "$SRC/$f" "$SCRATCH/restore/$f" 2>/dev/null; then
    log "FAIL restore: $f"; fail=1; return
  fi
  # 2) byte-verify restored copy vs Dropbox (download compare, not just hash metadata)
  if ! rclone check --download "$SCRATCH/restore/$(dirname "$f")" "$SRC/$(dirname "$f")" \
        --include "/$(basename "$f")" >/dev/null 2>&1; then
    log "FAIL byte-verify vs dropbox: $f"; fail=1; return
  fi
  # 3) cross-provider check (Drive mirror should hold an identical copy)
  if ! rclone check --download "$SCRATCH/restore/$(dirname "$f")" "$MIRROR/$(dirname "$f")" \
        --include "/$(basename "$f")" >/dev/null 2>&1; then
    log "WARN drive-mirror divergence: $f"; fail=1; return
  fi
  log "PASS: $f"
}

latest_pg_dump() {  # prints the newest *.sql.gz / *.dump.gz under $1
  rclone lsf --files-only -R "$1" 2>/dev/null | grep -E '\.(sql|dump)\.gz$' | sort | tail -1
}

# 4) latest pg dump restore-readability check (gunzip -t = integrity of the archive)
# dumps live under current/ here, or in the parallel session's market-data-archive tree
check_pg_dump() {
  local latest_dump
  latest_dump=$(latest_pg_dump "$SRC")
  if [ -z "$latest_dump" ]; then
    latest_dump=$(latest_pg_dump "$SRC_ALT")
    [ -n "$latest_dump" ] && SRC="$SRC_ALT"
  fi
  if [ -z "$latest_dump" ]; then
    log "NOTE: no pg dump found under current/"
  elif rclone cat "$SRC/$latest_dump" 2>/dev/null | gunzip -t 2>/dev/null; then
    log "PASS pg-dump integrity: $latest_dump"
  else
    log "FAIL pg-dump integrity: $latest_dump"; fail=1
  fi
}

main() {
  usage_if_requested "$USAGE" "$@"
  local files f
  mkdir -p "$REPO_DIR/state"
  log "drill start (sample=$N)"
  files=$(sample_files)
  if [ -z "$files" ]; then
    log "FAIL: could not list $SRC"
    exit 1
  fi
  while IFS= read -r f; do
    drill_file "$f"
  done <<< "$files"
  check_pg_dump
  log "drill end rc=$fail"
  exit "$fail"
}

main "$@"
