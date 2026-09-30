"""Identify the complete PR change using Git objects, never truncated patches."""

import argparse
import hashlib
import os
import re
import shlex
import subprocess
import sys
from pathlib import Path


def diff_identity(repo: str, base: str, head: str, root: Path) -> str:
    for value in (base, head):
        if re.fullmatch(r"[0-9a-f]{40}", value) is None:
            raise ValueError("base and head must be complete commit IDs")
    if re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo) is None:
        raise ValueError("invalid repository")
    # GitHub supplies the PR's three-dot merge base; shallow local history must
    # not invent a different one. Exact objects are sufficient after this read.
    merge_base = subprocess.check_output(
        [
            os.environ.get("GUARD_GH", "gh"),
            "api",
            f"repos/{repo}/compare/{base}...{head}",
            "--jq",
            ".merge_base_commit.sha",
        ],
        text=True,
    ).strip()
    if re.fullmatch(r"[0-9a-f]{40}", merge_base) is None:
        raise ValueError("GitHub did not return a complete merge base")
    git = ["git", "--no-replace-objects", "-C", str(root)]
    for commit in (merge_base, head):
        exists = subprocess.run(
            [*git, "cat-file", "-e", f"{commit}^{{commit}}"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if exists.returncode:
            subprocess.run(
                [
                    *git,
                    "-c", "credential.helper=",
                    "-c", "credential.helper=!" + shlex.quote(
                        os.environ.get("GUARD_GH", "gh")
                    ) + " auth git-credential",
                    "fetch",
                    "--no-tags",
                    f"https://github.com/{repo}.git",
                    commit,
                ],
                # Use the same authenticated gh installation as the API read,
                # without persistent config changes or an interactive fallback.
                env={**os.environ, "GIT_TERMINAL_PROMPT": "0",
                     "GIT_ASKPASS": "false", "SSH_ASKPASS": "false",
                     "GCM_INTERACTIVE": "Never"},
                check=True,
            )
    # -z preserves arbitrary filenames. Disable rename guessing, external
    # drivers, text conversions and abbreviated blob IDs. Binary, mode-only,
    # symlink and submodule changes retain their complete object identities.
    raw = subprocess.check_output(
        [
            *git,
            "diff",
            "--raw",
            "-z",
            "--no-abbrev",
            "--no-renames",
            "--no-ext-diff",
            "--no-textconv",
            "--no-relative",
            "--ignore-submodules=none",
            merge_base,
            head,
            "--",
        ],
    )
    fields = raw.split(b"\0")
    if fields[-1] or len(fields) % 2 != 1:
        raise ValueError("invalid NUL-delimited Git raw diff")
    entries = sorted(zip(fields[::2], fields[1::2]), key=lambda entry: entry[1])
    canonical = b"".join(header + b"\0" + path + b"\0" for header, path in entries)
    return hashlib.sha256(b"masc-reviewed-git-diff-v1\0" + canonical).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", required=True)
    args = parser.parse_args()
    root = Path(
        os.environ.get("GUARD_REPO_ROOT", str(Path(__file__).resolve().parents[2]))
    )
    try:
        print(diff_identity(args.repo, args.base, args.head, root))
        return 0
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"review diff unavailable: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
