#!/usr/bin/env python3
"""Remote_ssh Keeper workspace cleanup payload, embedded in the MASC binary.

Removes the immediate entries of one Keeper's workspace root that nobody
has touched for the retention period, unless removing one could lose a
commit or a stash. Inside an entry that was touched, it does the same for
old subdirectories, without entering a git tree or a Dune project.
Uncommitted changes and untracked files are not kept
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


# /proc/<pid>/stat after the command name: state, parent, process group, session.
SESSION = 3
ROOT_UID = 0


def led_by_root(proc: Path, process: Path) -> bool:
    """Whether a root process leads the session [process] is in.

    A session's id is the PID of its leader, and the kernel does not hand
    that PID to another process while the session has a member. So
    /proc/<session id> is the leader or nothing. Without a leader (it
    exited, or the id is 0 because it lives in another PID namespace) the
    answer is no.
    """
    # A process chooses its command name, parentheses included. The kernel's
    # own fields start after the last ")".
    fields = (process / "stat").read_text().rsplit(")", 1)[1].split()
    try:
        return (proc / fields[SESSION]).stat().st_uid == ROOT_UID
    except FileNotFoundError:
        # Raises instead when [process] is the one that is gone.
        process.stat()
        return False


def live_paths(proc: Path, root: Path) -> list[Path]:
    """cwd, exe and open files of the processes that can be inside [root].

    [root] is the Keeper's own directory. When it grants no search permission
    to group or others, only our own user's processes can be inside it, so
    other users' processes are passed over. That includes root: the Keeper
    user cannot read root's processes, and a root shell in a Keeper's
    directory is the operator's own act.

    A process of our own user that cannot be read is passed over only in a
    session a root process leads. That is the sshd pair of a connection, the
    one this payload runs under included: the root side opens the session,
    and the side that dropped to the Keeper user stays in it, closed to
    inspection by the kernel. sshd starts every command in a session of its
    own, and a process can leave its session but never enter another, so
    nothing a Keeper runs is in a session root leads. A Keeper command that
    turned inspection off itself (prctl PR_SET_DUMPABLE, as ssh-agent does)
    is in a session the Keeper user leads.

    Any other unreadable process keeps every entry. When that process
    belongs to another user, the root let it in, so the reason names the
    root's mode and how to close it.
    """
    if not proc.is_dir():
        raise Unreadable("/proc unavailable")
    mode = stat.S_IMODE(root.stat().st_mode)
    private = mode & (stat.S_IXGRP | stat.S_IXOTH) == 0
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
                    except (FileNotFoundError, ProcessLookupError):
                        continue
                # Compare real paths: the root was resolved the same way.
                paths.extend(
                    Path(os.path.realpath(target)) for target in targets if target.startswith("/")
                )
            except PermissionError as error:
                if owner != me:
                    raise Unreadable(
                        f"process {process.name}: {error}; {root} has mode {mode:04o},"
                        " so another user's process can be inside it; rerun"
                        " masc-exec-ssh-bootstrap for this Keeper or chmod go-rwx it"
                    ) from error
                if led_by_root(proc, process):
                    continue
                raise Unreadable(f"process {process.name}: {error}") from error
        except (FileNotFoundError, ProcessLookupError):
            # The process exited while it was being read. A read of
            # /proc/<pid>/stat that began before it was reaped ends in ESRCH.
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


def is_unit(directory: Path) -> bool:
    """A directory that goes whole or not at all.

    A git working tree, a Git directory and a Dune project are trees someone
    builds or reads as one piece: removing only their old part (docs/, an
    untouched pack) breaks the rest. Any other directory is a container whose
    old subdirectories can go on their own.
    """
    return (
        os.path.lexists(directory / ".git")
        or (directory / "dune-project").is_file()
        or (
            (directory / "HEAD").is_file()
            and ((directory / "objects").is_dir() or (directory / "commondir").is_file())
        )
    )


def judge(
    entry: Path, record: dict[str, Any], *, cutoff: float, in_use: list[Path], apply: bool
) -> bool:
    """Decide one entry and fill [record]. True when it was touched within
    the retention, the only case where something inside it can still be old."""
    try:
        size, newest, repos = tree_facts(entry)
        record["allocated_bytes"] = size
        if newest > cutoff:
            record["result"] = "skipped"
            record["reason"] = "touched within retention"
            return True
        if any(path == entry or path.is_relative_to(entry) for path in in_use):
            record["result"] = "skipped"
            record["reason"] = "live process uses it"
            return False
        reason = next(
            (found for repo in repos if (found := keep_reason(repo, entry)) is not None),
            None,
        )
    except Unreadable as error:
        record["result"] = "skipped"
        record["reason"] = str(error)
        return False
    if reason is not None:
        record["result"] = "skipped"
        record["reason"] = reason
        return False
    if not apply:
        record["result"] = "would remove"
        return False
    try:
        if entry.is_dir():
            shutil.rmtree(entry)
        else:
            entry.unlink()
        record["result"] = "removed"
    except OSError as error:
        record["result"] = "failed"
        record["reason"] = str(error)[-ERROR_TAIL_CHARS:]
    return False


def sweep_inside(
    container: Path,
    records: list[dict[str, Any]],
    *,
    root: Path,
    cutoff: float,
    in_use: list[Path],
    apply: bool,
) -> None:
    """The old subdirectories of a container touched within the retention.

    A Keeper that keeps writing notes into one directory keeps that whole
    directory young; the old copies beside the notes would otherwise never
    go. Only subdirectories are judged here: files, dot entries and symlinks
    inside stay. A young subdirectory that is not a unit is entered in turn.
    Only subdirectories that were old get a record, so the report does not
    list every young directory on the way down.
    """
    try:
        children = sorted(container.iterdir(), key=lambda path: path.name)
    except OSError as error:
        records.append(
            {
                "name": str(container.relative_to(root)),
                "result": "skipped",
                "reason": f"list: {error}"[-ERROR_TAIL_CHARS:],
            }
        )
        return
    for child in children:
        if child.name.startswith(".") or child.is_symlink() or not child.is_dir():
            continue
        record: dict[str, Any] = {"name": str(child.relative_to(root))}
        if judge(child, record, cutoff=cutoff, in_use=in_use, apply=apply):
            if not is_unit(child):
                sweep_inside(child, records, root=root, cutoff=cutoff, in_use=in_use, apply=apply)
            continue
        records.append(record)


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
    records: list[dict[str, Any]] = report["entries"]
    for entry in sorted(root.iterdir(), key=lambda path: path.name):
        record: dict[str, Any] = {"name": entry.name}
        records.append(record)
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
        young = judge(entry, record, cutoff=cutoff, in_use=in_use, apply=apply)
        if young and entry.is_dir() and not is_unit(entry):
            sweep_inside(entry, records, root=root, cutoff=cutoff, in_use=in_use, apply=apply)
    report["free_kib_after"] = free_kib(root)
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--retention-sec", type=float, required=True)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    print(json.dumps(sweep(args.root, args.retention_sec, args.apply)))
