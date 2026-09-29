#!/usr/bin/env python3
"""A PTY scenario keeps reading the terminal while it waits for a fixture.

The TUI writes each frame with a blocking stdout write. A scenario that sits
in a bare ``event.wait(n)`` stops reading the master fd, the PTY buffer fills,
and the write blocks the whole domain -- the Eio fiber that would send the
awaited request included. The request then never arrives, and the wait times
out. ``first_use_frames`` failed this way on CI while the startup candle drew
(#39760), and was fixed twice on two branches before anyone looked for the
other sites.

A function holds the terminal when it takes ``output`` and ``fd`` or
``master_fd`` -- every PTY ``interact`` callback and harness helper does. Any
``<x>.wait(...)`` in such a function, or in a closure defined inside it, is
reported, unless it sits in a ``while`` loop that also calls
``read_available``: that loop drains the terminal between waits, which is what
``wait_for_fixture_event`` does. ``process.wait`` is Popen's own and is not an
event. A fixture handler runs on the fixture server's thread, so a wait inside
one is not reported unless the handler is defined inside a terminal holder.
"""

from __future__ import annotations

import ast
import subprocess
import sys
from collections.abc import Iterator
from pathlib import Path

TERMINAL_FDS = ("fd", "master_fd")
DRAIN = "read_available"
POPEN = "process"


def holds_terminal(function: ast.FunctionDef) -> bool:
    names = {arg.arg for arg in function.args.args + function.args.kwonlyargs}
    return "output" in names and any(fd in names for fd in TERMINAL_FDS)


def calls_drain(node: ast.AST) -> bool:
    for call in ast.walk(node):
        if isinstance(call, ast.Call):
            func = call.func
            if isinstance(func, ast.Name) and func.id == DRAIN:
                return True
            if isinstance(func, ast.Attribute) and func.attr == DRAIN:
                return True
    return False


def is_event_wait(call: ast.Call) -> bool:
    func = call.func
    if not (isinstance(func, ast.Attribute) and func.attr == "wait"):
        return False
    return not (isinstance(func.value, ast.Name) and func.value.id == POPEN)


def findings(source: str, path: str) -> Iterator[str]:
    tree = ast.parse(source, filename=path)

    def visit(node: ast.AST, holder: str | None, draining: bool) -> Iterator[str]:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            if holder is None and isinstance(node, ast.FunctionDef) and holds_terminal(node):
                holder = node.name
            # A closure starts outside any loop of the function around it.
            draining = False
        elif isinstance(node, ast.While):
            draining = draining or calls_drain(node)
        elif isinstance(node, ast.Call) and holder is not None and not draining and is_event_wait(node):
            yield (
                f"{path}:{node.lineno}: {ast.unparse(node)} in {holder} stops reading the PTY; "
                "wait through wait_for_fixture_event(process, fd, output, event, timeout=...)"
            )
        for child in ast.iter_child_nodes(node):
            yield from visit(child, holder, draining)

    yield from visit(tree, None, False)


def tracked_test_files(root: Path) -> list[Path]:
    listed = subprocess.run(
        ["git", "ls-files", "--", "test/*.py"],
        cwd=root, check=True, capture_output=True, text=True,
    ).stdout.split()
    return [root / name for name in listed]


SELF_TEST_CASES = (
    (
        "bare wait in interact",
        "def interact(process, fd, _slave, output, _base):\n"
        "    if not requested.wait(10):\n"
        "        raise AssertionError('late')\n",
        1,
    ),
    (
        "bare wait in a closure inside interact",
        "def interact(process, master_fd, _slave, output, _base):\n"
        "    def key():\n"
        "        posted.wait(5)\n"
        "    key()\n",
        1,
    ),
    (
        "wait through the helper",
        "def interact(process, fd, _slave, output, _base):\n"
        "    keyboard.wait_for_fixture_event(process, fd, output, requested, timeout=10)\n",
        0,
    ),
    (
        "wait in a loop that drains",
        "def wait_for_fixture_event(process, master_fd, output, event, *, timeout):\n"
        "    while not event.is_set():\n"
        "        read_available(master_fd, output)\n"
        "        event.wait(timeout=0.05)\n",
        0,
    ),
    (
        "loop that drains through a module alias",
        "def interact(process, fd, _slave, output, _base):\n"
        "    while pending():\n"
        "        h.read_available(fd, output)\n"
        "        with admitted:\n"
        "            admitted.wait(timeout=0.02)\n",
        0,
    ),
    (
        "loop that does not drain",
        "def interact(process, fd, _slave, output, _base):\n"
        "    while pending():\n"
        "        admitted.wait(timeout=0.02)\n",
        1,
    ),
    (
        "fixture handler outside any terminal holder",
        "def run(executable):\n"
        "    def briefing():\n"
        "        release.wait(30)\n"
        "        return 200, {}\n",
        0,
    ),
    (
        "Popen wait",
        "def wait_for_stop(process, master_fd, output):\n"
        "    process.wait(timeout=2.0)\n",
        0,
    ),
)


def self_test() -> int:
    failed = 0
    for label, source, expected in SELF_TEST_CASES:
        found = list(findings(source, "<self-test>"))
        if len(found) != expected:
            failed += 1
            print(f"self-test {label!r}: expected {expected} finding(s), got {found!r}", file=sys.stderr)
    if failed:
        return 1
    print(f"PTY wait guard self-test: {len(SELF_TEST_CASES)} cases pass")
    return 0


def main(argv: list[str]) -> int:
    if argv[1:] == ["--self-test"]:
        return self_test()
    if argv[1:]:
        print("usage: check-pty-waits-read-the-terminal.py [--self-test]", file=sys.stderr)
        return 2
    root = Path(__file__).resolve().parents[2]
    found = [
        finding
        for path in tracked_test_files(root)
        for finding in findings(path.read_text(encoding="utf-8"), str(path.relative_to(root)))
    ]
    for finding in found:
        print(finding)
    if found:
        return 1
    print("PTY waits read the terminal: no bare wait in a terminal holder")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
