#!/usr/bin/env python3
r"""Pin what the ignore-justification lint sees and what it does not.

The lint this covers replaced a shell version whose `^\s*ignore \(` search
saw one shape out of five. The two directions matter equally here, so every
case below is asserted in both: a site the lint must report, or a token it
must leave alone. A test that only checked the first direction would pass
against a lint that reported every line in the file.

Run directly; exits non-zero on the first mismatch.
"""

from __future__ import annotations

import importlib.util
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location(
    "lint_ignore", HERE / "lint-ignore-without-comment.py"
)
assert spec and spec.loader
lint = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lint)

# Each entry: (source line, is_a_site). Line numbers below are 1-based and
# derived from position in this list, so keep additions at the end of a
# logical group rather than renumbering by hand.
CASES: list[tuple[str, bool]] = [
    ("let flat () =", False),
    ("  ignore (side_effect x);", True),
    ("", False),
    ("let folded () =", False),
    # ocamlformat writes this whenever the argument is long. The old shell
    # lint could not see it, and this is the case the rewrite exists for.
    ("  ignore", True),
    ("    (side_effect_with_a_long_name ~label:\"x\" ~count:3);", False),
    ("", False),
    ("let piped () = side_effect x |> ignore", True),
    ("", False),
    ("let applied () = ignore side_effect", True),
    ("", False),
    ("let mid_line () = if ok then ignore (side_effect x) else ()", True),
    ("", False),
    ("(* fire-and-forget: the counter is advisory *)", False),
    ("let justified_above () = ignore (side_effect x)", False),
    ("", False),
    ("let justified_same_line () = ignore (f x) (* WORKAROUND: see #1 *)", False),
    ("", False),
    ("(* the [ignore] here is prose, not a call *)", False),
    ("(** readers ignore earlier entries *)", False),
    ("(* outer (* inner ignore *) still comment *)", False),
    ("", False),
    ("let in_string () = log \"ignore this line\"", False),
    ("let in_quoted () = log {|ignore me too|}", False),
    ("let in_quoted_tag () = log {sql|ignore that|sql}", False),
    ("", False),
    ("let ignore_errors = true", False),
    ("let ignore' x = x", False),
    ("let _ = some_ignore_helper ()", False),
    ("", False),
    # A quote inside a string must not swallow the rest of the file.
    ("let quote_char () = char_is '\"' && ignore (f x) = ()", True),
    ("", False),
    # The OCaml lexer reads string literals inside comments, so a `"*)"`
    # written in prose does not close the comment. Ending it there left the
    # trailing quote opening a string nothing had opened, which pushed the
    # scan out of phase in both directions: a real call went unseen, and a
    # word inside an ordinary string was reported as one.
    ('(* the close marker "*)" written in prose *)', False),
    ("let after_quoted_close () = ignore (f x)", True),
    ("", False),
    ('(* a {|*)|} quoted literal in prose *)', False),
    ("let after_quoted_literal () = ignore (f x)", True),
    ("", False),
    ('(* prose mentioning "*)" again *)', False),
    ('let string_after_comment () = log "ignore this text"', False),
]


def main() -> int:
    source = "\n".join(line for line, _ in CASES) + "\n"
    expected = {i for i, (_, is_site) in enumerate(CASES, 1) if is_site}

    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "fixture.ml"
        path.write_text(source)
        reported = {lineno for lineno, _ in lint.sites(path, want_all=False)}
        every = {lineno for lineno, _ in lint.sites(path, want_all=True)}

    failures: list[str] = []

    for lineno in sorted(expected - reported):
        failures.append(f"  line {lineno} should be a site: {CASES[lineno-1][0]!r}")
    for lineno in sorted(reported - expected):
        failures.append(f"  line {lineno} is not a site: {CASES[lineno-1][0]!r}")

    # --all differs from the default only by the justified pair.
    justified = {
        i
        for i, (line, _) in enumerate(CASES, 1)
        if "fire-and-forget" not in line and "WORKAROUND" not in line
        and lint.TOKEN.search(lint.blank_noncode(line))
        and i not in expected
    }
    for lineno in sorted(justified - every):
        failures.append(f"  line {lineno} should appear under --all")

    # The scan boundary is the `test/` directory, not a filename prefix.
    for name, expected_test in (
        ("lib/exec/test/test_exec_buffer.ml", True),
        ("lib/keeper/test_helper.ml", False),
        ("test/test_foo.ml", True),
        ("lib/keeper/keeper_gate.ml", False),
    ):
        got = lint.is_test_path(Path(name))
        if got != expected_test:
            failures.append(
                f"  is_test_path({name!r}) = {got}, expected {expected_test}"
            )

    if failures:
        print("lint-ignore-without-comment mismatches:")
        print("\n".join(failures))
        return 1

    print(f"ok: {len(expected)} sites reported, {len(CASES) - len(expected)} lines left alone")
    return 0


if __name__ == "__main__":
    sys.exit(main())
