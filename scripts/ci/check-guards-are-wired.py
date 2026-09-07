#!/usr/bin/env python3
"""Every check script under scripts/ has to be reachable from something CI runs.

A guard nobody runs is a document. This repository has learned that three
times: the cancel-guard lint drifted to 32 violations and back to 0 with no
run reporting either move; check-tui-render-purity.sh sat at two writes
against a budget of zero on untouched main; and a sweep on 2026-09-07 found
four more guards red while unreachable, including an operator surface stating
a default the code does not use.

What "reachable" means here is deliberately generous. A guard reached from a
workflow, a Makefile fragment, a dune rule, a test stanza, or from another
script that is itself reached, counts. The point is to catch a guard that is
reached from nowhere at all, not to audit how it is called.

The reachability calculation has a seed, and a seed can miss a wiring
mechanism -- which would report a wired guard as unwired and send a reader
after nothing. So the seed is checked before it is used: SELF_CHECK names one
guard per mechanism, and if any of them comes out unreachable this exits
saying the method is wrong rather than printing a list.
"""

from __future__ import annotations

import os
import re
import sys

SKIP_DIRS = {".git", "_build", "node_modules", ".worktrees", "_opam", "dist"}
SCRIPT_SUFFIXES = (".sh", ".py")
GUARD_NAME = re.compile(r"(lint|check|guard|ratchet)")

# One guard per wiring mechanism, and where its name is written. A mechanism
# the seed loses shows up here as the file that names it no longer naming it,
# which is a fact about the seed rather than about the guard.
#
# The named file matters. Checking these against the reachability answer would
# pass on a guard some third script happens to mention, while the seed had
# dropped the mechanism entirely -- an assertion that cannot fail.
SELF_CHECK = {
    "scripts/ci/run-lint-suite.sh": "the seed: a workflow step",
    "scripts/check-variants.sh": "the seed: a Makefile fragment under mk/",
    "scripts/ci/check-telemetry-coverage.sh": "the seed: a dune test stanza",
    "scripts/ci/check-tui-render-purity.sh": "scripts/ci/run-lint-suite.sh",
}

BASELINE = os.path.join("scripts", "ci", "guards-not-wired.txt")


def repo_root() -> str:
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.abspath(os.path.join(here, "..", ".."))


def walk(root: str):
    for directory, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for name in files:
            yield directory, name


def without_comments(text: str) -> str:
    """[text] with each line cut at its first '#'.

    A name written in a comment is not a call. Without this, saying in
    run-lint-suite.sh that some guard is deliberately *not* wired makes this
    check believe it is -- an escape hatch that reads as documentation, which
    is the worst kind.

    Cutting at the first '#' also cuts one inside a string literal. That makes
    the check stricter, never more permissive: the cost is a guard reported as
    unwired when it is called through such a line, which fails loudly and is
    answered by a line in the baseline. The other direction is silent.
    """
    return "\n".join(line.split("#", 1)[0] for line in text.splitlines())


def read(path: str) -> str:
    try:
        with open(path, encoding="utf-8", errors="ignore") as handle:
            return handle.read()
    except OSError:
        return ""


def is_seed(directory: str, name: str) -> bool:
    """A file that can name a script and have it run."""
    if os.sep + ".github" in directory + os.sep:
        return True
    if name in ("dune", "dune-project", "Makefile"):
        return True
    return name.endswith((".yml", ".yaml", ".mk", ".inc"))


def main() -> int:
    root = repo_root()
    scripts: dict[str, str] = {}
    for directory, name in walk(os.path.join(root, "scripts")):
        if not name.endswith(SCRIPT_SUFFIXES):
            continue
        path = os.path.relpath(os.path.join(directory, name), root)
        scripts[path] = without_comments(read(os.path.join(root, path)))
    by_name = {os.path.basename(p): p for p in scripts}

    seed = []
    for directory, name in walk(root):
        if is_seed(directory, name):
            # Not comment-stripped: a workflow's YAML comment marker is the
            # same character a shell command's argument can carry, and a
            # workflow that names a guard in a comment is not the failure this
            # is about. The script-to-script edge is where a comment silences.
            seed.append(read(os.path.join(directory, name)))
    seed_text = "\n".join(seed)

    reached = {p for base, p in by_name.items() if base in seed_text}
    frontier = list(reached)
    while frontier:
        current = frontier.pop()
        body = scripts.get(current, "")
        for base, path in by_name.items():
            if path not in reached and path != current and base in body:
                reached.add(path)
                frontier.append(path)

    missed = []
    for path, where in SELF_CHECK.items():
        base = os.path.basename(path)
        if where.startswith("the seed:"):
            present = base in seed_text
        else:
            present = base in scripts.get(where, "")
        if not present:
            missed.append((path, where))
    if missed:
        print("FAIL: this check's own method is wrong, so its answer is not usable.")
        for path, why in missed:
            print(f"  {path} is wired through {why}, and that no longer names it.")
        print("  Teach [is_seed] that mechanism before reading anything below.")
        return 1

    guards = sorted(p for p in scripts if GUARD_NAME.search(os.path.basename(p)))
    unwired = sorted(p for p in guards if p not in reached)
    baseline_path = os.path.join(root, BASELINE)
    # A line may carry a trailing note; the path is what is compared.
    baseline = sorted(
        line.split("#", 1)[0].strip()
        for line in read(baseline_path).splitlines()
        if line.split("#", 1)[0].strip()
    )

    if "--print-unwired" in sys.argv:
        for path in unwired:
            print(path)
        return 0

    print(f"guards: {len(guards)}, reached: {len(guards) - len(unwired)}, not wired: {len(unwired)}")

    added = [p for p in unwired if p not in baseline]
    gone = [p for p in baseline if p not in unwired]
    if added:
        print("FAIL: a check script is reached from nothing CI runs.", file=sys.stderr)
        for path in added:
            print(f"  {path}", file=sys.stderr)
        print(
            "  Call it from scripts/ci/run-lint-suite.sh, or add it to\n"
            f"  {BASELINE} saying it is a developer tool.",
            file=sys.stderr,
        )
        return 1
    if gone:
        print("FAIL: one of these is wired now. Remove it from the baseline.", file=sys.stderr)
        for path in gone:
            print(f"  {path}", file=sys.stderr)
        return 1
    print("every check script is reached, or listed as one that is not.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
