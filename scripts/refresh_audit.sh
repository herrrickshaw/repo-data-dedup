#!/bin/bash
# Weekly LFS pointer-inventory refresh. Installed as cron (Mon 08:45):
#   45 8 * * 1 /Users/umashankar/repos/repo-data-dedup/scripts/refresh_audit.sh >> /Users/umashankar/repos/repo-data-dedup/state/cron.log 2>&1
set -euo pipefail
REPO="$HOME/repos/repo-data-dedup"
WORK="$(mktemp -d /tmp/lfs_audit.XXXXXX)"
DATE="$(date +%F)"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

cd "$WORK"
python3 "$REPO/scripts/audit_lfs.py" herrrickshaw "$WORK/clones" > audit.log

mkdir -p "$REPO/state"
cp lfs_inventory.csv "$REPO/audit/lfs_inventory.csv"
cp repo_summary.csv  "$REPO/audit/repo_summary.csv"
tail -4 audit.log > "$REPO/audit/latest_totals.txt"

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
rm -rf "$WORK"
