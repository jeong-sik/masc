#!/usr/bin/env python3
"""Self-test for dune_suite_scope.py (RFC-0428).

The tool decides whether a test suite can be run by executing its binary,
and the report-only step trusts that answer. A wrong "run" makes the step
report a failure the change did not cause -- which is how a report stops
being read -- so the shapes it has to tell apart are written out here as
synthetic dune files rather than argued for in prose.

Run directly: `python3 scripts/ci/test_dune_suite_scope.py`
Exits 0 on success, 1 on the first failed expectation.
"""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts" / "ci"))

from dune_suite_scope import scope  # noqa: E402

failures: list[str] = []


def check(label: str, dune: str, name: str, expected: str, *, inc: str | None = None):
    """Write a dune file into a throwaway directory and read the verdict."""
    with tempfile.TemporaryDirectory() as raw:
        directory = Path(raw)
        (directory / "dune").write_text(dune, encoding="utf-8")
        if inc is not None:
            (directory / "stanzas").mkdir()
            (directory / "stanzas" / f"{name}.inc").write_text(inc, encoding="utf-8")
        got = scope(str(directory), name)
    if expected == "run":
        ok = got == "run"
    else:
        ok = got.startswith("skip")
    if not ok:
        failures.append(f"{label}: expected {expected}, got {got!r}")


# A suite with nothing dune has to supply is the case the step exists for.
check("plain test stanza", "(test (name test_x) (libraries alcotest))", "test_x", "run")
check(
    "one name inside a group",
    "(tests (names test_a test_b test_c) (libraries alcotest))",
    "test_b",
    "run",
)

# Every shape where executing the binary is not what dune does.
check(
    "deps belong to the runtest action",
    "(test (name test_x) (deps ../bin/main_eio.exe))",
    "test_x",
    "skip",
)
check(
    "a custom action carries the environment",
    '(test (name test_x) (action (setenv MASC_BASE_PATH "b" (run %{test}))))',
    "test_x",
    "skip",
)
check(
    "a conditionally disabled stanza has no executable",
    '(test (name test_x) (enabled_if (= %{env:MASC_E2E_TESTS=false} true)))',
    "test_x",
    "skip",
)
check(
    "a group's deps reach every name in it",
    "(tests (names test_a test_b) (deps ../config/runtime.toml))",
    "test_a",
    "skip",
)

# A source can be compiled without being a suite. Reading a filename as an
# executable name is what made those report as a link failure.
check(
    "a module that is not an executable",
    "(test (name test_other) (modules test_other test_x))",
    "test_x",
    "skip",
)
check("nothing declares it", "(test (name test_other))", "test_x", "skip")
check(
    "two stanzas claim the name",
    "(test (name test_x))\n(tests (names test_x test_y))",
    "test_x",
    "skip",
)

# The splitter has to find the end of a form whatever the form contains.
check(
    "a paren inside a string does not move the balance",
    '(test (name test_x) (action (run %{test} "a ) b")))',
    "test_x",
    "skip",
)
check(
    "a comment does not open a form",
    "; (test (name test_x) (deps d))\n(test (name test_x))",
    "test_x",
    "run",
)

# test/dune reaches its per-suite stanzas through (include stanzas/x.inc),
# so a verdict that stops at the top file answers about the wrong stanza.
check(
    "an included stanza is read",
    "(include stanzas/test_x.inc)",
    "test_x",
    "run",
    inc="(test (name test_x) (libraries alcotest))",
)
check(
    "an included stanza's deps are read too",
    "(include stanzas/test_x.inc)",
    "test_x",
    "skip",
    inc="(test (name test_x) (deps ../config/runtime.toml))",
)

with tempfile.TemporaryDirectory() as raw:
    verdict = scope(raw, "test_x")
    if not verdict.startswith("skip"):
        failures.append(f"a directory with no dune file: got {verdict!r}")

if failures:
    print("dune_suite_scope self-test failed:")
    for failure in failures:
        print(f"  {failure}")
    sys.exit(1)

print("dune_suite_scope self-test: every shape reads as expected")
