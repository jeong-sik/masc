#!/usr/bin/env python3
# pyright: strict
"""Refuse ordinary pull requests that introduce merge commits.

The `changes` job of .github/workflows/pr-type-check.yml runs this against the
pull request's merge commit. `changes` is a required check, so a non-zero exit
blocks the merge.

Why: this repository squash-merges onto main. Pulling main or another pull
request into a feature or stack branch via `git merge` adds ancestry without
removing it, inflates stacks by hundreds of commits, and causes recurring
conflicts (2026-10-12 sweep; 2026-11-20 squash-only policy). Rebase with
`gh stack rebase` (or `git rebase`) and push with `--force-with-lease` instead.

How: fetches only the pull request's commits (`base..head`) into an isolated
temporary git directory using `--filter=tree:0` and `--shallow-exclude`, spending
no GitHub REST API quota. Because `--shallow-exclude` writes boundary commits to
`.git/shallow` (which hides their raw parents from `git rev-list --merges`),
every fetched commit object is read directly via `git cat-file --batch`.
(When a PR merges the base branch multiple times, `upload-pack` stops at the
newest merge-with-base commit; that commit is itself a merge commit so the check
still fails, and `git rebase` drops every merge commit in one pass.)

Same-repository `release/v*` branches are exempt. Any unexpected git failure
exits non-zero (fail closed).
"""

from __future__ import annotations

import argparse
import os
import pathlib
import re
import shlex
import subprocess
import sys
import tempfile

_SHA = re.compile(r"[0-9a-f]{40}")
_PARENT_LINE = re.compile(rb"parent [0-9a-f]{40,64}")
_NO_COMMITS_SHALLOW = "no commits selected for shallow requests"
_DEEPEN_NOT_MISSING = "deepen-not is not a ref"


def _git_env() -> dict[str, str]:
    return {**os.environ, "LC_ALL": "C"}


def _git(git_dir: str, *args: str) -> str:
    done = subprocess.run(
        ["git", "-C", git_dir, *args],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        errors="replace",
        env=_git_env(),
    )
    return done.stdout


def _validate_ref(name: str, label: str) -> str:
    if not name or any(ch in name for ch in ("\0", "\r", "\n")):
        raise ValueError(f"{label} must be a non-empty single-line branch name")
    return name


def _parse_bool(raw: str) -> bool:
    lowered = raw.strip().lower()
    if lowered == "true":
        return True
    if lowered == "false":
        return False
    raise ValueError(f"expected 'true' or 'false', got {raw!r}")


def _parse_raw_commits(raw: bytes) -> list[tuple[str, int, str]]:
    """Parse `git cat-file --batch` stdout into (sha, parent_count, subject)."""
    results: list[tuple[str, int, str]] = []
    pos = 0
    total = len(raw)
    while pos < total:
        nl = raw.find(b"\n", pos)
        if nl < 0:
            raise ValueError("truncated git cat-file --batch header")
        header_line = raw[pos:nl].decode("utf-8", errors="replace")
        parts = header_line.split(" ")
        if len(parts) != 3 or parts[1] != "commit":
            raise ValueError(f"unexpected git cat-file --batch header: {header_line!r}")
        sha = parts[0]
        size = int(parts[2])
        body_start = nl + 1
        body_end = body_start + size
        if body_end > total:
            raise ValueError(f"truncated commit payload for {sha}")
        payload = raw[body_start:body_end]
        # Git commit headers are strictly LF-delimited; split bytes on b"\n" so
        # Unicode/CR line breaks inside author/committer names cannot forge a
        # `parent ` line.
        commit_header, _, message_bytes = payload.partition(b"\n\n")
        parent_count = sum(
            1 for line in commit_header.split(b"\n") if _PARENT_LINE.fullmatch(line)
        )
        message = message_bytes.decode("utf-8", errors="replace")
        subject = ""
        for line in message.splitlines():
            stripped = line.strip()
            if stripped:
                subject = stripped
                break
        results.append((sha, parent_count, subject))
        pos = body_end + (1 if body_end < total and raw[body_end : body_end + 1] == b"\n" else 0)
    return results


def _fetch_pr_commits(
    probe: str, excludes: list[str], head_sha: str
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            "git",
            "-C",
            probe,
            "fetch",
            "-q",
            "--filter=tree:0",
            *excludes,
            "--",
            "origin",
            head_sha,
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        errors="replace",
        env=_git_env(),
    )


def find_merge_commits(
    git_dir: str,
    remote: str,
    merge: str,
    head_ref: str,
    base_ref: str,
    default_branch: str,
    fetch_ref: str = "",
) -> tuple[int, list[tuple[str, int, str]]]:
    """Return (checked_commit_count, merge_commits) for `base..head`."""
    base_ref = _validate_ref(base_ref, "--base-ref")
    default_branch = _validate_ref(default_branch, "--default-branch")
    base_sha = _git(git_dir, "rev-parse", f"{merge}^1").strip()
    head_sha = _git(git_dir, "rev-parse", f"{merge}^2").strip()
    if head_sha == base_sha:
        return 0, []

    remote_url = _git(git_dir, "remote", "get-url", "--", remote).strip()
    excludes = [f"--shallow-exclude=refs/heads/{base_ref}"]
    if base_ref != default_branch:
        excludes.append(f"--shallow-exclude=refs/heads/{default_branch}")

    def _run_fetch(target_ref: str) -> tuple[str, subprocess.CompletedProcess[str], tempfile.TemporaryDirectory[str]]:
        tmp_dir = tempfile.TemporaryDirectory(prefix="pr-no-merge-commits-")
        probe_dir = str(pathlib.Path(tmp_dir.name))
        _git(probe_dir, "init", "-q")
        _git(probe_dir, "remote", "add", "--", "origin", remote_url)
        res = _fetch_pr_commits(probe_dir, excludes, target_ref)
        if (
            res.returncode != 0
            and base_ref != default_branch
            and _DEEPEN_NOT_MISSING in res.stderr
        ):
            # A stacked parent branch can be deleted after merging while a
            # re-run or in-flight job still carries the old base ref. Fall back
            # to excluding only the repository default branch.
            res = _fetch_pr_commits(
                probe_dir, [f"--shallow-exclude=refs/heads/{default_branch}"], target_ref
            )
        return probe_dir, res, tmp_dir

    # Fork PR head commits are advertised on the base repository under
    # `refs/pull/<N>/head` rather than `refs/heads/*`, so prefer `--fetch-ref`
    # when provided and fall back to raw `head_sha` if the ref moved past this
    # workflow run's merge commit.
    targets: list[str] = []
    if fetch_ref:
        targets.append(_validate_ref(fetch_ref, "--fetch-ref"))
    targets.append(head_sha)

    probe = ""
    fetch: subprocess.CompletedProcess[str] | None = None
    active_tmp: tempfile.TemporaryDirectory[str] | None = None
    try:
        for idx, target in enumerate(targets):
            cand_probe, cand_fetch, cand_tmp = _run_fetch(target)
            if cand_fetch.returncode != 0:
                if _NO_COMMITS_SHALLOW in cand_fetch.stderr:
                    cand_tmp.cleanup()
                    return 0, []
                if idx + 1 < len(targets):
                    cand_tmp.cleanup()
                    continue
                probe, fetch, active_tmp = cand_probe, cand_fetch, cand_tmp
                break
            fetched_sha = _git(cand_probe, "rev-parse", "FETCH_HEAD").strip()
            if fetched_sha != head_sha and idx + 1 < len(targets):
                cand_tmp.cleanup()
                continue
            probe, fetch, active_tmp = cand_probe, cand_fetch, cand_tmp
            break

        assert fetch is not None
        if fetch.returncode != 0:
            raise RuntimeError(
                f"git fetch failed for {head_ref} ({head_sha[:12]}): "
                f"{fetch.stderr.strip() or f'exit {fetch.returncode}'}"
            )
        # Inspect every fetched commit object directly via `cat-file` rather
        # than `rev-list --merges`, because `.git/shallow` hides parent lines on
        # boundary commits from `rev-list`.
        inventory = _git(
            probe, "cat-file", "--batch-all-objects", "--batch-check=%(objectname) %(objecttype)"
        )
        shas: list[str] = []
        for line in inventory.splitlines():
            parts = line.split(" ")
            if len(parts) == 2 and parts[1] == "commit":
                shas.append(parts[0])
        if not shas:
            return 0, []
        batch = subprocess.run(
            ["git", "-C", probe, "cat-file", "--batch"],
            input=("\n".join(shas) + "\n").encode("utf-8"),
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=_git_env(),
        )
        parsed = _parse_raw_commits(batch.stdout)
        merges = sorted(
            (entry for entry in parsed if entry[1] >= 2), key=lambda item: item[0]
        )
        return len(parsed), merges
    finally:
        if active_tmp is not None:
            active_tmp.cleanup()


def check(
    git_dir: str,
    remote: str,
    merge: str,
    head_ref: str,
    base_ref: str,
    default_branch: str,
    same_repo: bool,
    fetch_ref: str = "",
) -> int:
    head_ref = _validate_ref(head_ref, "--head-ref")
    if same_repo and head_ref.startswith("release/v"):
        print(f"same-repo release branch '{head_ref}' is exempt from the merge-commit guard")
        return 0
    checked, merges = find_merge_commits(
        git_dir, remote, merge, head_ref, base_ref, default_branch, fetch_ref=fetch_ref
    )
    if not merges:
        print(
            f"ok: checked {checked} commit(s) on '{head_ref}' (base: '{base_ref}'); "
            "no merge commits"
        )
        return 0
    quoted_base = shlex.quote(base_ref)
    print(
        f"error: ordinary pull requests must not contain merge commits (squash-only repository).\n"
        f"Found {len(merges)} merge commit(s) on '{head_ref}' (base: '{base_ref}'):",
        file=sys.stderr,
    )
    for sha, parent_count, subject in merges:
        print(f"  - {sha[:12]} ({parent_count} parents): {subject}", file=sys.stderr)
    print(
        "\nRebase instead of merging main or another PR into your branch:\n"
        "  gh stack rebase && gh stack push\n"
        "Or for a standalone branch:\n"
        f"  git fetch origin {quoted_base} && git rebase origin/{quoted_base} "
        "&& git push --force-with-lease",
        file=sys.stderr,
    )
    return 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--git-dir", required=True, help="repository holding the merge commit")
    parser.add_argument("--remote", required=True, help="remote name to fetch PR commits from")
    parser.add_argument("--merge", required=True, help="the pull request's merge commit")
    parser.add_argument("--head-ref", required=True, help="pull request head branch name")
    parser.add_argument("--base-ref", required=True, help="pull request base branch name")
    parser.add_argument(
        "--default-branch",
        default="main",
        help="repository default branch used as a secondary shallow bound",
    )
    parser.add_argument(
        "--same-repo",
        default="false",
        help="'true' only when the PR head branch lives in the target repository",
    )
    parser.add_argument(
        "--fetch-ref",
        default="",
        help="optional ref on --remote (e.g. refs/pull/<N>/head) for fork PRs",
    )
    args = parser.parse_args()
    merge: str = args.merge
    if _SHA.fullmatch(merge) is None:
        parser.error("--merge must be a full commit sha")
    try:
        same_repo = _parse_bool(args.same_repo)
        return check(
            args.git_dir,
            args.remote,
            merge,
            args.head_ref,
            args.base_ref,
            args.default_branch,
            same_repo,
            fetch_ref=args.fetch_ref,
        )
    except subprocess.CalledProcessError as error:
        stderr = (
            error.stderr.decode("utf-8", errors="replace").strip()
            if isinstance(error.stderr, bytes)
            else (error.stderr or "").strip()
        )
        detail = f"{error}: {stderr}" if stderr else str(error)
        print(f"pr_no_merge_commits: {detail}", file=sys.stderr)
        return 1
    except (RuntimeError, ValueError) as error:
        print(f"pr_no_merge_commits: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
