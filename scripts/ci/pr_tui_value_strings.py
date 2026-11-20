#!/usr/bin/env python3
# pyright: strict
"""Refuse a pull request whose changed TUI files write a count by hand.

RFC tui-one-screen-grammar 6.3 writes a count that was cut off as
`Masc_tui_value.Count.more` ("12 more", "외 12"), a count that grew as
`Count.increase` ("+3") and one that shrank as `Count.decrease` ("−3", with a
minus sign). Reviews moved every hand-written spelling to those functions, and
later pull requests wrote them by hand again (RFC
tui-hand-written-counts-fail-the-pr-check). This script reads the string
literals of the TUI files a pull request changes and fails on three shapes:

- cut-off: `%d more`, `+%d more`, `(+%d)`, a word that starts with `외 %d`
- plus: `+%d` at the start of a literal or after a space, `(`, `[` or `/`
- hyphen-minus: `-%d` in the same places

`%s` counts as `%d`. A literal whose plus sign is not a count (an editor's
`+12` line argument, how late a run is) carries a marker, a comment
`(* tui-value: <reason> *)`. The marker frees the literals that start on a
line it covers or on the line after it, nothing else. A marker with an empty
reason fails the check.

The `changes` job of .github/workflows/pr-type-check.yml runs this against the
blobless fetch of the pull request's merge commit it already holds. Only the
files the pull request adds or edits are read, as the difference between the
merge commit and its first parent, and each is read whole: a hit on a line the
pull request did not touch still fails it (decision D1). Any git failure exits
non-zero.
"""

from __future__ import annotations

import argparse
import enum
import os
import pathlib
import re
import subprocess
import tempfile
from dataclasses import dataclass

_SHA = re.compile(r"[0-9a-f]{40}")
SCOPE = re.compile(r"bin/(?:masc_tui[^/]*|tui/.+)\.ml")

_IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_']*")
_CHAR = re.compile(r"'(?:[^\\'\n]|\\(?:[\\\"'ntbr ]|[0-9]{3}|x[0-9a-fA-F]{2}|o[0-3][0-7]{2}))'")
_QUOTED_OPEN = re.compile(r"\{([a-z_]*)\|")
_MARKER = re.compile(r"\(\*\s*tui-value:(.*)\*\)", re.DOTALL)


class Rule(enum.Enum):
    CUT_OFF = "cut-off"
    PLUS = "plus"
    HYPHEN_MINUS = "hyphen-minus"


_PATTERNS: tuple[tuple[Rule, re.Pattern[str], str], ...] = (
    (Rule.CUT_OFF,
     re.compile(r"\+?%[ds] more|\(\+%[ds]\)|(?:^|[ (])외 %[ds]"),
     "Masc_tui_value.Count.more"),
    (Rule.PLUS, re.compile(r"(?:^|[ (\[/])\+%[ds]"), "Masc_tui_value.Count.increase"),
    (Rule.HYPHEN_MINUS, re.compile(r"(?:^|[ (\[/])-%[ds]"), "Masc_tui_value.Count.decrease"),
)


@dataclass(frozen=True, slots=True)
class Literal:
    line: int
    text: str


@dataclass(frozen=True, slots=True)
class Marker:
    first_line: int
    last_line: int
    reason: str

    def frees(self, literal: Literal) -> bool:
        return self.first_line <= literal.line <= self.last_line + 1


@dataclass(frozen=True, slots=True)
class Lexed:
    literals: tuple[Literal, ...]
    markers: tuple[Marker, ...]


@dataclass(frozen=True, slots=True)
class Hit:
    line: int
    rule: Rule
    text: str
    instead: str


@dataclass(frozen=True, slots=True)
class Findings:
    hits: tuple[Hit, ...]
    empty_markers: tuple[Marker, ...]
    marked: int
    markers: int


def lex(source: str) -> Lexed:
    """String literals outside comments, and marker comments, with the line
    each starts on.

    Comments nest, and a string or a character literal inside a comment is
    read as one so that `"*)"` there does not end the comment. An identifier
    is read whole so that the prime in `x'` does not start a character
    literal. `{id|...|id}` is a string whose body is read as written.
    """
    literals: list[Literal] = []
    markers: list[Marker] = []
    i, n, line, depth = 0, len(source), 1, 0
    comment_start, comment_line = 0, 0
    while i < n:
        c = source[i]
        if c == "\n":
            line += 1
            i += 1
            continue
        if source.startswith("(*", i):
            if depth == 0:
                comment_start, comment_line = i, line
            depth += 1
            i += 2
            continue
        if depth > 0 and source.startswith("*)", i):
            depth -= 1
            i += 2
            if depth == 0:
                marker = _MARKER.fullmatch(source, comment_start, i)
                if marker is not None:
                    markers.append(Marker(comment_line, line, marker.group(1).strip()))
            continue
        ident = _IDENT.match(source, i)
        if ident is not None:
            i = ident.end()
            continue
        char = _CHAR.match(source, i)
        if char is not None:
            i = char.end()
            continue
        quoted = _QUOTED_OPEN.match(source, i)
        if quoted is not None:
            close = "|" + quoted.group(1) + "}"
            end = source.find(close, quoted.end())
            body_end = n if end < 0 else end
            body = source[quoted.end():body_end]
            if depth == 0:
                literals.append(Literal(line, body))
            line += body.count("\n")
            i = n if end < 0 else end + len(close)
            continue
        if c == '"':
            start_line, j = line, i + 1
            pieces: list[str] = []
            while j < n and source[j] != '"':
                step = source[j:j + 2] if source[j] == "\\" else source[j]
                line += step.count("\n")
                pieces.append(step)
                j += len(step)
            if depth == 0:
                literals.append(Literal(start_line, "".join(pieces)))
            i = j + 1
            continue
        i += 1
    return Lexed(tuple(literals), tuple(markers))


def judge(lexed: Lexed) -> Findings:
    reasoned = tuple(m for m in lexed.markers if m.reason)
    hits: list[Hit] = []
    marked = 0
    for literal in lexed.literals:
        found = [
            Hit(literal.line, rule, literal.text, instead)
            for rule, pattern, instead in _PATTERNS
            if pattern.search(literal.text)
        ]
        if not found:
            continue
        if any(marker.frees(literal) for marker in reasoned):
            marked += 1
            continue
        hits.extend(found)
    empty = tuple(m for m in lexed.markers if not m.reason)
    return Findings(tuple(hits), empty, marked, len(lexed.markers))


def _git(git_dir: str, *args: str, index: pathlib.Path | None = None) -> str:
    env = None if index is None else {**os.environ, "GIT_INDEX_FILE": str(index)}
    done = subprocess.run(
        ["git", "--literal-pathspecs", "-C", git_dir, *args],
        check=True, stdout=subprocess.PIPE, text=True, env=env,
    )
    return done.stdout


def changed_tui_files(git_dir: str, merge: str) -> tuple[str, ...]:
    """TUI sources the pull request adds or edits. --no-renames lists a moved
    file under its new name; --diff-filter=d drops the files it removes."""
    out = _git(
        git_dir, "diff", "--name-only", "-z", "--no-renames", "--diff-filter=d",
        f"{merge}^1", merge, "--", "bin/",
    )
    return tuple(path for path in out.split("\0") if SCOPE.fullmatch(path))


def check(git_dir: str, merge: str) -> int:
    paths = changed_tui_files(git_dir, merge)
    if not paths:
        print("tui-value: this pull request changes no TUI source file")
        return 0
    failed = 0
    marked = 0
    markers = 0
    with tempfile.TemporaryDirectory(prefix="pr-tui-value-strings-") as tmp:
        tree = pathlib.Path(tmp) / "tree"
        tree.mkdir()
        # The fetch was blobless: git asks the promisor remote for exactly
        # these files, and records them in a scratch index.
        _git(git_dir, f"--work-tree={tree}", "checkout", "-q", merge, "--", *paths,
             index=pathlib.Path(tmp) / "index")
        for path in paths:
            findings = judge(lex((tree / path).read_text(encoding="utf-8")))
            marked += findings.marked
            markers += findings.markers
            for hit in findings.hits:
                failed += 1
                print(f"{path}:{hit.line}: {hit.rule.value}: {hit.text!r} -> {hit.instead}")
            for marker in findings.empty_markers:
                failed += 1
                print(f"{path}:{marker.first_line}: marker: the reason after tui-value: is empty")
    print(f"tui-value: {len(paths)} files read, {failed} failures, "
          f"{marked} literals freed by {markers} markers")
    if failed:
        print("Write the count with the function named after ->, or, when the sign is "
              "not a count, put (* tui-value: <reason> *) on the literal's line or the "
              "line above it (RFC tui-hand-written-counts-fail-the-pr-check).")
        return 1
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--git-dir", required=True, help="repository holding the merge commit")
    parser.add_argument("--merge", required=True, help="the pull request's merge commit")
    args = parser.parse_args()
    git_dir: str = args.git_dir
    merge: str = args.merge
    if _SHA.fullmatch(merge) is None:
        parser.error("--merge must be a full commit sha")
    return check(git_dir, merge)


if __name__ == "__main__":
    raise SystemExit(main())
