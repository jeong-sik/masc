#!/usr/bin/env python3
# pyright: strict
"""Refuse a pull request that introduces unpinned credential-shaped strings.

The `changes` job of .github/workflows/pr-type-check.yml runs this against the
blobless fetch of the pull request's merge commit it already holds. `changes`
is a required check, so a non-zero exit here blocks the merge — including on
docs-only or config-only pull requests where `type-check` is skipped.

Previously `scripts/ci/check-committed-secrets.py` only ran in `full-check.yml`
(release gate) and `pr-check.yml` (manual workflow_dispatch), so an unpinned
credential or fixture shape could merge to `main` and only surface later at
release cut time (task-3834).

Only regular files added or modified by this pull request (`<merge>^1..merge`)
are read, each whole so multi-line PEM blocks and pre-existing secrets in
edited files are still caught. Rules, MAX_BYTES, allowlist parsing, and report
formatting come directly from `scripts/ci/check-committed-secrets.py` (SSOT),
and the allowlist is read from `<merge>:scripts/ci/committed-secrets-allowlist.txt`
as a verified regular blob so a PR that legitimately pins a test fixture in the
same PR passes. On blobless promisor clones, missing blobs are bulk-prefetched
in bounded chunks rather than lazy-fetched one by one. Any git failure or
missing scanner/allowlist exits non-zero (fail-closed).
"""

from __future__ import annotations

import argparse
import importlib.util
import os
import pathlib
import re
import subprocess
from collections.abc import Sequence
from types import ModuleType
from typing import Protocol, cast

_SHA = re.compile(r"[0-9a-f]{40}")
_REGULAR_MODES = (b"100644", b"100755")
_SKIPPED_MODES = (b"120000", b"160000")
_ALLOWED_STATUSES = (b"A", b"M", b"T")
_BATCH_CHUNK = 100
_FETCH_CHUNK = 250
_DRAIN_CHUNK = 65_536

SCANNER_PATH = "scripts/ci/check-committed-secrets.py"
ALLOWLIST_PATH = "scripts/ci/committed-secrets-allowlist.txt"

Finding = tuple[str, int, str, str]


class _ByteReader(Protocol):
    def read(self, size: int = -1, /) -> bytes: ...


class _ScannerModule(Protocol):
    MAX_BYTES: int

    def parse_allowlist(self, text: str) -> set[str]: ...

    def scan_bytes(self, relative: str, body: bytes, pinned: set[str]) -> list[Finding]: ...

    def report_findings(self, findings: list[Finding], *, allowlist_display: str) -> int: ...


def _load_scanner(scanner_file: pathlib.Path) -> _ScannerModule:
    if not scanner_file.is_file():
        raise RuntimeError(f"scanner module not found: {scanner_file}")
    spec = importlib.util.spec_from_file_location("check_committed_secrets", scanner_file)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"unable to load scanner module from {scanner_file}")
    module: ModuleType = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return cast(_ScannerModule, module)


def _git_bytes(git_dir: str, *args: str) -> bytes:
    done = subprocess.run(
        ["git", "--literal-pathspecs", "-C", git_dir, *args],
        check=True,
        stdout=subprocess.PIPE,
    )
    return done.stdout


def _resolve_regular_blob_sha(git_dir: str, commit: str, relpath: str) -> str:
    """Resolve `relpath` in `commit` via plumbing `ls-tree -z` and verify it is a
    regular file blob (`100644` or `100755`), failing closed on missing paths,
    directories (trees), symlinks, or submodules.
    """
    raw = _git_bytes(git_dir, "ls-tree", "-z", commit, "--", relpath)
    if not raw:
        raise RuntimeError(f"required file missing in {commit}: {relpath}")
    entries = raw.split(b"\0")
    if not entries or entries[-1] != b"":
        raise RuntimeError(f"unexpected non-NUL-terminated git ls-tree output for {relpath}")
    entries.pop()
    if len(entries) != 1:
        raise RuntimeError(
            f"expected single tree entry for {relpath} in {commit}, got {len(entries)}"
        )
    entry = entries[0]
    header, sep, entry_path = entry.partition(b"\t")
    if not sep or entry_path != relpath.encode("utf-8"):
        raise RuntimeError(
            f"unexpected git ls-tree entry for {relpath} in {commit}: {entry!r}"
        )
    parts = header.split(b" ")
    if len(parts) != 3:
        raise RuntimeError(f"unexpected git ls-tree header for {relpath}: {header!r}")
    mode, obj_type, sha_bytes = parts
    if mode not in _REGULAR_MODES or obj_type != b"blob":
        raise RuntimeError(
            f"required file {relpath} in {commit} is not a regular blob "
            f"(mode={mode!r}, type={obj_type!r})"
        )
    sha = sha_bytes.decode("ascii")
    if _SHA.fullmatch(sha) is None:
        raise RuntimeError(f"unexpected blob sha for {relpath}: {sha!r}")
    return sha


def _promisor_remote(git_dir: str) -> str | None:
    """Return the promisor remote name if `git_dir` is a partial/promisor clone."""
    done = subprocess.run(
        ["git", "-C", git_dir, "config", "-z", "--get-regexp", r"^remote\..*\.promisor$"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if done.returncode == 1:
        return None
    if done.returncode != 0:
        raise RuntimeError(
            f"git config --get-regexp failed with status {done.returncode}: "
            f"{done.stderr.decode('utf-8', errors='replace').strip()}"
        )
    remotes: list[str] = []
    for item in done.stdout.split(b"\0"):
        if not item:
            continue
        key_bytes, sep, val_bytes = item.partition(b"\n")
        if not sep:
            continue
        val = val_bytes.decode("utf-8", errors="replace").strip().lower()
        if val not in ("true", "1", "yes", "on"):
            continue
        key = key_bytes.decode("utf-8", errors="replace")
        if key.startswith("remote.") and key.endswith(".promisor"):
            remote_name = key[len("remote.") : -len(".promisor")]
            if remote_name:
                remotes.append(remote_name)
    if not remotes:
        return None
    if "origin" in remotes:
        return "origin"
    return remotes[0]


def _missing_blobs(git_dir: str, unique_shas: Sequence[str]) -> list[str]:
    """Identify which SHAs in `unique_shas` are absent locally without triggering
    per-object lazy promisor fetches.
    """
    if not unique_shas:
        return []
    env = dict(os.environ)
    env["GIT_NO_LAZY_FETCH"] = "1"
    payload = "".join(f"{sha}\n" for sha in unique_shas).encode("ascii")
    done = subprocess.run(
        ["git", "-C", git_dir, "cat-file", "--batch-check=%(objectname) %(objecttype)"],
        input=payload,
        stdout=subprocess.PIPE,
        env=env,
        check=True,
    )
    lines = done.stdout.splitlines()
    if len(lines) != len(unique_shas):
        raise RuntimeError(
            f"unexpected line count from git cat-file --batch-check: "
            f"expected {len(unique_shas)}, got {len(lines)}"
        )
    missing: list[str] = []
    for expected_sha, line in zip(unique_shas, lines):
        parts = line.split(b" ")
        if len(parts) != 2 or parts[0] != expected_sha.encode("ascii"):
            raise RuntimeError(
                f"unexpected git cat-file --batch-check line for {expected_sha}: {line!r}"
            )
        if parts[1] == b"missing":
            missing.append(expected_sha)
    return missing


def _prefetch_missing_blobs(git_dir: str, shas: Sequence[str]) -> None:
    """Bulk-fetch missing blob SHAs from the promisor remote in bounded chunks.

    Without this, `git cat-file --batch` on a `--filter=blob:none` clone spawns
    one `git fetch` subprocess and HTTPS round-trip per missing blob (`O(N)`).
    """
    unique_shas = list(dict.fromkeys(shas))
    if not unique_shas:
        return
    remote = _promisor_remote(git_dir)
    if remote is None:
        return
    missing = _missing_blobs(git_dir, unique_shas)
    if not missing:
        return
    for start in range(0, len(missing), _FETCH_CHUNK):
        chunk = missing[start : start + _FETCH_CHUNK]
        payload = "".join(f"{sha}\n" for sha in chunk).encode("ascii")
        subprocess.run(
            [
                "git",
                "-C",
                git_dir,
                "-c",
                "fetch.negotiationAlgorithm=noop",
                "fetch",
                "-q",
                remote,
                "--no-tags",
                "--no-write-fetch-head",
                "--recurse-submodules=no",
                "--filter=blob:none",
                "--stdin",
            ],
            input=payload,
            check=True,
        )


def changed_regular_blobs(git_dir: str, merge: str) -> list[tuple[str, str]]:
    """Return `(relative_path, blob_sha)` for every regular file added or edited
    between `<merge>^1` and `<merge>`.

    Uses `diff-tree --no-renames --diff-filter=d -z`, which inspects only tree
    objects on a blobless clone (fetching zero blobs). Symlinks (`120000`) and
    submodule gitlinks (`160000`) are skipped explicitly; any unexpected status
    or file mode raises (fail-closed).
    """
    raw = _git_bytes(
        git_dir,
        "diff-tree",
        "-r",
        "--no-commit-id",
        "--no-renames",
        "--diff-filter=d",
        "-z",
        f"{merge}^1",
        merge,
    )
    if not raw:
        return []
    tokens = raw.split(b"\0")
    if not tokens or tokens[-1] != b"":
        raise RuntimeError("unexpected non-NUL-terminated git diff-tree -z output")
    tokens.pop()
    if len(tokens) % 2 != 0:
        raise RuntimeError("unexpected odd token count in git diff-tree -z output")

    entries: list[tuple[str, str]] = []
    for i in range(0, len(tokens), 2):
        meta = tokens[i]
        path_bytes = tokens[i + 1]
        if not meta.startswith(b":"):
            raise RuntimeError(f"unexpected diff-tree header: {meta!r}")
        parts = meta[1:].split(b" ")
        if len(parts) != 5:
            raise RuntimeError(f"unexpected diff-tree metadata fields: {meta!r}")
        _old_mode, new_mode, _old_sha, new_sha, status = parts
        if status not in _ALLOWED_STATUSES:
            raise RuntimeError(f"unexpected diff-tree status with --no-renames: {status!r}")
        if new_mode in _SKIPPED_MODES:
            continue
        if new_mode not in _REGULAR_MODES:
            raise RuntimeError(f"unexpected git file mode in diff-tree: {new_mode!r}")
        blob_sha = new_sha.decode("ascii")
        if _SHA.fullmatch(blob_sha) is None:
            raise RuntimeError(f"unexpected blob sha in diff-tree: {blob_sha!r}")
        relpath = path_bytes.decode("utf-8", errors="replace")
        entries.append((relpath, blob_sha))
    return entries


def _read_exact(stream: _ByteReader, size: int) -> bytes:
    """Read exactly `size` bytes from a binary stream, raising on short EOF."""
    chunks: list[bytes] = []
    remaining = size
    while remaining > 0:
        chunk = stream.read(remaining)
        if not chunk:
            raise RuntimeError(f"unexpected EOF reading git blob ({remaining} bytes short)")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def _drain_exact(stream: _ByteReader, size: int) -> None:
    """Discard `size` bytes from a binary stream without buffering it whole."""
    remaining = size
    while remaining > 0:
        chunk = stream.read(min(remaining, _DRAIN_CHUNK))
        if not chunk:
            raise RuntimeError(
                f"unexpected EOF draining oversized git blob ({remaining} bytes short)"
            )
        remaining -= len(chunk)


def _scan_batch(
    git_dir: str,
    batch: Sequence[tuple[str, str]],
    scanner: _ScannerModule,
    pinned: set[str],
) -> list[Finding]:
    """Stream one bounded batch of blob SHAs through `git cat-file --batch`."""
    payload = "".join(f"{sha}\n" for _, sha in batch).encode("ascii")
    proc = subprocess.Popen(
        ["git", "-C", git_dir, "cat-file", "--batch"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
    )
    assert proc.stdin is not None and proc.stdout is not None
    findings: list[Finding] = []
    completed = False
    try:
        proc.stdin.write(payload)
        proc.stdin.close()
        for relpath, expected_sha in batch:
            header = proc.stdout.readline()
            if not header:
                raise RuntimeError(
                    f"unexpected EOF from git cat-file for {relpath} ({expected_sha})"
                )
            if not header.endswith(b"\n"):
                raise RuntimeError(
                    f"unterminated git cat-file header for {relpath}: {header!r}"
                )
            parts = header[:-1].split(b" ")
            if (
                len(parts) != 3
                or parts[0] != expected_sha.encode("ascii")
                or parts[1] != b"blob"
            ):
                raise RuntimeError(
                    f"unexpected git cat-file header for {relpath}: {header!r}"
                )
            size = int(parts[2])
            if size < 0:
                raise RuntimeError(f"negative git blob size for {relpath}: {size}")
            if size > scanner.MAX_BYTES:
                _drain_exact(proc.stdout, size)
                trailing = _read_exact(proc.stdout, 1)
                if trailing != b"\n":
                    raise RuntimeError(f"missing trailing LF after oversized blob {relpath}")
                continue
            body = _read_exact(proc.stdout, size)
            trailing = _read_exact(proc.stdout, 1)
            if trailing != b"\n":
                raise RuntimeError(f"missing trailing LF after blob {relpath}")
            findings.extend(scanner.scan_bytes(relpath, body, pinned))
        extra = proc.stdout.read(1)
        if extra:
            raise RuntimeError("unexpected trailing bytes from git cat-file --batch")
        completed = True
    finally:
        try:
            proc.stdin.close()
        except OSError:
            pass
        try:
            proc.stdout.close()
        except OSError:
            pass
        if not completed:
            try:
                proc.kill()
            except OSError:
                pass
        rc = proc.wait()
    if rc != 0:
        raise RuntimeError(f"git cat-file --batch exited with status {rc}")
    return findings


def check(
    git_dir: str,
    merge: str,
    *,
    scanner_file: pathlib.Path | None = None,
) -> int:
    if scanner_file is None:
        scanner_file = pathlib.Path(__file__).with_name(pathlib.Path(SCANNER_PATH).name)
    scanner = _load_scanner(scanner_file)

    # Always resolve and validate the allowlist as a regular blob in `<merge>`
    # (fail-closed if deleted, symlinked, or replaced with a directory).
    allowlist_sha = _resolve_regular_blob_sha(git_dir, merge, ALLOWLIST_PATH)
    blobs = changed_regular_blobs(git_dir, merge)

    # Bulk-prefetch the allowlist and all changed blobs together so a blobless
    # promisor clone performs O(ceil(N / _FETCH_CHUNK)) packfile fetches.
    _prefetch_missing_blobs(git_dir, [allowlist_sha, *(sha for _, sha in blobs)])

    allowlist_bytes = _git_bytes(git_dir, "cat-file", "blob", allowlist_sha)
    pinned = scanner.parse_allowlist(allowlist_bytes.decode("utf-8"))

    if not blobs:
        print("check-committed-secrets: this pull request changes no regular files")
        return 0

    findings: list[Finding] = []
    for start in range(0, len(blobs), _BATCH_CHUNK):
        findings.extend(_scan_batch(git_dir, blobs[start : start + _BATCH_CHUNK], scanner, pinned))
    return scanner.report_findings(sorted(findings), allowlist_display=ALLOWLIST_PATH)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--git-dir", required=True, help="repository holding the merge commit")
    parser.add_argument("--merge", required=True, help="the pull request's merge commit")
    parser.add_argument(
        "--scanner",
        default=None,
        help="path to check-committed-secrets.py (default: sibling of this script)",
    )
    args = parser.parse_args()
    git_dir: str = args.git_dir
    merge: str = args.merge
    if _SHA.fullmatch(merge) is None:
        parser.error("--merge must be a full commit sha")
    scanner_file = pathlib.Path(args.scanner) if args.scanner else None
    return check(git_dir, merge, scanner_file=scanner_file)


if __name__ == "__main__":
    raise SystemExit(main())
