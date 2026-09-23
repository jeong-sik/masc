#!/usr/bin/env python3
"""List TUI record fields a decoder fills that nothing reads (#38446).

The TUI decodes server JSON in two places: lib/tui_decode.ml, and the
masc_tui*.ml files in bin/ that call the decode helpers themselves
(masc_tui_repository_pulls.ml, masc_tui_loader.ml, ...). A field decoded
there and never read costs twice: it is not drawn, and a required one
still makes the whole row unreadable when the server leaves it out.

What counts as decoded:
  - every record field declared in lib/tui_decode.ml;
  - every record field declared in bin/masc_tui*.ml that a bin decoder file
    binds ([let* name =]) or assigns ([name = ...]).

What counts as a read, anywhere in bin/*.ml or lib/tui_decode.ml:
  - [x.name], a label [~name], or a bare [name] that is not a declaration
    ([name :]), a binding or assignment ([name =]), or a record pun
    ([{ name; ...}]). A pun in a pattern binds a local of the same name, and
    that local's later use is counted as the read; a pun in a construction
    only hands on a value a [let*] bound, so it reads nothing.

The output is a candidate list, not a verdict: a field read under another
name (a string built at run time, a same-named local) is missed, and the
same fact drawn from a different field is not seen. Check each field's
real readers before deleting it (see the corrections on #38446).
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path

LIB_DECODER = Path("lib/tui_decode.ml")
BIN_DIR = Path("bin")
BIN_TUI_GLOB = "masc_tui*.ml"
BIN_SCAN_GLOB = "*.ml"

# A field name: lowercase, at least four characters, so short locals and
# keywords ("ok", "id", "text") never enter the census.
NAME = r"[a-z][a-z0-9_]{3,}"
DECLARATION = re.compile(rf"^\s*[{{;]?\s*(?:mutable\s+)?({NAME})\s*:(?!:)")
# A bin file is a decoder when it calls a JSON field helper itself.
DECODE_CALL = re.compile(r"\b(?:required|optional)_[a-z_]*field\b|\bUtil\.member\b")
# A char literal ('"', '\n', '\x1b'), so its quote opens no string. A type
# variable ('a) or a primed name (x') has no closing quote right after.
CHAR_LITERAL = re.compile(r"'(?:[^\\']|\\(?:[\\'\"nrtb ]|[0-9]{3}|x[0-9a-fA-F]{2}|o[0-7]{3}))'")
BINDER = re.compile(r"(?:^|[^A-Za-z0-9_'])(?:let\*?|and\*?|with|rec)$")
# A quoted string literal: {|...|} or {id|...|id}.
QUOTED_STRING = re.compile(r"\{([a-z_]*)\|.*?\|\1\}", re.S)
WORD = re.compile(rf"(?<![A-Za-z0-9_'])({NAME})(?![A-Za-z0-9_'])")


@dataclass(frozen=True, slots=True)
class Finding:
    field: str
    decoder: Path


def strip_comments_and_strings(text: str) -> str:
    """Blank OCaml comments and string literals, keeping line breaks, so a
    field named in prose or in a JSON key string is neither declared nor
    read."""
    out: list[str] = []
    depth = 0
    i = 0
    n = len(text)
    in_string = False
    while i < n:
        ch = text[i]
        pair = text[i : i + 2]
        if in_string:
            if ch == "\\" and i + 1 < n:
                out.append(" " if text[i + 1] != "\n" else "\n")
                out.append(" ")
                i += 2
                continue
            if ch == '"':
                in_string = False
            out.append("\n" if ch == "\n" else " ")
            i += 1
            continue
        if pair == "(*":
            depth += 1
            out.append("  ")
            i += 2
            continue
        if depth > 0:
            if pair == "*)":
                depth -= 1
                out.append("  ")
                i += 2
                continue
            out.append("\n" if ch == "\n" else " ")
            i += 1
            continue
        if ch == '"':
            in_string = True
            out.append(" ")
            i += 1
            continue
        literal = CHAR_LITERAL.match(text, i) or QUOTED_STRING.match(text, i)
        if literal:
            out.append(re.sub(r"[^\n]", " ", literal.group(0)))
            i = literal.end()
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def code_lines(path: Path) -> list[str]:
    return strip_comments_and_strings(path.read_text(encoding="utf-8")).split("\n")


def declared_fields(lines: list[str]) -> set[str]:
    return {m.group(1) for line in lines if (m := DECLARATION.match(line))}


def classify(line: str, start: int, end: int) -> str:
    """'read', 'write' or 'declaration' for the word at [start, end)."""
    before = line[:start].rstrip()
    after = line[end:].lstrip()
    prev = before[-1:] if before else ""
    if prev in (".", "~", "?"):
        return "read"
    if after.startswith(":") and not after.startswith("::"):
        return "declaration"
    # [=] binds or assigns only after [let], [and], [with] or inside a record
    # ([{ name = ...] / [; name = ...]); elsewhere it compares, which reads.
    if after.startswith("=") and not after.startswith(("==", "=>")):
        if prev in ("{", ";") or BINDER.search(before):
            return "write"
        return "read"
    if prev in ("{", ";") and (after == "" or after[0] in ";}"):
        return "write"
    return "read"


def writes_in(lines: list[str], names: set[str]) -> set[str]:
    written: set[str] = set()
    for line in lines:
        for m in WORD.finditer(line):
            if m.group(1) in names and classify(line, m.start(1), m.end(1)) == "write":
                written.add(m.group(1))
    return written


def reads_in(lines: list[str], names: set[str]) -> set[str]:
    read: set[str] = set()
    for line in lines:
        for m in WORD.finditer(line):
            if m.group(1) in names and classify(line, m.start(1), m.end(1)) == "read":
                read.add(m.group(1))
    return read


def census(root: Path) -> list[Finding]:
    lib_decoder = root / LIB_DECODER
    lib_lines = code_lines(lib_decoder)
    bin_files = sorted((root / BIN_DIR).glob(BIN_SCAN_GLOB))
    bin_lines = {path: code_lines(path) for path in bin_files}
    tui_files = sorted((root / BIN_DIR).glob(BIN_TUI_GLOB))

    decoded: dict[str, Path] = {name: LIB_DECODER for name in declared_fields(lib_lines)}
    bin_declared: set[str] = set()
    for path in tui_files:
        bin_declared |= declared_fields(bin_lines[path])
    for path in tui_files:
        lines = bin_lines[path]
        if not any(DECODE_CALL.search(line) for line in lines):
            continue
        for name in writes_in(lines, bin_declared):
            decoded.setdefault(name, path.relative_to(root))

    names = set(decoded)
    read: set[str] = reads_in(lib_lines, names)
    for lines in bin_lines.values():
        read |= reads_in(lines, names)
    return sorted(
        (Finding(name, decoded[name]) for name in names - read),
        key=lambda f: (str(f.decoder), f.field),
    )


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args(argv)
    findings = census(args.root)
    for finding in findings:
        print(f"{finding.decoder}\t{finding.field}")
    print(f"{len(findings)} decoded field(s) read by nothing", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
