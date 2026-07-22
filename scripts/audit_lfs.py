#!/usr/bin/env python3
"""Account-wide LFS/storage redundancy audit — no LFS downloads needed.

For every repo: a --filter=blob:limit=2048 clone (full history, no checkout)
pulls all trees/commits and only blobs <=2KB — which includes every LFS pointer
file ever committed. Parse pointers -> (sha256 oid, size), map to paths at HEAD,
and aggregate duplicates within and across repos.

Usage: python3 audit_lfs.py <owner> <workdir>
Writes: lfs_inventory.csv, repo_summary.csv (into cwd)
"""
import csv
import json
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

OWNER = sys.argv[1] if len(sys.argv) > 1 else "herrrickshaw"
WORK = Path(sys.argv[2] if len(sys.argv) > 2 else "/tmp/lfs_audit")
WORK.mkdir(parents=True, exist_ok=True)

def sh(*args, cwd=None, check=True):
    r = subprocess.run(args, cwd=cwd, capture_output=True, text=True)
    if check and r.returncode != 0:
        raise RuntimeError(f"{args}: {r.stderr[:300]}")
    return r.stdout

repos = json.loads(sh("gh", "repo", "list", OWNER, "--limit", "200",
                      "--json", "name,diskUsage,visibility,isFork"))
print(f"{len(repos)} repos")

PTR_RE = re.compile(r"^version https://git-lfs\.github\.com/spec/v1\n"
                    r"oid sha256:([0-9a-f]{64})\n"
                    r"size (\d+)", re.M)

inv_rows = []      # repo, path_at_head, oid, size, at_head
repo_rows = []

for i, r in enumerate(repos, 1):
    name = r["name"]
    dest = WORK / name
    print(f"[{i}/{len(repos)}] {name} ({r['diskUsage']}KB)", flush=True)
    if not dest.exists():
        try:
            sh("git", "clone", "--filter=blob:limit=2048", "--no-checkout", "--quiet",
               f"https://github.com/{OWNER}/{name}.git", str(dest))
        except RuntimeError as e:
            print(f"  CLONE FAILED: {e}")
            repo_rows.append([name, r["visibility"], r["diskUsage"], "CLONE_FAILED", 0, 0])
            continue

    # every local blob (<=2KB by filter); find LFS pointers among them
    out = sh("git", "cat-file", "--batch-check=%(objectname) %(objecttype) %(objectsize)",
             "--batch-all-objects", cwd=dest)
    small_blobs = [ln.split()[0] for ln in out.splitlines()
                   if ln.split()[1:2] == ["blob"] and int(ln.split()[2]) < 1024]

    pointers = {}   # git blob oid -> (lfs sha256, size)
    if small_blobs:
        proc = subprocess.run(["git", "cat-file", "--batch"], cwd=dest,
                              input="\n".join(small_blobs).encode(),
                              capture_output=True)
        data = proc.stdout
        idx = 0
        while idx < len(data):
            nl = data.find(b"\n", idx)
            if nl < 0:
                break
            hdr = data[idx:nl].split()
            if len(hdr) < 3:
                break
            oid, _typ, size = hdr[0].decode(), hdr[1], int(hdr[2])
            body = data[nl + 1: nl + 1 + size].decode("utf-8", "ignore")
            m = PTR_RE.search(body)
            if m:
                pointers[oid] = (m.group(1), int(m.group(2)))
            idx = nl + 1 + size + 1

    # map to paths at HEAD
    head_paths = {}   # git oid -> path
    try:
        for ln in sh("git", "ls-tree", "-r", "HEAD",
                     "--format=%(objectname)|%(path)", cwd=dest).splitlines():
            o, p = ln.split("|", 1)
            head_paths.setdefault(o, p)
    except RuntimeError:
        pass

    uniq_lfs = {}    # sha256 -> size
    for goid, (sha, size) in pointers.items():
        uniq_lfs[sha] = size
        inv_rows.append([name, head_paths.get(goid, ""), sha, size,
                         1 if goid in head_paths else 0])

    total = sum(uniq_lfs.values())
    repo_rows.append([name, r["visibility"], r["diskUsage"], "ok",
                      len(uniq_lfs), total])
    print(f"  LFS objects: {len(uniq_lfs)}  bytes: {total:,}")

with open("lfs_inventory.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["repo", "path_at_head", "lfs_sha256", "size_bytes", "at_head"])
    w.writerows(sorted(inv_rows, key=lambda x: -x[3]))

with open("repo_summary.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["repo", "visibility", "git_disk_kb", "status", "lfs_objects", "lfs_bytes"])
    w.writerows(sorted(repo_rows, key=lambda x: -x[5]))

# aggregate
sizes = {}
owners = defaultdict(set)
for repo, path, sha, size, at_head in inv_rows:
    sizes[sha] = size
    owners[sha].add(repo)
total_stored = sum(sizes[s] * len(owners[s]) for s in sizes)      # per-repo namespaces
total_unique = sum(sizes.values())
cross = {s: o for s, o in owners.items() if len(o) > 1}
cross_waste = sum(sizes[s] * (len(o) - 1) for s, o in cross.items())
print(f"\nTOTAL stored across repos : {total_stored/1e9:.2f} GB")
print(f"TOTAL unique content      : {total_unique/1e9:.2f} GB")
print(f"cross-repo duplicate waste: {cross_waste/1e9:.2f} GB in {len(cross)} objects")
