#!/usr/bin/env bash
# Daily upload + disk guard — keeps data cloud-safe and the disk out of the
# corruption zone (duckdb/parquet writes into a full disk = corrupted files
# and crashed pipelines).
#
# Order matters: UPLOAD FIRST, evict only what is verified in the cloud.
#
# Tiers (free space on /):
#   >= 25 GB  normal   — incremental Dropbox sync, log, done
#   <  25 GB  WARN     — + clear true caches (brew/pip/old session tmp)
#   <  15 GB  CRITICAL — + verify-then-evict branch-archive bundles
#                        (delete local ONLY if rclone check proves the
#                         Dropbox copy is byte-identical) + alert
#   <   8 GB  EMERGENCY— + touch ~/.pipeline_pause + loud alert.
#                        Data-writing pipelines should check this flag
#                        before big writes:  [ -f ~/.pipeline_pause ] && exit
#
# Cron: daily 20:30. Log: state/disk_guard.log
set -uo pipefail

# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

USAGE="Usage: scripts/disk_guard_daily.sh
Runs cloud_backup.sh, then clears caches / evicts cloud-verified bundles /
sets ~/.pipeline_pause depending on free space on /. Takes no arguments.
Log: $DEDUP_STATE_DIR/disk_guard.log"

# ── constants ────────────────────────────────────────────────────────────────
RC="$RCLONE_BIN"
REMOTE="$DROPBOX_BACKUP"
LOG="$DEDUP_STATE_DIR/disk_guard.log"
BACKUP_SCRIPT="$DEDUP_REPO/scripts/cloud_backup.sh"
ALERT_DIR="$HOME/market-pipeline/code/python_files"   # holds .venv + send_alert.py
BUNDLE_DIR="$HOME/repos/branch-archives"
PAUSE_FLAG="$HOME/.pipeline_pause"
SCRATCH_ROOT="/private/tmp/claude-501"                 # Claude session scratchpads
WARN_GB=25
CRITICAL_GB=15
EMERGENCY_GB=8
STAMP=$(date '+%Y-%m-%d %H:%M')

free_gb() { df -g / | awk 'NR==2 {print $4}'; }

send_alert() {  # send_alert <message> — via the pipeline venv; cwd change stays in the subshell
  (cd "$ALERT_DIR" && ./.venv/bin/python3 send_alert.py "$1")
}

# 1. daily incremental upload (delta-only after first full sync)
run_upload() {
  "$BACKUP_SCRIPT" >> "$LOG" 2>&1
  log_to "$LOG" "post-upload free: $(free_gb) GB"
}

# 2. WARN tier: true caches only (never data)
clear_caches() {
  log_to "$LOG" "WARN tier: clearing caches"
  /opt/homebrew/bin/brew cleanup --prune=7 >> "$LOG" 2>&1
  rm -rf "$HOME/Library/Caches/pip" 2>/dev/null
  # session scratchpads older than 7 days (never the live one)
  find "$SCRATCH_ROOT" -maxdepth 2 -type d -mtime +7 \
       -exec rm -rf {} + 2>/dev/null
  log_to "$LOG" "after cache clear: $(free_gb) GB"
}

# 3. CRITICAL tier: verify-then-evict cloud-verified bundles
evict_verified_bundles() {
  local f name
  log_to "$LOG" "CRITICAL tier: verify-then-evict bundles"
  for f in "$BUNDLE_DIR"/*.bundle; do
    [ -e "$f" ] || continue
    name=$(basename "$f")
    if "$RC" check "$BUNDLE_DIR" "$REMOTE/current/branch-archives" \
         --one-way --include "$name" >> "$LOG" 2>&1; then
      rm -f "$f"
      log_to "$LOG" "EVICTED (cloud-verified): $name"
    else
      log_to "$LOG" "KEPT (cloud copy NOT verified): $name"
    fi
    [ "$(free_gb)" -ge "$CRITICAL_GB" ] && break
  done
  send_alert "disk guard CRITICAL: $(free_gb)GB free after eviction — review state/disk_guard.log" >> "$LOG" 2>&1
}

# 4. EMERGENCY tier: pause flag + loud alert; auto-clear the flag once healthy again
set_or_clear_pause_flag() {  # set_or_clear_pause_flag <free_gb>
  if [ "$1" -lt "$EMERGENCY_GB" ]; then
    touch "$PAUSE_FLAG"
    log_to "$LOG" "EMERGENCY: ~/.pipeline_pause created"
    send_alert "disk guard EMERGENCY: only $1GB free — ~/.pipeline_pause set, data pipelines should halt. Free space manually." >> "$LOG" 2>&1
  else
    [ -f "$PAUSE_FLAG" ] && rm -f "$PAUSE_FLAG" \
      && log_to "$LOG" "recovered: pause flag cleared"
  fi
}

main() {
  usage_if_requested "$USAGE" "$@"
  local free
  log_to "$LOG" "===== disk_guard $STAMP — free: $(free_gb) GB ====="
  run_upload
  free=$(free_gb)
  if [ "$free" -lt "$WARN_GB" ]; then
    clear_caches
    free=$(free_gb)
  fi
  if [ "$free" -lt "$CRITICAL_GB" ]; then
    evict_verified_bundles
    free=$(free_gb)
  fi
  set_or_clear_pause_flag "$free"
  log_to "$LOG" "done $(date '+%H:%M') — free: $(free_gb) GB"
}

main "$@"
