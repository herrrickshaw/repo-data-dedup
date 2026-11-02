#!/usr/bin/env bash
# Nightly Postgres logical backup, replicated to both clouds.
#
# Unlike the file-mirror datasets in datasets.conf (which sync a persistent
# local directory), this dumps FRESH each run, uploads to Dropbox AND Google
# Drive, verifies each upload byte-for-byte, then deletes the local dump —
# it never holds a permanent local copy, so it doesn't grow local disk usage
# over time the way a kept dump directory would.
#
# Databases covered: market_data, vcrud, repo_csv_archive (see DBS below —
# same set as market_data.duckdb's warehouse-duckdb sibling tables, i.e.
# every live Postgres DB this platform runs against).
#
# Cron: daily 20:00 (before disk_guard_daily.sh at 20:30, so disk pressure
# from the dump briefly existing is visible to that guard if it runs late).
# Log: state/pg_cloud_backup.log
set -uo pipefail

# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

USAGE="Usage: scripts/pg_cloud_backup.sh
pg_dump each database in DBS, upload to Dropbox and Google Drive, verify
sizes, delete the local dump only when both clouds verified. No arguments.
Log: $DEDUP_STATE_DIR/pg_cloud_backup.log"

# ── constants ────────────────────────────────────────────────────────────────
SCRATCH="$HOME/.cache/pg_cloud_backup"
LOG="$DEDUP_STATE_DIR/pg_cloud_backup.log"
RC="$RCLONE_BIN"
DBS=(market_data vcrud repo_csv_archive)
REMOTES=("dropbox:market-pipeline-cache/pg_backups" "$GDRIVE_BACKUP/current/pg_backups")
STALE_DAYS=3
STAMP=$(today)

dump_db() {  # dump_db <db> <dump_path> — non-zero and no file left on failure
  log_to "$LOG" "-- dumping $1 --"
  if ! pg_dump -U "$(whoami)" -Fc -Z 6 -d "$1" -f "$2" >> "$LOG" 2>&1; then
    log_to "$LOG" "FAIL dump $1"
    rm -f "$2"
    return 1
  fi
}

remote_size_bytes() {  # remote_size_bytes <remote_path> — prints -1 when unknown
  "$RC" size "$1" --json 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['bytes'])" 2>/dev/null \
    || echo -1
}

upload_and_verify() {  # upload_and_verify <db> <dump_path> <remote> — 0 only if size matches
  local db=$1 dump=$2 rem=$3 local_size remote_size
  log_to "$LOG" "-- uploading $db -> $rem --"
  if ! "$RC" copy "$dump" "$rem" --log-level ERROR >> "$LOG" 2>&1; then
    log_to "$LOG" "FAIL upload $db -> $rem"
    return 1
  fi
  local_size=$(stat -f%z "$dump")
  remote_size=$(remote_size_bytes "$rem/$(basename "$dump")")
  if [ "$local_size" = "$remote_size" ]; then
    log_to "$LOG" "OK   $db -> $rem (verified $local_size bytes)"
  else
    log_to "$LOG" "FAIL verify $db -> $rem (local=$local_size remote=$remote_size)"
    return 1
  fi
}

backup_db() {  # backup_db <db>
  local db=$1 dump="$SCRATCH/${db}_${STAMP}.dump" ok=1 rem
  dump_db "$db" "$dump" || return 0
  for rem in "${REMOTES[@]}"; do
    upload_and_verify "$db" "$dump" "$rem" || ok=0
  done
  if [ "$ok" = 1 ]; then
    rm -f "$dump"
    log_to "$LOG" "OK   $db fully verified on both clouds, local dump deleted"
  else
    log_to "$LOG" "KEPT local dump for $db (one or more clouds unverified): $dump"
  fi
}

# safety net: never let old dumps silently accumulate if a run partially fails
# repeatedly. Anything older than STALE_DAYS here means that many consecutive
# failures — surface it instead of quietly growing local disk.
warn_stale_dumps() {
  local old
  old=$(find "$SCRATCH" -name "*.dump" -mtime +"$STALE_DAYS" 2>/dev/null)
  [ -n "$old" ] && log_to "$LOG" "WARN stale dumps >$STALE_DAYS days old, investigate: $old"
}

main() {
  usage_if_requested "$USAGE" "$@"
  local db
  mkdir -p "$SCRATCH"
  log_to "$LOG" "===== pg_cloud_backup $STAMP $(now_hm) ====="
  for db in "${DBS[@]}"; do
    backup_db "$db"
  done
  warn_stale_dumps
  log_to "$LOG" "done $(now_hm)"
}

main "$@"
