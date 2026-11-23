import csv
import json
import pathlib
import subprocess
import sys
import types

import pytest

REPO = pathlib.Path(__file__).resolve().parents[1]
SHA1, SHA2 = "a" * 64, "b" * 64


def pointer(sha, size):
    return f"version https://git-lfs.github.com/spec/v1\noid sha256:{sha}\nsize {size}\n"


class FakeGit:
    """Dispatches the git/gh calls audit_lfs.py makes."""

    def __init__(self, repos, blobs=None, tree=None, clone_fail=()):
        self.repos, self.blobs, self.tree, self.clone_fail = repos, blobs or {}, tree or {}, set(clone_fail)
        self.calls = []

    def __call__(self, args, cwd=None, capture_output=True, text=None, input=None):
        args = list(args)
        self.calls.append((args, cwd))
        ok = lambda out="", **k: types.SimpleNamespace(returncode=0, stdout=out, stderr="", **k)  # noqa: E731
        if args[0] == "gh":
            return ok(json.dumps(self.repos))
        if args[:2] == ["git", "clone"]:
            name = args[-1].rsplit("/", 1)[-1]
            if name in self.clone_fail:
                return types.SimpleNamespace(returncode=128, stdout="", stderr="fatal: not found " + "x" * 400)
            pathlib.Path(args[-1]).mkdir(parents=True, exist_ok=True)
            return ok()
        repo = pathlib.Path(cwd).name
        if args[:3] == ["git", "cat-file", "--batch-check=%(objectname) %(objecttype) %(objectsize)"]:
            lines = [f"{oid} blob {len(body)}" for oid, body in self.blobs.get(repo, {}).items()]
            lines.append("c0ffee commit 200")
            lines.append("bigblob blob 5000")
            return ok("\n".join(lines) + "\n")
        if args[:3] == ["git", "cat-file", "--batch"]:
            wanted = input.decode().split("\n")
            data = b""
            for oid in wanted:
                body = self.blobs[repo][oid].encode()
                data += f"{oid} blob {len(body)}\n".encode() + body + b"\n"
            return types.SimpleNamespace(returncode=0, stdout=data, stderr=b"")
        if args[:3] == ["git", "ls-tree", "-r"]:
            if repo in self.tree and self.tree[repo] is None:
                return types.SimpleNamespace(returncode=128, stdout="", stderr="fatal: bad HEAD")
            t = self.tree.get(repo, {})
            pairs = t.items() if isinstance(t, dict) else t
            return ok("".join(f"{o}|{p}\n" for o, p in pairs))
        raise AssertionError(args)


def run_script(monkeypatch, tmp_path, fake, argv=None):
    monkeypatch.setattr(subprocess, "run", fake)
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(sys, "argv", ["audit_lfs.py", *(argv if argv is not None else ["owner", str(tmp_path / "work")])])
    real = REPO / "scripts" / "audit_lfs.py"
    ns = {"__name__": "audit_lfs_under_test", "__file__": str(real)}
    exec(compile(real.read_text(encoding="utf-8"), str(real), "exec"), ns)
    return ns


def read(path):
    return list(csv.reader(open(path)))


REPOS = [{"name": "alpha", "diskUsage": 100, "visibility": "PUBLIC", "isFork": False},
         {"name": "beta", "diskUsage": 50, "visibility": "PRIVATE", "isFork": False},
         {"name": "gamma", "diskUsage": 5, "visibility": "PUBLIC", "isFork": False}]


def standard_fake(**kw):
    blobs = {"alpha": {"o1": pointer(SHA1, 4_000_000), "o2": pointer(SHA2, 1_000_000), "o3": "plain readme\n"},
             "beta": {"o4": pointer(SHA1, 4_000_000)}, "gamma": {}}
    tree = {"alpha": {"o1": "data/a.parquet", "o3": "README.md"}, "beta": {"o4": "copy/a.parquet"}}
    return FakeGit(REPOS, blobs, tree, **kw)


def test_inventory_and_summary_files(monkeypatch, tmp_path, capsys):
    ns = run_script(monkeypatch, tmp_path, standard_fake())
    inv = read(tmp_path / "lfs_inventory.csv")
    assert inv[0] == ["repo", "path_at_head", "lfs_sha256", "size_bytes", "at_head"]
    rows = inv[1:]
    assert [(r[0], r[1], r[3], r[4]) for r in rows] == [("alpha", "data/a.parquet", "4000000", "1"),
                                                         ("beta", "copy/a.parquet", "4000000", "1"),
                                                         ("alpha", "", "1000000", "0")]       # sorted by size desc; o2 is history-only
    summ = read(tmp_path / "repo_summary.csv")
    assert summ[0] == ["repo", "visibility", "git_disk_kb", "status", "lfs_objects", "lfs_bytes"]
    assert summ[1:] == [["alpha", "PUBLIC", "100", "ok", "2", "5000000"], ["beta", "PRIVATE", "50", "ok", "1", "4000000"],
                        ["gamma", "PUBLIC", "5", "ok", "0", "0"]]
    out = capsys.readouterr().out
    assert "3 repos" in out and "[1/3] alpha (100KB)" in out and "LFS objects: 2  bytes: 5,000,000" in out


def test_cross_repo_duplicate_accounting(monkeypatch, tmp_path, capsys):
    run_script(monkeypatch, tmp_path, standard_fake())
    out = capsys.readouterr().out
    # SHA1 (4 MB) lives in alpha and beta; SHA2 (1 MB) only in alpha
    assert "TOTAL stored across repos : 0.01 GB" in out          # 4+4+1 = 9 MB
    assert "TOTAL unique content      : 0.01 GB" in out          # 5 MB
    assert "cross-repo duplicate waste: 0.00 GB in 1 objects" in out


def test_clone_failure_recorded_and_skipped(monkeypatch, tmp_path, capsys):
    run_script(monkeypatch, tmp_path, standard_fake(clone_fail=["beta"]))
    summ = read(tmp_path / "repo_summary.csv")[1:]
    assert ["beta", "PRIVATE", "50", "CLONE_FAILED", "0", "0"] in summ
    assert "CLONE FAILED:" in capsys.readouterr().out
    assert {r[0] for r in read(tmp_path / "lfs_inventory.csv")[1:]} == {"alpha"}


def test_existing_clone_directory_is_reused(monkeypatch, tmp_path):
    (tmp_path / "work" / "gamma").mkdir(parents=True)
    fake = standard_fake()
    run_script(monkeypatch, tmp_path, fake)
    cloned = [a[-1] for a, _ in fake.calls if a[:2] == ["git", "clone"]]
    assert str(tmp_path / "work" / "gamma") not in cloned and len(cloned) == 2


def test_clone_command_is_a_partial_nocheckout_clone(monkeypatch, tmp_path):
    fake = standard_fake()
    run_script(monkeypatch, tmp_path, fake)
    clone = [a for a, _ in fake.calls if a[:2] == ["git", "clone"]][0]
    assert clone[:6] == ["git", "clone", "--filter=blob:limit=2048", "--no-checkout", "--quiet",
                         "https://github.com/owner/alpha.git"]
    gh = [a for a, _ in fake.calls if a[0] == "gh"][0]
    assert gh == ["gh", "repo", "list", "owner", "--limit", "200", "--json", "name,diskUsage,visibility,isFork"]


def test_defaults_when_no_arguments(monkeypatch, tmp_path):
    fake = FakeGit([])
    monkeypatch.setattr(pathlib.Path, "mkdir", lambda self, parents=False, exist_ok=False: None)
    ns = run_script(monkeypatch, tmp_path, fake, argv=[])
    assert ns["OWNER"] == "herrrickshaw" and str(ns["WORK"]) == "/tmp/lfs_audit"
    assert read(tmp_path / "repo_summary.csv") == [["repo", "visibility", "git_disk_kb", "status", "lfs_objects", "lfs_bytes"]]


def test_blobs_of_1024_bytes_or_more_are_not_parsed(monkeypatch, tmp_path):
    big = pointer(SHA1, 10) + "#" * 1100
    fake = FakeGit([REPOS[0]], {"alpha": {"o1": big, "o2": pointer(SHA2, 7)}}, {"alpha": {"o2": "p"}})
    run_script(monkeypatch, tmp_path, fake)
    assert [(r[2][:1], r[3]) for r in read(tmp_path / "lfs_inventory.csv")[1:]] == [("b", "7")]


def test_ls_tree_failure_leaves_paths_blank(monkeypatch, tmp_path):
    fake = FakeGit([REPOS[0]], {"alpha": {"o1": pointer(SHA1, 9)}}, {"alpha": None})
    run_script(monkeypatch, tmp_path, fake)
    assert read(tmp_path / "lfs_inventory.csv")[1] == ["alpha", "", SHA1, "9", "0"]


def test_same_lfs_object_twice_in_one_repo_counts_once(monkeypatch, tmp_path):
    fake = FakeGit([REPOS[0]], {"alpha": {"o1": pointer(SHA1, 9), "o2": pointer(SHA1, 9)}}, {"alpha": {"o1": "a", "o2": "b"}})
    run_script(monkeypatch, tmp_path, fake)
    assert read(tmp_path / "repo_summary.csv")[1] == ["alpha", "PUBLIC", "100", "ok", "1", "9"]
    assert len(read(tmp_path / "lfs_inventory.csv")) == 3


def test_sh_helper_raises_on_failure(monkeypatch, tmp_path):
    ns = run_script(monkeypatch, tmp_path, FakeGit([]))
    monkeypatch.setattr(subprocess, "run", lambda args, cwd, capture_output, text:
                        types.SimpleNamespace(returncode=1, stdout="", stderr="E" * 500))
    with pytest.raises(RuntimeError) as e:
        ns["sh"]("git", "x")
    assert len(str(e.value).split(": ", 1)[1]) == 300
    assert ns["sh"]("git", "x", check=False) == ""


@pytest.mark.parametrize("stdout", [b"no newline at all", b"short header\njunk", b""])
def test_malformed_batch_output_stops_parsing(monkeypatch, tmp_path, stdout):
    fake = FakeGit([REPOS[0]], {"alpha": {"o1": pointer(SHA1, 9)}}, {"alpha": {"o1": "p"}})
    orig = fake.__call__

    def broken(args, cwd=None, capture_output=True, text=None, input=None):
        if list(args)[:3] == ["git", "cat-file", "--batch"]:
            return types.SimpleNamespace(returncode=0, stdout=stdout, stderr=b"")
        return orig(args, cwd=cwd, capture_output=capture_output, text=text, input=input)

    run_script(monkeypatch, tmp_path, broken)
    assert read(tmp_path / "lfs_inventory.csv") == [["repo", "path_at_head", "lfs_sha256", "size_bytes", "at_head"]]


def test_blob_size_threshold_is_below_1024_bytes(monkeypatch, tmp_path):
    ptr = pointer(SHA1, 11)
    ptr2 = pointer(SHA2, 22)
    ok_blob = ptr + " " * (1023 - len(ptr))          # 1023 bytes: scanned
    edge_blob = ptr2 + " " * (1024 - len(ptr2))      # 1024 bytes: skipped
    assert len(ok_blob) == 1023 and len(edge_blob) == 1024
    fake = FakeGit([REPOS[0]], {"alpha": {"o1": ok_blob, "o2": edge_blob}}, {"alpha": {"o1": "a", "o2": "b"}})
    run_script(monkeypatch, tmp_path, fake)
    assert [r[3] for r in read(tmp_path / "lfs_inventory.csv")[1:]] == ["11"]


def test_first_path_wins_when_a_blob_appears_twice_at_head(monkeypatch, tmp_path):
    fake = FakeGit([REPOS[0]], {"alpha": {"o1": pointer(SHA1, 9)}}, {"alpha": [("o1", "first/path"), ("o1", "second/path")]})
    run_script(monkeypatch, tmp_path, fake)
    assert read(tmp_path / "lfs_inventory.csv")[1][1] == "first/path"


def test_gigabyte_totals(monkeypatch, tmp_path, capsys):
    blobs = {"alpha": {"o1": pointer(SHA1, 4_000_000_000), "o2": pointer(SHA2, 1_000_000_000)},
             "beta": {"o4": pointer(SHA1, 4_000_000_000)}}
    fake = FakeGit(REPOS[:2], blobs, {"alpha": {"o1": "a", "o2": "b"}, "beta": {"o4": "c"}})
    run_script(monkeypatch, tmp_path, fake)
    out = capsys.readouterr().out
    assert "TOTAL stored across repos : 9.00 GB" in out and "TOTAL unique content      : 5.00 GB" in out
    assert "cross-repo duplicate waste: 4.00 GB in 1 objects" in out
