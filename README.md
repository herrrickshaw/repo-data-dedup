# repo-data-dedup — account-wide data redundancy reduction

Working space and tooling for getting the `herrrickshaw` GitHub account off LFS: an audit tool that
inventories every LFS pointer across all repos without downloading LFS objects, a remediation
playbook, and the shell scripts that run the cloud backup / disk-guard / verify-then-delete chores
around it. Outputs are CSV inventories under `audit/`, findings in `audit/AUDIT_2026-07-22.md`, and
logs under `state/`.

> Status: maintained (scripts run from cron on the owner's Mac). Personal infrastructure, not a
> general-purpose tool; several scripts hard-code the owner's paths and rclone remotes.

New here? See [How to use this repo with AI](HOW_TO_USE_WITH_AI.md).
[![Open In Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/herrrickshaw/repo-data-dedup/blob/main/notebooks/colab_test.ipynb)

## What it does
- Audits LFS pointers for every repo (path at HEAD, sha256, size) using `--filter=blob:limit=2048` clones.
- Refreshes that inventory weekly and commits the CSVs here.
- Replicates durable datasets to Dropbox and Google Drive (`cloud_backup.sh`) and dumps Postgres nightly (`pg_cloud_backup.sh`).
- Guards free disk space: uploads first, then evicts only what `rclone check` proves is in the cloud.
- Deletes the 35 `-archive-2026-07-17` twin repos (dry run by default).
- Runs a monthly tested-restore drill and a retry-until-unblocked rescue of `working-files` LFS payloads.

## Why (first audit, 2026-07-22)
The account's LFS budget is **exhausted**: every LFS object in every repo (including the
`-archive-2026-07-17` backups) returns *"This repository exceeded its LFS budget"* — 403 for everyone,
public clones included. 12.58 GB billed LFS storage; only ~4.3 GB is unique content referenced at HEAD;
a realistic end state is ~1–1.5 GB with zero LFS.

- 3.67 GB — archive-twin repos re-storing every object (LFS is per-repo, not shared)
- 2.77 GB — history-only objects nothing references any more
- 1.81 GB — the same datasets living in multiple split repos
- 0.22 GB — one extraction stored in 4 formats side by side

## Quick start
```bash
git clone https://github.com/herrrickshaw/repo-data-dedup.git && cd repo-data-dedup
python3 scripts/audit_lfs.py herrrickshaw /tmp/lfs_audit_clones   # needs `gh auth`; no LFS quota used
# writes lfs_inventory.csv + repo_summary.csv into the current directory
```

## How it works
| Stage | Script | Output |
|---|---|---|
| Inventory | `scripts/audit_lfs.py` | `audit/lfs_inventory.csv`, `audit/repo_summary.csv` |
| Weekly refresh | `scripts/refresh_audit.sh` (cron Mon 08:45) | commits `audit/*.csv` + `audit/latest_totals.txt`; log `state/cron.log` |
| Per-repo docs | `scripts/distribute_data_access_docs.py` | `DATA_ACCESS.md` pushed into every LFS-bearing repo (idempotent) |
| Cloud backup | `scripts/cloud_backup.sh` | `sync` + `check` to Dropbox and Drive; log `state/cloud_backup.log` |
| Disk guard | `scripts/disk_guard_daily.sh` (cron 20:30) | calls the backup first; tiers WARN <25 GB, CRITICAL <15 GB, EMERGENCY <8 GB (`~/.pipeline_pause`) |
| Postgres backup | `scripts/pg_cloud_backup.sh` (cron 20:00) | dump → both clouds → size-verify → delete local dump only if both verified |
| Restore drill | `scripts/restore_drill.sh [N]` (monthly) | PASS/FAIL per sampled file; exit 1 on any failure |
| LFS rescue | `scripts/lfs_rescue_working_files.sh` (cron) | probes until reads unblock, then archives all payloads and writes `state/wf_lfs_rescued.done` |
| Twin deletion | `scripts/delete_archive_twins.sh [--run]` | dry run unless `--run`; needs `gh auth refresh -h github.com -s delete_repo` |

Shared constants and helpers (repo path, rclone binary, remotes, timestamps, `log_to`/`warn`/`die`,
`--help`) live in `lib/common.sh`. It sets **no** shell options: `cloud_backup.sh` must keep going after
a failed dataset (`set -uo pipefail`), `refresh_audit.sh` and `delete_archive_twins.sh` must stop at the
first error (`set -euo pipefail`). Everything stays bash 3.2 compatible (macOS `/bin/bash`).

## Repository layout
| Path | Purpose |
|---|---|
| `scripts/` | audit tool, backup / guard / restore scripts (see above) |
| `lib/common.sh` | shared constants and helpers, sourced by `scripts/*.sh` |
| `tests/smoke.sh`, `tests/expected/` | sandboxed characterisation test (recorded from the pre-refactor scripts) |
| `audit/` | findings (`AUDIT_2026-07-22.md`), `lfs_inventory.csv`, `repo_summary.csv`, `latest_totals.txt` |
| `PLAYBOOK.md` | per-repo recipe: rescue → dedup → rewrite → verify → delete |
| `SOP_DATA_SOURCES.md` | source catalogue: every dataset's origin, collector, refresh cadence, gotchas |
| `DATA_TIER_POLICY.md` | decision framework: disk vs cloud vs compressed vs delete |
| `state/` | run logs (committed by a maintenance job) |

## Configuration
No environment variables. Paths and remotes are constants in `lib/common.sh` and at the top of each
script: clone at `~/repos/repo-data-dedup`, `/opt/homebrew/bin/rclone`, remotes `dropbox:market-data-backup`
and `googledrive:market-data-backup`, dataset list from `~/.config/market-data/datasets.conf`
(read via `datasets.py`). No secrets are stored here; auth comes from `gh` and the local rclone config.

## Testing
```bash
tests/smoke.sh        # bash -n, --help, and sandboxed runs diffed against tests/expected/
```
Runs inside a throw-away `$HOME` with stub `df`/`rclone`/`pg_dump`; never uses `--run` or any
deleting path. CI (`.github/workflows/ci.yml`) runs the same plus `shellcheck -S error`.

## Ground rules for the cleanup
1. Nothing is deleted until its content is verified elsewhere (fresh temp clone + row-count/schema check) — see the playbook's verify step.
2. **Only deleting a repo frees its LFS storage quota** — removing files, rewriting history or removing LFS tracking does not. Billing is per repo and recalculated lazily.
3. `global-market-data` (10.5y point-in-time OHLCV incl. delisted names) is rescued **first**; it is the only partly irreplaceable dataset in the account.
4. New repos never use LFS: one canonical format per dataset, gzip/parquet, files under 50 MB. Reference implementation: `cng-cgd-retail-outlet-mapping`.
5. Every rescue/dedup/rewrite/push step operates on one specific nested repo clone — always `cd` into that exact clone before any broad `git` command (`add -A`, filter-branch, etc.). After a history rewrite + push, confirm it landed on the intended remote (`git ls-remote <remote>`) rather than trusting "Everything up-to-date."

## Limitations and known issues
- Hard-coded owner paths (`~/repos/...`, `~/market-pipeline/...`) and rclone remotes; not portable as is.
- `delete_archive_twins.sh --run` is irreversible and intentionally not run by automation.
- `cloud_backup.sh` waits up to 90 minutes on a shared rclone account lock, then proceeds anyway.
- `refresh_audit.sh` commits and pushes to `origin main`; if `audit/latest_totals.txt` is >1 week stale, check `crontab -l`.
- All 14 non-archive LFS-bearing repos carry a `DATA_ACCESS.md` (pushed 2026-07-22, including the three archived repos, briefly unarchived for the commit). Re-run the distributor after audits change footprints.

## Licence
No licence file yet — all rights reserved.
