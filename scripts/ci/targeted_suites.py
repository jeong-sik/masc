#!/usr/bin/env python3
# pyright: strict
"""Enumerate and verify Dune test suites for scripts/ci-run-targeted-tests.sh.

Parses Dune S-expressions directly (following `(include ...)` directives,
independent of `alias_prebuild_deps.py` so stubbing the prebuild reader never
affects suite discovery or resolution) so shard enumeration and explicit
`TARGET_SUITES` resolution agree with Dune's actual declarations:
  - Only `(test (name X))` and `(tests (names ...))` stanzas are enumerated for
    OCaml suites — helper `.ml` modules (like `test_operator_control_support.ml`
    or `test_exact_output_catalog_precedence_fixture.ml`) are never emitted.
  - Subdirectory paths are preserved (`test/<dir>/<name>`,
    `packages/agent_core/test/<name>`, `lib/exec/test/<name>`,
    `tools/rtev_trace/<name>`) instead of stripping `<dir>/` or emitting bare
    directory names.
  - Only `runtest-<name>` rules referenced by `(alias (name runtest) (deps ...))`
    bundles in `test/dune` (and its includes) are enumerated for shard runs,
    excluding unbundled opt-in/benchmark rules and non-suite helper `.py` files.
  - `(enabled_if ...)` predicates using `%{system}` and `%{env:VAR=DEFAULT}`
    are evaluated against the host platform and environment so shard runs do
    not pass disabled targets (e.g. macOS-only or `MASC_E2E_TESTS=true`-gated
    tests) to `dune build`.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import re
import sys
from collections.abc import Iterator, Mapping
from typing import TypeAlias

Sexp: TypeAlias = "str | list[Sexp]"

_SEARCH_ROOTS = ("test", "lib", "packages", "tools")
_SKIP_DIR_NAMES = frozenset(
    {
        ".git",
        ".worktrees",
        "worktrees",
        "_build",
        "vendor",
        "artifacts",
        "logs",
        "refute_tmp",
        "node_modules",
    }
)
_VAR_RE = re.compile(r"%\{")
_ENV_VAR_RE = re.compile(r"%\{env:([^=}]+)=([^}]*)\}")


class StanzaError(Exception):
    pass


class _Delimiter:
    __slots__ = ("kind",)

    def __init__(self, kind: str) -> None:
        self.kind = kind


_LPAREN = _Delimiter("(")
_RPAREN = _Delimiter(")")
_Token: TypeAlias = "str | _Delimiter"


def _tokenize(text: str) -> list[_Token]:
    """Tokenize Dune S-expressions, skipping `;` comments and handling quoted strings.

    Structural parentheses are emitted as distinct `_LPAREN`/`_RPAREN` sentinel
    tokens so literal quoted `"("` or `")"` strings never corrupt the AST.
    """
    tokens: list[_Token] = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == ";":
            while i < n and text[i] != "\n":
                i += 1
        elif c == "(":
            tokens.append(_LPAREN)
            i += 1
        elif c == ")":
            tokens.append(_RPAREN)
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


def _parse(tokens: list[_Token]) -> list[Sexp]:
    pos = 0

    def walk(depth: int) -> list[Sexp]:
        nonlocal pos
        out: list[Sexp] = []
        while pos < len(tokens):
            tok = tokens[pos]
            pos += 1
            if tok is _LPAREN:
                out.append(walk(depth + 1))
            elif tok is _RPAREN:
                if depth == 0:
                    raise StanzaError("unexpected ')' in stanza")
                return out
            elif isinstance(tok, str):
                out.append(tok)
        if depth > 0:
            raise StanzaError("unclosed '(' in stanza")
        return out

    return walk(0)


def _fields(form: list[Sexp], head: str) -> list[list[Sexp]]:
    return [
        field
        for field in form[1:]
        if isinstance(field, list) and field and field[0] == head
    ]


def _atoms(form: list[Sexp]) -> list[str]:
    return [item for item in form[1:] if isinstance(item, str)]


def _included_forms(path: str, ancestors: tuple[str, ...] = ()) -> Iterator[list[Sexp]]:
    """Yield every top-level list form of `path` and each file it literally includes."""
    real = os.path.realpath(path)
    if real in ancestors:
        raise StanzaError("include cycle: " + " -> ".join((*ancestors, real)))
    try:
        with open(real, encoding="utf-8") as handle:
            text = handle.read()
    except OSError as exc:
        raise StanzaError(f"cannot read {real}: {exc}") from exc
    forms = [form for form in _parse(_tokenize(text)) if isinstance(form, list) and form]
    yield from forms
    for form in forms:
        if form[0] != "include":
            continue
        target = form[1] if len(form) == 2 else None
        if not isinstance(target, str) or _VAR_RE.search(target):
            raise StanzaError(f"unsupported include in {real}: {form}")
        yield from _included_forms(
            os.path.join(os.path.dirname(real), target), (*ancestors, real)
        )


def host_dune_system() -> str:
    """Return Dune's `%{system}` value for the active host platform."""
    if sys.platform.startswith("linux"):
        return "linux"
    if sys.platform == "darwin":
        return "macosx"
    if sys.platform in ("win32", "cygwin"):
        return "win32"
    if sys.platform.startswith("freebsd"):
        return "freebsd"
    if sys.platform.startswith("openbsd"):
        return "openbsd"
    if sys.platform.startswith("netbsd"):
        return "netbsd"
    return sys.platform


def _expand_dune_atom(atom: str, *, system: str, env: Mapping[str, str]) -> str | None:
    expanded = atom.replace("%{system}", system)

    def _replace_env(match: re.Match[str]) -> str:
        var_name, default_val = match.group(1), match.group(2)
        return env.get(var_name, default_val)

    expanded = _ENV_VAR_RE.sub(_replace_env, expanded)
    if "%{" in expanded:
        return None
    return expanded


def _eval_enabled_if(expr: Sexp, *, system: str, env: Mapping[str, str]) -> bool | None:
    if isinstance(expr, str):
        val = _expand_dune_atom(expr, system=system, env=env)
        if val == "true":
            return True
        if val == "false":
            return False
        return None
    if not expr or not isinstance(expr[0], str):
        return None
    op = expr[0]
    if (
        op in ("=", "<>")
        and len(expr) == 3
        and isinstance(expr[1], str)
        and isinstance(expr[2], str)
    ):
        lhs = _expand_dune_atom(expr[1], system=system, env=env)
        rhs = _expand_dune_atom(expr[2], system=system, env=env)
        if lhs is None or rhs is None:
            return None
        return (lhs == rhs) if op == "=" else (lhs != rhs)
    if op == "not" and len(expr) == 2:
        inner = _eval_enabled_if(expr[1], system=system, env=env)
        return None if inner is None else (not inner)
    if op == "and":
        saw_unknown = False
        for item in expr[1:]:
            res = _eval_enabled_if(item, system=system, env=env)
            if res is False:
                return False
            if res is None:
                saw_unknown = True
        return None if saw_unknown else True
    if op == "or":
        saw_unknown = False
        for item in expr[1:]:
            res = _eval_enabled_if(item, system=system, env=env)
            if res is True:
                return True
            if res is None:
                saw_unknown = True
        return None if saw_unknown else False
    return None


def stanza_enabled(form: list[Sexp], *, system: str, env: Mapping[str, str]) -> bool:
    """Evaluate `(enabled_if ...)` fields on a stanza; unknown predicates stay enabled."""
    for ef in _fields(form, "enabled_if"):
        if len(ef) != 2:
            continue
        verdict = _eval_enabled_if(ef[1], system=system, env=env)
        if verdict is False:
            return False
    return True


def _skip_dir(dirname: str) -> bool:
    return (
        dirname in _SKIP_DIR_NAMES
        or dirname.startswith(".")
        or dirname.startswith("_build")
    )


def discover_dune_dirs(repo_root: pathlib.Path) -> list[str]:
    """Return sorted POSIX-relative directories containing a `dune` file."""
    dirs: list[str] = []
    for top in _SEARCH_ROOTS:
        top_path = repo_root / top
        if not top_path.is_dir():
            continue
        for current, dirnames, filenames in os.walk(top_path):
            dirnames[:] = sorted(d for d in dirnames if not _skip_dir(d))
            if "dune" in filenames:
                rel = pathlib.Path(current).relative_to(repo_root).as_posix()
                dirs.append(rel)
    return sorted(set(dirs))


def _stanza_test_names(form: list[Sexp]) -> list[str]:
    if not form or not isinstance(form[0], str):
        return []
    head = form[0]
    if head == "test":
        return [nm for field in _fields(form, "name") for nm in _atoms(field)]
    if head == "tests":
        return [nm for field in _fields(form, "names") for nm in _atoms(field)]
    return []


def enumerate_suites(
    repo_root: pathlib.Path,
    *,
    system: str,
    env: Mapping[str, str],
) -> list[str]:
    """Enumerate all runnable `@runtest` suites in deterministic sorted order."""
    suites: set[str] = set()
    for rel_dir in discover_dune_dirs(repo_root):
        dune_file = repo_root / rel_dir / "dune"
        forms = list(_included_forms(str(dune_file)))
        rule_enabled: dict[str, bool] = {}
        bundle_refs: set[str] = set()

        for form in forms:
            if not form or not isinstance(form[0], str):
                continue
            head = form[0]
            if head in ("test", "tests"):
                if not stanza_enabled(form, system=system, env=env):
                    continue
                # A `(test)`/`(tests)` stanza defaults to the `runtest` alias;
                # skip stanzas explicitly moved to a custom non-`runtest` alias.
                alias_fields = _fields(form, "alias")
                if alias_fields and not any(
                    "runtest" in _atoms(af) for af in alias_fields
                ):
                    continue
                for nm in _stanza_test_names(form):
                    suites.add(nm if rel_dir == "test" else f"{rel_dir}/{nm}")
            elif rel_dir == "test" and head == "rule":
                enabled = stanza_enabled(form, system=system, env=env)
                for af in _fields(form, "alias"):
                    for alias_name in _atoms(af):
                        if alias_name.startswith("runtest-"):
                            stem = alias_name[len("runtest-") :]
                            rule_enabled[stem] = rule_enabled.get(stem, False) or enabled
            elif rel_dir == "test" and head == "alias":
                is_runtest = any("runtest" in _atoms(nf) for nf in _fields(form, "name"))
                if not is_runtest or not stanza_enabled(form, system=system, env=env):
                    continue
                for df in _fields(form, "deps"):
                    for item in df[1:]:
                        if (
                            isinstance(item, list)
                            and len(item) == 2
                            and item[0] == "alias"
                            and isinstance(item[1], str)
                            and item[1].startswith("runtest-")
                        ):
                            bundle_refs.add(item[1][len("runtest-") :])

        if rel_dir == "test":
            for stem in bundle_refs:
                if rule_enabled.get(stem, False):
                    suites.add(stem)

    return sorted(suites)


def declared_test_names_in_dir(repo_root: pathlib.Path, rel_dir: str) -> set[str]:
    """Return every OCaml test name declared by `(test)`/`(tests)` in `rel_dir/dune`."""
    dune_file = repo_root / rel_dir / "dune"
    if not dune_file.is_file():
        return set()
    names: set[str] = set()
    for form in _included_forms(str(dune_file)):
        names.update(_stanza_test_names(form))
    return names


def declared_runtest_aliases(repo_root: pathlib.Path) -> list[str]:
    """Return sorted `runtest-<name>` suffixes declared as rules in `test/dune`."""
    dune_file = repo_root / "test" / "dune"
    if not dune_file.is_file():
        return []
    aliases: set[str] = set()
    for form in _included_forms(str(dune_file)):
        if form and form[0] == "rule":
            for af in _fields(form, "alias"):
                for alias_name in _atoms(af):
                    if alias_name.startswith("runtest-"):
                        aliases.add(alias_name[len("runtest-") :])
    return sorted(aliases)


def verify_ocaml_suites(repo_root: pathlib.Path, suite_paths: list[str]) -> list[tuple[str, bool]]:
    """Batch-check whether each `dir/name` path is declared by a `(test)`/`(tests)` stanza."""
    cache: dict[str, set[str]] = {}
    results: list[tuple[str, bool]] = []
    for suite_path in suite_paths:
        rel_dir, name = os.path.split(suite_path)
        if not rel_dir or not name:
            results.append((suite_path, False))
            continue
        if rel_dir not in cache:
            cache[rel_dir] = declared_test_names_in_dir(repo_root, rel_dir)
        results.append((suite_path, name in cache[rel_dir]))
    return results


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_enum = sub.add_parser("enumerate", help="list all runnable @runtest suites")
    p_enum.add_argument("--repo-root", default=".", help="repository checkout root")
    p_enum.add_argument("--system", default=None, help="override Dune %%{system} value")

    p_aliases = sub.add_parser("list-runtest-aliases", help="list test/ runtest-* rule suffixes")
    p_aliases.add_argument("--repo-root", default=".", help="repository checkout root")

    p_verify = sub.add_parser(
        "verify-ocaml-suites",
        help="read dir/name lines from stdin and report OK or UNDECLARED",
    )
    p_verify.add_argument("--repo-root", default=".", help="repository checkout root")

    args = parser.parse_args(argv)
    repo_root = pathlib.Path(args.repo_root).resolve()

    try:
        if args.cmd == "enumerate":
            system: str = args.system if args.system else host_dune_system()
            for suite in enumerate_suites(repo_root, system=system, env=os.environ):
                print(suite)
            return 0

        if args.cmd == "list-runtest-aliases":
            for alias in declared_runtest_aliases(repo_root):
                print(alias)
            return 0

        if args.cmd == "verify-ocaml-suites":
            paths = [line.strip() for line in sys.stdin.read().splitlines() if line.strip()]
            for suite_path, declared in verify_ocaml_suites(repo_root, paths):
                status = "OK" if declared else "UNDECLARED"
                print(f"{suite_path}\t{status}")
            return 0
    except StanzaError as exc:
        print(f"targeted_suites: {exc}", file=sys.stderr)
        return 1

    return 2


if __name__ == "__main__":
    raise SystemExit(main())
