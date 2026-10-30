"""What a trial's rendered config was made from, recorded beside the binary identity.

The binaries come from a release and the config from this checkout, so two
trials of one arm can run different configs under the same release. A trial's
metadata names the checkout commit, a digest of the rendered runtime.toml, a
digest of the whole rendered directory and the effort, so a result can be
matched to a config without rendering it again.

`render_arm` is deterministic for a given checkout and arguments (plus
external OpenRouter model limits when queried): equal digests mean equal configs.
"""
from __future__ import annotations

import hashlib
import subprocess
from dataclasses import dataclass
from pathlib import Path

# `git status` reads the working tree: 0.41 s cold and 0.04 s warm on this
# checkout (16,891 tracked files, 2026-10-01). The bound only keeps a hung git
# from holding up every trial of a run.
GIT_TIMEOUT_S = 30


@dataclass(frozen=True)
class ConfigProvenance:
    # None when git cannot say (not a repository, git missing, timeout). Unknown
    # is recorded as unknown, not as a commit or as clean.
    checkout_commit: str | None
    checkout_dirty: bool | None
    runtime_toml_sha256: str
    config_dir_sha256: str
    effort: str


def _git(repo_root: Path, *args: str) -> str | None:
    try:
        done = subprocess.run(
            ["git", "-C", str(repo_root), *args],
            capture_output=True, text=True, errors="replace", timeout=GIT_TIMEOUT_S)
    except (OSError, subprocess.SubprocessError):
        return None
    return done.stdout if done.returncode == 0 else None


def checkout_state(repo_root: Path) -> tuple[str | None, bool | None]:
    """HEAD and whether tracked files differ from it at observation time.

    Each trial's provenance reads current checkout state so edits or HEAD
    movements between renders are attributed accurately.
    """
    head = _git(repo_root, "rev-parse", "HEAD")
    commit = head.strip() if head and head.strip() else None
    status = _git(repo_root, "status", "--porcelain", "--untracked-files=no")
    dirty = None if status is None else bool(status.strip())
    return commit, dirty


def tree_sha256(root: Path) -> str:
    """Digest over every file's relative path and bytes, in path order."""
    digest = hashlib.sha256()
    for path in sorted(p for p in root.rglob("*") if p.is_file()):
        digest.update(path.relative_to(root).as_posix().encode())
        digest.update(b"\0")
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()


def config_provenance(config_dir: Path, repo_root: Path, effort: str) -> ConfigProvenance:
    commit, dirty = checkout_state(repo_root)
    return ConfigProvenance(
        checkout_commit=commit,
        checkout_dirty=dirty,
        runtime_toml_sha256=hashlib.sha256(
            (config_dir / "runtime.toml").read_bytes()).hexdigest(),
        config_dir_sha256=tree_sha256(config_dir),
        effort=effort,
    )


def provenance_metadata(provenance: ConfigProvenance | None) -> dict:
    if provenance is None:
        return {}
    return {"config_provenance": {
        "checkout_commit": provenance.checkout_commit,
        "checkout_dirty": provenance.checkout_dirty,
        "runtime_toml_sha256": provenance.runtime_toml_sha256,
        "config_dir_sha256": provenance.config_dir_sha256,
        "effort": provenance.effort,
    }}
