# repo-data-dedup — account-wide data redundancy reduction

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
