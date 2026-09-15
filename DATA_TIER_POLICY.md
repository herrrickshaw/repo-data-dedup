# Data Tier Policy

A decision framework for "should this data live on disk, in the cloud, compressed,
or nowhere" — distilled from a real, extended cleanup session that found (and fixed)
several genuine mistakes along the way. Read this before doing ad-hoc cleanup;
apply it with `cache_memory_cleaner.sh classify <path>` (see bottom) rather than
re-deriving the rules from scratch each time.

The classification is driven by two questions, asked in this order:

1. **Is this data reproducible, and from what?** (git+GitHub / a public source /
   nothing — genuinely irreplaceable)
2. **Is this data *actively read* by something that needs it in a specific form
   right now?** (a running pipeline, a live app's own sandbox, an MCP server's
   in-memory load, a human who needs to *see* the original document)

Everything else — size, age, file type — only decides *how* to protect it, not
*whether*.

---

## Tier 0 — Never touch programmatically

Data where the right action is either "do nothing" or "hand it to the human,"
never an automated `rm`/`mv`/`compress`.

| What | Why | Real example this session |
|---|---|---|
| A live app's own sandbox/VM state | Deleting it can break the app that's running *right now*, including this one | `Library/Application Support/Claude/vm_bundles/claudevm.bundle` (8.2GB) — has an active `vmIP`/`.cowork-adopted` marker |
| Scanned/signed/official documents (certificates, ID scans, tax filings, loan forms) | The PDF *is* the document — OCR text extraction loses seals, signatures, letterhead, and is not a legal substitute even when it "succeeds" | `Documents/personal-archive/dpiit certificate.pdf` — OCR extracted 1,027 chars, but that's not a usable certificate |
| Anything gated behind a GUI-only setting (selective sync, feature toggles) | No stable CLI/API exists; scripting it risks corrupting the vendor's own state tracking | Dropbox "Online Only" for Zotero (4.1GB fixed this way, but only via the Dropbox app); macOS Apple Intelligence models (13.88GB, only via System Settings) |
| A path another **currently running** process has open | Deleting out from under a live process risks a crash or silent data loss for unrelated work | Confirmed via a static `ps aux` snapshot + grep, never a live re-invoked `pgrep` (self-matches its own argv) |
| Files an active session (yours or another) is mid-write to | "Regrowth" isn't always garbage — check `pgrep`/`lsof` before assuming a dir is dormant | `lng-design-opensource`, `coal-to-urea-design-opensource` `.venv`s reappeared mid-session from another running session's work — compressed, not deleted |

**Rule of thumb:** if the action can't be verified safe by reading a file, and can
only be justified by "probably fine," it's Tier 0. Ask, or hand the exact command
to the human.

---

## Tier 1 — Permanent local, compress in place

Data something reads directly and needs *as a real file*, but which doesn't need
to be byte-for-byte on disk — HFS/APFS transparent compression (`decmpfs`) shrinks
it with **zero** workflow change: every reader gets the original bytes back
automatically, no unzip step anywhere in code.

**Decision test:** `grep` the codebase/scripts that touch this file. If something
opens it directly (sqlite3, `open()`, an interpreter import) rather than treating
it as a static blob to serve elsewhere, it's Tier 1, not Tier 3.

| What | Real example | Measured savings |
|---|---|---|
| Python venvs | 15 venvs across the machine | 7.1GB → 4.4GB (38%) |
| A knowledge-graph JSON a live MCP server loads | `.graphify/global-graph.json` | 123MB → 6.2MB (95%) — verified `json.load()` byte-identical after |
| A repo's own generated reports (CSV/Markdown) | `market-pipeline/.../reports/` | 60MB → 16MB (73%) |
| SQLite databases a script opens directly (not exported elsewhere) | `global_expansion_screener_framework/india_stocks_*.db` | 42MB → 21MB (50%), all 5 DBs confirmed queryable after |
| Reference data pulled once, read repeatedly | `market-pipeline/data/reference_data` (Damodaran tables) | 24MB → 7.4MB |

**Hazard already found and fixed:** don't confuse this with a same-named `.gz`
*export* sitting next to the raw file — `groww_data_pipeline.py` writes
`india_stocks_15y.db.gz` as a distribution artifact; every actual pipeline script
(`phase2_geographic_regression.py`, `phase4_live_screener.py`, etc.) reads the raw
`.db` directly. The `.gz` is not an interchangeable smaller copy of the same
working file — deleting the raw `.db` in favor of it would have broken five live
scripts. Compress the raw file instead (Tier 1), don't delete it in favor of its
export sibling.

**Tool:** `cache_memory_cleaner.sh compress-local <path> [<path>...]`
(needs `brew install afsctool` — `ditto --hfsCompression` looks like the built-in
answer but silently no-ops on non-Apple content on recent macOS).

**Automation:** a weekly cron (Sundays 03:00) re-applies this to the standing
candidate list, since venvs and generated reports regrow. Idempotent — re-running
on already-compressed content just re-verifies, doesn't redo work.

---

## Tier 2 — Cloud-backed, keep the local copy too

Active data that should be redundant across machine + cloud, with **no**
eviction — the local copy is the one actually in use day to day.

| What | Backup mechanism | Note |
|---|---|---|
| Git-tracked repos | GitHub (via normal `git push`) | Already redundant — do NOT also duplicate the whole working tree to Dropbox/GDrive; that's wasted space for zero extra safety |
| `~/Desktop`, `~/Documents` (incl. `personal-archive`) | `rclone copy` (not `sync`) to `dropbox:.../current/home-{desktop,documents}` | Registered in `~/.config/market-data/datasets.conf` so nightly `cloud_backup.sh` keeps it current automatically |
| Small, actively-referenced loose assets (e.g. blog post images) | One-off `rclone copy` to `.../one-off-archives/<name>` | `blog_images/` (13.8MB, 40 files) — backed up, kept local since the blog workflow needs it |

**Rule of thumb:** if you'd be upset to lose it AND you still open/edit it
regularly, it's Tier 2 — copy, don't move.

---

## Tier 3 — Archive to cloud, then evict locally

Data that's expensive or slow to lose, but genuinely **not** needed as a local
file day-to-day — a stale research pile, a raw pipeline cache that regenerates,
a one-off large discovery. This is where actual disk space gets reclaimed.

**Sequence, always, no exceptions:** tar/zstd → upload to *every* configured
remote → **byte-verify each one independently** (`rclone size`/`lsl`, compare to
local `stat`) → delete the local original **only if every remote verified** →
delete the local archive copy too. If any remote fails verification, keep both
local copies and say so — never partial-evict on a guess.

| What | Real example | Result |
|---|---|---|
| A pipeline's raw many-small-file cache (regenerates via its own fingerprint check) | `market-pipeline/market_cache/{nse_xbrl,ohlc,dart,intl_pit}` | 1.9GB → 83MB; the existing `archive_static()` fingerprint step in `cloud_backup.sh` already kept the *archive* current — the raw copy just hadn't been evicted after |
| A transient processing/staging pile | `research-toolkit/gdrive_stage` (438MB, extracted-PDF staging explicitly called out in its own README as not-a-corpus) | archived + evicted, 438MB freed |
| Reference material bundled with a repo but gitignored | `financial-analysis-toolkit/downloads/` (CFI/BIWS course PDFs) | 172MB freed |
| Orphaned git branches with no upstream | `vehicle_fuel_mileage` (no remote at all), 4 more across 3 repos | `git bundle` per repo, uploaded to both clouds |
| Converted documents where the source PDF isn't personal/scanned | 550 of 590 PDFs machine-wide | PDF → `.md` (pymupdf4llm, OCR fallback), original deleted only when >200 chars of real text extracted **and** the file didn't match a personal-document filename/path pattern |

**🔴 The one bug that actually lost data this session, and the fix:** never point
a Tier-3 upload at a cloud path some *other* job also mirrors with
`rclone sync --delete-excluded` from a local source. Four freshly-uploaded,
byte-verified archives were silently deleted hours later because
`cloud_backup.sh`'s `static-archives` dataset syncs `~/.backup-archives` →
`dropbox:.../static-archives`, and the archive-evict pattern's own logic (delete
the local copy right after upload) made the next sync treat those files as
"removed locally, so remove from remote too." Fix: one-off Tier-3 uploads go to
`.../one-off-archives/`, a path nothing else ever syncs into — never the same
folder a `datasets.conf` entry owns.

**Tool:** `cache_memory_cleaner.sh archive-evict <path> [name]` (set
`CLEANER_REMOTES` to space-separated `remote:path` destinations — never a
sync-managed one). Recurring datasets (the market_cache pattern) instead belong
in `~/.config/market-data/datasets.conf` + `cloud_backup.sh`'s `STATIC_SUBDIRS`,
which already does fingerprint-gated re-archival on its own schedule.

---

## Tier 4 — Delete immediately, no backup

Pure cache: reproducible from a package manager, a build step, or a URL, in
seconds to minutes, with no unique bytes anywhere.

| What | Regenerates via |
|---|---|
| Browser render/JS caches, app Cache/Code Cache | The app itself, next launch |
| `~/.npm`, `~/.cache/uv`, `~/Library/Caches/Homebrew`, `pip` cache | The package manager |
| `__pycache__`, `.pytest_cache`, `node_modules` (with a lockfile present) | `python`/`pip install -r requirements.txt`/`npm install` |
| A cask/formula whose `.app` was deleted by hand (ghost install) | `brew info --cask` shows the real app path is gone |
| A never-started VM/container disk allocation | `podman machine list` shows `Last Up: Never` |
| Redundant `git clone`s used only for read access (no unique commits, no unpushed branches) | `git clone` from the same GitHub remote, any time — but check `git log --branches --not --remotes` first; two of these clones had genuine unpushed work and were archived (Tier 3) instead of deleted |
| System log/diagnostic archives | macOS regenerates them; `sudo log erase --all` is the sanctioned way to force it (needs the human's password) |

**Tool:** `cache_memory_cleaner.sh clean-caches` / `clean-packages` / `git-gc`.

---

## Cross-cutting hazards (apply at every tier)

- **Git-tracked ≠ safe to delete from the working tree.** It means "recoverable
  from GitHub," not "not currently needed." Deleting a tracked file from an
  active repo's checkout just shows up as an uncommitted deletion — it doesn't
  free space until committed, and breaks the working tree meanwhile.
- **A directory being large and old doesn't make it Tier 3 or 4 by itself** —
  check what actually reads it first (`grep` the codebase, `lsof` the process
  table) before deciding it's dead weight.
- **Self-matching greps lie.** `ps aux | grep "$pattern"` in a loop matches its
  own argv. Snapshot `ps aux` once, then `grep` the static text.
- **`du -sh` on macOS reports logical size for HFS-compressed files correctly**,
  but a quick sanity check (`ls -la@`, or the tool's own `-v` summary) is worth
  it after a big compression pass.
- **Sudo-gated system data** (hibernation image, system-level `DiagnosticReports`,
  Spotlight index) gets the exact command handed to the human, never run
  automatically, even when the fix is a single line.
- **A concurrent process on the same machine is real evidence, not noise** — if
  disk usage keeps climbing faster than cleanup can free it, check `ps aux` for
  other active sessions before concluding cleanup "isn't working."

---

## Quick classification

```bash
cache_memory_cleaner.sh classify <path>
```

Walks the same decision tree as this document (git status, sync-managed
destination check, dormancy, live-process check, personal-document filename
patterns) and prints a recommended tier + the specific reason. It's a
recommendation, not an executor — nothing in `classify` deletes, moves, or
compresses anything.
