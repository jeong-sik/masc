#!/usr/bin/env python3
"""Refuse credential-shaped strings in tracked files.

Three commits in this repo say "security: remove tracked <secret>" -- #636
(launchd OAuth tokens), #3422 (a Supabase connection string in CLAUDE.md),
#6487 (certs/localhost.key). All three removed the file from the working
tree, which is what GitHub's secret scanning observes, so all three alerts
closed. None of the values stopped being served: on 2026-09-07 the blob
holding four Claude OAuth tokens still answered an unauthenticated
`api.github.com/.../git/blobs/<sha>` with HTTP 200, and three of the four
tokens still authenticated against api.anthropic.com. They were live for
five months.

GitHub push protection would not have stopped two of the three. It matches
known provider patterns, so it caught the `sk-ant-` key in
docs/evidence/task-362-bundle (the redaction marker there is its own) and
let a postgres URL carrying inline credentials through in the same bundle.
This scanner exists for the shapes that protection does not name.

Written without any literal that its own rules match, so that scanning the
tree it lives in stays a question about the tree.

Budget is zero. The allowlist pins the exact strings the tree already
carries -- redaction fixtures, dummy tokens, a test's own input -- by
hash, so a new credential-shaped string fails even in a file that already
holds a fixture. A path exemption would not do that.

Usage:
    check-committed-secrets.py [--root DIR]

Exit 0 when every match is pinned, 1 otherwise. Matched values are never
printed: the report names the file, the line, and the rule.
"""

from __future__ import annotations

import argparse
import hashlib
import pathlib
import re
import subprocess
import sys

ALLOWLIST = pathlib.Path(__file__).with_name("committed-secrets-allowlist.txt")

# A tracked file this size is a build artifact or a capture, not source, and
# reading every one of them costs more than the scan is worth.
MAX_BYTES = 4_000_000

# A PEM header with no key material under it is not a key. Requiring the
# body keeps every redaction fixture in the tree out of the report without
# naming any of them: they carry `ABCD` or nothing where a key carries
# ~1600 base64 characters over ~50 lines.
PEM_BODY_CHARS = 128

RULES: list[tuple[str, re.Pattern[bytes]]] = [
    (
        "private-key-pem",
        re.compile(
            rb"-----BEGIN [A-Z ]*PRIVATE KEY-----"
            rb"(?:[\s]*[A-Za-z0-9+/=]){%d,}" % PEM_BODY_CHARS
        ),
    ),
    ("anthropic-key", re.compile(rb"sk-ant-[A-Za-z0-9_-]{24,}")),
    ("openai-key", re.compile(rb"\bsk-(?:proj-)?[A-Za-z0-9]{32,}")),
    ("github-token", re.compile(rb"\bgh[pousr]_[A-Za-z0-9]{30,}")),
    ("github-pat", re.compile(rb"\bgithub_pat_[A-Za-z0-9_]{30,}")),
    ("slack-token", re.compile(rb"\bxox[baprs]-[A-Za-z0-9-]{10,}")),
    ("aws-access-key", re.compile(rb"\bAKIA[0-9A-Z]{16}\b")),
    ("google-api-key", re.compile(rb"\bAIza[0-9A-Za-z_-]{35}\b")),
    ("resend-key", re.compile(rb"\bre_[A-Za-z0-9]{32}\b")),
    ("huggingface-token", re.compile(rb"\bhf_[A-Za-z0-9]{30,}\b")),
    ("groq-key", re.compile(rb"\bgsk_[A-Za-z0-9]{40,}\b")),
    (
        # The shape #3422 and the task-362 bundle both carried, and the one
        # push protection does not name. Requires a password in the
        # userinfo: `postgresql://[redacted]@host` is what a cleaned log
        # looks like and must not report.
        "db-url-password",
        re.compile(
            rb"\b(?:postgres|postgresql|mysql|redis|rediss|mongodb(?:\+srv)?)"
            rb"://[^:/@\s'\"]+:[^@\s'\"]{6,}@"
        ),
    ),
]


def digest(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def load_allowlist(path: pathlib.Path) -> set[str]:
    if not path.exists():
        return set()
    pinned = set()
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        pinned.add(line.split()[0])
    return pinned


def tracked_files(root: pathlib.Path) -> list[pathlib.Path]:
    listing = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=root,
        capture_output=True,
        check=True,
    ).stdout
    return [root / raw.decode() for raw in listing.split(b"\0") if raw]


def line_of(body: bytes, offset: int) -> int:
    return body.count(b"\n", 0, offset) + 1


def scan(root: pathlib.Path, pinned: set[str]) -> list[tuple[str, int, str, str]]:
    findings = []
    for path in tracked_files(root):
        try:
            if path.stat().st_size > MAX_BYTES:
                continue
            body = path.read_bytes()
        except (OSError, ValueError):
            # A tracked path that is not a readable regular file -- a
            # submodule gitlink, a symlink to nowhere -- holds no bytes to
            # scan. Skipping is not a silent pass: git ls-files named it,
            # and there is nothing to read.
            continue
        for rule, pattern in RULES:
            for match in pattern.finditer(body):
                sha = digest(match.group(0))
                if sha in pinned:
                    continue
                findings.append(
                    (
                        str(path.relative_to(root)),
                        line_of(body, match.start()),
                        rule,
                        sha,
                    )
                )
    return sorted(findings)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=".", help="repository root to scan")
    args = parser.parse_args()

    root = pathlib.Path(args.root).resolve()
    findings = scan(root, load_allowlist(ALLOWLIST))

    if not findings:
        print("check-committed-secrets: no unpinned credential shapes")
        return 0

    print(f"check-committed-secrets: {len(findings)} unpinned match(es)\n")
    for relative, line, rule, sha in findings:
        print(f"  {relative}:{line}  [{rule}]  sha256={sha[:16]}")
    print(
        "\nA real credential: revoke it at the provider first -- removing the\n"
        "file leaves the blob served, and this repo has three commits that\n"
        "learned that. Then take the value out of the file.\n"
        "\n"
        "A fixture or an already-redacted capture: pin it by appending the\n"
        "full sha256 and a reason to\n"
        f"  {ALLOWLIST.relative_to(root) if ALLOWLIST.is_relative_to(root) else ALLOWLIST}\n"
        "Print the sha with:\n"
        "  python3 -c 'import hashlib,sys;"
        "print(hashlib.sha256(sys.argv[1].encode()).hexdigest())' '<value>'"
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
