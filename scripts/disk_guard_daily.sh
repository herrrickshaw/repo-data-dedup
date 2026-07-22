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

RC="/opt/homebrew/bin/rclone"
REMOTE="dropbox:market-data-backup"
LOG="$HOME/repos/repo-data-dedup/state/disk_guard.log"
ALERT="cd $HOME/market-pipeline/code/python_files && ./.venv/bin/python3 send_alert.py"
STAMP=$(date '+%Y-%m-%d %H:%M')

free_gb () { df -g / | awk 'NR==2 {print $4}'; }

echo "===== disk_guard $STAMP — free: $(free_gb) GB =====" >> "$LOG"

# ---- 1. daily incremental upload (delta-only after first full sync) ----
"$HOME/repos/repo-data-dedup/scripts/cloud_backup.sh" >> "$LOG" 2>&1

FREE=$(free_gb)
echo "post-upload free: ${FREE} GB" >> "$LOG"

# ---- 2. WARN tier: true caches only (never data) ----
if [ "$FREE" -lt 25 ]; then
  echo "WARN tier: clearing caches" >> "$LOG"
  /opt/homebrew/bin/brew cleanup --prune=7 >> "$LOG" 2>&1
  rm -rf "$HOME/Library/Caches/pip" 2>/dev/null
  # session scratchpads older than 7 days (never the live one)
  find /private/tmp/claude-501 -maxdepth 2 -type d -mtime +7 \
       -exec rm -rf {} + 2>/dev/null
  FREE=$(free_gb); echo "after cache clear: ${FREE} GB" >> "$LOG"
fi

# ---- 3. CRITICAL tier: verify-then-evict cloud-verified bundles ----
if [ "$FREE" -lt 15 ]; then
  echo "CRITICAL tier: verify-then-evict bundles" >> "$LOG"
  for f in "$HOME"/repos/branch-archives/*.bundle; do
    [ -e "$f" ] || continue
    name=$(basename "$f")
    if $RC check "$HOME/repos/branch-archives" \
         "$REMOTE/current/branch-archives" --one-way --include "$name" \
         >> "$LOG" 2>&1; then
      rm -f "$f"
      echo "EVICTED (cloud-verified): $name" >> "$LOG"
    else
      echo "KEPT (cloud copy NOT verified): $name" >> "$LOG"
    fi
    [ "$(free_gb)" -ge 15 ] && break
  done
  FREE=$(free_gb)
  eval "$ALERT \"disk guard CRITICAL: ${FREE}GB free after eviction — review state/disk_guard.log\"" >> "$LOG" 2>&1
fi

# ---- 4. EMERGENCY tier: pause flag + loud alert ----
if [ "$FREE" -lt 8 ]; then
  touch "$HOME/.pipeline_pause"
  echo "EMERGENCY: ~/.pipeline_pause created" >> "$LOG"
  eval "$ALERT \"disk guard EMERGENCY: only ${FREE}GB free — ~/.pipeline_pause set, data pipelines should halt. Free space manually.\"" >> "$LOG" 2>&1
else
  # auto-clear the flag once healthy again
  [ -f "$HOME/.pipeline_pause" ] && rm -f "$HOME/.pipeline_pause" \
    && echo "recovered: pause flag cleared" >> "$LOG"
fi

echo "done $(date '+%H:%M') — free: $(free_gb) GB" >> "$LOG"
