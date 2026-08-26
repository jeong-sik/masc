#!/usr/bin/env python3
r"""Report `ignore` sites in OCaml sources that carry no justification comment.

Rationale: sw-dev 임시조치 주석 의무. `ignore (...)` throws away a return
value, and with it a contract, without saying why. The 2026-05-19 audit
(memory/masc-code-smell-report-2026-05-19.html Hotspot #4) counted 94 such
calls, 85 of them silent.

This replaces the shell version, which searched for `^\s*ignore \(` and so
only ever saw one of the several shapes `ignore` takes. Counted on lib/ the
day of the rewrite:

    ignore (...)   flat, on its own line     79   <- all the old lint saw
    ignore         alone, arguments below    88   <- ocamlformat writes this
    ignore x       applied without parens    19
    ... |> ignore  piped                     15
    mid-line       `if ok then ignore (...)` ~40

The folded shape outnumbers the flat one, and that is not a coincidence: the
longer the expression, the more likely ocamlformat breaks the line, and the
site disappears from the lint. Two such sites sat in lib/ unjustified while
the lint reported nothing. They were never passing -- they were never looked
at (masc#30575).

So detection works on tokens, not on line shapes. Comments and string
literals are blanked first: OCaml comments nest, so no regex can do this,
and `[ignore]` really does appear inside odoc comments in this tree.

A justification is accepted on the same line or the line directly above:

    (* WORKAROUND: ... *)  (* HACK: ... *)  (* fire-and-forget: ... *)
    (* RFC-XXXX: ... *)    (* TODO: ... *)  (* See ... *)

This script never edits code. It surfaces sites and lets a reviewer decide
between adding a comment, changing the signature, or accepting the site as
fire-and-forget with a reason.

Modes:
    (default)   list every unjustified site as file:line:body
    --counts    per-file totals
    --strict    exit 1 when any unjustified site is found
    --all       list every site, justified or not (for measuring)
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

JUSTIFY = re.compile(
    r"\(\*\s*(WORKAROUND|HACK|fire-and-forget|RFC-[0-9]{4}|TODO|See|see)\b"
)

# An `ignore` identifier token. OCaml identifiers may carry a trailing quote,
# so `ignore'` is a different name and must not match.
TOKEN = re.compile(r"(?<![A-Za-z0-9_'])ignore(?![A-Za-z0-9_'])")

QUOTED_OPEN = re.compile(r"\{([a-z_]*)\|")
CHAR_LIT = re.compile(r"'(\\[\\\"'ntbr ]|\\[0-9]{3}|\\x[0-9A-Fa-f]{2}|[^\\'\n])'")


def blank_noncode(src: str) -> str:
    """Replace comment and string-literal characters with spaces.

    Newlines survive so line numbers are preserved. Comment nesting is
    tracked with a depth counter -- `(* (* *) *)` is one comment, and a
    regex cannot see that.
    """
    out = list(src)
    i, n, depth = 0, len(src), 0

    def blank(start: int, stop: int) -> None:
        for k in range(start, stop):
            if out[k] != "\n":
                out[k] = " "

    def consume_double_quoted(i: int) -> int:
        """Blank a `"`-delimited literal and return the index past it."""
        blank(i, i + 1)
        i += 1
        while i < n:
            if src[i] == "\\" and i + 1 < n:
                blank(i, i + 2)
                i += 2
                continue
            if src[i] == '"':
                blank(i, i + 1)
                return i + 1
            blank(i, i + 1)
            i += 1
        return i

    def consume_quoted_literal(i: int) -> int | None:
        """Blank a `{id|...|id}` literal, or return None if this is not one."""
        m = QUOTED_OPEN.match(src, i)
        if not m:
            return None
        close = "|" + m.group(1) + "}"
        end = src.find(close, m.end())
        end = n if end < 0 else end + len(close)
        blank(i, end)
        return end

    while i < n:
        if depth:
            if src.startswith("(*", i):
                depth += 1
                blank(i, i + 2)
                i += 2
                continue
            if src.startswith("*)", i):
                depth -= 1
                blank(i, i + 2)
                i += 2
                continue
            # The OCaml lexer reads string literals inside comments, so a
            # `"*)"` written in prose does not close the comment. Skipping
            # them here would end the comment early and leave the trailing
            # quote to open a string that was never opened -- which both
            # invents call sites inside real strings and hides real ones.
            if src[i] == '"':
                i = consume_double_quoted(i)
                continue
            end = consume_quoted_literal(i)
            if end is not None:
                i = end
                continue
            blank(i, i + 1)
            i += 1
            continue

        if src.startswith("(*", i):
            depth = 1
            blank(i, i + 2)
            i += 2
            continue

        c = src[i]

        if c == '"':
            i = consume_double_quoted(i)
            continue

        if c == "{":
            end = consume_quoted_literal(i)
            if end is not None:
                i = end
                continue

        if c == "'":
            # A char literal, or a type variable such as 'a. Only the former
            # can hide a quote character, so leave anything else alone.
            m = CHAR_LIT.match(src, i)
            if m:
                blank(i, m.end())
                i = m.end()
                continue

        i += 1

    return "".join(out)


def is_test_path(path: Path) -> bool:
    """A `test/` directory anywhere in the path, and nothing else.

    Not the `test_` filename prefix: the shell version this replaced matched
    `(^|/)test/` only, and narrowing what gets scanned is the same kind of
    quiet shrink this rewrite exists to undo. Today no `test_*.ml` sits
    outside a `test/` directory, so the two rules agree -- keep them agreeing.
    """
    return "test" in path.parts


def collect(target: Path, include_tests: bool) -> list[Path]:
    if target.is_file():
        files = [target]
    else:
        files = sorted(
            p
            for pattern in ("*.ml", "*.mli")
            for p in target.rglob(pattern)
            if "_build" not in p.parts
        )
    if not include_tests:
        files = [p for p in files if not is_test_path(p)]
    return files


def sites(path: Path, want_all: bool) -> list[tuple[int, str]]:
    try:
        src = path.read_text(errors="replace")
    except OSError:
        return []
    if "ignore" not in src:
        # Blanking is a character-at-a-time walk; most files never mention
        # the name at all, and a plain substring test settles those.
        return []
    original = src.splitlines()
    masked = blank_noncode(src).splitlines()
    found = []
    for idx, mline in enumerate(masked):
        if not TOKEN.search(mline):
            continue
        line = original[idx] if idx < len(original) else ""
        if not want_all:
            above = original[idx - 1] if idx > 0 else ""
            if JUSTIFY.search(line) or JUSTIFY.search(above):
                continue
        found.append((idx + 1, line))
    return found


def main() -> int:
    ap = argparse.ArgumentParser(add_help=True, description=__doc__)
    ap.add_argument("--counts", action="store_true", help="per-file totals")
    ap.add_argument("--strict", action="store_true", help="exit 1 on any finding")
    ap.add_argument("--all", action="store_true", help="list every site")
    ap.add_argument("--include-tests", action="store_true")
    ap.add_argument("--target", nargs="+", default=["lib/"])
    args = ap.parse_args()

    targets = [Path(t) for t in args.target]
    missing = [t for t in targets if not t.exists()]
    if missing:
        print(f"target not found: {missing[0]}", file=sys.stderr)
        return 2

    seen: set[Path] = set()
    rows = []
    for target in targets:
        for path in collect(target, args.include_tests):
            if path in seen:
                continue
            seen.add(path)
            rows.extend(
                (str(path), lineno, body) for lineno, body in sites(path, args.all)
            )

    if args.counts:
        per_file: dict[str, int] = {}
        for name, _, _ in rows:
            per_file[name] = per_file.get(name, 0) + 1
        for name, count in sorted(per_file.items(), key=lambda kv: (-kv[1], kv[0])):
            print(f"{count:7} {name}")
    else:
        for name, lineno, body in rows:
            print(f"{name}:{lineno}:{body}")

    if args.strict and rows:
        print(
            f"STRICT FAIL: {len(rows)} ignore sites lack a justification comment",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
