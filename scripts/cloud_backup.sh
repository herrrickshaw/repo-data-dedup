#!/usr/bin/env bash
# Multi-provider replication of all durable market data.
#
# Policy (user decision 2026-07-22): NO paid LFS packs. Data must be secure
# and recoverable across THREE independent stores, actively synced:
#   local disk  <->  Dropbox (primary cloud, large files)  <->  Google Drive
# GitHub carries the regular-git copies (post-LFS migration) as the 4th leg.
#
# Layout on BOTH clouds (identical):
#   market-data-backup/current/<dataset>     live mirror
#   market-data-backup/versions/<date>/      superseded versions (append-only)
#   market-data-backup/history/              recovered deleted data (append-only)
#
# Cron: daily 20:30 via disk_guard_daily.sh. Log: state/cloud_backup.log
set -uo pipefail

DBX="dropbox:market-data-backup"
GDR="googledrive:market-data-backup"
STAMP=$(date +%Y-%m-%d)
LOG="$HOME/repos/repo-data-dedup/state/cloud_backup.log"
RC="/opt/homebrew/bin/rclone"
FLAGS=(--transfers 4 --timeout 60s --retries 3 --log-level ERROR)

echo "===== cloud_backup $STAMP $(date +%H:%M) -> dropbox + gdrive =====" >> "$LOG"

# ── account-level serialisation (2026-07-29) ─────────────────────────────────
# rclone rate limits are per-ACCOUNT, not per-destination. Two backup scripts
# exist — this one and the other cloud_backup.sh — writing to different Dropbox
# paths (market-data-archive vs market-data-backup) from the SAME source trees
# and the same Dropbox account. Any lock keyed by remote therefore never
# excluded the other: on 2026-07-28 both ran together and pipeline step [16]
# took 4h19m instead of minutes, with two rclones fighting for one account's
# throughput.
#
# This lock WAITS instead of exiting, which is the opposite of the daily_pipeline
# lock and deliberately so: a duplicate pipeline run is redundant work, but a
# skipped backup is lost coverage, and these two write to different destinations
# so both genuinely have to run. After 90 minutes it gives up waiting and
# proceeds anyway — a slow backup beats no backup, and a wedged peer must not be
# able to suppress this one indefinitely.
ACCT_LOCK="/tmp/cloud_backup.rclone-dropbox.lock"
ACCT_OWNED=0
_acct_waited=0
while :; do
  if mkdir "$ACCT_LOCK" 2>/dev/null; then
    ACCT_OWNED=1; echo $$ > "$ACCT_LOCK/pid"; break
  fi
  _acct_peer="$(cat "$ACCT_LOCK/pid" 2>/dev/null || true)"
  if [ -z "${_acct_peer:-}" ] || ! kill -0 "$_acct_peer" 2>/dev/null; then
    rm -rf "$ACCT_LOCK" 2>/dev/null; continue          # stale: owner is gone
  fi
  if [ "$_acct_waited" -ge 5400 ]; then
    echo "cloud_backup: waited 90m on $ACCT_LOCK (pid $_acct_peer) — proceeding concurrently" >> "$LOG"
    break
  fi
  [ "$_acct_waited" = 0 ] && echo "cloud_backup: waiting for rclone account lock (pid $_acct_peer)" >> "$LOG"
  sleep 30; _acct_waited=$((_acct_waited + 30))
done

trap '[ "$ACCT_OWNED" = 1 ] && rm -rf "$ACCT_LOCK" 2>/dev/null' EXIT


# ── static-subdir archive pattern (standard 2026-07-23) ──────────────────────
# Many-small-file subdirs that are STATIC or APPEND-ONLY upload catastrophically
# slowly (cloud throughput is per-file, not per-byte: 5,269 XBRL XMLs moved
# slower than a 3.5GB archive). Such subdirs are tar.zst'd into ~/.backup-archives
# (rebuilt only when their file-count:size fingerprint changes), EXCLUDED from
# their dataset's raw sync, and the archives dir syncs as its own dataset.
# To add one: append to STATIC_SUBDIRS and add its pattern in exclude_patterns_for.
#
# 🔴 market_cache/ohlc ADDED 2026-07-30, and it is NOT static or append-only —
# 7,571 of its 7,682 parquets (98.6%) are rewritten every day (new price bar per
# ticker). It qualifies for the SAME fix for a different reason: 7,682 individual
# files still trip Dropbox's per-request throttling regardless of how often they
# change (this repo's own log shows 2,705 "too_many_write_operations" errors
# syncing it raw, 4h for what should be minutes — the exact shape of the
# nse_xbrl/xml problem, just daily instead of append-only).
#
# That daily rewrite is exactly why the fingerprint below was widened to include
# max-mtime. file-count:size-KB alone can understate a rewritten directory: parquet
# compression means adding one day's row does not guarantee a size delta large
# enough to survive `du -sk`'s KB rounding, and a same-day re-run must not skip a
# real rebuild. mtime changes are unambiguous. This makes the check MORE correct
# for every entry (nse_xbrl/xml gets no less protection, since a genuinely static
# dir's mtimes do not move either — this is strictly additive) rather than adding
# a special case only for the new directory.
ARCH_ROOT="$HOME/.backup-archives"
STATIC_SUBDIRS=(
  "$HOME/market-pipeline/market_cache/nse_xbrl/xml|nse_xbrl-xml"
  "$HOME/market-pipeline/market_cache/ohlc|market_cache-ohlc"
)

archive_static () {
  local pair src name fp stamp old
  mkdir -p "$ARCH_ROOT"
  for pair in "${STATIC_SUBDIRS[@]}"; do
    src="${pair%%|*}"; name="${pair##*|}"
    [ -d "$src" ] || continue
    fp="$(find "$src" -type f | wc -l | tr -d ' '):$(du -sk "$src" | cut -f1):$(find "$src" -type f -exec stat -f '%m' {} + 2>/dev/null | sort -rn | head -1)"
    stamp="$ARCH_ROOT/$name.fingerprint"
    old="$(cat "$stamp" 2>/dev/null || true)"
    if [ "$fp" != "$old" ] || [ ! -f "$ARCH_ROOT/$name.tar.zst" ]; then
      tar --zstd -cf "$ARCH_ROOT/$name.tar.zst.tmp" \
          -C "$(dirname "$src")" "$(basename "$src")" \
        && mv "$ARCH_ROOT/$name.tar.zst.tmp" "$ARCH_ROOT/$name.tar.zst" \
        && echo "$fp" > "$stamp" \
        && echo "ARCH $name rebuilt ($fp)" >> "$LOG" \
        || echo "FAIL archive $name" >> "$LOG"
    fi
  done
}

exclude_patterns_for () {  # dataset name -> raw subdir patterns replaced by archives
  case "$1" in
    pipeline-market_cache) printf '%s\n' "/nse_xbrl/xml/**" "/ohlc/**" ;;
  esac
}

backup () {  # backup <local_dir> <name> <remote>
  local src=$1 name=$2 rem=$3 p
  [ -d "$src" ] || { echo "SKIP missing $src" >> "$LOG"; return; }
  local sync_x=() check_x=()
  for p in $(exclude_patterns_for "$name"); do
    sync_x+=(--exclude "$p"); check_x+=(--exclude "$p")
  done
  # --delete-excluded prunes raw copies of now-archived subdirs from the remote
  [ ${#sync_x[@]} -gt 0 ] && sync_x+=(--delete-excluded)
  $RC sync "$src" "$rem/current/$name" \
      --backup-dir "$rem/versions/$STAMP/$name" \
      ${sync_x[@]+"${sync_x[@]}"} \
      "${FLAGS[@]}" >> "$LOG" 2>&1 \
    && $RC check "$src" "$rem/current/$name" --one-way --size-only \
        ${check_x[@]+"${check_x[@]}"} \
        >> "$LOG" 2>&1 \
    && echo "OK   $name -> $rem" >> "$LOG" \
    || echo "FAIL $name -> $rem" >> "$LOG"
}

archive_static

DATASETS=(
  "$HOME/repos/global-market-data/warehouse|gmd-warehouse"
  "$HOME/repos/global-market-data/cache_seed|gmd-cache_seed"
  "$HOME/market-pipeline/code/python_files/cache_seed|pipeline-cache_seed"
  "$HOME/market-pipeline/code/python_files/reports|pipeline-reports"
  "$HOME/repos/branch-archives|branch-archives"
  # RETIRED 2026-07-23: ~/Downloads/market_cache (stale pre-move tree) evicted
  # locally after cloud verification (7,661 files matched). Its remote copy at
  # current/market_cache stays as an archival snapshot — do not re-add or prune.
  # "$HOME/Downloads/market_cache|market_cache"
  "$HOME/repos/global-stock-screener/cache_seed|gss-cache_seed"
  "$HOME/repos/india-trade-tracker/data|tracker-trade-data"
  "$HOME/repos/agri-commodity-tracker/data|tracker-agri-data"
  # added 2026-07-23 coverage audit — the LIVE market_cache (the Downloads one
  # above is the stale pre-move tree): nse_xbrl filing index+XMLs (the map that
  # cannot be reconstructed), Korea dart cache, CA history + board-meeting
  # intimations (the validated-claim source data), ohlc caches
  "$HOME/market-pipeline/market_cache|pipeline-market_cache"
  # bhavcopy_cache + dated scan outputs
  "$HOME/market-pipeline/data|pipeline-data"
  # recomputed 2026-07-23 correlation matrices — only copies (the 346MB
  # predecessor duckdb is LFS-locked in deleted working-files history)
  "$HOME/market-pipeline/code/python_files/correlation_scan|correlation-scan"
  # IUDX flood sensor archive (tiny, irreplaceable time series)
  "$HOME/iudx-flood-collector|iudx-flood-collector"
  # FULL MemPalace (user request 2026-07-23): live palace (5.9G) + damaged/
  # pre-rebuild snapshots (7.5G — the only fallback if the 07-17 rebuild ever
  # proves lossy). ~13G first upload per provider; embeddings (chroma) are
  # technically regenerable by re-mining but the mined content is not.
  "$HOME/.mempalace|mempalace"
  # single-file tar.zst archives of static many-small-file subdirs (see above)
  "$HOME/.backup-archives|static-archives"
)

for rem in "$DBX" "$GDR"; do
  for pair in "${DATASETS[@]}"; do
    backup "${pair%%|*}" "${pair##*|}" "$rem"
  done
done

# history/ is append-only: replicate dropbox's history tree to gdrive
$RC copy "$DBX/history" "$GDR/history" "${FLAGS[@]}" >> "$LOG" 2>&1 \
  && echo "OK   history -> gdrive (server-side relay)" >> "$LOG" \
  || echo "FAIL history -> gdrive" >> "$LOG"

echo "done $(date +%H:%M)" >> "$LOG"
tail -14 "$LOG"
