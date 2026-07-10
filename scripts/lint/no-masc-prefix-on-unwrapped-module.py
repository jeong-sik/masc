#!/usr/bin/env python3
"""Lint: reject `Masc.<Module>` references that do not compile because
`<Module>` is owned by a `(wrapped false)` dune library and the wrapped
`masc` library carries no facade for it.

A `(wrapped false)` library's modules compile as bare top-level OCaml
identifiers. The wrapped `masc` library (lib/dune, `(include_subdirs
unqualified)`) sees those bare names internally too (it depends on the
leaf), but `Masc.<Module>` is only valid for external callers when `masc`
also has its OWN module of that name — either authored directly or a
deliberate one-line facade (`include Leaf_module`, e.g. `lib/auth.ml` ->
`include Auth_leaf`, kept so `Masc.Auth` and bare `Auth` both work without
`masc` carrying a second implementation). Absent that facade,
`Masc.<Module>` is `Unbound module`, never a legitimate qualification.
This is not a style ratchet: any true hit is a genuine build break.

Recurrence: the same class of mistake landed twice in one day —
  - #23904: `Masc.Runtime` (masc.runtime is `(wrapped false)`, no
    `lib/runtime.ml` facade)
  - #23918: `Masc.Keeper_event_queue` (masc.keeper_runtime is
    `(wrapped false)`, no `lib/keeper_event_queue.ml` facade)
Per the repo's 2-strikes rule (`software-development.md` AI 페어 프로그래밍
검증 규칙 #2), the second occurrence forces a harness-level fix instead of a
third manual call-site patch.

SSOT, two derivations, never hardcoded:
  1. Unwrapped module names: every `dune` file under lib/, bin/, test/
     declaring a `(library ...)` stanza with `(wrapped false)`. A
     library's module set is its explicit `(modules ...)` field when
     present, otherwise every `.ml`/`.mli` basename directly inside that
     library's directory (every `(wrapped false)` leaf in this repo is
     `(include_subdirs no)`, so the directory-listing fallback is correct
     without recursing).
  2. `masc`'s own module set: every `.ml`/`.mli` reachable from `lib/`
     via `(include_subdirs unqualified)` — i.e. every file directly under
     `lib/`, recursing into subdirectories EXCEPT ones that declare their
     own `(library ...)` / `(executable ...)` dune stanza (those are
     separate components, excluded from `masc`'s sweep by construction;
     dune would refuse to compile a file claimed by two stanzas).
A `Masc.<Module>` reference is a real violation iff `<Module>` is in set 1
and NOT in set 2.

This linter parses dune files with a minimal S-expression reader (comments
and quoted strings handled) and OCaml source files with a comment/string
stripper before matching, to avoid both dune-comment false positives (dune
files describing this exact pattern in prose, e.g. this repo's own
`lib/dune`) and OCaml doc-comment/string false positives.

Usage:
  scripts/lint/no-masc-prefix-on-unwrapped-module.py [--list]

Exit codes:
  0  no violations
  1  violation(s) found (fail CI)
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
SCAN_ROOTS = ("lib", "bin", "test")
# Excluded *within* the scanned tree — e.g. a nested worktree someone
# created under lib/. Checked against the path relative to REPO_ROOT, not
# the absolute path: REPO_ROOT itself is commonly a git worktree checkout
# (`<repo>/.worktrees/<branch>/...`), so an absolute-path check would match
# `.worktrees` on every single file and exclude the entire repo.
EXCLUDED_PATH_PARTS = frozenset({"_build", ".worktrees", "node_modules"})


def _is_excluded(path: Path) -> bool:
    return any(part in EXCLUDED_PATH_PARTS for part in path.relative_to(REPO_ROOT).parts)


# ---------------------------------------------------------------------------
# Minimal dune S-expression reader.
#
# Dune's lang is a plain S-expression syntax: parenthesized lists of atoms
# and double-quoted strings, `;` comments running to end of line. No block
# comments, no reader macros beyond that — this is intentionally not a full
# dune-lang implementation, only enough to walk `(library ...)` stanzas.
# ---------------------------------------------------------------------------


def _strip_dune_comments(text: str) -> str:
    out: list[str] = []
    in_string = False
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if in_string:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == '"':
                in_string = False
            i += 1
            continue
        if c == '"':
            in_string = True
            out.append(c)
            i += 1
            continue
        if c == ";":
            while i < n and text[i] != "\n":
                i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def _tokenize_dune(text: str) -> list[str]:
    tokens: list[str] = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c.isspace():
            i += 1
            continue
        if c in "()":
            tokens.append(c)
            i += 1
            continue
        if c == '"':
            j = i + 1
            buf: list[str] = []
            while j < n and text[j] != '"':
                if text[j] == "\\" and j + 1 < n:
                    buf.append(text[j + 1])
                    j += 2
                    continue
                buf.append(text[j])
                j += 1
            tokens.append("".join(buf))
            i = j + 1
            continue
        j = i
        while j < n and not text[j].isspace() and text[j] not in "()":
            j += 1
        tokens.append(text[i:j])
        i = j
    return tokens


def _parse_sexps(tokens: list[str]) -> list:
    """Parse a flat dune token list into nested lists (an s-expression is
    either an atom `str` or a `list` of s-expressions — not spelled as a
    type alias since Python has no clean self-referential union here)."""
    pos = 0

    def parse_one():
        nonlocal pos
        tok = tokens[pos]
        if tok == "(":
            pos += 1
            items = []
            while tokens[pos] != ")":
                items.append(parse_one())
            pos += 1  # consume ')'
            return items
        pos += 1
        return tok

    exprs = []
    while pos < len(tokens):
        exprs.append(parse_one())
    return exprs


def parse_dune_file(path: Path) -> list:
    text = path.read_text(encoding="utf-8", errors="replace")
    tokens = _tokenize_dune(_strip_dune_comments(text))
    try:
        return _parse_sexps(tokens)
    except IndexError as exc:
        raise ValueError(f"malformed dune file: {path}") from exc


def _field(stanza: list, name: str):
    """Return the value list of `(name ...)` inside `stanza`, or None."""
    for item in stanza[1:]:
        if isinstance(item, list) and item and item[0] == name:
            return item[1:]
    return None


def _is_wrapped_false(stanza: list) -> bool:
    w = _field(stanza, "wrapped")
    return w is not None and w == ["false"]


def _ocaml_module_name(basename: str) -> str:
    return basename[:1].upper() + basename[1:] if basename else basename


def _modules_for_stanza(stanza: list, dune_dir: Path, dune_path: Path) -> set[str]:
    explicit = _field(stanza, "modules")
    if explicit is not None:
        names: set[str] = set()
        for m in explicit:
            if not isinstance(m, str) or m in (":standard", "\\"):
                # Non-atomic or :standard-based (modules ...) — this repo's
                # (wrapped false) leaves only use plain atom lists (verified
                # by the self-check below); bail rather than guess so a
                # future dune-syntax change surfaces as a loud warning
                # instead of a silently wrong module set.
                print(
                    f"WARN: {dune_path.relative_to(REPO_ROOT)}: "
                    f"(modules ...) uses non-atomic entry {m!r}; skipping "
                    f"SSOT derivation for this stanza",
                    file=sys.stderr,
                )
                return set()
            names.add(_ocaml_module_name(m))
        return names
    # No explicit (modules ...): every .ml/.mli directly in the library's
    # own directory belongs to it (matches the (include_subdirs no)
    # convention every (wrapped false) leaf in this repo currently uses).
    names = set()
    for f in dune_dir.iterdir():
        if f.is_file() and f.suffix in (".ml", ".mli"):
            names.add(_ocaml_module_name(f.stem))
    return names


@dataclass(frozen=True)
class UnwrappedModule:
    name: str
    defining_dune: str  # repo-relative path, for diagnostics


def collect_unwrapped_modules() -> dict[str, UnwrappedModule]:
    """Map OCaml module name -> the (wrapped false) library that owns it."""
    out: dict[str, UnwrappedModule] = {}
    for root_name in SCAN_ROOTS:
        root = REPO_ROOT / root_name
        if not root.is_dir():
            continue
        for dune_path in sorted(root.rglob("dune")):
            if _is_excluded(dune_path):
                continue
            try:
                stanzas = parse_dune_file(dune_path)
            except ValueError as exc:
                print(f"WARN: {exc}", file=sys.stderr)
                continue
            for stanza in stanzas:
                if not (isinstance(stanza, list) and stanza and stanza[0] == "library"):
                    continue
                if not _is_wrapped_false(stanza):
                    continue
                dune_dir = dune_path.parent
                for name in _modules_for_stanza(stanza, dune_dir, dune_path):
                    out.setdefault(
                        name,
                        UnwrappedModule(
                            name=name,
                            defining_dune=dune_path.relative_to(REPO_ROOT).as_posix(),
                        ),
                    )
    return out


def _is_component_dir(d: Path) -> bool:
    """True iff `d` declares its own `(library ...)` / `(executable(s) ...)`
    dune stanza — i.e. it is a separate component, excluded from the
    parent's `(include_subdirs unqualified)` sweep. dune would refuse to
    compile a source file claimed by two stanzas, so this boundary is
    exact, not a heuristic."""
    dune_path = d / "dune"
    if not dune_path.is_file():
        return False
    try:
        stanzas = parse_dune_file(dune_path)
    except ValueError as exc:
        print(f"WARN: {exc}", file=sys.stderr)
        return False
    return any(
        isinstance(s, list) and s and s[0] in ("library", "executable", "executables")
        for s in stanzas
    )


def collect_masc_own_modules() -> set[str]:
    """Module names genuinely part of the wrapped `masc` library's own
    compilation unit — reachable from `lib/` via `(include_subdirs
    unqualified)`, stopping at any subdirectory that is its own component
    (see `_is_component_dir`). Includes deliberate one-line facades like
    `lib/auth.ml` (`include Auth_leaf`) that re-export a leaf library's
    module under the wrapped namespace — from the compiler's point of
    view a facade module is exactly as real as an authored one."""
    lib_root = REPO_ROOT / "lib"
    names: set[str] = set()

    def walk(d: Path) -> None:
        for entry in sorted(d.iterdir()):
            if entry.name in EXCLUDED_PATH_PARTS:
                continue
            if entry.is_dir():
                if _is_component_dir(entry):
                    continue
                walk(entry)
            elif entry.is_file() and entry.suffix in (".ml", ".mli"):
                names.add(_ocaml_module_name(entry.stem))

    if lib_root.is_dir():
        walk(lib_root)
    return names


# ---------------------------------------------------------------------------
# OCaml comment/string stripper — avoids flagging doc-comment prose or
# string-literal contents (nested `(* *)` per OCaml lexical rules).
# ---------------------------------------------------------------------------


def strip_ocaml_comments_and_strings(text: str) -> str:
    """Blank out comment/string contents, preserving every `\\n` byte
    exactly where it was. Line numbers computed against the result (via
    `.count("\\n", 0, pos)`) must stay identical to line numbers in the
    original `text` — blanking a newline to a space here would silently
    desync every match's reported line number from the actual source line
    for any match following a multi-line comment or string.
    """
    out = list(text)

    def blank(idx: int) -> None:
        if text[idx] != "\n":
            out[idx] = " "

    i, n = 0, len(text)
    depth = 0
    while i < n:
        if depth > 0:
            if text[i : i + 2] == "(*":
                blank(i)
                blank(i + 1)
                depth += 1
                i += 2
                continue
            if text[i : i + 2] == "*)":
                blank(i)
                blank(i + 1)
                depth -= 1
                i += 2
                continue
            if text[i] == '"':
                blank(i)
                i += 1
                while i < n and text[i] != '"':
                    if text[i] == "\\" and i + 1 < n:
                        blank(i)
                        blank(i + 1)
                        i += 2
                        continue
                    blank(i)
                    i += 1
                if i < n:
                    blank(i)
                    i += 1
                continue
            blank(i)
            i += 1
            continue
        # depth == 0: code
        if text[i : i + 2] == "(*":
            blank(i)
            blank(i + 1)
            depth = 1
            i += 2
            continue
        if text[i] == '"':
            j = i + 1
            while j < n and text[j] != '"':
                if text[j] == "\\" and j + 1 < n:
                    j += 2
                    continue
                j += 1
            for k in range(i, min(j + 1, n)):
                blank(k)
            i = j + 1
            continue
        i += 1
    return "".join(out)


@dataclass(frozen=True)
class Violation:
    file: str
    line: int
    module: str
    context: str

    def render(self) -> str:
        return f"{self.file}:{self.line}: Masc.{self.module} — {self.module} is (wrapped false), reference it bare"


def build_violation_regex(unwrapped_names: set[str]) -> re.Pattern:
    alt = "|".join(re.escape(n) for n in sorted(unwrapped_names, key=len, reverse=True))
    return re.compile(r"\bMasc\.(" + alt + r")\b")


def scan_file(path: Path, pattern: re.Pattern) -> list[Violation]:
    rel = path.relative_to(REPO_ROOT).as_posix()
    text = path.read_text(encoding="utf-8", errors="replace")
    stripped = strip_ocaml_comments_and_strings(text)
    lines = text.splitlines()
    violations = []
    for m in pattern.finditer(stripped):
        line_no = stripped.count("\n", 0, m.start()) + 1
        line_text = lines[line_no - 1].strip() if line_no - 1 < len(lines) else ""
        violations.append(
            Violation(file=rel, line=line_no, module=m.group(1), context=line_text)
        )
    return violations


def collect_violations(pattern: re.Pattern) -> list[Violation]:
    out: list[Violation] = []
    for root_name in SCAN_ROOTS:
        root = REPO_ROOT / root_name
        if not root.is_dir():
            continue
        for suffix in ("*.ml", "*.mli"):
            for path in sorted(root.rglob(suffix)):
                if _is_excluded(path):
                    continue
                out.extend(scan_file(path, pattern))
    return out


def main() -> int:
    list_only = "--list" in sys.argv[1:]

    unwrapped = collect_unwrapped_modules()
    if not unwrapped:
        print(
            "ERROR: derived zero unwrapped modules from dune files — the "
            "SSOT derivation is broken (expected 90+ (wrapped false) "
            "libraries under lib/), refusing to report a false-clean pass",
            file=sys.stderr,
        )
        return 1

    masc_own = collect_masc_own_modules()
    if not masc_own:
        print(
            "ERROR: derived zero of masc's own modules from lib/ — the "
            "(include_subdirs unqualified) sweep is broken (expected 200+ "
            "top-level modules), refusing to report a false-clean pass",
            file=sys.stderr,
        )
        return 1

    # `Auth` (leaf, bare) vs `Masc.Auth` (facade in lib/auth.ml, `include
    # Auth_leaf`) are both real modules — only names with no facade in
    # masc_own are genuine violations.
    violating_names = set(unwrapped) - masc_own
    violations = (
        collect_violations(build_violation_regex(violating_names))
        if violating_names
        else []
    )

    if list_only:
        for v in sorted(violations, key=lambda v: (v.file, v.line)):
            print(v.render())
        print(
            f"\n[lint] {len(unwrapped)} unwrapped module(s) tracked, "
            f"{len(masc_own)} of masc's own modules (facades included), "
            f"{len(violating_names)} name(s) with no facade, "
            f"{len(violations)} violation(s)",
            file=sys.stderr,
        )
        return 0

    if violations:
        print(
            "[lint] Masc.<unwrapped module> reference(s) — these do not "
            "compile (Unbound module):",
            file=sys.stderr,
        )
        for v in sorted(violations, key=lambda v: (v.file, v.line)):
            owner = unwrapped[v.module]
            print(f"  {v.render()}", file=sys.stderr)
            print(f"      ({owner.defining_dune} declares (wrapped false))", file=sys.stderr)
            print(f"      {v.context}", file=sys.stderr)
        print(
            f"\nFix: drop the `Masc.` prefix — reference the module bare "
            f"(add `open Masc` first if the surrounding file has none).",
            file=sys.stderr,
        )
        return 1

    print(
        f"[lint] clean: {len(unwrapped)} unwrapped module(s) tracked, 0 violations",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
