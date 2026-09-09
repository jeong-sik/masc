#!/usr/bin/env python3
"""Report candidates that may have only inline-test callers.

This is a lexical advisory, not an OCaml reachability proof. Inline tests need
not end with ;;, comments and strings may contain names, and a same-line
production use is not counted. Release compilation is the authority; findings
must be checked against source before removing code or suppressing warnings.

`dune build --release` drops ppx inline tests. A top-level value that no
`.mli` exports and that nothing outside a `let%test` block calls therefore
has no caller at all in the release build, and `-w +32 -warn-error +a` turns
that into a build failure.

The PR gate builds the dev profile, where the inline test *is* a caller, so
this state reaches main and surfaces later from whichever workflow happens to
run a release build. Three values took that path (#34848, #34861, fixed in
#34876); the release build that caught them runs behind a `paths:` filter and
covers two executables, so it is not a gate this can rely on (#34878).

Reported values are not necessarily wrong to have: the fix is to delete the
value and rewrite the test against the surface production actually uses, or,
when the helper genuinely exists for the test, to annotate the binding
(`let[@warning "-32"] name = ...`), which this guard skips.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

TEST_START = ("let%test", "let%expect_test", "let%test_module", "let%test_unit")
VAL_RE = re.compile(r"^val\s+(?:\(\s*)?([a-z_][A-Za-z0-9_']*)", re.M)
LET_RE = re.compile(r"^let (?:rec )?([a-z_][A-Za-z0-9_']*)\b")
SKIP_DIRS = ("test/", "/test/", "_build/", ".worktrees/")


def tracked_ml(root: Path) -> list[Path]:
    out = subprocess.run(
        ["git", "-C", str(root), "ls-files", "*.ml"],
        capture_output=True, text=True, check=True,
    ).stdout.split()
    return [root / p for p in out if not any(s in "/" + p for s in SKIP_DIRS)]


def test_spans(lines: list[str]) -> list[tuple[int, int]]:
    """Line ranges each inline test occupies, inclusive of its `;;`."""
    spans: list[tuple[int, int]] = []
    i = 0
    while i < len(lines):
        if lines[i].startswith(TEST_START):
            j = i
            while j < len(lines) and lines[j].rstrip() != ";;":
                j += 1
            spans.append((i, j))
            i = j + 1
        else:
            i += 1
    return spans


def violations(root: Path) -> list[tuple[str, int, str]]:
    found: list[tuple[str, int, str]] = []
    for ml in tracked_ml(root):
        mli = ml.with_suffix(".mli")
        if not mli.exists():
            continue
        exported = set(VAL_RE.findall(mli.read_text(encoding="utf-8", errors="replace")))
        lines = ml.read_text(encoding="utf-8", errors="replace").split("\n")
        spans = test_spans(lines)
        if not spans:
            continue

        def in_test(line_no: int) -> bool:
            return any(a <= line_no <= b for a, b in spans)

        for i, line in enumerate(lines):
            if in_test(i):
                continue
            m = LET_RE.match(line)
            if not m:
                continue
            name = m.group(1)
            if name in exported:
                continue
            word = re.compile(r"\b" + re.escape(name) + r"\b")
            uses = [j for j, other in enumerate(lines) if j != i and word.search(other)]
            if uses and all(in_test(j) for j in uses):
                found.append((str(ml.relative_to(root)), i + 1, name))
    return found


def run_self_test() -> int:
    import tempfile

    failures: list[str] = []
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        subprocess.run(["git", "-C", tmp, "init", "-q"], check=True)
        lib = root / "lib"
        lib.mkdir()
        (lib / "sample.mli").write_text("val exported_helper : unit -> int\n")
        (lib / "sample.ml").write_text(
            "let exported_helper () = 0\n"
            "let test_only_helper () = 1\n"
            "let production_helper () = 2\n"
            "let exported_helper2 () = production_helper ()\n"
            "\n"
            'let%test "reads the test-only helper" =\n'
            "  test_only_helper () = 1\n"
            ";;\n"
        )
        subprocess.run(["git", "-C", tmp, "add", "-A"], check=True)
        found = {name for _f, _l, name in violations(root)}
        if "test_only_helper" not in found:
            failures.append("value reachable only from an inline test not reported")
        if "production_helper" in found:
            failures.append("value with a production caller reported")
        if "exported_helper" in found:
            failures.append("exported value reported")

    for line in failures:
        print(f"self-test FAIL: {line}", file=sys.stderr)
    if failures:
        return 1
    print("self-test OK")
    return 0


def main(argv: list[str]) -> int:
    if "--self-test" in argv:
        return run_self_test()
    root = Path(
        subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
    )
    found = violations(root)
    if not found:
        print("[inline-test-only] no candidates found by lexical scan")
        return 0
    print(
        f"[inline-test-only] {len(found)} candidate(s) need reachability review.\n"
        "Lexical test spans can include real production callers; verify against\n"
        "OCaml source and release compilation before changing code.\n",
        file=sys.stderr,
    )
    for path, line, name in found:
        print(f"  {path}:{line}  {name}", file=sys.stderr)
    print(
        "\nA candidate is not proof that deleting or annotating the value is safe.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
