#!/usr/bin/env python3
"""List the dashboard tests that read OCaml source, so CI can run them.

Five dashboard suites assert that a TypeScript vocabulary still matches the
OCaml that produces it: the SSE event union, the turn-outcome codes, the
keeper attention reasons, the lane registry fields, the TUI answering glow.
They are the only guards over those wire contracts, and every one of them
lives in the dashboard suite that CI does not run (see #35032). A backend
change that renames a token touches no file under `dashboard/`, so nothing
selects them, and the drift lands unseen -- that is how `keepalive_stopped`
reached main with no dashboard label for it (#35031).

This prints the set so the workflow runs exactly the tests that couple to the
backend, rather than a hand-kept list that a sixth such test would not join.

Detection: a `*.test.ts` under `dashboard/` that references `readFileSync` and
quotes a path ending in `.ml`/`.mli` which resolves -- against its own
directory or the repository root -- to a file that exists.

Known false positive: a test that both reads some file and quotes a real
OCaml path as fixture data lands in the list and runs in the lane. That costs
a few seconds and no correctness; the alternative, narrowing to reads only,
would drop the attention-label guard, which builds its paths at call time.
"""

from __future__ import annotations

import argparse
import re
import sys
import tempfile
from pathlib import Path

# A quoted path whose last segment ends in .ml or .mli.
OCAML_PATH_RE = re.compile(r"""['"`]([^'"`\s]*\.mli?)['"`]""")
READ_CALL = "readFileSync"
TEST_GLOB = "*.test.ts"
SCAN_ROOTS = ("dashboard/src", "dashboard/design-system")


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def backend_coupled(test_file: Path, root: Path) -> list[str]:
    """OCaml sources this test points at; empty when it points at none."""
    source = test_file.read_text(encoding="utf-8", errors="replace")
    if READ_CALL not in source:
        return []
    hits: list[str] = []
    for literal in OCAML_PATH_RE.findall(source):
        # vitest runs from `dashboard/`, so a literal may be relative to the
        # test file, to that working directory, or to the repository root.
        for base in (test_file.parent, root / "dashboard", root):
            candidate = (base / literal).resolve()
            if candidate.is_file():
                try:
                    hits.append(str(candidate.relative_to(root)))
                except ValueError:
                    # Outside the repository: not a backend coupling.
                    continue
                break
    return hits


def collect(root: Path) -> dict[str, list[str]]:
    found: dict[str, list[str]] = {}
    for scan_root in SCAN_ROOTS:
        base = root / scan_root
        if not base.is_dir():
            continue
        for test_file in sorted(base.rglob(TEST_GLOB)):
            sources = backend_coupled(test_file, root)
            if sources:
                relative = test_file.relative_to(root / "dashboard")
                found[str(relative)] = sorted(set(sources))
    return found


def self_test() -> int:
    """A planted coupled test is listed; a fixture-only mention is not."""
    with tempfile.TemporaryDirectory() as tmp:
        # Resolved: on macOS /tmp is a symlink, and the paths this walks
        # are resolved, so an unresolved root makes every hit look external.
        root = Path(tmp).resolve()
        (root / "lib" / "keeper").mkdir(parents=True)
        (root / "lib" / "keeper" / "real.ml").write_text("let x = 1\n")
        tests = root / "dashboard" / "src"
        tests.mkdir(parents=True)
        (tests / "cwd-relative-parity.test.ts").write_text(
            "import { readFileSync } from 'node:fs'\n"
            "readFileSync(resolve(process.cwd(), '../lib/keeper/real.ml'))\n"
        )
        (tests / "coupled-parity.test.ts").write_text(
            "import { readFileSync } from 'node:fs'\n"
            "readFileSync(resolve(__dirname, '../../lib/keeper/real.ml'))\n"
        )
        (tests / "root-relative.drift.test.ts").write_text(
            "import { readFileSync } from 'node:fs'\n"
            "read('lib/keeper/real.ml')\n"
        )
        (tests / "fixture-only.test.ts").write_text(
            "import { readFileSync } from 'node:fs'\n"
            "const details = { file_path: 'lib/keeper/absent.ml' }\n"
        )
        (tests / "no-read.test.ts").write_text(
            "const p = 'lib/keeper/real.ml'\n"
        )
        listed = set(collect(root))
        expected = {
            "src/coupled-parity.test.ts",
            "src/cwd-relative-parity.test.ts",
            "src/root-relative.drift.test.ts",
        }
        if listed != expected:
            print(f"self-test: FAIL listed={sorted(listed)} expected={sorted(expected)}")
            return 1
    print("self-test: a coupled test is listed, a fixture-only mention is not (PASS)")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true", help="check the detector")
    parser.add_argument(
        "--with-sources",
        action="store_true",
        help="print the OCaml sources each test reads, for review",
    )
    args = parser.parse_args()

    if args.self_test:
        return self_test()

    root = repo_root()
    found = collect(root)
    if not found:
        # A detector that selects nothing would make the lane report green
        # without running a single guard.
        print(
            "ERROR: no dashboard test reads OCaml source. Either the guards "
            "were deleted or this detector stopped matching them.",
            file=sys.stderr,
        )
        return 1
    for test, sources in found.items():
        if args.with_sources:
            print(f"{test}\t{' '.join(sources)}")
        else:
            print(test)
    return 0


if __name__ == "__main__":
    sys.exit(main())
