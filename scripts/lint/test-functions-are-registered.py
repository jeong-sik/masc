#!/usr/bin/env python3
"""Every top-level `test_*` value in test/*.ml is used somewhere.

Test executables have no .mli, so warning 32 (unused value) never fires on a
test file: a `let test_foo () = ...` that no `test_case` list names compiles,
the run is green, and the test never executes. #39166 landed
`test_read_seed_stops_at_a_floor_response` this way (the fix for #39013 shipped
with a test that never ran), and #39185 repeated it with two more; a 5/5 run
and one PASS verdict let the second through.

The rule: a top-level `let test_<x>` / `and test_<x>` in `test/**/*.ml` must be
named again somewhere outside comments and string literals -- in its own file
(a `test_case` list, a table, a caller that is itself registered) or, qualified
as `Module.test_<x>`, in another test file. Reachability is approximated by
"named again"; a test called only by another dead test is not caught, and that
is accepted.

A value that is a helper, not a test, says so on the line directly above its
definition:

    (* test-helper: builds the fixture the three cases below share *)
    let test_fixture () = ...

The reason after the colon is required. Renaming the helper so it does not
start with `test_` is the other way out. There is no silent skip.

The baseline is 0, so the guard is strict.
"""
from __future__ import annotations

import pathlib
import re
import sys
import tempfile

# A scan that finds almost nothing has lost its tree, not found a clean one.
MIN_FILES = 500

DEF = re.compile(r"^(?:let(?:\s+rec)?|and)\s+(test_[A-Za-z0-9_']*)\b")
HELPER = re.compile(r"^\s*\(\*\s*test-helper:\s*\S.*\*\)\s*$")
IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_']*")
CHAR_LITERAL = re.compile(
    r"'(?:\\(?:[\\'\"ntbr ]|[0-9]{3}|x[0-9a-fA-F]{2}|o[0-7]{3})|[^\\'\n])'"
)


def strip_code(src: str) -> str:
    """Blank out comments, string and char literals; keep newlines and columns.

    Handles nested comments, strings inside comments (OCaml lexes them), escape
    sequences, and quoted strings `{id|...|id}`.
    """
    out = list(src)
    i, n = 0, len(src)
    depth = 0

    def blank(a: int, b: int) -> None:
        for k in range(a, b):
            if out[k] != "\n":
                out[k] = " "

    def skip_string(j: int) -> int:
        # j at opening quote; returns index after closing quote
        j += 1
        while j < n:
            c = src[j]
            if c == "\\":
                j += 2
                continue
            if c == '"':
                return j + 1
            j += 1
        return n

    def skip_quoted(j: int) -> int | None:
        m = re.match(r"\{([a-z_]*)\|", src[j:])
        if not m:
            return None
        close = "|" + m.group(1) + "}"
        k = src.find(close, j + m.end())
        return n if k < 0 else k + len(close)

    def char_literal_end(j: int) -> int | None:
        # 'x' or an escape; a type variable 'a or a prime in an identifier is not.
        if j > 0 and (src[j - 1].isalnum() or src[j - 1] == "_"):
            return None
        m = CHAR_LITERAL.match(src, j)
        return m.end() if m else None

    start = 0
    while i < n:
        c = src[i]
        if src.startswith("(*", i) and not src.startswith("(*)", i):
            if depth == 0:
                start = i
            depth += 1
            i += 2
            continue
        if depth > 0:
            if src.startswith("*)", i):
                depth -= 1
                i += 2
                if depth == 0:
                    blank(start, i)
                continue
            if c == "'":
                j = char_literal_end(i)
                if j is not None:
                    i = j
                    continue
            if c == '"':
                i = skip_string(i)
                continue
            i += 1
            continue
        if c == '"':
            j = skip_string(i)
            blank(i, j)
            i = j
            continue
        if c == "{":
            j = skip_quoted(i)
            if j is not None:
                blank(i, j)
                i = j
                continue
        if c == "'":
            j = char_literal_end(i)
            if j is not None:
                blank(i, j)
                i = j
                continue
        i += 1
    if depth > 0:
        blank(start, n)
    return "".join(out)


def module_name(path: pathlib.Path) -> str:
    return path.stem[:1].upper() + path.stem[1:]


def findings(root: pathlib.Path) -> tuple[list[str], int]:
    files = sorted(p for p in (root / "test").rglob("*.ml") if "_build" not in p.parts)
    raw = {p: p.read_text(encoding="utf-8", errors="replace") for p in files}
    code = {p: strip_code(t) for p, t in raw.items()}
    # Another file uses a value of module M when it names M (qualified use,
    # `module A = M`, `open M`, `include M`) and names the value too. The
    # value may come through an alias (`KSP.test_x`) or unqualified after
    # `open`, so both tokens are counted per file, not as one pattern.
    tokens_by_file = {p: set(IDENT.findall(text)) for p, text in code.items()}

    def used_elsewhere(owner: pathlib.Path, name: str) -> bool:
        mod = module_name(owner)
        return any(
            mod in toks and name in toks
            for p, toks in tokens_by_file.items()
            if p != owner
        )

    out: list[str] = []
    for p in files:
        lines_code = code[p].split("\n")
        lines_raw = raw[p].split("\n")
        counts: dict[str, int] = {}
        for tok in IDENT.findall(code[p]):
            if tok.startswith("test_"):
                counts[tok] = counts.get(tok, 0) + 1
        defs: dict[str, list[int]] = {}
        for ln, line in enumerate(lines_code, 1):
            m = DEF.match(line)
            if m:
                defs.setdefault(m.group(1), []).append(ln)
        for name, lns in defs.items():
            if counts.get(name, 0) > len(lns):
                continue
            if used_elsewhere(p, name):
                continue
            for ln in lns:
                if ln >= 2 and HELPER.match(lines_raw[ln - 2]):
                    continue
                out.append(f"{p.relative_to(root)}:{ln}: {name} is defined but never named by a test list or caller")
    return out, len(files)


def self_test() -> int:
    cases = {
        "registered": ("let test_a () = ()\nlet () = Alcotest.run \"x\" [ \"s\", [ Alcotest.test_case \"a\" `Quick test_a ] ]\n", []),
        "unregistered": ("let test_a () = ()\nlet test_b () = ()\nlet () = run [ tc test_a ]\n", ["test_b"]),
        "only in comment": ("let test_a () = ()\n(* test_a is registered below *)\nlet () = run []\n", ["test_a"]),
        "only in string": ("let test_a () = ()\nlet () = run [ \"test_a\", [] ]\n", ["test_a"]),
        "only in quoted string": ("let test_a () = ()\nlet s = {|test_a|}\n", ["test_a"]),
        "nested comment": ("let test_a () = ()\n(* (* test_a *) test_a \"*)\" *)\n", ["test_a"]),
        "called by another": ("let test_a () = ()\nlet test_b () = test_a ()\nlet () = run [ tc test_b ]\n", []),
        "and binding": ("let rec test_a () = test_b ()\nand test_b () = ()\n", ["test_a"]),
        "helper marker": ("(* test-helper: shared fixture *)\nlet test_fix () = ()\n", []),
        "helper marker needs reason": ("(* test-helper: *)\nlet test_fix () = ()\n", ["test_fix"]),
        "quote char inside a comment": ("(* a '\"' char *)\nlet test_a () = ()\nlet () = run [ tc test_a ]\n", []),
        "char literal quote": ("let q = '\"'\nlet test_a () = ()\nlet () = run [ tc test_a ]\n", []),
        "shadowed and unused": ("let test_a () = ()\nlet test_a () = ()\n", ["test_a", "test_a"]),
        "indented is not top-level": ("let f () =\n  let test_inner () = () in\n  ()\n", []),
    }
    failed = 0
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        (root / "test").mkdir()
        for label, (src, want) in cases.items():
            for f in (root / "test").glob("*.ml"):
                f.unlink()
            (root / "test" / "test_case_file.ml").write_text(src)
            got, _ = findings(root)
            got_names = [g.split(": ")[1].split(" ")[0] for g in got]
            if got_names != want:
                failed += 1
                print(f"FAIL {label}: want {want} got {got_names}", file=sys.stderr)
        # cross-file qualified reference
        for f in (root / "test").glob("*.ml"):
            f.unlink()
        (root / "test" / "helpers_x.ml").write_text("let test_shared () = ()\n")
        (root / "test" / "test_y.ml").write_text("let () = run [ tc Helpers_x.test_shared ]\n")
        got, _ = findings(root)
        if got:
            failed += 1
            print(f"FAIL qualified cross-file: {got}", file=sys.stderr)
        # through a module alias, and through open
        for label, user in {
            "alias cross-file": "module H = Helpers_x\nlet () = run [ tc H.test_shared ]\n",
            "open cross-file": "open Helpers_x\nlet () = run [ tc test_shared ]\n",
        }.items():
            (root / "test" / "test_y.ml").write_text(user)
            got, _ = findings(root)
            if got:
                failed += 1
                print(f"FAIL {label}: {got}", file=sys.stderr)
        # a same-named value in an unrelated file does not count
        (root / "test" / "test_y.ml").write_text("let test_shared () = ()\nlet () = run [ tc test_shared ]\n")
        got, _ = findings(root)
        if [g.split(": ")[1].split(" ")[0] for g in got] != ["test_shared"]:
            failed += 1
            print(f"FAIL unrelated same name: {got}", file=sys.stderr)
    total = len(cases) + 4
    print(f"test-functions-are-registered self-test: {total - failed}/{total} passed")
    return 1 if failed else 0


def main(argv: list[str]) -> int:
    if "--self-test" in argv:
        return self_test()
    root = pathlib.Path(__file__).resolve().parents[2]
    for a in argv:
        if a.startswith("--root="):
            root = pathlib.Path(a.split("=", 1)[1]).resolve()
    out, nfiles = findings(root)
    if nfiles < MIN_FILES and "--root=" not in " ".join(argv):
        print(f"::error::scanned only {nfiles} test files; expected at least {MIN_FILES}", file=sys.stderr)
        return 1
    for line in out:
        print(f"::error file={line.split(':')[0]},line={line.split(':')[1]}::{line}")
    if out:
        print(
            f"{len(out)} test_* value(s) are never run. Register each in a test_case list, "
            "delete it, rename it so it does not start with test_, or mark a helper with "
            "`(* test-helper: <reason> *)` on the line above.",
            file=sys.stderr,
        )
        return 1
    print(f"test-functions-are-registered: {nfiles} files, 0 unregistered test_* values")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
