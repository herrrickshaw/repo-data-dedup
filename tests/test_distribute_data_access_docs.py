import base64
import csv
import json
import subprocess
import types

import pytest


def write_summary(root, rows):
    (root / "audit").mkdir(parents=True, exist_ok=True)
    with (root / "audit" / "repo_summary.csv").open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["repo", "visibility", "git_disk_kb", "status", "lfs_objects", "lfs_bytes"])
        w.writerows(rows)


class FakeGh:
    """subprocess.run replacement for `gh api ...`: existing[repo] = content string."""

    def __init__(self, existing=None, put_fail=()):
        self.existing, self.put_fail, self.puts, self.gets = existing or {}, set(put_fail), [], []

    def __call__(self, cmd, capture_output, input):
        assert cmd[0] == "gh" and capture_output is True
        if "-X" in cmd:
            self.methods = getattr(self, "methods", []) + [cmd[cmd.index("-X") + 1]]
            path = cmd[cmd.index("-X") + 2]
            payload = json.loads(input.decode())
            self.puts.append((path, payload))
            repo = path.split("/")[2]
            if repo in self.put_fail:
                return types.SimpleNamespace(returncode=1, stdout=b"", stderr=b"HTTP 403 " + b"x" * 300)
            return types.SimpleNamespace(returncode=0, stdout=b"{}", stderr=b"")
        path = cmd[2]
        self.gets.append(path)
        repo = path.split("/")[2]
        if repo in self.existing:
            body = {"sha": f"sha-{repo}", "content": base64.b64encode(self.existing[repo].encode()).decode()}
            return types.SimpleNamespace(returncode=0, stdout=json.dumps(body).encode(), stderr=b"")
        return types.SimpleNamespace(returncode=1, stdout=b"", stderr=b"404")


@pytest.fixture
def env(tmp_path, distribute, monkeypatch):
    monkeypatch.setattr(distribute, "HERE", tmp_path)
    fake = FakeGh()
    monkeypatch.setattr(subprocess, "run", fake)
    return fake


def test_targets_exclude_zero_lfs_and_archive_repos(env, tmp_path, distribute, capsys):
    write_summary(tmp_path, [["a", "public", 10, "ok", 3, 5_000_000], ["b", "public", 10, "ok", 0, 0],
                             ["c-archive-2026-07-17", "private", 10, "ok", 9, 9], ["d", "private", 1, "CLONE_FAILED", 1, 1]])
    distribute.main()
    out = capsys.readouterr().out
    assert "2 target repos" in out
    assert [p for p, _ in env.puts] == ["repos/herrrickshaw/a/contents/DATA_ACCESS.md", "repos/herrrickshaw/d/contents/DATA_ACCESS.md"]


def test_rendered_document_contents(env, tmp_path, distribute):
    write_summary(tmp_path, [["fuel-retail-outlets", "public", 10, "ok", 7, 12_345_678]])
    distribute.main()
    path, payload = env.puts[0]
    doc = base64.b64decode(payload["content"]).decode()
    assert "| 7 | 12.3 MB |" in doc                                       # 12,345,678 bytes -> 12.3 MB
    assert "Fully re-collectable in ~6 min" in doc and "herrrickshaw/repo-data-dedup" in doc
    assert "**Policy: do not add new LFS objects**" in doc
    assert payload["message"].startswith("docs: DATA_ACCESS") and "sha" not in payload     # creating, not updating
    assert env.methods == ["PUT"] and path == "repos/herrrickshaw/fuel-retail-outlets/contents/DATA_ACCESS.md"


def test_unknown_repo_gets_generic_note(env, tmp_path, distribute):
    write_summary(tmp_path, [["some-new-repo", "public", 1, "ok", 1, 1_000_000]])
    distribute.main()
    doc = base64.b64decode(env.puts[0][1]["content"]).decode()
    assert "See the source catalogue in the SOP linked below." in doc and "| 1 | 1.0 MB |" in doc


def test_identical_existing_file_is_skipped(tmp_path, distribute, monkeypatch, capsys):
    write_summary(tmp_path, [["a", "public", 1, "ok", 2, 3_000_000]])
    monkeypatch.setattr(distribute, "HERE", tmp_path)
    fake = FakeGh()
    monkeypatch.setattr(subprocess, "run", fake)
    distribute.main()
    rendered = base64.b64decode(fake.puts[0][1]["content"]).decode()
    capsys.readouterr()
    fake2 = FakeGh(existing={"a": rendered})
    monkeypatch.setattr(subprocess, "run", fake2)
    distribute.main()
    assert fake2.puts == [] and "a: up to date" in capsys.readouterr().out


def test_changed_existing_file_is_updated_with_sha(tmp_path, distribute, monkeypatch, capsys):
    write_summary(tmp_path, [["a", "public", 1, "ok", 2, 3_000_000]])
    monkeypatch.setattr(distribute, "HERE", tmp_path)
    fake = FakeGh(existing={"a": "old text"})
    monkeypatch.setattr(subprocess, "run", fake)
    distribute.main()
    assert fake.puts[0][1]["sha"] == "sha-a" and "a: OK" in capsys.readouterr().out


def test_put_failure_is_reported_and_loop_continues(tmp_path, distribute, monkeypatch, capsys):
    write_summary(tmp_path, [["a", "public", 1, "ok", 1, 1], ["b", "public", 1, "ok", 1, 1]])
    monkeypatch.setattr(distribute, "HERE", tmp_path)
    fake = FakeGh(put_fail=["a"])
    monkeypatch.setattr(subprocess, "run", fake)
    distribute.main()
    out = capsys.readouterr().out
    assert "a: FAILED HTTP 403" in out and "b: OK" in out
    assert len(out.split("a: FAILED ")[1].split("\n")[0]) == 120            # error text cut at 120 chars


def test_gh_helper_passes_arguments_and_decodes(distribute, monkeypatch):
    seen = {}

    def run(cmd, capture_output, input):
        seen.update(cmd=cmd, input=input)
        return types.SimpleNamespace(returncode=3, stdout=b"out", stderr=b"err")

    monkeypatch.setattr(subprocess, "run", run)
    assert distribute.gh("api", "x", input_bytes=b"in") == (3, "out", "err")
    assert seen == {"cmd": ["gh", "api", "x"], "input": b"in"}


def test_notes_cover_documented_repos(distribute):
    assert "global-market-data" in distribute.NOTES and len(distribute.NOTES) == 14
    assert "{objects}" in distribute.TEMPLATE and "{size_mb:,.1f}" in distribute.TEMPLATE
