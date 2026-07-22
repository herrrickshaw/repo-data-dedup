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
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$REPO_DIR/state/restore_drill.log"
SCRATCH="$(mktemp -d /tmp/restore_drill.XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT
N="${1:-3}"
SRC="dropbox:market-data-backup/current"
MIRROR="googledrive:market-data-backup/current"
STAMP="$(date '+%Y-%m-%d %H:%M:%S')"
fail=0

mkdir -p "$REPO_DIR/state"
echo "[$STAMP] drill start (sample=$N)" >> "$LOG"

# Sample N random files (skip zero-byte; cap 50MB so the drill stays fast)
files=$(rclone lsf --files-only -R --format sp "$SRC" 2>/dev/null \
        | awk -F';' '$1 > 0 && $1 < 52428800 {print $2}' | sort -R | head -n "$N")

if [ -z "$files" ]; then
  echo "[$STAMP] FAIL: could not list $SRC" >> "$LOG"
  exit 1
fi

while IFS= read -r f; do
  # 1) restore
  if ! rclone copyto "$SRC/$f" "$SCRATCH/restore/$f" 2>/dev/null; then
    echo "[$STAMP] FAIL restore: $f" >> "$LOG"; fail=1; continue
  fi
  # 2) byte-verify restored copy vs Dropbox (download compare, not just hash metadata)
  if ! rclone check --download "$SCRATCH/restore/$(dirname "$f")" "$SRC/$(dirname "$f")" \
        --include "/$(basename "$f")" >/dev/null 2>&1; then
    echo "[$STAMP] FAIL byte-verify vs dropbox: $f" >> "$LOG"; fail=1; continue
  fi
  # 3) cross-provider check (Drive mirror should hold an identical copy)
  if ! rclone check --download "$SCRATCH/restore/$(dirname "$f")" "$MIRROR/$(dirname "$f")" \
        --include "/$(basename "$f")" >/dev/null 2>&1; then
    echo "[$STAMP] WARN drive-mirror divergence: $f" >> "$LOG"; fail=1; continue
  fi
  echo "[$STAMP] PASS: $f" >> "$LOG"
done <<< "$files"

# 4) latest pg dump restore-readability check (gunzip -t = integrity of the archive)
# dumps live under current/ here, or in the parallel session's market-data-archive tree
latest_dump=$(rclone lsf --files-only -R "$SRC" 2>/dev/null | grep -E '\.(sql|dump)\.gz$' | sort | tail -1)
if [ -z "$latest_dump" ]; then
  SRC_ALT="dropbox:market-data-archive"
  latest_dump=$(rclone lsf --files-only -R "$SRC_ALT" 2>/dev/null | grep -E '\.(sql|dump)\.gz$' | sort | tail -1)
  [ -n "$latest_dump" ] && SRC="$SRC_ALT"
fi
if [ -n "$latest_dump" ]; then
  if rclone cat "$SRC/$latest_dump" 2>/dev/null | gunzip -t 2>/dev/null; then
    echo "[$STAMP] PASS pg-dump integrity: $latest_dump" >> "$LOG"
  else
    echo "[$STAMP] FAIL pg-dump integrity: $latest_dump" >> "$LOG"; fail=1
  fi
else
  echo "[$STAMP] NOTE: no pg dump found under current/" >> "$LOG"
fi

echo "[$STAMP] drill end rc=$fail" >> "$LOG"
exit "$fail"
