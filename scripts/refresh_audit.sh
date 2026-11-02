#!/bin/bash
# Weekly LFS pointer-inventory refresh. Installed as cron (Mon 08:45):
#   45 8 * * 1 /Users/umashankar/repos/repo-data-dedup/scripts/refresh_audit.sh >> /Users/umashankar/repos/repo-data-dedup/state/cron.log 2>&1
set -euo pipefail

# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

USAGE="Usage: scripts/refresh_audit.sh
Re-runs audit_lfs.py for $GH_OWNER, copies the CSVs into audit/, and commits +
pushes to origin main when they changed. No arguments."

# ── constants ────────────────────────────────────────────────────────────────
REPO="$DEDUP_REPO"
WORK=""   # scratch dir, created in main
DATE="$(date +%F)"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

run_audit() {  # writes lfs_inventory.csv, repo_summary.csv, audit.log into $WORK
  cd "$WORK"
  python3 "$REPO/scripts/audit_lfs.py" "$GH_OWNER" "$WORK/clones" > audit.log
}

publish_results() {
  mkdir -p "$REPO/state"
  cp lfs_inventory.csv "$REPO/audit/lfs_inventory.csv"
  cp repo_summary.csv  "$REPO/audit/repo_summary.csv"
  tail -4 audit.log > "$REPO/audit/latest_totals.txt"
}

commit_if_changed() {
  cd "$REPO"
  if ! git diff --quiet -- audit/; then
    git add audit/
    git -c user.name="lfs-audit-cron" -c user.email="noreply@local" \
        commit -q -m "audit refresh $DATE ($(tail -3 audit/latest_totals.txt | head -1))"
    git push -q origin main
    echo "$DATE refreshed + pushed"
  else
    echo "$DATE no change"
  fi
}

main() {
  usage_if_requested "$USAGE" "$@"
  WORK="$(mktemp -d /tmp/lfs_audit.XXXXXX)"
  run_audit
  publish_results
  commit_if_changed
  rm -rf "$WORK"
}

main "$@"
