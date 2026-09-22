#!/usr/bin/env python3
"""Name the suites whose source refers to what a pull request changed.

run-edited-tests.sh already matches a suite to a change by the suite's file
name, by the library its dune stanza links, and by a quoted path. Three pull
requests merged with a suite red that none of those reached (RFC-0428,
"넓힌 선택"): #29365 and #36885 changed modules that the red suites call by
name, and #36885 also changed scripts/install-runtime-setup.py, which its red
Python suite runs. This answers those two shapes.

Usage: referencing_suites.py < changed-paths

Prints "module <suite>" and "file <suite>" lines, sorted, one per suite a
rule names; a suite both rules name is printed under each.

module: for each changed .ml or .mli under bin/, lib/ or packages/*/lib/,
the .ml suites whose code refers to that module -- a qualified path (Foo.x),
open, include, a module alias, or a first-class module. Comments and string
literals are removed first, so a suite that only mentions the name in prose
is not one that calls it.

file: for each changed file that is not OCaml source and not under test/,
the .ml and .py suites whose text contains its file name, when no other
tracked file has that name. A shared name does not say which file a suite
means -- 79 suites contain "dune" -- and a suite that names one exact path is
already found by the quoted-path mapping.

exactpath: for each changed file that is not OCaml source and not under
test/, the suites whose text contains its exact path, in either quote
style. OCaml source is left to the module rule above, which already names
its suites; an exact-path match on lib/runtime/runtime.ml would select
every suite that mentions the file. The file rule above
skips a shared basename because the name alone does not say which file a
suite means, and the quoted-literal mapping in run-edited-tests.sh matches
only double-quoted OCaml literals -- so a Python suite that opens
'scripts/fixtures/release-evidence/runtime.toml' with single quotes, while a
transport-harness runtime.toml shares the basename, was invisible to both:
#37396's incident 4 merged with test_setup_cli.py unselected. An exact path
is the claim the file rule waits for, whatever the basename, and a single
quote is as much a literal as a double one. A path that is merely a prefix
of a longer name -- runtime.toml inside runtime.toml.bak -- is not the file.

Suite paths are relative to the repository root. Exits 1 on any argument
or when the tracked file list cannot be read.
"""

from __future__ import annotations

import collections
import functools
import re
import subprocess
import sys
from pathlib import Path, PurePosixPath

SUITE = re.compile(
    r"^(test|packages/[^/]+/test)/([a-z0-9_]+/)?test_[a-z0-9_]+\.(ml|py)$"
)
MODULE_SOURCE = re.compile(r"^(bin|lib|packages/[^/]+/lib)/.*\.mli?$")
IDENT = r"[A-Z][A-Za-z0-9_']*"
REFERENCES = (
    re.compile(rf"\b({IDENT})\."),
    re.compile(rf"\b(?:open!?|include)\s+(?:{IDENT}\.)*({IDENT})"),
    re.compile(rf"\bmodule\s+{IDENT}\s*=\s*(?:{IDENT}\.)*({IDENT})"),
    re.compile(rf"\(\s*module\s+(?:{IDENT}\.)*({IDENT})"),
)
CHAR_LITERAL = re.compile(
    r"'(?:\\(?:[\\'\"ntbr ]|[0-9]{3}|x[0-9a-fA-F]{2}|o[0-3][0-7]{2})|[^\\'\n])'"
)
SPECIAL = re.compile(r"\(\*|\*\)|\"|\{[a-z_]*\||'")
# A file name inside a longer name is not that file: install.sh is not
# masc-install.sh.
NAME_CHAR = r"A-Za-z0-9_.\-"


def skip_string(text: str, start: int) -> int:
    """Index just past the string literal whose opening quote is at start."""
    i = start + 1
    while i < len(text):
        if text[i] == "\\":
            i += 2
        elif text[i] == '"':
            return i + 1
        else:
            i += 1
    return len(text)


def ocaml_code(text: str) -> str:
    """The text with comments and string literals blanked.

    OCaml comments nest, and a string inside a comment is lexed as a string,
    so a `*)` inside it does not close the comment. Character literals are
    skipped whole so '"' does not open a string.
    """
    out: list[str] = []
    depth = 0
    i = 0
    n = len(text)
    while i < n:
        token = SPECIAL.search(text, i)
        if token is None:
            if depth == 0:
                out.append(text[i:])
            break
        if depth == 0:
            out.append(text[i : token.start()])
        lexeme = token.group(0)
        i = token.end()
        if lexeme == "(*":
            depth += 1
            out.append(" ")
        elif lexeme == "*)":
            if depth:
                depth -= 1
            else:
                out.append(lexeme)
        elif lexeme == '"':
            i = skip_string(text, token.start())
            out.append(" ")
        elif lexeme == "'":
            char = CHAR_LITERAL.match(text, token.start())
            if char:
                i = char.end()
                out.append(" ")
            elif depth == 0:
                out.append(lexeme)
        else:
            close = "|" + lexeme[1:-1] + "}"
            end = text.find(close, i)
            i = n if end < 0 else end + len(close)
            out.append(" ")
    return "".join(out)


def referenced_modules(text: str) -> set[str]:
    code = ocaml_code(text)
    names: set[str] = set()
    for pattern in REFERENCES:
        names.update(pattern.findall(code))
    return names


def refers_to(text: str, modules: set[str]) -> bool:
    # Most suites never spell any of the names; skip lexing those.
    if not any(module in text for module in modules):
        return False
    return bool(modules & referenced_modules(text))


def module_name(path: str) -> str:
    stem = PurePosixPath(path).name.split(".", 1)[0]
    return stem[:1].upper() + stem[1:]


def tracked_files(root: Path) -> list[str]:
    listed = subprocess.run(
        ["git", "ls-files", "-z"], cwd=root, capture_output=True, check=True
    )
    return [p for p in listed.stdout.decode().split("\0") if p]


@functools.cache
def read(root: Path, path: str) -> str:
    return (root / path).read_text(encoding="utf-8", errors="replace")


def module_suites(root: Path, tracked: list[str], changed: list[str]) -> set[str]:
    modules = {module_name(p) for p in changed if MODULE_SOURCE.match(p)}
    if not modules:
        return set()
    return {
        suite
        for suite in tracked
        if SUITE.match(suite)
        and suite.endswith(".ml")
        and refers_to(read(root, suite), modules)
    }


def file_suites(root: Path, tracked: list[str], changed: list[str]) -> set[str]:
    counts = collections.Counter(PurePosixPath(p).name for p in tracked)
    tracked_set = set(tracked)
    patterns = []
    for path in changed:
        if path.startswith("test/") or path.endswith((".ml", ".mli")):
            continue
        name = PurePosixPath(path).name
        others = counts[name] - (1 if path in tracked_set else 0)
        if others == 0:
            patterns.append(
                (
                    name,
                    re.compile(
                        rf"(?<![{NAME_CHAR}]){re.escape(name)}(?![{NAME_CHAR}])"
                    ),
                )
            )
    if not patterns:
        return set()
    return {
        suite
        for suite in tracked
        if SUITE.match(suite)
        and any(
            name in read(root, suite) and bounded.search(read(root, suite))
            for name, bounded in patterns
        )
    }


def exactpath_suites(root: Path, tracked: list[str], changed: list[str]) -> set[str]:
    # The file rule skips a shared basename; the quoted-literal mapping in
    # run-edited-tests.sh matches only double quotes. This rule takes the
    # exact path in either quote style, which is the claim the file rule
    # waits for: incident 4 of #37396 changed
    # scripts/fixtures/release-evidence/runtime.toml while
    # scripts/fixtures/transport-harness/runtime.toml shared its basename,
    # and test_setup_cli.py opens it with single quotes -- invisible to both
    # rules above. A path that is a prefix of a longer name is not the file.
    paths = [
        path
        for path in changed
        if not path.startswith("test/") and not path.endswith((".ml", ".mli"))
    ]
    if not paths:
        return set()
    patterns = [
        (path, re.compile(rf"(?<![{NAME_CHAR}]){re.escape(path)}(?![{NAME_CHAR}])"))
        for path in paths
    ]
    return {
        suite
        for suite in tracked
        if SUITE.match(suite)
        and any(
            path in read(root, suite) and bounded.search(read(root, suite))
            for path, bounded in patterns
        )
    }


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print("usage: referencing_suites.py < changed-paths", file=sys.stderr)
        return 1
    root = Path(__file__).resolve().parents[2]
    changed = [line.strip() for line in sys.stdin if line.strip()]
    try:
        tracked = tracked_files(root)
    except (OSError, subprocess.CalledProcessError) as error:
        print(
            f"referencing_suites.py: cannot list tracked files: {error}",
            file=sys.stderr,
        )
        return 1
    # One pass for both rules: the gate asks for both on every pull request,
    # and each reads every suite.
    for suite in sorted(module_suites(root, tracked, changed)):
        print(f"module {suite}")
    for suite in sorted(file_suites(root, tracked, changed)):
        print(f"file {suite}")
    for suite in sorted(exactpath_suites(root, tracked, changed)):
        print(f"exactpath {suite}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
