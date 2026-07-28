#!/usr/bin/env python3
"""Find out which test suites could join the CI gate, by running them.

CI executes 6 of ~848 test files (#26113). The reason is recorded in
ci.yml: the old catch-all ``dune test`` gate mixed behaviour tests with
source-text and log-wording assertions, so legitimate refactors turned main
red and the gate was switched off rather than the tests fixed.

That leaves one question unanswered: of the suites that assert on behaviour
rather than prose, how many pass right now? "No substring assertion" is a
static property and says nothing about whether a suite is green — it may be
flaky, environment-dependent, or already broken and invisible (#26104).

This lists the prose-free suites and runs each one, reporting pass / fail /
timeout. The failing list is the actual work item behind #26113; the passing
list is what could be gated today.

It is a measurement, not a gate: exit is 0 whenever the run completes, so
wiring it into CI cannot make main red. Use --strict to invert that once the
failing set is empty.

Usage:
    scripts/audit-test-gate-candidates.py --list
    scripts/audit-test-gate-candidates.py --run [--limit N] [--timeout SEC]
    scripts/audit-test-gate-candidates.py --run --json
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Final

# Assertions that compare against a fragment of prose rather than a value.
# These are what made the catch-all gate unusable: they break on any wording
# change, including one that fixes a bug.
PROSE_ASSERTION: Final[re.Pattern[str]] = re.compile(
    r"contains_sub"
    r"|contains\s+~needle"
    r"|str_contains"
    r"|contains_substring"
    r"|starts_with\s+~prefix"
)

TEST_DIR: Final[str] = "test"
DEFAULT_TIMEOUT_SEC: Final[int] = 120


@dataclass(frozen=True, slots=True)
class SuiteResult:
    name: str
    status: str  # "pass" | "fail" | "timeout"
    seconds: float
    detail: str


def prose_free_suites(test_dir: Path) -> list[str]:
    """Test files whose assertions are all value comparisons, by static scan."""
    names: list[str] = []
    for path in sorted(test_dir.glob("test_*.ml")):
        try:
            text = path.read_text()
        except OSError:
            continue
        if not PROSE_ASSERTION.search(text):
            names.append(path.stem)
    return names


def run_suite(name: str, *, timeout_sec: int, dune: list[str]) -> SuiteResult:
    target = f"@{TEST_DIR}/runtest-{name}"
    started = 0.0
    try:
        completed = subprocess.run(
            [*dune, "build", "--root", ".", target],
            capture_output=True,
            text=True,
            timeout=timeout_sec,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return SuiteResult(name, "timeout", float(timeout_sec), f"exceeded {timeout_sec}s")
    except OSError as exc:
        return SuiteResult(name, "fail", started, f"could not launch dune: {exc}")

    if completed.returncode == 0:
        return SuiteResult(name, "pass", started, "")
    tail = (completed.stderr or completed.stdout or "").strip().splitlines()
    return SuiteResult(name, "fail", started, " / ".join(tail[-3:])[:400])


def render(results: list[SuiteResult], candidates: int) -> str:
    passed = [r for r in results if r.status == "pass"]
    failed = [r for r in results if r.status == "fail"]
    timed_out = [r for r in results if r.status == "timeout"]

    lines: list[str] = []
    lines.append(f"prose-free suites  : {candidates}")
    lines.append(f"  ran              : {len(results)}")
    lines.append(f"  pass             : {len(passed)}")
    lines.append(f"  fail             : {len(failed)}")
    lines.append(f"  timeout          : {len(timed_out)}")
    if failed:
        lines.append("")
        lines.append("failing (this is the #26113 work item):")
        for r in failed:
            lines.append(f"  {r.name}")
            if r.detail:
                lines.append(f"      {r.detail}")
    if timed_out:
        lines.append("")
        lines.append("timed out:")
        lines.extend(f"  {r.name}" for r in timed_out)
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--list", action="store_true", help="print candidate suite names")
    mode.add_argument("--run", action="store_true", help="run each candidate suite")
    parser.add_argument("--limit", type=int, default=0, help="run only the first N (0 = all)")
    parser.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT_SEC)
    parser.add_argument("--json", action="store_true", help="emit machine-readable JSON")
    parser.add_argument(
        "--strict",
        action="store_true",
        help="exit 1 when any candidate fails (off by default: this measures, it does not gate)",
    )
    parser.add_argument(
        "--dune",
        default="opam exec -- dune",
        help='dune invocation (default: "opam exec -- dune")',
    )
    args = parser.parse_args()

    test_dir = Path(TEST_DIR)
    if not test_dir.is_dir():
        print(f"no {TEST_DIR}/ directory; run from the repository root", file=sys.stderr)
        return 2

    candidates = prose_free_suites(test_dir)
    if not candidates:
        print(f"no prose-free suites found under {TEST_DIR}/", file=sys.stderr)
        return 2

    if args.list:
        if args.json:
            print(json.dumps({"candidates": candidates}, indent=2))
        else:
            print("\n".join(candidates))
        return 0

    selected = candidates[: args.limit] if args.limit > 0 else candidates
    dune = args.dune.split()
    results = [run_suite(name, timeout_sec=args.timeout, dune=dune) for name in selected]

    if args.json:
        print(
            json.dumps(
                {
                    "candidates": len(candidates),
                    "ran": len(results),
                    "results": [
                        {"name": r.name, "status": r.status, "detail": r.detail}
                        for r in results
                    ],
                },
                indent=2,
            )
        )
    else:
        print(render(results, len(candidates)))

    if args.strict and any(r.status != "pass" for r in results):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
