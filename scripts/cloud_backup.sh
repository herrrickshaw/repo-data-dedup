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

backup () {  # backup <local_dir> <name> <remote>
  local src=$1 name=$2 rem=$3
  [ -d "$src" ] || { echo "SKIP missing $src" >> "$LOG"; return; }
  $RC sync "$src" "$rem/current/$name" \
      --backup-dir "$rem/versions/$STAMP/$name" \
      "${FLAGS[@]}" >> "$LOG" 2>&1 \
    && $RC check "$src" "$rem/current/$name" --one-way --size-only \
        >> "$LOG" 2>&1 \
    && echo "OK   $name -> $rem" >> "$LOG" \
    || echo "FAIL $name -> $rem" >> "$LOG"
}

DATASETS=(
  "$HOME/repos/global-market-data/warehouse|gmd-warehouse"
  "$HOME/repos/global-market-data/cache_seed|gmd-cache_seed"
  "$HOME/market-pipeline/code/python_files/cache_seed|pipeline-cache_seed"
  "$HOME/market-pipeline/code/python_files/reports|pipeline-reports"
  "$HOME/repos/branch-archives|branch-archives"
  "$HOME/Downloads/market_cache|market_cache"
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
