#!/usr/bin/env python3
"""Report OCaml modules and `.mli` exports that nothing outside their own
module pair references.

Two modes:

    --modules   modules whose name token appears in no other file
    --exports   `val` bindings declared in a `.mli` whose name token appears
                in no file other than that module's own `.ml`/`.mli`

Both directions are deliberately biased toward reporting *fewer* candidates:
every file in the tree is scanned regardless of extension (dune stanzas,
`.inc` includes, TLA specs, docs, shell, CI YAML), and a bare token match
anywhere counts as a reference. A reported name is therefore a candidate for
removal, not a proof of deadness -- the compiler is the proof. The intended
workflow is:

    1. delete the `val` line from the `.mli`
    2. rebuild; if the name was in fact used elsewhere the build fails loudly
    3. if the implementation is now unreachable inside its own `.ml`, the
       compiler reports it (warning 32) and the implementation goes too

Matching is on token boundaries, not substrings: `cached_entry_count` is not
considered referenced by a call to `reset_cached_entry_count`. Conversely the
`.inc` and dune stanza files are scanned, so a test module registered only
from `test/stanzas/*.inc` is correctly seen as live.

Usage:
    python3 scripts/audit-dead-surface.py --modules
    python3 scripts/audit-dead-surface.py --exports [--min-name-len N]
    python3 scripts/audit-dead-surface.py --exports --json
    python3 scripts/audit-dead-surface.py --self-test
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import defaultdict
from pathlib import Path
from typing import TypedDict

ROOT = Path(__file__).resolve().parent.parent

# Trees that own OCaml compilation units.
SOURCE_ROOTS = ("lib", "bin", "test")

# Directories that never contain authored source.
SKIP_PARTS = frozenset({"_build", "node_modules", ".git", "_opam", ".worktrees"})

# Short names collide with unrelated identifiers often enough that a token
# scan says little about them, so `--exports` skips them by default.
DEFAULT_MIN_NAME_LEN = 8

TOKEN_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_']*")
VAL_RE = re.compile(r"^val\s+(?:\(\s*)?([a-z_][A-Za-z0-9_']*)", re.M)


class DeadModule(TypedDict):
    module: str
    ml: str
    mli: str | None
    loc: int


class DeadExport(TypedDict):
    name: str
    module: str
    mli: str
    # Facades republishing this module's whole signature; empty when none do.
    reexported_by: list[str]


def is_skipped(rel: Path) -> bool:
    return any(part in SKIP_PARTS or part.startswith(".worktree") for part in rel.parts)


def module_name(stem: str) -> str:
    return stem[0].upper() + stem[1:]


def all_files(root: Path) -> list[Path]:
    """Every authored file in the tree, whatever its extension.

    Extension allow-lists are the failure mode this audit exists to avoid: an
    earlier ad-hoc version skipped `test/stanzas/*.inc` and reported three
    live, CI-running tests as orphans.
    """
    out: list[Path] = []
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        if is_skipped(path.relative_to(root)):
            continue
        out.append(path)
    return out


def read_text(path: Path) -> str:
    try:
        return path.read_text(errors="replace")
    except OSError:
        return ""


def source_modules(root: Path) -> dict[str, Path]:
    """OCaml module name -> its `.ml` path, for every compilation unit."""
    mods: dict[str, Path] = {}
    for base in SOURCE_ROOTS:
        directory = root / base
        if not directory.is_dir():
            continue
        for path in sorted(directory.rglob("*.ml")):
            if is_skipped(path.relative_to(root)):
                continue
            mods.setdefault(module_name(path.stem), path)
    return mods


def find_dead_modules(root: Path) -> list[DeadModule]:
    mods = source_modules(root)
    names = set(mods)
    own: dict[str, set[Path]] = {}
    for name, ml in mods.items():
        mli = ml.with_suffix(".mli")
        own[name] = {ml, mli} if mli.exists() else {ml}

    referenced: set[str] = set()
    lower_index = {name.lower(): name for name in names}
    for path in all_files(root):
        text = read_text(path)
        if not text:
            continue
        tokens = set(TOKEN_RE.findall(text))
        hits = tokens & names
        # dune stanzas, `.inc` includes, scripts and fixture path literals name
        # modules in their lowercase file-stem form, so match that spelling in
        # every file type -- including `.ml`, where a fixture is loaded by path.
        for token in tokens:
            canonical = lower_index.get(token)
            if canonical is not None:
                hits.add(canonical)
        for name in hits:
            if path in own[name]:
                continue
            referenced.add(name)

    dead: list[DeadModule] = []
    for name in sorted(names - referenced):
        ml = mods[name]
        mli = ml.with_suffix(".mli")
        loc = len(read_text(ml).splitlines())
        if mli.exists():
            loc += len(read_text(mli).splitlines())
        dead.append({
            "module": name,
            "ml": str(ml.relative_to(root)),
            "mli": str(mli.relative_to(root)) if mli.exists() else None,
            "loc": loc,
        })
    return sorted(dead, key=lambda d: -d["loc"])


def find_dead_exports(root: Path, min_name_len: int) -> list[DeadExport]:
    owners: dict[str, list[tuple[str, Path]]] = defaultdict(list)
    for base in SOURCE_ROOTS:
        directory = root / base
        if not directory.is_dir():
            continue
        for mli in sorted(directory.rglob("*.mli")):
            if is_skipped(mli.relative_to(root)):
                continue
            for match in VAL_RE.finditer(read_text(mli)):
                name = match.group(1)
                if len(name) >= min_name_len:
                    owners[name].append((mli.stem, mli))

    wanted = set(owners)
    seen: dict[str, set[Path]] = defaultdict(set)
    for path in all_files(root):
        text = read_text(path)
        if not text:
            continue
        for token in set(TOKEN_RE.findall(text)) & wanted:
            seen[token].add(path)

    republished = reexporting_modules(root)
    dead: list[DeadExport] = []
    for name, declared in owners.items():
        if len(declared) > 1:
            # The same name is exported by several modules; a token scan cannot
            # attribute a reference to one of them.
            continue
        module, mli = declared[0]
        pair = {mli, mli.with_suffix(".ml")}
        if seen.get(name, set()) - pair:
            continue
        dead.append({
            "name": name,
            "module": module,
            "mli": str(mli.relative_to(root)),
            "reexported_by": sorted(republished.get(module, [])),
        })
    return sorted(dead, key=lambda d: (d["module"], d["name"]))


def reexporting_modules(root: Path) -> dict[str, list[str]]:
    """Module -> the modules that republish its whole signature.

    Three shapes republish a module wholesale without ever naming the values
    they carry, so a token scan cannot see them:

        include module type of Foo          (in a .mli)
        module Bar = Foo                    (in a .mli -- a signature alias)
        include Foo                         (in a .ml, when the .mli also
                                             republishes the signature)

    Adversarial review of an earlier run of this audit found every one of its
    28 false positives here: values with no call site anywhere, still exposed
    through a facade's published signature. Deleting one of those means editing
    the facade too, which makes it a different change from deleting a value
    nothing can reach.
    """
    by_source: dict[str, list[str]] = defaultdict(list)
    patterns = (
        re.compile(r"include\s+module\s+type\s+of\s+(?:struct\s+include\s+)?([A-Z][A-Za-z0-9_]*)"),
        re.compile(r"^\s*module\s+[A-Z][A-Za-z0-9_]*\s*=\s*([A-Z][A-Za-z0-9_]*)\s*$", re.M),
        re.compile(r"^\s*include\s+([A-Z][A-Za-z0-9_]*)\s*$", re.M),
    )
    for base in SOURCE_ROOTS:
        directory = root / base
        if not directory.is_dir():
            continue
        for path in sorted(directory.rglob("*.ml*")):
            if path.suffix not in (".ml", ".mli") or is_skipped(path.relative_to(root)):
                continue
            text = read_text(path)
            facade = path.stem
            for pattern in patterns:
                for match in pattern.finditer(text):
                    source = match.group(1)
                    source_module = source[0].lower() + source[1:]
                    if source_module != facade and facade not in by_source[source_module]:
                        by_source[source_module].append(facade)
    return dict(by_source)


def find_orphan_stanzas(root: Path) -> list[str]:
    """`test/stanzas/*.inc` files that `test/dune` never includes.

    Dune ignores them, so they compile nothing and run nothing while still
    reading like a registered test.
    """
    dune = root / "test" / "dune"
    stanzas = root / "test" / "stanzas"
    if not dune.is_file() or not stanzas.is_dir():
        return []
    text = read_text(dune)
    orphans: list[str] = []
    for inc in sorted(stanzas.glob("*.inc")):
        if f"stanzas/{inc.name}" not in text:
            orphans.append(str(inc.relative_to(root)))
    return orphans


def run_self_test() -> int:
    """Guard the two failure modes this audit was written against."""
    import tempfile

    failures: list[str] = []
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "lib").mkdir()
        (root / "test").mkdir()
        (root / "test" / "stanzas").mkdir()

        # A module referenced only from a dune `.inc` stanza is live.
        (root / "test" / "test_included_only.ml").write_text("let () = ()\n")
        (root / "test" / "stanzas" / "t.inc").write_text(
            "(test (name test_included_only) (modules test_included_only))\n"
        )
        # A module referenced from nowhere is dead.
        (root / "lib" / "totally_unreferenced_leaf.ml").write_text("let x = 1\n")

        dead_modules = {d["module"] for d in find_dead_modules(root)}
        if "Test_included_only" in dead_modules:
            failures.append("module registered via .inc stanza reported dead")
        if "Totally_unreferenced_leaf" not in dead_modules:
            failures.append("unreferenced module not reported")

        # Substring must not count as a reference.
        (root / "lib" / "sample_surface.mli").write_text(
            "val cached_entry_count : unit -> int\nval used_entry_helper : unit -> int\n"
        )
        (root / "lib" / "sample_surface.ml").write_text(
            "let cached_entry_count () = 0\nlet used_entry_helper () = 0\n"
        )
        (root / "test" / "test_sample_surface.ml").write_text(
            "let () = ignore (Sample_surface.reset_cached_entry_count ())\n"
            "let () = ignore (Sample_surface.used_entry_helper ())\n"
        )
        dead_exports = {d["name"] for d in find_dead_exports(root, DEFAULT_MIN_NAME_LEN)}
        if "cached_entry_count" not in dead_exports:
            failures.append("substring match counted as a reference")
        if "used_entry_helper" in dead_exports:
            failures.append("token reference from a test not counted")

        # A value republished through a facade's signature must be flagged as
        # such: nothing calls it, but deleting it means editing the facade.
        (root / "lib" / "leaf_surface.mli").write_text("val republished_helper : unit -> int\n")
        (root / "lib" / "leaf_surface.ml").write_text("let republished_helper () = 0\n")
        (root / "lib" / "facade_surface.ml").write_text("include Leaf_surface\n")
        (root / "lib" / "facade_surface.mli").write_text(
            "include module type of Leaf_surface\n"
        )
        entries = {d["name"]: d for d in find_dead_exports(root, DEFAULT_MIN_NAME_LEN)}
        republished = entries.get("republished_helper")
        if republished is None:
            failures.append("value behind a facade not reported at all")
        elif not republished.get("reexported_by"):
            failures.append("facade re-export not recorded on the finding")

    for failure in failures:
        print(f"self-test FAIL: {failure}", file=sys.stderr)
    if failures:
        return 1
    print("self-test OK")
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--modules", action="store_true",
                        help="Report modules nothing outside their own pair references.")
    parser.add_argument("--exports", action="store_true",
                        help="Report .mli `val` exports with no external reference.")
    parser.add_argument("--min-name-len", type=int, default=DEFAULT_MIN_NAME_LEN,
                        help=f"Skip export names shorter than this (default {DEFAULT_MIN_NAME_LEN}).")
    parser.add_argument("--stanzas", action="store_true",
                        help="Report test/stanzas/*.inc files that test/dune never includes.")
    parser.add_argument("--json", action="store_true", help="Emit JSON instead of text.")
    parser.add_argument("--self-test", action="store_true", help="Run the regression guard and exit.")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        return run_self_test()
    if not args.modules and not args.exports and not args.stanzas:
        print("choose --modules, --exports or --stanzas (or --self-test)", file=sys.stderr)
        return 2

    payload: dict[str, object] = {}
    if args.modules:
        dead_modules = find_dead_modules(ROOT)
        payload["dead_modules"] = dead_modules
        if not args.json:
            print(f"dead modules: {len(dead_modules)}")
            for entry in dead_modules:
                print(f"  {entry['loc']:6d} LoC  {entry['module']}  {entry['ml']}")
    if args.exports:
        dead_exports = find_dead_exports(ROOT, args.min_name_len)
        per_module: dict[str, int] = defaultdict(int)
        for entry in dead_exports:
            per_module[entry["module"]] += 1
        payload["dead_exports"] = dead_exports
        behind_facade = [d for d in dead_exports if d.get("reexported_by")]
        if not args.json:
            print(f"dead exports: {len(dead_exports)} "
                  f"across {len(per_module)} modules "
                  f"(names >= {args.min_name_len} chars)")
            print(f"  directly removable: {len(dead_exports) - len(behind_facade)}")
            print(f"  behind a facade re-export (needs the facade edited too): "
                  f"{len(behind_facade)}")
            for module, count in sorted(per_module.items(), key=lambda kv: (-kv[1], kv[0]))[:40]:
                print(f"  {count:4d}  {module}")
    if args.stanzas:
        orphans = find_orphan_stanzas(ROOT)
        payload["orphan_stanzas"] = orphans
        if not args.json:
            print(f"orphan stanza files: {len(orphans)}")
            for orphan in orphans:
                print(f"  {orphan}")
    if args.json:
        print(json.dumps(payload, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
