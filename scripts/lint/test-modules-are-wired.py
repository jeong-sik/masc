#!/usr/bin/env python3
"""Every test/*.ml must be named by a dune stanza, or dune silently skips it.

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

The baseline is 0 orphans, so the guard is strict: any orphan fails. A guard
added after the baseline drifts has to carry an allowance forever; this one
does not.
"""
from __future__ import annotations

import pathlib
import re
import sys
import tempfile

# A scan that finds almost nothing has lost its tree, not found a clean one.
MIN_MODULES = 1000

MODULE_TOKEN = re.compile(r"[A-Za-z0-9_]+")
INCLUDE = re.compile(r"\(include\s+([^)\s]+)\)")


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


def scan(repo_root: pathlib.Path) -> tuple[int, list[str]]:
    test_dir = repo_root / "test"
    checked = len(modules_in(test_dir))
    found = [f"test/{name}.ml" for name in orphans(test_dir, test_dir / "dune")]

    for dune in sorted(test_dir.glob("*/dune")):
        sub = dune.parent
        checked += len(modules_in(sub))
        found += [f"test/{sub.name}/{name}.ml" for name in orphans(sub, dune)]

    return checked, found


def self_test() -> int:
    rc = 0
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        test = root / "test"
        (test / "stanzas").mkdir(parents=True)
        (test / "sub").mkdir()

        (test / "dune").write_text("(include stanzas/wired.inc)\n")
        (test / "stanzas" / "wired.inc").write_text(
            "(test\n (name test_alpha)\n (modules test_alpha)\n (libraries x))\n"
        )
        (test / "test_alpha.ml").write_text("")
        (test / "test_orphan.ml").write_text("")
        (test / "sub" / "dune").write_text("(test\n (name test_sub)\n (modules test_sub))\n")
        (test / "sub" / "test_sub.ml").write_text("")
        (test / "sub" / "test_sub_orphan.ml").write_text("")

        checked, found = scan(root)
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
        _, found = scan(root)
        if found == []:
            print("[PASS] pass: a fully wired tree reports nothing")
        else:
            print(f"[FAIL] a clean tree was reported: {found}", file=sys.stderr)
            rc = 1

    return rc


def main() -> int:
    if "--self-test" in sys.argv[1:]:
        return self_test()

    repo_root = pathlib.Path(__file__).resolve().parents[2]
    checked, found = scan(repo_root)

    if checked < MIN_MODULES:
        print(
            f"[test-wiring] read {checked} test module(s), expected at least "
            f"{MIN_MODULES}. The scan lost the tree or its shape, rather than "
            "finding a clean one.",
            file=sys.stderr,
        )
        return 2

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
        return 1

    print(f"test modules: 0 unwired across {checked} module(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
