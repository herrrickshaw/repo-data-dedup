# SOP — data sources, re-collection, and refresh cadence

One page per question: *"the LFS copy is unreachable / stale — where does this data
actually come from, how do I re-collect it, and how often should it refresh?"*
Every LFS-bearing repo carries a `DATA_ACCESS.md` pointing here.

## Ground rules

1. **The collector script is the durable asset, not the dump.** Every dataset in
   every repo must have its collector committed alongside it; a dump without a
   collector is a liability (this is what made the LFS outage painful).
2. **One canonical home per dataset.** Other repos link to it; they do not copy it.
3. **No new LFS.** Tabular → parquet or `csv.gz`; geo → gzipped geojson; files
   < 50 MB (split by year/market if needed).
4. **Refresh = collector + cron/scheduled task, never by hand.** If it should stay
   current, it gets a schedule; if it has no schedule it is a dated snapshot and
   the filename says so (`*_20260722.*`).

## Source catalogue

| Source | What | Access | Cadence | Collector / home | Gotchas |
|---|---|---|---|---|---|
| NSE Bhavcopy | India EOD OHLCV, all equities | free bulk download, no auth | daily (post-close) | `global-market-data` | preferred over yfinance for bulk (2,681 stocks in hrs not days); ISIN prefix INE=equity — SctySrs does NOT filter ETFs/G-Secs |
| yfinance | Global OHLCV + fundamentals | free API | daily/weekly | `global-market-data`, app repos | never `or` two DataFrames; debtToEquity /100 if >10; India history = use bhavcopy instead |
| screener.in | India fundamentals, 10y dated history | account login (creds in `global-stock-screener/.env`) | quarterly (results seasons) | `global-stock-screener` (`screener_history_collector.py`) | "Operating Profit" exists ONLY in quarterly block — derive `ebit = PBT + interest`; 10y beats yfinance's 5y |
| SEC EDGAR | US point-in-time fundamentals | free API, throttled | quarterly | `global-stock-screener` | parallel-friendly; the US price panel two-file trap — use `global-stock-screener/ltm/US.parquet` (9,278 syms), NOT `global-market-data/ltm` (interrupted alphabetical) |
| SSRI / FuelABC | 107k India fuel retail outlets, lat/lon, CNG flags | public API, no auth (`api.ssrinnovationlab.com/api/petrol-pumps/pumps/`) | monthly or on demand (~6 min full crawl, 3 workers) | `cng-cgd-retail-outlet-mapping` (`scripts/crawl_ssri.py`) | DB has genuine duplicate rows (105k ids → 82.6k after name+addr+coord dedup); its `district` field unreliable — assign by point-in-polygon |
| PNGRB | CGD GA authorisations, entities, districts | public PDFs (pngrb.gov.in) | per bidding round (rare) | `cng-cgd-retail-outlet-mapping` (`scripts/parse_ga.py`) | PDF under-fills district columns for GAs 9.50/9.52–54; mixes district vintages (TS post-2016, AP pre-2022) |
| PPAC | petroleum/retail-outlet statistics | public site | monthly | cross-tally only | outlet counts by state/OMC for validation |
| Agmarknet (data.gov.in) | mandi prices | public sample API key works | daily, pull after 14:00 IST | `agri-commodity-tracker` (cron 14:30 installed) | |
| DGFT EIDB | India trade by HS code | Livewire = Selenium-only | monthly (15th, cron installed) | `india-trade-tracker` | validated FY24-25 |
| MoSPI / RBI / World Bank | CPI/WPI/IIP/GDP + macro | public APIs / rbi.org.in WSSView archive | monthly | `mospi-dataset-analysis` connector | NAS upstream 500s; RBI forex ~13mo stale — use WSSView archive (to 1998, no key) |
| JPX / FinanceDataReader / NASDAQ trader / Wikipedia | instrument lists (JP/KR/US/EU) | free downloads/scrape | daily at app startup | screener app `run_app.sh` | same-day cache, never store durably |
| udit-001/india-maps-data | India district boundaries (737, clean LGD names) | GitHub raw | static | `cng-cgd-retail-outlet-mapping` | datta07/INDIAN-SHAPEFILES rejected: diacritic corruption truncates Karnataka names |

## LFS usage policy (until fully retired)

- **Status 2026-07-22: account LFS budget exhausted — every `git lfs pull` in every
  repo 403s.** Do not add LFS objects anywhere; they would be born unreachable.
- Reading what's *in* LFS without quota: `git clone --filter=blob:limit=2048
  --no-checkout <url>` fetches all pointer files; parse with
  `repo-data-dedup/scripts/audit_lfs.py`.
- If a repo still uses LFS after cleanup (it shouldn't): document the budget owner,
  expected object count/size in its `DATA_ACCESS.md`, and clone with
  `GIT_LFS_SKIP_SMUDGE=1` by default.
- Migration recipe off LFS: `PLAYBOOK.md` in this repo.

## Keeping the pointer inventory fresh

`scripts/refresh_audit.sh` re-runs the account-wide audit and commits dated
CSVs + a delta note to this repo. Installed as a weekly cron (Mon 08:45 local).
If a week's entry is missing from `audit/`, the cron died — re-run by hand and
check `crontab -l`.
