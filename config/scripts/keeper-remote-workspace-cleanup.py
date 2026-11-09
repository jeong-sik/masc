#!/usr/bin/env python3
"""Remote_ssh Keeper workspace cleanup payload, embedded in the MASC binary.

Removes the immediate entries of one Keeper's workspace root that nobody
has touched for the retention period, unless removing one could lose a
commit or a stash. Uncommitted changes and untracked files are not kept
(RFC-remote-keeper-workspace-entries-are-swept-on-their-endpoint, section 2).
Any fact the decision needs that cannot be read keeps the entry.

Without --apply it only reports. An operator can run the same file by hand:
  ssh <endpoint> python3 - --root <keeper root> --retention-sec 172800 < this
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import time
from typing import Any

GIT_TIMEOUT_SEC = 5.0
LS_REMOTE_TIMEOUT_SEC = 20.0
ERROR_TAIL_CHARS = 300


class Unreadable(Exception):
    """A fact the decision needs could not be read; the entry stays."""


def git_env() -> dict[str, str]:
    env = dict(os.environ)
    # A credential prompt would hang until the timeout; fail instead.
    env["GIT_TERMINAL_PROMPT"] = "0"
    env["GIT_OPTIONAL_LOCKS"] = "0"
    return env


def git(repo: Path, *args: str, timeout: float = GIT_TIMEOUT_SEC) -> str:
    try:
        result = subprocess.run(
            ["git", "-C", str(repo), *args],
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
            env=git_env(),
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise Unreadable(f"git {args[0]} in {repo.name}: {error}") from error
    if result.returncode != 0:
        detail = result.stderr.strip()[-ERROR_TAIL_CHARS:]
        raise Unreadable(f"git {args[0]} in {repo.name} exited {result.returncode}: {detail}")
    return result.stdout


def tree_facts(entry: Path) -> tuple[int, float, list[Path]]:
    """Allocated bytes, newest max(mtime, ctime), and the git repositories.

    Symlinks are measured, never followed. ctime counts because an archive
    extracted a minute ago carries its commit's old mtimes.
    """
    top = entry.lstat()
    size = top.st_blocks * 512
    newest = max(top.st_mtime, top.st_ctime)
    repos: list[Path] = []
    administrative_dirs: list[Path] = []
    owned_git_dirs: set[Path] = set()
    if not stat.S_ISDIR(top.st_mode):
        return size, newest, repos

    def fail(error: OSError) -> None:
        raise Unreadable(f"walk {entry.name}: {error}")

    try:
        for directory, dirs, files in os.walk(entry, followlinks=False, onerror=fail):
            here = Path(directory)
            if ".git" in dirs or ".git" in files:
                repos.append(here)
                if ".git" in dirs:
                    owned_git_dirs.add((here / ".git").resolve(strict=True))
                else:
                    # Linked worktrees and initialized submodules point to
                    # an administrative directory already checked via them.
                    git_dir = git(here, "rev-parse", "--absolute-git-dir").removesuffix("\n")
                    owned_git_dirs.add(Path(git_dir).resolve(strict=True))
            elif "HEAD" in files and ("objects" in dirs or "commondir" in files):
                administrative_dirs.append(here.resolve(strict=True))
            for name in dirs + files:
                info = (here / name).lstat()
                size += info.st_blocks * 512
                newest = max(newest, info.st_mtime, info.st_ctime)
    except OSError as error:
        # A file that vanished or turned unreadable mid-walk: someone is here.
        raise Unreadable(f"walk {entry.name}: {error}") from error
    # An administrative directory can be visited before its worktree. Only
    # omit exact owned paths after discovery; orphaned submodule/worktree
    # directories and standalone repositories may still own unique commits.
    repos.extend(
        here for here in administrative_dirs if here not in owned_git_dirs
    )
    return size, newest, repos


def live_paths(proc: Path, root: Path) -> list[Path]:
    """cwd, exe and open files of the processes that can be inside [root].

    [root] is the Keeper's own directory. When it grants no search permission
    to group or others, only our own user's processes can be inside it, so
    other users' processes are passed over. That includes root: the Keeper
    user cannot read root's processes, and a root shell in a Keeper's
    directory is the operator's own act. A process of our own user whose
    /proc links belong to root has given up being inspectable: the kernel
    does that for privilege-dropping or setuid programs, such as the sshd
    session this payload itself runs under. Keeper work runs inspectable,
    so such a process is passed over too. Any other unreadable process
    keeps every entry.
    """
    if not proc.is_dir():
        raise Unreadable("/proc unavailable")
    private = root.stat().st_mode & (stat.S_IXGRP | stat.S_IXOTH) == 0
    me = os.getuid()
    paths: list[Path] = []
    for process in proc.iterdir():
        if not process.name.isdecimal() or int(process.name) == os.getpid():
            continue
        try:
            owner = process.stat().st_uid
            if private and owner != me:
                continue
            try:
                targets = [os.readlink(process / name) for name in ("cwd", "exe")]
                for descriptor in (process / "fd").iterdir():
                    try:
                        targets.append(os.readlink(descriptor))
                    except FileNotFoundError:
                        continue
                # Compare real paths: the root was resolved the same way.
                paths.extend(
                    Path(os.path.realpath(target)) for target in targets if target.startswith("/")
                )
            except PermissionError as error:
                if owner == me and (process / "cwd").lstat().st_uid != me:
                    continue
                raise Unreadable(f"process {process.name}: {error}") from error
        except FileNotFoundError:
            # The process exited while it was being read.
            continue
    return paths


def unpushed_tip(repo: Path) -> str | None:
    """The first HEAD or local branch tip no remote is known to hold.

    A tip is held when a remote-tracking ref reaches it, or when origin
    advertises that exact commit (a PR head fetched without a tracking ref).
    """
    tips = git(repo, "for-each-ref", "--format=%(objectname)", "refs/heads").split()
    try:
        tips.append(git(repo, "rev-parse", "--verify", "HEAD").strip())
    except Unreadable:
        # A repository with no commit yet has no HEAD to lose.
        if git(repo, "rev-list", "--all", "--max-count=1").strip():
            raise
    pending = [
        tip
        for tip in dict.fromkeys(tips)
        if git(repo, "rev-list", "--count", tip, "--not", "--remotes").strip() != "0"
    ]
    if not pending:
        return None
    advertised = {
        line.split()[0]
        for line in git(repo, "ls-remote", "origin", timeout=LS_REMOTE_TIMEOUT_SEC).splitlines()
        if line.strip()
    }
    return next((tip for tip in pending if tip not in advertised), None)


def foreign_worktree(repo: Path, entry: Path) -> Path | None:
    """A linked worktree of the main repository [repo] outside [entry].

    Removing a linked worktree loses no commit: they live in its main
    repository. Removing a main repository breaks its worktrees elsewhere.
    """
    if not (repo / ".git").is_dir():
        return None
    for line in git(repo, "worktree", "list", "--porcelain").splitlines():
        if line.startswith("worktree "):
            path = Path(line[len("worktree ") :])
            if not path.resolve().is_relative_to(entry.resolve()):
                return path
    return None


def keep_reason(repo: Path, entry: Path) -> str | None:
    if git(repo, "rev-parse", "--is-inside-git-dir").strip() == "true":
        # A standalone administrative directory may own an external worktree;
        # a bare repository may be the only copy of its commits. Neither has
        # the worktree contract required by the checks below.
        return f"Git directory in {repo.relative_to(entry.parent)}"
    if git(repo, "stash", "list").strip():
        return f"stash in {repo.relative_to(entry.parent)}"
    tip = unpushed_tip(repo)
    if tip is not None:
        return f"commit {tip[:12]} only in {repo.relative_to(entry.parent)}"
    outside = foreign_worktree(repo, entry)
    if outside is not None:
        return f"worktree {outside} of {repo.relative_to(entry.parent)} lives outside"
    return None


def free_kib(root: Path) -> int:
    return shutil.disk_usage(root).free // 1024


def sweep(
    root: Path, retention_sec: float, apply: bool, *, proc: Path = Path("/proc"), now: float | None = None
) -> dict[str, Any]:
    if not root.is_dir() or root.is_symlink():
        raise ValueError(f"not a real Keeper workspace root: {root}")
    root = root.resolve(strict=True)
    cutoff = (time.time() if now is None else now) - retention_sec
    report: dict[str, Any] = {
        "root": str(root),
        "apply": apply,
        "free_kib_before": free_kib(root),
        "entries": [],
    }
    try:
        in_use = live_paths(proc, root)
    except Unreadable as error:
        report["skip"] = str(error)
        report["free_kib_after"] = report["free_kib_before"]
        return report
    for entry in sorted(root.iterdir(), key=lambda path: path.name):
        record: dict[str, Any] = {"name": entry.name}
        report["entries"].append(record)
        if entry.name.startswith("."):
            # Home and tool state: the Keeper's gh login (.config/gh) and the
            # remote write tool's .masc-write.* temporaries live here.
            record["result"] = "skipped"
            record["reason"] = "dot entry"
            continue
        if entry.is_symlink():
            record["result"] = "skipped"
            record["reason"] = "symlink"
            continue
        try:
            size, newest, repos = tree_facts(entry)
            record["allocated_bytes"] = size
            if newest > cutoff:
                record["result"] = "skipped"
                record["reason"] = "touched within retention"
                continue
            if any(path == entry or path.is_relative_to(entry) for path in in_use):
                record["result"] = "skipped"
                record["reason"] = "live process uses it"
                continue
            reason = next(
                (found for repo in repos if (found := keep_reason(repo, entry)) is not None),
                None,
            )
        except Unreadable as error:
            record["result"] = "skipped"
            record["reason"] = str(error)
            continue
        if reason is not None:
            record["result"] = "skipped"
            record["reason"] = reason
            continue
        if not apply:
            record["result"] = "would remove"
            continue
        try:
            if entry.is_dir():
                shutil.rmtree(entry)
            else:
                entry.unlink()
            record["result"] = "removed"
        except OSError as error:
            record["result"] = "failed"
            record["reason"] = str(error)[-ERROR_TAIL_CHARS:]
    report["free_kib_after"] = free_kib(root)
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--retention-sec", type=float, required=True)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    print(json.dumps(sweep(args.root, args.retention_sec, args.apply)))
