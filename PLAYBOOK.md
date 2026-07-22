# Remediation playbook — getting repos off LFS without losing data

Goal state per repo: **zero LFS**, one canonical format per dataset, gzip/parquet
compression, every file a regular git object under GitHub's 100 MB hard limit.
`cng-cgd-retail-outlet-mapping` is the reference implementation of this recipe.

## Order of operations (per repo)

1. **Rescue content first.** LFS downloads are blocked while the budget is
   exhausted, so the bytes must come from somewhere else:
   - a local working copy (check `~/repos`, `~/Downloads/code`, old scratchpads)
   - `market-data-artifacts` (the designated backup repo — check before re-collecting)
   - re-collection from the original source (often faster than expected — the SSRI
     retail-outlet crawl is ~6 min; NSE bhavcopy, SEC EDGAR, screener.in all have
     documented collectors in their repos)
   - **temporarily raising the LFS budget for one billing cycle** to drain
     everything out is the fallback if unique content exists only in LFS.
2. **Deduplicate formats.** Keep ONE canonical format per dataset:
   - tabular → parquet (already compressed) or `csv.gz`
   - geo → one geojson (gzipped if >5 MB), never csv+json+geojson+js copies
   - drop `.js` data mirrors (`const DATA = …`) — generate them at build time
   - drop timestamped re-extractions; keep latest + the extraction script
3. **Rewrite or restart history:**
   - if history matters: `git lfs migrate export --include="*"` then
     `git filter-repo --strip-blobs-bigger-than 90M`; force-push
   - if history doesn't matter (data dumps): orphan commit —
     `git checkout --orphan clean && git commit && git push -f`
   - **untrack LFS**: remove `.gitattributes` filter lines *in the same commit*
     that adds the plain files, or the push re-uploads to LFS
4. **Delete the `-archive-2026-07-17` twin** once its source repo is verified clean
   (the archives were exact-copy insurance for the public flip; each one doubles
   LFS storage because LFS namespaces are per-repo, not shared).
5. **Verify before deleting anything**: fresh clone in a temp dir, row-count/schema
   checks against the old data, then and only then remove the old branch/repo.

## Gotchas (learned account-wide)

- `gh api repos/.../size` **excludes LFS** — a "0 MB" repo can hold GBs of LFS;
  never conclude a repo is empty from API size (see deep-10y false alarm).
- LFS pointer files survive any budget state — a `--filter=blob:limit=2048`
  clone inventories all of them without downloading a single object.
- On a fresh checkout after re-tracking, use `git add --renormalize` (plain
  `git add` misses clean-filter changes).
- Auto-mode may block `git push` to new public repos on secret-scan false
  positives — hand the push command to a human terminal instead of retrying.
- GitHub warns at 50 MB per file and rejects at 100 MB; keep gzipped chunks
  under 50 MB (split large parquet by year/market as needed).
- LFS **bandwidth** quota resets monthly; **storage** only drops when objects
  are deleted AND the repos referencing them are deleted or history-rewritten
  (dangling LFS objects still bill until GC on GitHub's side).
