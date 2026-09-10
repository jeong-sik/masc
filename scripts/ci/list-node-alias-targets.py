#!/usr/bin/env python3
"""List the dune aliases whose action runs a node test, as build targets.

Five suites under test/ are node scripts run by a dune rule rather than a
linked executable: test_browser_elements, test_browser_screenshot,
test_browser_interact_extension, test_browser_scene_resource,
test_browser_connection_extension. Each asserts that the browser extension
and the OCaml driver carry the *same* injection script, a match that is kept
by hand across connectors/browser/extension/background.js and
lib/browser_{page,scene}_script.ml / lib/browser_interaction.ml.

Nothing ran them. `dune build @check` links test/ without running it, the
targeted runner builds `<dir>/<name>.exe` and these have no executable, and
the edited-test selector reads only `test/test_*.ml` (#34837). PR #34831
edited three of those source files and both node suites, and the check log
shows only the OCaml suite beside them.

Printing the targets rather than keeping a list in the workflow means a sixth
such rule joins by existing. The rules already declare what they watch, so
there is nothing here to keep in sync with them.

Usage: list-node-alias-targets.py [--self-test]
Prints one `@<dir>/<alias>` per line. Exits 1 when it finds none, because a
build line that expands to nothing reports success without running a suite.
"""

from __future__ import annotations

import argparse
import re
import sys
import tempfile
from pathlib import Path

ALIAS_RE = re.compile(r"\(alias\s+(runtest-[A-Za-z0-9_-]+)\)")
NODE_ACTION_RE = re.compile(r"\(action\s+\(run\s+node\b")
INCLUDE_RE = re.compile(r"\(include\s+([^\s()]+)\)")
DUNE_FILES = ("test/dune", "packages/*/test/dune")


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def top_level_forms(text: str) -> list[str]:
    """Split a dune file into balanced top-level parenthesised forms.

    Comments and strings are stepped over so neither can move the depth.
    """
    forms: list[str] = []
    depth = 0
    start = 0
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        if ch == ";":
            while i < n and text[i] != "\n":
                i += 1
            continue
        if ch == '"':
            i += 1
            while i < n and text[i] != '"':
                i += 2 if text[i] == "\\" else 1
            i += 1
            continue
        if ch == "(":
            if depth == 0:
                start = i
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                forms.append(text[start : i + 1])
        i += 1
    return forms


def node_aliases_in(text: str) -> list[str]:
    found = []
    for form in top_level_forms(text):
        if not form.startswith("(rule"):
            continue
        alias = ALIAS_RE.search(form)
        if alias and NODE_ACTION_RE.search(form):
            found.append(alias.group(1))
    return found


def collect(root: Path) -> list[str]:
    """Targets for every node rule, in the directory that owns its alias.

    A rule in an included .inc belongs to the directory of the dune file that
    includes it, not to the directory the .inc sits in -- which is why the
    include is resolved rather than the tree walked.
    """
    targets: list[str] = []
    dune_files: list[Path] = []
    for pattern in DUNE_FILES:
        if "*" in pattern:
            dune_files.extend(sorted(root.glob(pattern)))
        else:
            candidate = root / pattern
            if candidate.is_file():
                dune_files.append(candidate)
    for dune_file in dune_files:
        owner = dune_file.parent.relative_to(root)
        text = dune_file.read_text(encoding="utf-8", errors="replace")
        sources = [text]
        for included in INCLUDE_RE.findall(text):
            path = dune_file.parent / included
            if path.is_file():
                sources.append(path.read_text(encoding="utf-8", errors="replace"))
        for source in sources:
            for alias in node_aliases_in(source):
                targets.append(f"@{owner}/{alias}")
    return sorted(set(targets))


def self_test() -> int:
    """A node rule is a target, a python rule is not, and an include is owned
    by the directory that includes it."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp).resolve()
        test_dir = root / "test"
        (test_dir / "stanzas").mkdir(parents=True)
        (test_dir / "dune").write_text(
            "(rule\n"
            " (alias runtest-inline_node)\n"
            " (deps a.mjs)\n"
            " (action (run node %{dep:a.mjs})))\n"
            "\n"
            "(rule\n"
            " (alias runtest-a_python_one)\n"
            " (deps b.py)\n"
            " (action (run python3 %{dep:b.py})))\n"
            "\n"
            "(include stanzas/browser.inc)\n"
        )
        (test_dir / "stanzas" / "browser.inc").write_text(
            "(rule\n"
            " (alias runtest-included_node)\n"
            " (deps c.cjs ../lib/x.ml)\n"
            " (action (run node %{dep:c.cjs})))\n"
        )
        got = collect(root)
        want = ["@test/runtest-included_node", "@test/runtest-inline_node"]
        if got != want:
            print(f"self-test: FAIL got={got} want={want}")
            return 1
    print(
        "self-test: a node rule is a target, a python one is not, and an "
        "included rule is owned by the including directory (PASS)"
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true", help="check the reader")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    targets = collect(repo_root())
    if not targets:
        print(
            "ERROR: no dune rule under test/ runs a node suite. Either the "
            "browser extension parity rules were removed or this reader "
            "stopped matching them.",
            file=sys.stderr,
        )
        return 1
    for target in targets:
        print(target)
    return 0


if __name__ == "__main__":
    sys.exit(main())
