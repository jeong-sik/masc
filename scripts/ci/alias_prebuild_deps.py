#!/usr/bin/env python3
"""Build targets a targeted suite's Dune alias needs before its budget starts.

The targeted runner runs every suite by building its Dune alias:
`@@DIR/runtest-NAME` for a (test)/(tests) stanza, which Dune 3.20+ generates
for each named test, and `@runtest-NAME` for a script declared as
`(rule (alias runtest-NAME) ...)`. Dune evaluates the run itself: the stanza's
(setenv ...), the directory's (env ...), every dependency expression and the
working directory are the ones the root @runtest uses.

Building the alias also compiles whatever its action needs, inside the suite's
timeout. A suite that drives ../bin/main_eio.exe or a Cargo binary can spend
the whole budget compiling (run 41730441832 used 601s of 600s and printed no
"Ran N tests" line). This reader names those targets so the runner builds them
first, outside the budget.

A misread here moves compile time into or out of the budget. It cannot change
a verdict, because Dune still evaluates the action.

    alias_prebuild_deps.py DIR NAME

prints one target per line, relative to the repository root. It exits 1 when
neither a rule carrying (alias runtest-NAME) nor a (test)/(tests) stanza naming
NAME is in DIR/dune or a file it includes.

Targets are the literal paths in the stanza's (deps ...) and every path its
fields name as %{exe:PATH} or %{dep:PATH}. A dependency expression such as
(source_tree DIR) or (glob_files ...) names source files, which Dune copies
inside the action and which need no compile, so it contributes nothing.
"""

from __future__ import annotations

import os
import re
import sys
from collections.abc import Iterator
from typing import TypeAlias

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

Sexp: TypeAlias = "str | list[Sexp]"

VAR_RE = re.compile(r"%\{")
TARGET_VAR_RE = re.compile(r"%\{(?:exe|dep):([^}]+)\}")

# Dune variables that name the checkout root. This repository has one
# dune-project and its dune-workspace at the root, so the project root and the
# workspace root are both REPO_ROOT, and rewriting either prefix is not a guess.
ROOT_VARS = ("%{project_root}/", "%{workspace_root}/")


class StanzaError(Exception):
    pass


def tokenize(text: str) -> list[str]:
    """S-expression tokens, with comments and strings handled.

    Dune comments run from ';' to end of line. A quoted value keeps its
    spaces and loses its quotes.
    """
    tokens: list[str] = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == ";":
            while i < n and text[i] != "\n":
                i += 1
        elif c in "()":
            tokens.append(c)
            i += 1
        elif c.isspace():
            i += 1
        elif c == '"':
            i += 1
            start = i
            while i < n and text[i] != '"':
                if text[i] == "\\":
                    i += 1
                i += 1
            if i >= n:
                raise StanzaError("unterminated string in stanza")
            tokens.append(text[start:i])
            i += 1
        else:
            start = i
            while i < n and not text[i].isspace() and text[i] not in '();"':
                i += 1
            tokens.append(text[start:i])
    return tokens


def parse(tokens: list[str]) -> list[Sexp]:
    """Tokens to nested lists. Atoms stay strings."""
    pos = 0

    def walk() -> list[Sexp]:
        nonlocal pos
        out: list[Sexp] = []
        while pos < len(tokens):
            tok = tokens[pos]
            pos += 1
            if tok == "(":
                out.append(walk())
            elif tok == ")":
                return out
            else:
                out.append(tok)
        return out

    return walk()


def fields(form: list[Sexp], head: str) -> list[list[Sexp]]:
    return [
        field for field in form[1:]
        if isinstance(field, list) and field and field[0] == head
    ]


def atoms(form: list[Sexp]) -> list[str]:
    return [item for item in form[1:] if isinstance(item, str)]


def declares(form: Sexp, name: str) -> bool:
    """Whether FORM is the stanza whose alias runs NAME."""
    if not isinstance(form, list) or not form:
        return False
    match form[0]:
        case "rule":
            return any(f"runtest-{name}" in atoms(field) for field in fields(form, "alias"))
        case "test":
            return any(name in atoms(field) for field in fields(form, "name"))
        case "tests":
            return any(name in atoms(field) for field in fields(form, "names"))
        case _:
            return False


def literal_target(path: str, suite_dir: str) -> str | None:
    """PATH as the stanza directory sees it, or None when only Dune can name it.

    A root variable becomes the way back from SUITE_DIR to the checkout root,
    because main() prefixes every target with SUITE_DIR. Any other variable
    stays with Dune: guessing it would hand `dune build` a literal '%{...}',
    which fails the preparation build of every suite in the dispatch.
    """
    if not VAR_RE.search(path):
        return path
    for var in ROOT_VARS:
        rest = path[len(var):]
        if path.startswith(var) and not VAR_RE.search(rest):
            return os.path.join(
                os.path.relpath(REPO_ROOT, os.path.join(REPO_ROOT, suite_dir)), rest
            )
    return None


def variable_targets(form: Sexp) -> list[str]:
    """Paths named by %{exe:PATH} or %{dep:PATH} anywhere in a form."""
    if isinstance(form, str):
        return TARGET_VAR_RE.findall(form)
    return [path for item in form for path in variable_targets(item)]


def stanza_targets(form: list[Sexp], suite_dir: str) -> list[str]:
    targets: list[str] = []
    for deps in fields(form, "deps"):
        for item in atoms(deps):
            target = literal_target(item, suite_dir)
            if target is not None:
                targets.append(target)
    for path in variable_targets(form):
        target = literal_target(path, suite_dir)
        if target is not None:
            targets.append(target)
    return list(dict.fromkeys(targets))


def included_forms(path: str, ancestors: tuple[str, ...] = ()) -> Iterator[list[Sexp]]:
    """Every top-level form of PATH and of each file it literally includes.

    Include filenames are relative to their containing file. The stanzas
    inside still belong to the original Dune directory, as Dune reads them.
    """
    path = os.path.realpath(path)
    if path in ancestors:
        raise StanzaError("include cycle: " + " -> ".join((*ancestors, path)))
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
    except OSError as exc:
        raise StanzaError(f"cannot read {path}: {exc}") from exc
    forms = [form for form in parse(tokenize(text)) if isinstance(form, list) and form]
    yield from forms
    for form in forms:
        if form[0] != "include":
            continue
        target = form[1] if len(form) == 2 else None
        if not isinstance(target, str) or VAR_RE.search(target):
            raise StanzaError(f"unsupported include in {path}: {form}")
        yield from included_forms(
            os.path.join(os.path.dirname(path), target), (*ancestors, path)
        )


def prebuild_targets(suite_dir: str, name: str) -> list[str]:
    dune_file = os.path.join(REPO_ROOT, suite_dir, "dune")
    for form in included_forms(dune_file):
        if declares(form, name):
            return [
                os.path.normpath(os.path.join(suite_dir, target))
                for target in stanza_targets(form, suite_dir)
            ]
    raise StanzaError(
        f"no (rule (alias runtest-{name}) ...) and no (test)/(tests) stanza "
        f"naming {name} in {suite_dir}/dune or its includes"
    )


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    suite_dir, name = argv[1], argv[2]
    try:
        targets = prebuild_targets(suite_dir, name)
    except StanzaError as exc:
        print(f"{name}: {exc}", file=sys.stderr)
        return 1
    for target in targets:
        print(target)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
