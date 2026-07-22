# repo-data-dedup — account-wide data redundancy reduction

[![Open In Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/herrrickshaw/repo-data-dedup/blob/main/notebooks/colab_test.ipynb)

The `herrrickshaw` account's GitHub **LFS budget is exhausted**: every LFS object
in every repo (including the `-archive-2026-07-17` backups) returns
*"This repository exceeded its LFS budget"* — 403 for everyone, public clones
included. This repo is the working space for fixing that permanently:
**audit → deduplicate → compress → eliminate LFS**.

## TL;DR from the first audit (2026-07-22)

**12.58 GB billed LFS storage; only ~4.3 GB is unique content referenced at HEAD;
a realistic end state is ~1–1.5 GB with zero LFS.**

- 3.67 GB — archive-twin repos re-storing every object (LFS is per-repo, not shared)
- 2.77 GB — history-only objects nothing references any more
- 1.81 GB — the same datasets living in multiple split repos
- 0.22 GB — one extraction stored in 4 formats side by side

Full findings: [`audit/AUDIT_2026-07-22.md`](audit/AUDIT_2026-07-22.md) ·
Remediation recipe: [`PLAYBOOK.md`](PLAYBOOK.md)

## Contents

| Path | What |
|---|---|
| `scripts/audit_lfs.py` | The audit tool — inventories every LFS pointer across all repos **without downloading LFS objects** (`--filter=blob:limit=2048` clones; pointer files are ~130 B blobs and always fetchable) |
| `audit/AUDIT_2026-07-22.md` | Findings + priority order |
| `audit/lfs_inventory.csv` | Every pointer: repo, path at HEAD, sha256, size, at-HEAD flag |
| `audit/repo_summary.csv` | Per-repo LFS object count and bytes |
| `PLAYBOOK.md` | Per-repo recipe to get off LFS safely (rescue → dedup → rewrite → verify → delete) |
| `SOP_DATA_SOURCES.md` | **Source catalogue**: every dataset's origin, collector, refresh cadence, gotchas |
| `scripts/distribute_data_access_docs.py` | Pushes a per-repo `DATA_ACCESS.md` (LFS status + re-collection path) into every LFS-bearing repo — idempotent, rerun after audits change |
| `scripts/refresh_audit.sh` | Weekly inventory refresh (cron Mon 08:45 local) — re-audits and commits updated CSVs here |

## Re-run the audit

```bash
python3 scripts/audit_lfs.py herrrickshaw /tmp/lfs_audit_clones
# writes lfs_inventory.csv + repo_summary.csv to cwd; needs gh auth, no LFS quota
```

## Ground rules for the cleanup

1. Nothing is deleted until its content is verified elsewhere (fresh temp clone +
   row-count/schema check) — see the playbook's verify step.
2. `global-market-data` (10.5y point-in-time OHLCV incl. delisted names) is rescued
   **first**; it is the only partly irreplaceable dataset in the account.
3. New repos never use LFS: one canonical format per dataset, gzip/parquet, files
   under 50 MB. Reference implementation: `cng-cgd-retail-outlet-mapping`.

## Standing automation

- **Weekly pointer-inventory refresh**: cron `45 8 * * 1` runs
  `scripts/refresh_audit.sh` → re-audits all repos, commits updated
  `audit/*.csv` + `audit/latest_totals.txt` here. Log: `state/cron.log`.
  If `audit/latest_totals.txt` goes stale by >1 week, check `crontab -l`.
- **Per-repo docs**: all 14 non-archive LFS-bearing repos carry a `DATA_ACCESS.md`
  (pushed 2026-07-22, including the three GitHub-archived repos, which were
  briefly unarchived for the commit and re-archived). Re-run the distributor
  after each audit if footprints change.
