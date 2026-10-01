"""The provenance of a rendered config: what it was made from, said as digests and a commit.

These hold the digests (same bytes, same digest; any change, a different one),
the git reading (a commit, a clean or dirty tree, and unknown when git cannot
say), and that each trial observes fresh checkout state.
"""
import hashlib
import os
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "agents"))

import masc_config_provenance as provenance  # noqa: E402

GIT_ENV = {
    **os.environ,
    "GIT_CONFIG_GLOBAL": os.devnull,
    "GIT_CONFIG_NOSYSTEM": "1",
}


def git(repo: Path, *args: str) -> str:
    done = subprocess.run(
        ["git", "-c", "user.name=t", "-c", "user.email=t@example.com",
         "-c", "commit.gpgsign=false", "-C", str(repo), *args],
        capture_output=True, text=True, check=True, env=GIT_ENV)
    return done.stdout.strip()


def repo_with_one_commit(tmp_path: Path, name: str = "repo") -> Path:
    repo = tmp_path / name
    repo.mkdir()
    git(repo, "init", "-q")
    (repo / "tracked.txt").write_text("one\n")
    git(repo, "add", "tracked.txt")
    git(repo, "commit", "-q", "-m", "first")
    return repo


def config_tree(root: Path, **files: str) -> Path:
    root.mkdir(parents=True)
    for relative, body in files.items():
        path = root / relative.replace("__", "/")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body)
    return root


def test_the_same_files_have_the_same_digest_wherever_they_are(tmp_path):
    files = {"runtime.toml": "a = 1\n", "keepers__bench-1.toml": "name = 'x'\n"}
    first = config_tree(tmp_path / "one", **files)
    second = config_tree(tmp_path / "two" / "deeper", **files)
    assert provenance.tree_sha256(first) == provenance.tree_sha256(second)


def test_a_changed_byte_a_renamed_file_or_an_added_file_changes_the_digest(tmp_path):
    base = provenance.tree_sha256(config_tree(
        tmp_path / "base", **{"runtime.toml": "a = 1\n", "skills__s.md": "text\n"}))
    changed = provenance.tree_sha256(config_tree(
        tmp_path / "changed", **{"runtime.toml": "a = 2\n", "skills__s.md": "text\n"}))
    renamed = provenance.tree_sha256(config_tree(
        tmp_path / "renamed", **{"runtime.toml": "a = 1\n", "skills__t.md": "text\n"}))
    added = provenance.tree_sha256(config_tree(
        tmp_path / "added", **{"runtime.toml": "a = 1\n", "skills__s.md": "text\n", "extra": ""}))
    assert len({base, changed, renamed, added}) == 4


def test_the_runtime_toml_digest_is_the_digest_of_that_file(tmp_path):
    config = config_tree(tmp_path / "config", **{"runtime.toml": "a = 1\n", "other": "x"})
    result = provenance.config_provenance(config, tmp_path, "high")
    assert result.runtime_toml_sha256 == hashlib.sha256(b"a = 1\n").hexdigest()
    assert result.config_dir_sha256 == provenance.tree_sha256(config)
    assert result.effort == "high"


def test_a_config_without_a_runtime_toml_is_an_error_not_a_blank_digest(tmp_path):
    config = config_tree(tmp_path / "config", other="x")
    with pytest.raises(FileNotFoundError):
        provenance.config_provenance(config, tmp_path, "high")


def test_a_clean_checkout_reports_its_commit_and_not_dirty(tmp_path):
    repo = repo_with_one_commit(tmp_path)
    assert provenance.checkout_state(repo) == (git(repo, "rev-parse", "HEAD"), False)


def test_a_modified_tracked_file_makes_the_checkout_dirty(tmp_path):
    repo = repo_with_one_commit(tmp_path)
    (repo / "tracked.txt").write_text("two\n")
    commit, dirty = provenance.checkout_state(repo)
    assert commit == git(repo, "rev-parse", "HEAD")
    assert dirty is True


def test_an_untracked_file_does_not_make_the_checkout_dirty(tmp_path):
    repo = repo_with_one_commit(tmp_path)
    (repo / "untracked.txt").write_text("x\n")
    assert provenance.checkout_state(repo)[1] is False


def test_a_directory_that_is_not_a_repository_is_unknown_not_clean(tmp_path):
    outside = tmp_path / "plain"
    outside.mkdir()
    assert provenance.checkout_state(outside) == (None, None)


def test_a_missing_git_is_unknown_not_clean(tmp_path, monkeypatch):
    def no_git(*_args, **_kwargs):
        raise FileNotFoundError("git")

    monkeypatch.setattr(provenance.subprocess, "run", no_git)
    assert provenance.checkout_state(tmp_path / "anywhere") == (None, None)


def test_git_timeout_or_error_returns_unknown_not_clean(tmp_path, monkeypatch):
    repo = repo_with_one_commit(tmp_path)

    def timeout_git(*_args, **_kwargs):
        raise subprocess.TimeoutExpired(cmd="git", timeout=30)

    monkeypatch.setattr(provenance.subprocess, "run", timeout_git)
    assert provenance.checkout_state(repo) == (None, None)


def test_subsequent_render_reflects_tracked_file_edit_as_dirty(tmp_path):
    repo = repo_with_one_commit(tmp_path)
    initial_commit = git(repo, "rev-parse", "HEAD")
    config1 = config_tree(tmp_path / "config1", **{
        "runtime.toml": (repo / "tracked.txt").read_text(),
    })
    prov1 = provenance.config_provenance(config1, repo, "high")
    assert prov1.checkout_commit == initial_commit
    assert prov1.checkout_dirty is False

    # Edit tracked file in the repository without committing
    (repo / "tracked.txt").write_text("two\n")
    config2 = config_tree(tmp_path / "config2", **{
        "runtime.toml": (repo / "tracked.txt").read_text(),
    })
    prov2 = provenance.config_provenance(config2, repo, "high")
    assert prov2.checkout_commit == initial_commit
    assert prov2.checkout_dirty is True
    assert prov2.runtime_toml_sha256 != prov1.runtime_toml_sha256
    assert prov2.config_dir_sha256 != prov1.config_dir_sha256


def test_subsequent_render_reflects_head_commit_advance(tmp_path):
    repo = repo_with_one_commit(tmp_path)
    initial_commit = git(repo, "rev-parse", "HEAD")
    config1 = config_tree(tmp_path / "config1", **{"runtime.toml": "a = 1\n"})
    prov1 = provenance.config_provenance(config1, repo, "high")
    assert prov1.checkout_commit == initial_commit
    assert prov1.checkout_dirty is False

    # Advance HEAD with a new commit
    (repo / "tracked.txt").write_text("second commit\n")
    git(repo, "commit", "-q", "-am", "second")
    second_commit = git(repo, "rev-parse", "HEAD")
    assert second_commit != initial_commit

    config2 = config_tree(tmp_path / "config2", **{"runtime.toml": "a = 2\n"})
    prov2 = provenance.config_provenance(config2, repo, "high")
    assert prov2.checkout_commit == second_commit
    assert prov2.checkout_dirty is False


def test_metadata_carries_every_field_and_nothing_when_nothing_was_installed():
    assert provenance.provenance_metadata(None) == {}
    value = provenance.ConfigProvenance(
        checkout_commit="c" * 40, checkout_dirty=True,
        runtime_toml_sha256="r" * 64, config_dir_sha256="d" * 64, effort="high")
    assert provenance.provenance_metadata(value) == {"config_provenance": {
        "checkout_commit": "c" * 40, "checkout_dirty": True,
        "runtime_toml_sha256": "r" * 64, "config_dir_sha256": "d" * 64,
        "effort": "high"}}
