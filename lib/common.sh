#!/usr/bin/env bash
# lib/common.sh — helpers shared by scripts/*.sh.  Source it, never execute it:
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
#
# Deliberately sets NO shell options. Each script keeps its own `set` line
# because they tolerate failure differently (cloud_backup.sh must keep going
# after a failed dataset; refresh_audit.sh must stop at the first error).
# Must stay bash 3.2 compatible (macOS /bin/bash): no `declare -A`, no mapfile.

[ -n "${DEDUP_COMMON_LOADED:-}" ] && return 0
DEDUP_COMMON_LOADED=1

# ── constants ────────────────────────────────────────────────────────────────
# The clone that cron runs from. Log files are written here by absolute path on
# purpose: the weekly maintenance job tails them by this exact location.
DEDUP_REPO="$HOME/repos/repo-data-dedup"
DEDUP_STATE_DIR="$DEDUP_REPO/state"
RCLONE_BIN="/opt/homebrew/bin/rclone"
GH_OWNER="herrrickshaw"
DROPBOX_BACKUP="dropbox:market-data-backup"
GDRIVE_BACKUP="googledrive:market-data-backup"

# ── timestamps (one format per helper; scripts pick the one they always used) ──
today()  { date +%Y-%m-%d; }             # 2026-07-22
now_hm() { date +%H:%M; }                # 20:30
now_ts() { date '+%Y-%m-%d %H:%M:%S'; }  # 2026-07-22 20:30:00

# ── logging ──────────────────────────────────────────────────────────────────
# log_to <file> <text...>  — append one line verbatim. Each script owns its own
# line format (OK/FAIL prefixes, [timestamp] brackets) so nothing is added here.
log_to() {
  local file=$1; shift
  printf '%s\n' "$*" >> "$file"
}

# warn <text...> — message to stderr, no exit.
warn() { printf '%s\n' "$*" >&2; }

# die <text...> — message to stderr, exit 1.
die() { warn "$@"; exit 1; }

# ── CLI ──────────────────────────────────────────────────────────────────────
# usage_if_requested <usage-text> "$@" — print usage and exit 0 on -h/--help.
# Only the first argument is inspected, so positional arguments keep working.
usage_if_requested() {
  local text=$1; shift
  case "${1:-}" in
    -h|--help) printf '%s\n' "$text"; exit 0 ;;
  esac
}
