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

SCRATCH="$HOME/.cache/pg_cloud_backup"
LOG="$HOME/repos/repo-data-dedup/state/pg_cloud_backup.log"
RC="/opt/homebrew/bin/rclone"
DBS=(market_data vcrud repo_csv_archive)
STAMP=$(date +%Y-%m-%d)
mkdir -p "$SCRATCH"

echo "===== pg_cloud_backup $STAMP $(date +%H:%M) =====" >> "$LOG"

for db in "${DBS[@]}"; do
  dump="$SCRATCH/${db}_${STAMP}.dump"
  echo "-- dumping $db --" >> "$LOG"
  if ! pg_dump -U "$(whoami)" -Fc -Z 6 -d "$db" -f "$dump" >> "$LOG" 2>&1; then
    echo "FAIL dump $db" >> "$LOG"
    rm -f "$dump"
    continue
  fi

  ok=1
  for rem in "dropbox:market-pipeline-cache/pg_backups" "googledrive:market-data-backup/current/pg_backups"; do
    echo "-- uploading $db -> $rem --" >> "$LOG"
    if ! "$RC" copy "$dump" "$rem" --log-level ERROR >> "$LOG" 2>&1; then
      echo "FAIL upload $db -> $rem" >> "$LOG"
      ok=0
      continue
    fi
    local_size=$(stat -f%z "$dump")
    remote_size=$("$RC" size "$rem/$(basename "$dump")" --json 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)['bytes'])" 2>/dev/null || echo -1)
    if [ "$local_size" = "$remote_size" ]; then
      echo "OK   $db -> $rem (verified $local_size bytes)" >> "$LOG"
    else
      echo "FAIL verify $db -> $rem (local=$local_size remote=$remote_size)" >> "$LOG"
      ok=0
    fi
  done

  if [ "$ok" = 1 ]; then
    rm -f "$dump"
    echo "OK   $db fully verified on both clouds, local dump deleted" >> "$LOG"
  else
    echo "KEPT local dump for $db (one or more clouds unverified): $dump" >> "$LOG"
  fi
done

# safety net: never let old dumps silently accumulate if a run partially fails
# repeatedly. Anything older than 3 days here means 3+ consecutive failures —
# surface it instead of quietly growing local disk.
old=$(find "$SCRATCH" -name "*.dump" -mtime +3 2>/dev/null)
[ -n "$old" ] && echo "WARN stale dumps >3 days old, investigate: $old" >> "$LOG"

echo "done $(date +%H:%M)" >> "$LOG"
