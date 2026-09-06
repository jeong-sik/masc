#!/usr/bin/env python3
"""Self-test for check-wildcard-only-match.py.

Feeds the checker the shapes it is meant to separate: the two that were
actually in the tree on 2026-09-06 (a single wildcard arm, and two wildcard
arms decided by a [when] guard), a real match beside them, and the two ways
a line is exempt. Each expectation is a file the checker reads, so the
detection semantics are proven by construction rather than argued.

Run directly: `python3 scripts/ci/test_check_wildcard_only_match.py`
Exits 0 on success, 1 on the first failed expectation.
"""

from __future__ import annotations

import importlib.util
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
GUARD = REPO_ROOT / "scripts" / "ci" / "check-wildcard-only-match.py"


def load_guard():
    spec = importlib.util.spec_from_file_location("wildcard_only_match", GUARD)
    if spec is None or spec.loader is None:
        raise SystemExit(f"cannot load {GUARD}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


CASES: list[tuple[str, str, int]] = [
    (
        "single wildcard arm fires",
        """let reason err =
  match classify err with
  | _ -> Failure_provider_error err
""",
        1,
    ),
    (
        "when-guarded pair of wildcards fires",
        """let reason err =
  match classify err with
  | _ when exhausted err -> Failure_runtime_unavailable
  | _ -> Failure_provider_error err
""",
        1,
    ),
    (
        "a match with real arms stays quiet",
        """let value opt =
  match opt with
  | Some v -> v
  | None -> 0
""",
        0,
    ),
    (
        "a trailing wildcard beside a real arm stays quiet",
        """let value opt =
  match opt with
  | Some v -> v
  | _ -> 0
""",
        0,
    ),
    (
        "the waiver silences the line",
        """let reason err =
  match classify err with (* wildcard-match-ok *)
  | _ -> Failure_provider_error err
""",
        0,
    ),
    (
        "two of them in one file are both reported",
        """let a err =
  match classify err with
  | _ -> 1

let b err =
  match classify err with
  | _ -> 2
""",
        2,
    ),
]


def main() -> int:
    guard = load_guard()
    failures = 0
    with tempfile.TemporaryDirectory() as tmp:
        for label, source, expected in CASES:
            path = Path(tmp) / "case.ml"
            path.write_text(source)
            found = guard.violations_in(path)
            if len(found) == expected:
                print(f"[PASS] {label} (found {len(found)}, want {expected})")
            else:
                print(f"[FAIL] {label}: found {len(found)}, want {expected}: {found}")
                failures += 1
    if failures:
        print(f"\n{failures} self-test expectation(s) failed.")
        return 1
    print("\nAll wildcard-only match self-tests passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
