#!/usr/bin/env python3
# pyright: strict
"""Refuse a pull request that adds or edits a malformed changelog fragment.

The `changes` job of .github/workflows/pr-type-check.yml runs this against the
blobless fetch of the pull request's merge commit it already holds. `changes`
is a required check, so a non-zero exit here blocks the merge. The fragment
check used to be a workflow of its own that nothing required: #50755 merged
with it red, and the whole-directory check on main failed until #50768.

Only the fragments this pull request changes are read, as the difference
between the merge commit and its first parent. A malformed fragment already on
the base branch is not this pull request's to answer for. Every layer of a
native stack answers for its own fragments: a lower layer can merge before the
top, so the top does not stand in for it.

The format itself is judged by scripts/changelog-fragments.py `check-files`,
taken from the merge commit together with the changed fragments. Its exit
status is this script's. Any git failure exits non-zero.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import re
import subprocess
import sys
import tempfile

_SHA = re.compile(r"[0-9a-f]{40}")
FRAGMENT_DIR = "changelog.d/"
CHECKER = "scripts/changelog-fragments.py"


def _git(git_dir: str, *args: str, index: pathlib.Path | None = None) -> str:
    env = None if index is None else {**os.environ, "GIT_INDEX_FILE": str(index)}
    done = subprocess.run(
        ["git", "--literal-pathspecs", "-C", git_dir, *args],
        check=True, stdout=subprocess.PIPE, text=True, env=env,
    )
    return done.stdout


def changed_fragments(git_dir: str, merge: str) -> tuple[str, ...]:
    """Paths under changelog.d/ that the pull request adds or edits.

    --no-renames lists a moved fragment under its new name and needs no file
    contents; --diff-filter=d drops the paths the pull request removes.
    """
    out = _git(
        git_dir, "diff", "--name-only", "-z", "--no-renames", "--diff-filter=d",
        f"{merge}^1", merge, "--", FRAGMENT_DIR,
    )
    return tuple(path for path in out.split("\0") if path)


def export(
    git_dir: str, merge: str, paths: tuple[str, ...], tree: pathlib.Path, index: pathlib.Path
) -> None:
    """Write `paths` as they are in `merge` under `tree`. The fetch was
    blobless, so git asks the promisor remote for exactly these files. The
    checkout records them in `index`, not in the repository's own index."""
    _git(git_dir, f"--work-tree={tree}", "checkout", "-q", merge, "--", *paths, index=index)


def check(git_dir: str, merge: str) -> int:
    fragments = changed_fragments(git_dir, merge)
    if not fragments:
        print("this pull request changes no changelog fragment")
        return 0
    with tempfile.TemporaryDirectory(prefix="pr-changelog-fragments-") as tmp:
        tree = pathlib.Path(tmp) / "tree"
        tree.mkdir()
        export(git_dir, merge, (CHECKER, *fragments), tree, pathlib.Path(tmp) / "index")
        done = subprocess.run(
            [sys.executable, "-I", CHECKER, "check-files", *fragments], cwd=tree
        )
    return done.returncode


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--git-dir", required=True, help="repository holding the merge commit")
    parser.add_argument("--merge", required=True, help="the pull request's merge commit")
    args = parser.parse_args()
    git_dir: str = args.git_dir
    merge: str = args.merge
    if _SHA.fullmatch(merge) is None:
        parser.error("--merge must be a full commit sha")
    return check(git_dir, merge)


if __name__ == "__main__":
    raise SystemExit(main())
