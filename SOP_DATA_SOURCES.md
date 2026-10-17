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

## New verified sources 2026-10-17

Compiled read-only from the READMEs, collectors and `DATA_ACCESS` notes of the named repos
(none of those repos was modified). "Licence" is quoted from the repo where it states one;
otherwise it is marked *not recorded* and must be checked at the publisher before redistribution.

| Source | What | Endpoint | Licence | Cadence | Collector / home | Gotchas |
|---|---|---|---|---|---|---|
| FAOSTAT bulk | Producer prices (1991-2025, 91,334 rows) and crop area/production/yield (1961-2024, 140,295 rows) for IN CN BR US ID VN TH | `https://bulks-faostat.fao.org/production/` (e.g. `Prices_E_All_Data_(Normalized).zip`; also `Production_Crops_Livestock`) | not recorded in repo | annual; re-pull monthly | `agri-commodity-tracker` (`collectors/faostat_prices.py`, `faostat_crops.py`) | no key; crop production last updated Dec 2025 (data through 2024) |
| NASA POWER | Monthly rainfall (mm/day) and 2 m temperature, one point per state for 14 Indian agri states, 2015-2025 (3,696 rows) | `https://power.larc.nasa.gov/api/temporal/monthly/point` | not recorded in repo | monthly | `agri-commodity-tracker` (`collectors/nasa_power.py`) | no key; single coordinate per state, not a state average |
| NIRYAT bilateral | India exports/imports/balance by partner (16 countries), US$ mn, yearly + latest-year monthly | `https://niryat.gov.in/public/country/bilateralMonthlyDataPublic` (open JSON) | not recorded in repo | monthly (~2-month lag) | `india-trade-tracker` (`collectors/niryat_bilateral.py`) | TLS cert mismatch, so verification is disabled in the collector; no Chrome needed |
| NIRYAT HS8 | HS8 exports/imports by partner (CHE ARE USA DEU JPN), one FY, US$ mn; reconciles to TradeStat | `https://niryat.gov.in/public/country/getIndiaSupplyDataPublic` (open JSON) | not recorded in repo | monthly | `india-trade-tracker` (`collectors/niryat_hs8.py`) | same TLS caveat; see `reference_tradestat_niryat_programmatic_access` memory for token handling |
| UN Comtrade public preview | India world-total exports/imports by HS chapter, US$, 2020-2024 (India-reported) | `https://comtradeapi.un.org/public/v1/preview/C/A/HS?reporterCode=699...` | not recorded in repo | annual | `india-trade-tracker` (`collectors/comtrade_chapters.py`) | no key, but capped at 500 rows and 1 period per call, so loop per chapter/year |
| TPEX (Taipei Exchange, OTC) | Listed company codes, 4-digit, suffix `.TWO`; +893 tickers (TW 1,065 -> 1,958) | `https://www.tpex.org.tw/openapi/v1/mopsfin_t187ap03_O` | Taiwan Government Open Data License (data.gov.tw/license), attribution required | on demand / monthly | `global-ticker-universe` (`fetch_exchange_lists.py`) | endpoint intermittently truncates JSON; fetcher retries until it parses |
| SGX securities list | Stocks, REITs, business trusts, ETFs, suffix `.SI`; +683 tickers (SG 171 -> 854) | `https://api.sgx.com/securities/v1.1?excludetypes=bonds&params=nc,n,type,m,cur` | none published for this endpoint; codes/names only, check SGX terms before redistributing | on demand / monthly | `global-ticker-universe` (`fetch_exchange_lists.py`) | public endpoint behind sgx.com price pages, undocumented, may change; warrants/certificates/ADRs excluded |
| TAIC New Zealand | Maritime inquiry reports (final/interim PDFs) for the RAG corpus | listing `taic.org.nz/inquiries-recommendations?mode=3` | NZ Crown copyright; public information usable if used or quoted in context, with acknowledgement, not for legal proceedings | on demand | `ship2shore_rag` (`cli.py ingest --source taic`, `ingest/sources.py`) | not blocked by robots.txt; only inquiries with a report PDF are ingested; `--dry-run` previews |
| PPAC CGD network | CNG stations + PNG connections by state (31.01.2025 and 31.07.2026 blocks) | xlsx link discovered on `ppac.gov.in/natural-gas/city-gas-distribution-network` | not recorded in repo | monthly | `cng-cgd-retail-outlet-mapping` (`scripts/refresh_ppac_cng.py`) | PPAC has no outlet- or district-level CNG list; multi-state GAs are clubbed, so compare single-state rows only; SSRI `has_cng` overstates PPAC by ~23% (Delhi is the reverse) |

### Tried, failed (do not retry without a new reason)

| Source | Result | Reported by |
|---|---|---|
| WTO Timeseries API | HTTP 401, needs a subscription key | `india-trade-tracker` README |
| UNCTADstat bulk download | HTTP 403 to scripted clients | `india-trade-tracker` README |
| TSB Canada (marine investigation reports) | HTTP 403 to non-browser clients, including with a browser User-Agent | `ship2shore_rag` README |
| `eands.dacnet.nic.in` (DES agri statistics) | DNS does not resolve | `agri-commodity-tracker` README |

Other probes recorded in those READMEs, not in the request but useful: `www.data.gov.in/backend/dataapi` returned an edge error page from this host (agri-commodity-tracker); ATSB Australia failed with an HTTP/2 INTERNAL_ERROR; Germany BSU has no stated reuse licence and `Crawl-delay: 180`; Denmark DMAIB has no licence stated and loads lists dynamically (ship2shore_rag); the PNGRB GA-list PDF has no stable URL (cng-cgd-retail-outlet-mapping).

Not re-probed in this pass: the status above is as recorded by each repo on 2026-10-17, not re-tested from this repo.

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
