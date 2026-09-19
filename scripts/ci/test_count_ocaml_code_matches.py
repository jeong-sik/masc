#!/usr/bin/env python3
"""Self-test for count_ocaml_code_matches.py.

Each case is OCaml text and the number of [@@deriving tla] the counter must
find in its code. The shapes are the ones the lexer has to read the way the
OCaml lexer does: nested comments, strings and characters inside comments,
quoted strings, and quotes that belong to identifiers. The CLI modes are then
run against a small tree on disk.

Run directly: `python3 scripts/ci/test_count_ocaml_code_matches.py`
Exits 0 on success, 1 on the first failed expectation.
"""

from __future__ import annotations

import importlib.util
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
COUNTER = REPO_ROOT / "scripts" / "ci" / "count_ocaml_code_matches.py"
DERIVING_TLA = r"\[@@deriving tla\]"


def load_counter():
    spec = importlib.util.spec_from_file_location("count_ocaml_code_matches", COUNTER)
    if spec is None or spec.loader is None:
        raise SystemExit(f"cannot load {COUNTER}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


CASES: list[tuple[str, str, int]] = [
    ("an attribute in code counts", "type t = A [@@deriving tla]\n", 1),
    ("a comment naming the attribute does not", "(* no [@@deriving tla] here *)\n", 0),
    (
        "a nested comment ends at its own close",
        "(* outer (* inner *) still [@@deriving tla] *)\ntype t = A [@@deriving tla]\n",
        1,
    ),
    (
        "a string inside a comment hides a close",
        '(* "*)" [@@deriving tla] *)\ntype t = A [@@deriving tla]\n',
        1,
    ),
    (
        "a character literal inside a comment opens no string",
        "(* '\"' [@@deriving tla] *)\ntype t = A [@@deriving tla]\n",
        1,
    ),
    (
        "an identifier's quote inside a comment is not a character",
        "(* don't \"stop\" [@@deriving tla] *)\ntype t = A [@@deriving tla]\n",
        1,
    ),
    (
        # The OCaml lexer reads x' as one identifier, so '"' is not a
        # character here and the " opens a string that ends before *).
        "an identifier ending in a quote is read before a character",
        "(* x'\"' \" *)\ntype t = A [@@deriving tla]\n",
        1,
    ),
    (
        "an escaped quote character in code",
        "let q = '\\''\ntype t = A [@@deriving tla]\n",
        1,
    ),
    ("a string literal in code does not count", 'let s = "[@@deriving tla]"\n', 0),
    ("a quoted string does not count", "let s = {|[@@deriving tla]|}\n", 0),
    (
        "a named quoted string ends only at its own terminator",
        "let s = {id|a |} [@@deriving tla] |id}\ntype t = A [@@deriving tla]\n",
        1,
    ),
    (
        "two in code both count",
        "type a = A [@@deriving tla]\ntype b = B [@@deriving tla]\n",
        2,
    ),
]

REJECTED: list[tuple[str, str]] = [
    ("an unterminated comment", "(* open [@@deriving tla]\n"),
    ("an unterminated string inside a comment", '(* "open *)\n'),
    ("an unterminated quoted string", "let s = {x|open\n"),
]


def run_cli(mode: str, root: Path) -> str:
    result = subprocess.run(
        [sys.executable, str(COUNTER), mode, DERIVING_TLA, str(root)],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise AssertionError(f"{mode} exited {result.returncode}: {result.stderr}")
    return result.stdout.strip()


def main() -> int:
    counter = load_counter()
    pattern = re.compile(DERIVING_TLA)
    failures = 0

    for name, text, expected in CASES:
        masked = counter.mask_ocaml_non_code(text)
        found = len(pattern.findall(masked))
        if found != expected:
            print(f"FAIL {name}: expected {expected}, found {found}")
            failures += 1
        elif len(masked) != len(text) or masked.count("\n") != text.count("\n"):
            print(f"FAIL {name}: masking changed length or line count")
            failures += 1

    for name, text in REJECTED:
        try:
            counter.mask_ocaml_non_code(text)
        except counter.OcamlLexError:
            continue
        print(f"FAIL {name}: accepted input the OCaml lexer rejects")
        failures += 1

    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        (root / "a").mkdir()
        (root / "b").mkdir()
        (root / "a" / "one.ml").write_text(
            "type x = X [@@deriving tla]\ntype y = Y [@@deriving tla]\n", encoding="utf-8"
        )
        (root / "a" / "one.mli").write_text("type x = X [@@deriving tla]\n", encoding="utf-8")
        (root / "b" / "note.ml").write_text("(* [@@deriving tla] *)\n", encoding="utf-8")
        (root / "top.ml").write_text("type z = Z [@@deriving tla]\n", encoding="utf-8")
        for mode, expected in (("files", "2"), ("matches", "3"), ("subdirs", "2")):
            got = run_cli(mode, root)
            if got != expected:
                print(f"FAIL cli {mode}: expected {expected}, got {got}")
                failures += 1

        (root / "b" / "broken.ml").write_text("(* open\n", encoding="utf-8")
        broken = subprocess.run(
            [sys.executable, str(COUNTER), "files", DERIVING_TLA, str(root)],
            capture_output=True,
            text=True,
            check=False,
        )
        if broken.returncode == 0 or "broken.ml" not in broken.stderr:
            print("FAIL cli: an unreadable file must fail and name the file")
            failures += 1

    if failures:
        return 1
    print(f"count_ocaml_code_matches: {len(CASES) + len(REJECTED) + 4} expectations hold")
    return 0


if __name__ == "__main__":
    sys.exit(main())
