#!/usr/bin/env bash
# Characterisation smoke test for scripts/*.sh. Nothing here touches a real repo,
# cloud remote or disk: every case runs inside a throw-away $HOME with stub
# `df`, `rclone` and `pg_dump` on PATH, and never uses a deleting/moving mode.
#
#   tests/smoke.sh                 compare against tests/expected/
#   RECORD=1 tests/smoke.sh        (re)record expectations from the scripts under test
#   ROOT=/path/to/old/checkout RECORD=1 tests/smoke.sh   record from the pre-refactor tree
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${ROOT:-$(cd "$HERE/.." && pwd)}"
EXPECTED="$HERE/expected"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export GIT_CEILING_DIRECTORIES="$T"
pass=0; fail=0

ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

# ── sandbox: scripts copied to $HOME/repos/repo-data-dedup, stubs first on PATH ──
export HOME="$T/home"
SB="$HOME/repos/repo-data-dedup"
mkdir -p "$SB/state" "$SB/audit" "$T/bin"
cp -R "$ROOT/scripts" "$SB/scripts"
[ -d "$ROOT/lib" ] && cp -R "$ROOT/lib" "$SB/lib"

cat > "$T/bin/df" <<'STUB'
#!/bin/sh
printf 'Filesystem 1G-blocks Used Available Capacity Mounted\n/dev/x 500 100 400 20%% /\n'
STUB
cat > "$T/bin/rclone" <<'STUB'
#!/bin/sh
case "$1" in
  lsf) case "$*" in *--format*) printf '100;dir/a.txt\n200;b.txt\n0;empty.txt\n' ;;
                    *) printf 'x/db_1.sql.gz\n' ;; esac ;;
  copyto) mkdir -p "$(dirname "$3")"; echo data > "$3" ;;
  cat) printf x | gzip ;;
  *) exit 0 ;;
esac
STUB
printf '#!/bin/sh\nexit 1\n' > "$T/bin/pg_dump"
printf '#!/bin/sh\nexit 0\n' > "$SB/scripts/.cloud_backup_stub"
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"

normalise() {
  sed -E -e "s#$T#<T>#g" \
         -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}( [0-9]{2}:[0-9]{2}(:[0-9]{2})?)?/<TS>/g' \
         -e 's/[0-9]{2}:[0-9]{2}/<HM>/g' \
         -e 's#/tmp/restore_drill\.[A-Za-z0-9]+#<SCRATCH>#g' | LC_ALL=C sort
}

check() {  # check <name> <actual-file>
  if [ -n "${RECORD:-}" ]; then normalise < "$2" > "$EXPECTED/$1.txt"; ok "$1 (recorded)"
  elif normalise < "$2" | diff -u "$EXPECTED/$1.txt" - > "$T/diff.out"; then ok "$1"
  else bad "$1"; cat "$T/diff.out"; fi
}

# 1. syntax of every shell file
for f in "$ROOT"/scripts/*.sh "$ROOT"/lib/*.sh "$HERE"/smoke.sh; do
  [ -e "$f" ] || continue
  if bash -n "$f"; then ok "bash -n ${f#"$ROOT"/}"; else bad "bash -n ${f#"$ROOT"/}"; fi
done

# 2. --help prints usage and exits 0 (only meaningful on the refactored tree)
if [ -d "$ROOT/lib" ]; then
  for s in delete_archive_twins disk_guard_daily lfs_rescue_working_files pg_cloud_backup \
           cloud_backup refresh_audit restore_drill; do
    if "$SB/scripts/$s.sh" --help 2>&1 | grep -q '^Usage:'; then ok "--help $s"; else bad "--help $s"; fi
  done
fi

# 3. delete_archive_twins dry run (default and any non-"--run" argument)
"$SB/scripts/delete_archive_twins.sh" > "$T/o" 2>&1; echo "exit=$?" >> "$T/o"
check twins_dry "$T/o"
"$SB/scripts/delete_archive_twins.sh" bogus > "$T/o" 2>&1; echo "exit=$?" >> "$T/o"
check twins_dry_other_arg "$T/o"

# 4. disk_guard_daily, normal tier (stub df = 400 GB free; backup script stubbed)
cp "$SB/scripts/.cloud_backup_stub" "$SB/scripts/cloud_backup.sh"
"$SB/scripts/disk_guard_daily.sh" > "$T/o" 2>&1; echo "exit=$?" >> "$T/o"
cat "$SB/state/disk_guard.log" >> "$T/o"
check disk_guard_normal "$T/o"
cp "$ROOT/scripts/cloud_backup.sh" "$SB/scripts/cloud_backup.sh"

# 5. pg_cloud_backup with a failing pg_dump: logs FAIL per db, uploads nothing
"$SB/scripts/pg_cloud_backup.sh" > "$T/o" 2>&1; echo "exit=$?" >> "$T/o"
cat "$SB/state/pg_cloud_backup.log" >> "$T/o"
check pg_backup_dump_fails "$T/o"

# 6. lfs_rescue: pre-made empty clone => probe fails => "still blocked", exit 0
mkdir -p "$SB/state/wf-lfs-rescue-clone/.git"
"$SB/scripts/lfs_rescue_working_files.sh" > "$T/o" 2>&1; echo "exit=$?" >> "$T/o"
cat "$SB/state/wf_lfs_rescue.log" >> "$T/o"
check lfs_rescue_blocked "$T/o"
touch "$SB/state/wf_lfs_rescued.done"
"$SB/scripts/lfs_rescue_working_files.sh" > "$T/o" 2>&1; echo "exit=$?" >> "$T/o"
check lfs_rescue_done_marker "$T/o"

# 7. restore_drill against the stub remote (all PASS, exit 0)
"$SB/scripts/restore_drill.sh" 3 > "$T/o" 2>&1; echo "exit=$?" >> "$T/o"
cat "$SB/state/restore_drill.log" >> "$T/o"
check restore_drill_pass "$T/o"

# 8. cloud_backup aborts (exit 1, stderr message) when the dataset SSOT is empty
mkdir -p "$HOME/.config/market-data"
: > "$HOME/.config/market-data/datasets.py"
"$SB/scripts/cloud_backup.sh" > "$T/o" 2>&1; echo "exit=$?" >> "$T/o"
check cloud_backup_empty_ssot "$T/o"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
