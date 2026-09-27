#!/usr/bin/env python3
"""Test wiring agrees with the files in both directions.

A test/*.ml must be named by a dune stanza, or dune silently skips it; and a
script a stanza names must exist, or root `dune build @runtest` fails with
"No rule found". A script is any atom ending in .py, .sh, .cjs or .mjs --
whether it sits in `%{dep:...}`, a `(deps ...)` field or a bare `(run ...)`
argument -- read as a complete atom under Dune's quoting rules, where only
`"` quotes and `;` starts a comment. Arguments of (glob_files ...) and
(glob_files_rec ...) are patterns rather than filenames, so those forms are
skipped whole. No rule in the test tree produces a file with those extensions,
so every other such atom names a source file.

`test/dune` has no top-level `(modules)` field, so a `test/*.ml` that no stanza
names is not an error: dune leaves it out of the build, CI stays green, and that
suite never runs. The file stays in the tree and the only sign is a human
counting which files ran. PR #37980 came within one review of adding the first
such orphan -- it deleted the `test_operator_attention_summary` stanza while
leaving `test/test_operator_attention_summary.ml` (3,487 B) in place, and its
head was 6/6 green.

Wiring sites, all counted:
  - `test/dune` itself
  - `test/stanzas/*.inc`, which `test/dune` `(include ...)`s
  - a subdirectory's own `dune` (`test/<d>/*.ml` is matched against
    `test/<d>/dune`)

The reverse direction: #37016 deleted `test/test_runtime_default_catalog_cli.py`
and kept its rule and runtest alias. PR checks never run root @runtest, so it
surfaced four days later as the only error in the release-candidate behavior
job (run 35811260145), fixed by #38177. A script dependency resolves against
the directory of the dune file whose stanzas include it, so `test/stanzas/*.inc`
resolves against `test/`.

The baseline is 0 orphans and 0 missing scripts, so the guard is strict. A
guard added after the baseline drifts has to carry an allowance forever; this
one does not.
"""
from __future__ import annotations

import os
import pathlib
import re
import sys
import tempfile

# A scan that finds almost nothing has lost its tree, not found a clean one.
MIN_MODULES = 1000

MODULE_TOKEN = re.compile(r"[A-Za-z0-9_]+")
INCLUDE = re.compile(r"\(include\s+([^)\s]+)\)")
SCRIPT_ATOM = re.compile(
    r"(%\{workspace_root\}/)?((?:\.\.?/)?[\w./' -]*\w\.(?:py|sh|cjs|mjs))"
)

# Dependency forms whose arguments are patterns, not literal filenames.
GLOB_FORMS = frozenset({"glob_files", "glob_files_rec"})


def dune_tokens(text: str):
    """Split stanza text into `(`, `)` and atoms, following Dune's quoting.

    Only `"` quotes; `'` is an ordinary atom character and `;` starts a
    comment. An unterminated quote yields the rest of the input rather than
    raising, because a lint must report, not crash.
    """
    buf: list[str] = []
    i, n = 0, len(text)
    while i < n:
        ch = text[i]
        if ch == ";":
            if buf:
                yield "".join(buf)
                buf.clear()
            nl = text.find("\n", i)
            i = n if nl < 0 else nl + 1
        elif ch == "(" or ch == ")":
            if buf:
                yield "".join(buf)
                buf.clear()
            yield ch
            i += 1
        elif ch == '"':
            if buf:
                yield "".join(buf)
                buf.clear()
            i += 1
            quoted: list[str] = []
            while i < n and text[i] != '"':
                if text[i] == "\\" and i + 1 < n:
                    i += 1
                quoted.append(text[i])
                i += 1
            i += 1
            yield "".join(quoted)
        elif ch.isspace():
            if buf:
                yield "".join(buf)
                buf.clear()
            i += 1
        else:
            buf.append(ch)
            i += 1
    if buf:
        yield "".join(buf)


def script_atoms(text: str):
    """Literal script references only; never a pattern inside a glob form.

    A glob form without metacharacters still expands to an empty dependency
    set rather than a missing file, so each list's head atom decides whether
    its arguments are skipped.
    """
    stack: list[bool | None] = []
    for tok in dune_tokens(text):
        if tok == "(":
            stack.append(None)
        elif tok == ")":
            if stack:
                stack.pop()
        else:
            if stack and stack[-1] is None:
                stack[-1] = tok in GLOB_FORMS
            if True in stack:
                continue
            atom = tok
            if atom.startswith("%{dep:") and atom.endswith("}"):
                atom = atom[len("%{dep:"):-1]
            match = SCRIPT_ATOM.fullmatch(atom)
            if match is not None:
                yield match.groups()


def read_text(path: pathlib.Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def wiring_text(dune: pathlib.Path) -> str:
    """The dune file plus every file it (include ...)s, recursively."""
    seen: set[pathlib.Path] = set()
    parts: list[str] = []

    def walk(path: pathlib.Path) -> None:
        path = path.resolve()
        if path in seen or not path.is_file():
            return
        seen.add(path)
        text = read_text(path)
        parts.append(text)
        for target in INCLUDE.findall(text):
            walk(path.parent / target)

    walk(dune)
    return "\n".join(parts)


def modules_in(directory: pathlib.Path) -> list[str]:
    return sorted(p.stem for p in directory.glob("*.ml"))


def orphans(directory: pathlib.Path, dune: pathlib.Path) -> list[str]:
    if not dune.is_file():
        return []
    wired = set(MODULE_TOKEN.findall(wiring_text(dune)))
    return [name for name in modules_in(directory) if name not in wired]


def missing_scripts(
    repo_root: pathlib.Path, directory: pathlib.Path, dune: pathlib.Path, label: str
) -> list[str]:
    """Script atoms that resolve to no file. Stanzas pulled in by (include)
    behave as if written in [dune], so they resolve against its directory;
    a %{workspace_root}/ prefix resolves against the repository root."""
    if not dune.is_file():
        return []
    missing = set()
    for root_prefix, name in script_atoms(wiring_text(dune)):
        base, shown = (repo_root, name) if root_prefix else (directory, f"{label}/{name}")
        shown = os.path.normpath(shown)
        if not (base / name).is_file():
            missing.add(shown)
    return sorted(missing)


def scan(repo_root: pathlib.Path) -> tuple[int, list[str], list[str]]:
    test_dir = repo_root / "test"
    checked = len(modules_in(test_dir))
    found = [f"test/{name}.ml" for name in orphans(test_dir, test_dir / "dune")]
    missing = missing_scripts(repo_root, test_dir, test_dir / "dune", "test")

    for dune in sorted(test_dir.glob("*/dune")):
        sub = dune.parent
        checked += len(modules_in(sub))
        found += [f"test/{sub.name}/{name}.ml" for name in orphans(sub, dune)]
        missing += missing_scripts(repo_root, sub, dune, f"test/{sub.name}")

    return checked, found, missing


def self_test() -> int:
    rc = 0
    # This is valid Dune dependency syntax. The old substring scan invented
    # [_pty.py] from the wildcard, blocking #39263 although Dune built it.
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        dune = root / "dune"
        dune.write_text(
            '(rule (deps (glob_files test_tui_keyboard_*_pty.py)\n'
            ' (glob_files "test_tui_keyboard_?_pty.py")\n'
            ' (glob_files test_tui_keyboard_[ab]_pty.py)\n'
            ' "missing.py" %{dep:also_missing.sh}))\n'
            '; ignored.py is a comment\n'
        )
        missing = missing_scripts(root, root, dune, "test")
        if missing == ["test/also_missing.sh", "test/missing.py"]:
            print("[PASS] glob suffixes are not scripts; adjacent quoted and dep literals still fail")
        else:
            print(f"[FAIL] glob/literal distinction: {missing}", file=sys.stderr)
            rc = 1
    # Red controls for the review of this fix: a glob form without
    # metacharacters is still a pattern, an apostrophe is an ordinary atom
    # character that must not abort the scan, and a quoted path with a
    # space is still checked whole.
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        dune = root / "dune"
        dune.write_text(
            "(rule (deps (glob_files optional.py)\n"
            " cant's.py\n"
            ' "fixtures/missing script.py"))\n'
        )
        missing = missing_scripts(root, root, dune, "test")
        if missing == ["test/cant's.py", "test/fixtures/missing script.py"]:
            print("[PASS] glob forms are skipped whole;"
                  " apostrophe and spaced paths are checked, not fatal")
        else:
            print(f"[FAIL] dune quoting/glob context: {missing}", file=sys.stderr)
            rc = 1
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        test = root / "test"
        (test / "stanzas").mkdir(parents=True)
        (test / "sub").mkdir()

        (test / "dune").write_text("(include stanzas/wired.inc)\n")
        (test / "stanzas" / "wired.inc").write_text(
            "(test\n (name test_alpha)\n (modules test_alpha)\n (libraries x))\n"
            "(rule\n (alias runtest-present)\n"
            " (action (run python3 %{dep:present.py} %{dep:../bin/x.exe})))\n"
            "(rule\n (alias runtest-gone)\n (action (run python3 %{dep:gone.py})))\n"
            "(rule\n (alias runtest-deps-only)\n (deps ../scripts/gone-tool.sh)\n"
            " (action (run node gone.cjs)))\n"
            "(rule\n (alias runtest-rooted)\n (deps %{workspace_root}/scripts/rooted.sh))\n"
            "; a comment naming %{dep:only-in-comment.py} is not wiring\n"
        )
        (test / "present.py").write_text("")
        (root / "scripts").mkdir()
        (root / "scripts" / "rooted.sh").write_text("")
        (test / "test_alpha.ml").write_text("")
        (test / "test_orphan.ml").write_text("")
        (test / "sub" / "dune").write_text("(test\n (name test_sub)\n (modules test_sub))\n")
        (test / "sub" / "test_sub.ml").write_text("")
        (test / "sub" / "test_sub_orphan.ml").write_text("")

        checked, found, missing = scan(root)
        if missing == ["scripts/gone-tool.sh", "test/gone.cjs", "test/gone.py"]:
            print("[PASS] fire: a missing script is reported from %{dep:}, a (deps) field and a"
                  " bare run argument; an included stanza resolves against test/,"
                  " %{workspace_root}/ against the root, and comments and build products are skipped")
        else:
            print(f"[FAIL] wrong missing scripts: {missing}", file=sys.stderr)
            rc = 1

        if checked != 4:
            print(f"[FAIL] expected 4 modules, counted {checked}", file=sys.stderr)
            rc = 1
        else:
            print("[PASS] counts every top-level and subdirectory module")

        if found == ["test/test_orphan.ml", "test/sub/test_sub_orphan.ml"]:
            print("[PASS] fire: an unwired module is reported, wired ones are not")
        else:
            print(f"[FAIL] wrong orphans: {found}", file=sys.stderr)
            rc = 1

        (test / "test_orphan.ml").unlink()
        (test / "sub" / "test_sub_orphan.ml").unlink()
        (test / "gone.py").write_text("")
        (test / "gone.cjs").write_text("")
        (root / "scripts" / "gone-tool.sh").write_text("")
        _, found, missing = scan(root)
        if found == [] and missing == []:
            print("[PASS] pass: a fully wired tree reports nothing")
        else:
            print(f"[FAIL] a clean tree was reported: {found} {missing}", file=sys.stderr)
            rc = 1

    return rc


def main() -> int:
    if "--self-test" in sys.argv[1:]:
        return self_test()

    repo_root = pathlib.Path(__file__).resolve().parents[2]
    checked, found, missing = scan(repo_root)

    if checked < MIN_MODULES:
        print(
            f"[test-wiring] read {checked} test module(s), expected at least "
            f"{MIN_MODULES}. The scan lost the tree or its shape, rather than "
            "finding a clean one.",
            file=sys.stderr,
        )
        return 2

    rc = 0
    if missing:
        print("A script a dune stanza runs is not in the tree, so root @runtest fails:",
              file=sys.stderr)
        for name in missing:
            print(f"  {name}", file=sys.stderr)
        print(file=sys.stderr)
        print("Delete the stanza and its runtest alias with the script, or restore the script.",
              file=sys.stderr)
        rc = 1

    if found:
        print("A test module no dune stanza names, so dune silently skips it:", file=sys.stderr)
        for name in found:
            print(f"  {name}", file=sys.stderr)
        print(file=sys.stderr)
        print(
            "Name it in test/dune (or a test/stanzas/*.inc it includes), or "
            "delete the file. dune builds only what a stanza names.",
            file=sys.stderr,
        )
        rc = 1

    if rc == 0:
        print(f"test modules: 0 unwired across {checked} module(s); 0 missing stanza scripts")
    return rc


if __name__ == "__main__":
    sys.exit(main())
