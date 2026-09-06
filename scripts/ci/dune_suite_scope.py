#!/usr/bin/env python3
"""Say whether one test suite can be run by executing its binary directly.

`dune build <dir>/<name>.exe` links a suite; it does not do what dune does
when it runs one. A stanza can carry `(deps ...)` that only the runtest
action materialises, an `(action (setenv ...))` that only dune applies, or
an `enabled_if` that means there is no executable at all. A suite like that
run by hand fails for reasons that have nothing to do with the change under
test -- test_server_runtime_bootstrap fails with the literal words "run the
test via Dune" -- and a report that cries wolf is worse than no report.

So this reads the stanza that declares the suite and answers "run" only when
nothing in it needs dune. Everything else is named and skipped out loud.

Usage: dune_suite_scope.py <dir> <name>
Prints "run" or "skip <reason>" and always exits 0; a scope it cannot
determine is a skip, not a run.
"""
import re
import sys
from pathlib import Path


def top_level_stanzas(text):
    """Split a dune file into top-level parenthesised forms.

    Comments and strings are skipped so a paren inside either cannot move
    the balance. Dune's own lexer is richer than this; what it needs to get
    right is where one top-level form ends, and that only needs the depth.
    """
    forms, depth, start, i, n = [], 0, None, 0, len(text)
    while i < n:
        ch = text[i]
        if ch == ";" and depth >= 0:
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
            if depth == 0 and start is not None:
                forms.append(text[start : i + 1])
                start = None
        i += 1
    return forms


def expand_includes(dune_path):
    """The stanzas of a dune file, with (include stanzas/x.inc) inlined."""
    text = dune_path.read_text(encoding="utf-8")
    out = []
    for form in top_level_stanzas(text):
        include = re.match(r"\(include\s+([^\s)]+)\s*\)", form.strip())
        if include:
            included = dune_path.parent / include.group(1)
            if included.is_file():
                out.extend(top_level_stanzas(included.read_text(encoding="utf-8")))
            continue
        out.append(form)
    return out


def declares(form, name):
    """Whether this stanza declares an executable called [name].

    Both shapes count: (test (name x) ...) and (tests (names a b c) ...).
    A bare mention elsewhere in the stanza -- a (modules ...) list, a
    (libraries ...) entry -- does not, which is the distinction that keeps
    a module-only source from being read as a suite.
    """
    head = re.match(r"\(\s*(tests?)\b", form)
    if not head:
        return False
    field = re.search(r"\(\s*names?\s+([^)]*)\)", form)
    if not field:
        return False
    return name in field.group(1).split()


def scope(directory, name):
    dune = Path(directory) / "dune"
    if not dune.is_file():
        return f"skip no {dune} to read"
    stanzas = [form for form in expand_includes(dune) if declares(form, name)]
    if not stanzas:
        return "skip not declared as a test executable in its dune file"
    if len(stanzas) > 1:
        return "skip declared by more than one stanza"
    form = stanzas[0]
    for field, reason in (
        ("action", "its stanza has a custom action dune has to apply"),
        ("deps", "its stanza has deps only the runtest action materialises"),
        ("enabled_if", "its stanza is conditionally disabled"),
    ):
        if re.search(r"\(\s*" + field + r"\b", form):
            return f"skip {reason}"
    return "run"


def main(argv):
    if len(argv) != 3:
        print("skip usage: dune_suite_scope.py <dir> <name>")
        return 0
    print(scope(argv[1], argv[2]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
