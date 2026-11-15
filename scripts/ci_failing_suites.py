#!/usr/bin/env python3
"""Name the test commands that failed in a full dune @runtest log.

Dune prints each test action as one block: the command line
`(cd <dir> && <command>)`, then everything the command wrote. A block is a
failure when dune put a `File "<dune file>", line N` location right before
its command line, or when the command wrote an Alcotest `[FAIL]` case line.
Dune does not print the location for every failing action, and a command
that is not Alcotest writes no `[FAIL]` line, so either mark is enough.

Alcotest repeats a failed case inside a box drawn with `│`; only the list
line, which starts with spaces, is counted.

Usage: ci_failing_suites.py <dune log>
Prints one line per failing command, in log order:
    <failed case count>  <dir>/<command>
"""
from __future__ import annotations

import re
import sys
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path

COMMAND_LINE = re.compile(r"^\(cd (?P<dir>\S+) && (?P<command>.+)\)$")
DUNE_LOCATION = re.compile(r'^File "[^"]*dune", line \d+')
ALCOTEST_FAILED_CASE = re.compile(r"^\s*\[FAIL\]")
# A sandboxed action runs under _build/.sandbox/<digest>/default/<dir>; an
# unsandboxed one under _build/default/<dir>. Both name the same source dir.
BUILD_CONTEXT = re.compile(r"^_build/(?:\.sandbox/[0-9a-f]+/)?default/")
# Dune's location is three lines: the `File` line, the quoted source line,
# and the caret line. The command line follows them.
LOCATION_BLOCK_LINES = 3


@dataclass(frozen=True, slots=True)
class FailingCommand:
    directory: str
    command: str
    failed_cases: int
    dune_named_it: bool


def failing_commands(lines: Iterable[str]) -> tuple[FailingCommand, ...]:
    found: list[FailingCommand] = []
    current: tuple[str, str, bool] | None = None
    failed_cases = 0
    since_location: int | None = None

    def close() -> None:
        if current is None:
            return
        directory, command, dune_named_it = current
        if failed_cases > 0 or dune_named_it:
            found.append(FailingCommand(directory, command, failed_cases, dune_named_it))

    for raw in lines:
        line = raw.rstrip("\n")
        matched = COMMAND_LINE.match(line)
        if matched is not None:
            close()
            directory = BUILD_CONTEXT.sub("", matched.group("dir"))
            current = (directory, matched.group("command"), since_location == LOCATION_BLOCK_LINES)
            failed_cases = 0
            since_location = None
            continue
        if DUNE_LOCATION.match(line) is not None:
            since_location = 1
            continue
        if since_location is not None:
            since_location += 1
        if ALCOTEST_FAILED_CASE.match(line) is not None:
            failed_cases += 1
    close()
    return tuple(found)


def render(commands: tuple[FailingCommand, ...]) -> str:
    return "".join(f"{c.failed_cases:3d}  {c.directory}/{c.command}\n" for c in commands)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        sys.stderr.write(f"usage: {Path(argv[0]).name} <dune log>\n")
        return 2
    with open(argv[1], encoding="utf-8", errors="replace") as log:
        sys.stdout.write(render(failing_commands(log)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
