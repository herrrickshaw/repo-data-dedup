#!/usr/bin/env python3
"""Push a DATA_ACCESS.md into every non-archive repo that carries LFS objects.

Reads audit/repo_summary.csv, renders a per-repo doc (audit numbers + repo-specific
re-collection notes), and creates/updates the file via the GitHub contents API.
Idempotent: skips a repo when the rendered content is already there.
"""
import base64
import csv
import json
import subprocess
import sys
from pathlib import Path

OWNER = "herrrickshaw"
HERE = Path(__file__).resolve().parent.parent

# repo-specific "where the data actually lives / how to re-collect" notes
NOTES = {
    "global-market-data": (
        "**Rescue-first repo — partly irreplaceable.** 10.5y point-in-time OHLCV "
        "including 964 delisted names. Primary local copy: `~/repos/global-market-data/"
        "cache_seed/ltm/*.parquet` — verify completeness before trusting. Re-collection "
        "covers only listed names (NSE Bhavcopy archive); delisted history cannot be "
        "re-collected. Raw Close not Adj Close — splits fake illiquid premiums."),
    "global-stock-screener": (
        "India 10y dated fundamentals via `screener_history_collector.py` (creds in "
        "`.env`); US point-in-time via SEC EDGAR. US price panel: use THIS repo's "
        "`ltm/US.parquet` (9,278 symbols) — the global-market-data one is an "
        "interrupted alphabetical collection."),
    "fuel-retail-outlets": (
        "Fully re-collectable in ~6 min: public SSRI API crawl — see "
        "`cng-cgd-retail-outlet-mapping/scripts/crawl_ssri.py` (105k records, "
        "content-dedupe to ~82.6k; SSRI DB itself contains duplicate rows). A fresh "
        "2026-07-22 snapshot already lives in `cng-cgd-retail-outlet-mapping/data/`."),
    "market-data-artifacts": (
        "This is the designated backup repo for dvm/fundamentals/edgar caches — "
        "ironically LFS-locked itself. Contents overlap `global-stock-screener`; "
        "check there first."),
    "market-screener-backtests": (
        "Backtest result artifacts — regenerable by re-running the backtests in this "
        "repo against `global-market-data`/`global-stock-screener` inputs."),
    "global-market-research-platform": (
        "Largest LFS holder (3.56 GB, of which 1.97 GB history-only dead weight). "
        "Data overlaps global-market-data + screener caches; treat as derived, "
        "dedupe against the canonical homes before rescuing anything."),
    "working-files": (
        "1.42 GB LFS, 0.74 GB history-only. By name and content this is scratch "
        "material — triage: promote anything canonical to its dataset's home repo, "
        "let the rest go with the history rewrite."),
    "stock-screener-platform": (
        "LFS content is byte-identical with `ocaml-stock-screener` (repo split). "
        "One canonical home will be chosen during cleanup; don't add data here."),
    "ocaml-stock-screener": (
        "LFS content is byte-identical with `stock-screener-platform` (repo split). "
        "One canonical home will be chosen during cleanup; don't add data here."),
    "event-driven-stock-analysis": (
        "45 MB of deployment/data artifacts; regenerable from the pipeline in-repo."),
    "BazaarTalks": (
        "11.6 MB — ticker dashboard caches; regenerable from live Trendlyne/"
        "Screener.in fetchers in-repo. Durable backups: `market-data-artifacts`."),
    "global-market-scanners": (
        "2 MB — scan outputs, regenerable by re-running the scanners."),
    "agri-commodity-tracker": (
        "1.9 MB — Agmarknet mandi daily pulls; re-collectable via the repo's own "
        "collector (data.gov.in public key, pull after 14:00 IST; daily 14:30 cron)."),
    "india-trade-tracker": (
        "1.1 MB — DGFT EIDB extracts (Livewire is Selenium-only); monthly cron on "
        "the 15th re-collects."),
}

TEMPLATE = """# DATA_ACCESS — how to get this repo's data

> ⚠️ **Git LFS in this repo is currently unreachable** — the account's LFS budget
> is exhausted, so `git clone` / `git lfs pull` cannot download the data files
> (they arrive as ~130-byte pointer stubs). This is account-wide, not specific to
> this repo. Clone with `GIT_LFS_SKIP_SMUDGE=1 git clone …` to avoid errors.

## This repo's LFS footprint (audit 2026-07-22)

| LFS objects | Total size |
|---|---|
| {objects} | {size_mb:,.1f} MB |

## Where the data actually comes from

{notes}

## Account-wide context

- Full pointer inventory, dedup plan and audit tooling:
  [`{owner}/repo-data-dedup`](https://github.com/{owner}/repo-data-dedup)
- Source catalogue + re-collection SOP for every dataset:
  [`SOP_DATA_SOURCES.md`](https://github.com/{owner}/repo-data-dedup/blob/main/SOP_DATA_SOURCES.md)
- Migration recipe off LFS:
  [`PLAYBOOK.md`](https://github.com/{owner}/repo-data-dedup/blob/main/PLAYBOOK.md)
- **Policy: do not add new LFS objects** — they would be born unreachable. New data
  goes in as gzipped/parquet regular git objects under 50 MB, one canonical format,
  with its collector script committed alongside.
"""


def gh(*args, input_bytes=None):
    r = subprocess.run(["gh"] + list(args), capture_output=True, input=input_bytes)
    return r.returncode, r.stdout.decode(), r.stderr.decode()


def main():
    rows = list(csv.DictReader(open(HERE / "audit" / "repo_summary.csv")))
    targets = [r for r in rows if int(r["lfs_objects"]) > 0
               and "archive-2026-07-17" not in r["repo"]]
    print(f"{len(targets)} target repos")
    for r in targets:
        name = r["repo"]
        body = TEMPLATE.format(
            objects=r["lfs_objects"], size_mb=int(r["lfs_bytes"]) / 1e6,
            notes=NOTES.get(name, "See the source catalogue in the SOP linked below."),
            owner=OWNER)
        # existing file? (need sha to update; skip if identical)
        code, out, _ = gh("api", f"repos/{OWNER}/{name}/contents/DATA_ACCESS.md")
        sha = None
        if code == 0:
            j = json.loads(out)
            sha = j["sha"]
            existing = base64.b64decode(j["content"]).decode()
            if existing == body:
                print(f"  {name}: up to date")
                continue
        payload = {"message": "docs: DATA_ACCESS — LFS status, re-collection path, no-new-LFS policy\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>",
                   "content": base64.b64encode(body.encode()).decode()}
        if sha:
            payload["sha"] = sha
        code, out, err = gh("api", "-X", "PUT",
                            f"repos/{OWNER}/{name}/contents/DATA_ACCESS.md",
                            "--input", "-", input_bytes=json.dumps(payload).encode())
        print(f"  {name}: {'OK' if code == 0 else 'FAILED ' + err[:120]}")


if __name__ == "__main__":
    main()
