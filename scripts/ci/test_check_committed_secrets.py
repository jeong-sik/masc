#!/usr/bin/env python3
"""Self-test for check-committed-secrets.py.

Every positive case below is a shape that was actually committed to this
repo and served publicly, reproduced with substitute bytes: the launchd
OAuth tokens (#636), the CLAUDE.md Supabase connection string (#3422), the
TLS private key (#6487), and the Resend key that opened secret-scanning
alert #10. A guard that only passes on a clean tree proves nothing about
what it catches, and each of these got past something -- two of them past
GitHub push protection.

The negative cases are the two ways this scanner could become noise: the
redacted form the task-362 bundle was cleaned to, and a bare PEM header,
which every redaction fixture in the tree carries and which is not a key
without body under it.

Run directly: `python3 scripts/ci/test_check_committed_secrets.py`
Exits 0 on success, 1 on the first failed expectation.
"""

from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
GUARD = REPO_ROOT / "scripts" / "ci" / "check-committed-secrets.py"

PEM_BODY = (
    "MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDNqrstuvwxyzAB\n"
    "CDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789abcd\n"
    "EFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789abcdEF\n"
)

CASES: list[tuple[str, str, int]] = [
    (
        "launchd OAuth token (#636)",
        "<key>CLAUDE_CODE_OAUTH_TOKEN_ci</key>\n"
        "<string>sk-ant-oat01-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA</string>\n",
        1,
    ),
    (
        "Supabase connection string (#3422)",
        "psql postgresql://postgres.abcdefgh:sOmePassw0rd"
        "@aws-1-ap-south-1.pooler.supabase.com:5432/postgres\n",
        1,
    ),
    (
        "TLS private key (#6487)",
        f"-----BEGIN PRIVATE KEY-----\n{PEM_BODY}-----END PRIVATE KEY-----\n",
        1,
    ),
    (
        "Resend API key (alert #10)",
        "RESEND_API_KEY=re_AbCdEfGhIjKlMnOpQrStUvWxYz012345\n",
        1,
    ),
    (
        "GitHub token",
        "gh_token: ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789\n",
        1,
    ),
    (
        "AWS access key id",
        "aws_access_key_id = AKIAIOSFODNN7EXAMPLE\n",
        1,
    ),
    (
        # How the task-362 bundle reads after the credential came out. The
        # host is the evidence; keeping the shape would keep the alarm.
        "redacted connection string stays quiet",
        "postgresql://[redacted]@aws-1-ap-southeast-1.pooler.supabase.com:6543/postgres\n",
        0,
    ),
    (
        # secret_redactor.ml and the redaction tests all carry this. A
        # header without key material under it is a string literal.
        "bare PEM header stays quiet",
        '-----BEGIN PRIVATE KEY-----\\nABCD\\n-----END PRIVATE KEY-----\n',
        0,
    ),
    (
        "ordinary prose stays quiet",
        "The keeper reads its token from the environment, never from disk.\n",
        0,
    ),
]


def load_guard():
    spec = importlib.util.spec_from_file_location("committed_secrets", GUARD)
    if spec is None or spec.loader is None:
        raise SystemExit(f"cannot load {GUARD}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def matches_in(guard, body: str) -> int:
    raw = body.encode()
    return sum(len(pattern.findall(raw)) for _, pattern in guard.RULES)


def check_repo_is_clean() -> int:
    """The budget is zero, so the tree itself is the guard's first fixture:
    if this repo stops passing its own check, the allowlist and the tree
    have drifted apart and every later PR inherits a red lint."""
    result = subprocess.run(
        [sys.executable, str(GUARD), "--root", str(REPO_ROOT)],
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        print("pass the tracked tree holds no unpinned credential shape")
        return 0
    print("FAIL the tracked tree no longer passes its own check:", file=sys.stderr)
    print(result.stdout, file=sys.stderr)
    return 1


def check_allowlist_entries_are_reachable(guard) -> int:
    """A pinned hash that matches nothing in the tree is a value that left
    without its exemption. Stale pins accumulate into a list nobody can
    read, which is how a real key eventually hides in one."""
    pinned = guard.load_allowlist(guard.ALLOWLIST)
    live = set()
    for path in guard.tracked_files(REPO_ROOT):
        try:
            body = path.read_bytes()
        except OSError:
            continue
        for _, pattern in guard.RULES:
            for match in pattern.finditer(body):
                live.add(guard.digest(match.group(0)))
    stale = sorted(pinned - live)
    if stale:
        print(
            f"FAIL {len(stale)} allowlist entr(ies) match nothing in the tree, "
            f"first sha256={stale[0][:16]}",
            file=sys.stderr,
        )
        return 1
    print(f"pass all {len(pinned)} allowlist entries still match a tracked value")
    return 0


def main() -> int:
    guard = load_guard()
    failures = check_repo_is_clean()
    failures += check_allowlist_entries_are_reachable(guard)

    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "case.txt"
        for label, body, expected in CASES:
            path.write_text(body)
            found = matches_in(guard, body)
            if found == expected:
                print(f"[PASS] {label} (found {found}, want {expected})")
            else:
                print(
                    f"[FAIL] {label}: found {found}, want {expected}",
                    file=sys.stderr,
                )
                failures += 1

    if failures:
        print(f"\n{failures} expectation(s) failed", file=sys.stderr)
        return 1
    print(f"\nall {len(CASES)} cases and 2 tree checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
