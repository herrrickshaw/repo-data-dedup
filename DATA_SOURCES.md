```markdown
# DATA_SOURCES

repo-data-dedup stores no third-party datasets. Its data are (A) metadata about the owner's own GitHub repositories and (B) operational logs. Section C is the reference catalogue of upstream sources that other repos collect (see SOP_DATA_SOURCES.md for the collector/home of each).

## A. audit/ (tracked)
| File | Publisher | Collection | Fields | Coverage | Refresh | Caveats |
|---|---|---|---|---|---|---|
| lfs_inventory.csv | GitHub (owner account) | `scripts/audit_lfs.py`: `--filter=blob:limit=2048` bare clones, parse LFS pointer files over full history | repo, path_at_head, lfs_sha256, size_bytes, at_head | 87 repos, 1,370 pointers, 12.58 GB (2026-07-22) | weekly cron (currently failing: `gh` HTTP 401; re-run `gh auth login`) | frozen 2026-07-22; pre-cleanup; must exclude private repos before publishing |
| repo_summary.csv | GitHub | same | repo, visibility, git_disk_kb, status, lfs_objects, lfs_bytes | 87 repos | same | contains 38 private repo names - filter |
| twin_verify.json | owner | `scripts/delete_archive_twins.sh` verification | per-twin content check | archive twins | one-off | - |
Licence: owner-authored metadata; add MIT. No third-party content.

## B. state/ (should be untracked)
Logs of cloud_backup, pg_cloud_backup, restore_drill, disk_guard, compress-local. Contain local paths and a personal e-mail; keep out of git.

## C. Upstream sources catalogued in SOP_DATA_SOURCES.md
| Source | Publisher | URL | Licence | Fields | Coverage | Refresh | Caveats | Method |
|---|---|---|---|---|---|---|---|---|
| NSE Bhavcopy | NSE India | nseindia.com archives | NSE terms (personal use; unverified) | EOD OHLCV, ISIN | all NSE equities | daily | ETFs/G-Secs not filtered by series | HTTP bulk download |
| Yahoo Finance via yfinance | Yahoo | n/a | Yahoo ToS, personal use | OHLCV, fundamentals | global | daily | rate limits, silent adjustments | API library |
| screener.in | Screener | screener.in | account ToS | 10y fundamentals | India | quarterly | quarterly-only operating profit | authenticated session |
| SEC EDGAR | US SEC | sec.gov | public domain; fair-access UA | XBRL facts | US | quarterly | declare User-Agent | REST |
| SSRI/FuelABC | SSR Innovation Lab | api.ssrinnovationlab.com | not stated | 107k outlets, lat/lon | India | monthly | duplicates; unreliable district | public API crawl |
| PNGRB / PPAC | Govt of India | pngrb.gov.in / ppac.gov.in | site terms | CGD authorisations; CNG counts | India | rare / monthly | PDF layout; clubbed GAs | PDF parse / xlsx |
| FAOSTAT | FAO | bulks-faostat.fao.org | CC BY 4.0 (verify) | prices, crop production | 7 countries | annual | - | bulk zip |
| NASA POWER | NASA | power.larc.nasa.gov | open (cite) | rainfall, temperature | 14 states | monthly | point not area | REST |
| NIRYAT / TradeStat | DGCI&S / Commerce | niryat.gov.in | GoI site terms | exports/imports by HS | India | monthly | TLS mismatch | open JSON |
| UN Comtrade preview | UN | comtradeapi.un.org | UN terms | trade by HS chapter | India | annual | 500-row cap | REST |
| TPEX / SGX | TPEX / SGX | per SOP | Taiwan GODL / none | listed codes | TW OTC, SG | monthly | undocumented endpoints | JSON |
| TAIC NZ | TAIC | taic.org.nz | NZ Crown copyright, acknowledge | maritime reports | NZ | on demand | - | HTML+PDF |

Failed/blocked (do not retry without new reason): WTO Timeseries (401), UNCTADstat bulk (403), TSB Canada (403), eands.dacnet.nic.in (DNS).
```
