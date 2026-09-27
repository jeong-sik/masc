#!/usr/bin/env python3
"""Test wiring agrees with the files in both directions.

A test/*.ml must be named by a dune stanza, or dune silently skips it; and a
script a stanza names must exist, or root `dune build @runtest` fails with
"No rule found". A script is any atom ending in .py, .sh, .cjs or .mjs --
whether it sits in `%{dep:...}`, a `(deps ...)` field or a bare `(run ...)`
argument -- read as a complete atom, with quoted atoms and `;` comments
respected. Glob patterns are dependencies, not literal filenames; their
suffixes must not be interpreted as missing scripts. No rule in the test tree
produces a file with those extensions, so every such atom names a source file.

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

from dataclasses import dataclass
import os
import pathlib
import re
import sys
import tempfile

# A scan that finds almost nothing has lost its tree, not found a clean one.
MIN_MODULES = 1000

MODULE_TOKEN = re.compile(r"[A-Za-z0-9_]+")
SCRIPT_SUFFIXES = (b".py", b".sh", b".cjs", b".mjs")
DUNE_WHITESPACE = " \t\r\n\f"


@dataclass(frozen=True)
class DuneAtom:
    value: bytes
    # Byte offsets in the decoded value where a real %{ expansion starts.
    # An escaped percent or a raw block string can spell the same literal text.
    expansions: frozenset[int]

    @property
    def text(self) -> str:
        return self.value.decode("utf-8", errors="surrogateescape")


def dune_forms(text: str) -> list:
    """Read Dune lists and literal atoms, without shell quoting rules.

    https://dune.readthedocs.io/en/stable/reference/lexical-conventions.html
    Apostrophes and unquoted backslashes are ordinary atom characters.
    """
    pos = 0

    def escaped() -> bytes:
        nonlocal pos
        if pos >= len(text):
            raise ValueError("unfinished escape in Dune string")
        char = text[pos]
        pos += 1
        simple = {"n": "\n", "r": "\r", "t": "\t", "b": "\b",
                  "\\": "\\", '"': '"'}
        if char in simple:
            return simple[char].encode("utf-8")
        if char in "0123456789":
            digits = char + text[pos:pos + 2]
            if len(digits) != 3 or any(c not in "0123456789" for c in digits):
                raise ValueError("invalid decimal escape in Dune string")
            pos += 2
            value = int(digits)
            if value > 255:
                raise ValueError("Dune decimal escape exceeds one byte")
            return bytes([value])
        if char == "x":
            digits = text[pos:pos + 2]
            if len(digits) != 2 or any(c not in "0123456789abcdefABCDEF" for c in digits):
                raise ValueError("invalid hexadecimal escape in Dune string")
            pos += 2
            return bytes([int(digits, 16)])
        if char == "%" and text[pos:pos + 1] == "{":
            return b"%"
        if char in "\r\n":
            if char == "\r" and text[pos:pos + 1] == "\n":
                pos += 1
            while pos < len(text) and text[pos] in " \t":
                pos += 1
            return b""
        raise ValueError(f"unsupported Dune string escape: {char!r}")

    def quoted() -> DuneAtom:
        nonlocal pos
        pos += 1
        chars = bytearray()
        expansions = set()

        def append(char, interpret=True):
            if interpret and char == "\\":
                chars.extend(escaped())
            else:
                if interpret and char == "%" and text[pos:pos + 1] == "{":
                    expansions.add(len(chars))
                chars.extend(char.encode("utf-8"))

        def atom():
            return DuneAtom(bytes(chars), frozenset(expansions))

        # Dune's end-of-line strings may continue on adjacent marked lines.
        if text[pos:pos + 2] in ("\\|", "\\>"):
            while True:
                interpret = text[pos + 1] == "|"
                pos += 2
                if text[pos:pos + 1] == " ":
                    pos += 1
                elif pos < len(text) and text[pos] not in "\r\n":
                    raise ValueError("Dune block strings require a space after the marker")
                escaped_newline = False
                while pos < len(text) and text[pos] not in "\r\n":
                    char = text[pos]
                    pos += 1
                    if interpret and char == "\\" and text[pos:pos + 1] in ("\r", "\n"):
                        escaped_newline = True
                        break
                    append(char, interpret)
                following = pos
                if text[following:following + 2] == "\r\n":
                    following += 2
                elif following < len(text):
                    following += 1
                if not escaped_newline:
                    chars.extend(text[pos:following].encode("utf-8"))
                pos = following
                while following < len(text) and text[following] in " \t\f":
                    following += 1
                if text[following:following + 3] not in ('"\\|', '"\\>'):
                    return atom()
                pos = following + 1
        while pos < len(text):
            char = text[pos]
            pos += 1
            if char == '"':
                return atom()
            append(char)
        raise ValueError("unterminated Dune string")

    def sequence(nested=False) -> list:
        nonlocal pos
        result = []
        while pos < len(text):
            char = text[pos]
            if char in DUNE_WHITESPACE:
                pos += 1
            elif char == ";":
                while pos < len(text) and text[pos] != "\n":
                    pos += 1
            elif char == "(":
                pos += 1
                result.append(sequence(nested=True))
            elif char == ")":
                if not nested:
                    raise ValueError("unmatched closing Dune parenthesis")
                pos += 1
                return result
            elif char == '"':
                result.append(quoted())
            else:
                start = pos
                while pos < len(text) and text[pos] not in DUNE_WHITESPACE and text[pos] not in '();"':
                    pos += 1
                value = text[start:pos].encode("utf-8")
                expansions = frozenset(i for i in range(len(value))
                                       if value[i:i + 2] == b"%{")
                result.append(DuneAtom(value, expansions))
        if nested:
            raise ValueError("unclosed Dune list")
        return result

    return sequence()


def script_atoms(text: str):
    """Find literal script atoms; skip complete glob dependency expressions."""
    def literals(form):
        if isinstance(form, DuneAtom):
            yield form
        elif form and not (isinstance(form[0], DuneAtom)
                           and form[0].text in ("glob_files", "glob_files_rec")):
            for child in form:
                yield from literals(child)

    for form in dune_forms(text):
        for atom in literals(form):
            value, expansions = atom.value, atom.expansions
            if (value.startswith(b"%{dep:") and value.endswith(b"}")
                    and expansions == {0}):
                value = value[len(b"%{dep:"):-1]
                expansions = frozenset()
            root_prefix = b"%{workspace_root}/"
            if value.startswith(root_prefix) and 0 in expansions:
                prefix, name = root_prefix.decode("ascii"), value[len(root_prefix):]
                expansions = frozenset(i - len(root_prefix) for i in expansions if i != 0)
            else:
                prefix, name = None, value
            if not expansions and name.endswith(SCRIPT_SUFFIXES):
                yield prefix, name.decode("utf-8", errors="surrogateescape")


def read_text(path: pathlib.Path) -> str:
    with path.open(encoding="utf-8", errors="replace", newline="") as source:
        return source.read()


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
        for form in dune_forms(text):
            if (isinstance(form, list) and len(form) == 2
                    and isinstance(form[0], DuneAtom) and form[0].text == "include"
                    and isinstance(form[1], DuneAtom) and not form[1].expansions):
                walk(path.parent / form[1].text)

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
    # Dune's lexer preserves a block's last newline, and an escaped newline
    # continues only into another block marker. Compare the literal bytes,
    # not a filename guessed after trimming them.
    block_cases = [
        ('"\\> %{raw}.py\n', b"%{raw}.py\n"),
        ('"\\| \\%{escaped}.py\r\n', b"%{escaped}.py\r\n"),
        ('"\\| first\\\n "\\> second.py\n', b"firstsecond.py\n"),
        ('"\\> first\n "\\| second.py', b"first\nsecond.py"),
        ('"\\> %{eof}.py', b"%{eof}.py"),
    ]
    for source, expected in block_cases:
        actual = dune_forms(source)
        if actual == [DuneAtom(expected, frozenset())]:
            print("[PASS] block string bytes " + repr(expected))
        else:
            print(f"[FAIL] block string bytes: {actual!r}", file=sys.stderr)
            rc = 1
    literal_cases = [
        (
            "escaped expansion text remains a checked literal filename",
            r'''(rule (deps "\%{literal}.py" "\x25{hex}.sh"
                 "\%{dep:literal.py}" "\%{present}.py"
                 "\%{workspace_root}/missing.py"))''',
            ["test/%{hex}.sh", "test/%{literal}.py",
             "test/%{workspace_root}/missing.py"],
        ),
        (
            "real expansions keep their scope beside literal expansion text",
            r'''(rule (deps "%{dep:missing.sh}" "%{dep:present.sh}"
                 "%{workspace_root}/tools/\%{literal}.py"
                 "%{workspace_root}/tools/\%{present}.py"
                 "%{unknown}/dynamic.py"))''',
            ["test/missing.sh", "tools/%{literal}.py"],
        ),
        (
            "block strings retain final newlines rather than invent script paths",
            '(rule (deps\n "\\> %{raw}.py\n) (deps\n'
            ' "\\| \\%{escaped}.py\n) (deps\n'
            ' "\\| %{unknown}/dynamic.py\n))\n',
            [],
        ),
        (
            "apostrophes remain ordinary Dune atom characters",
            """(rule (deps can't foo's.py "present's.py"))""",
            ["test/foo's.py"],
        ),
        (
            "quoted path spaces and escapes name complete literal files",
            r'''(rule (deps "missing script.py" "%{dep:missing dep.sh}"
                 "%{workspace_root}/tools/missing tool.mjs"
                 "present\032script.py" "caf\xc3\xa9.py" "quote\"name.py"))''',
            ["test/missing dep.sh", "test/missing script.py",
             'test/quote"name.py', "tools/missing tool.mjs"],
        ),
        (
            "glob dependency forms remain optional without wildcard characters",
            """(rule (deps (:optional (glob_files optional.py)
                 (glob_files_rec "optional script.py")
                 (glob_files_rec %{workspace_root}/optional.sh))
                 (file mandatory.py) "literal*name.py" mandatory.sh))""",
            ["test/literal*name.py", "test/mandatory.py", "test/mandatory.sh"],
        ),
        (
            "quoted parentheses and semicolons cannot change list structure",
            r'''(rule (deps (glob_files "optional(name).py")
                 "missing;name.py" "missing(name).py" "back\092slash.py"))
                 ; not-a-file.py
                 (rule (deps present\name.py))''',
            ["test/back\\slash.py", "test/missing(name).py", "test/missing;name.py"],
        ),
        (
            "end-of-line strings do not discard their final newline",
            '(rule (deps\n "\\| missing\\032line.py\n))\n',
            [],
        ),
    ]
    for title, text, expected in literal_cases:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            dune = root / "dune"
            dune.write_text(text)
            for name in ["present's.py", "present script.py", "café.py", r"present\name.py",
                         "%{dep:literal.py}", "%{present}.py", "present.sh",
                         "tools/%{present}.py"]:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("")
            missing = missing_scripts(root, root, dune, "test")
            if missing == expected:
                print(f"[PASS] {title}")
            else:
                print(f"[FAIL] {title}: {missing}", file=sys.stderr)
                rc = 1

    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        dune = root / "dune"
        dune.write_bytes(b'(rule (deps "missing\r\nscript.py" "present\r\nscript.py"))\r\n')
        (root / "present\r\nscript.py").write_bytes(b"")
        missing = missing_scripts(root, root, dune, "test")
        if missing == ["test/missing\r\nscript.py"]:
            print("[PASS] filesystem reads preserve CRLF in literal filenames")
        else:
            print(f"[FAIL] filesystem CRLF literal filenames: {missing!r}", file=sys.stderr)
            rc = 1

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
