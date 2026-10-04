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

Step 3 needs warning 32 forced on -- the root `dune` sets `-warn-error +8`, so
it is off by default (see #25455). Give it its own build directory:

    OCAMLPARAM='_,w=+32' DUNE_BUILD_DIR=/tmp/masc-w32 dune build @check

Sharing `_build` with an ordinary build silently defeats this. Dune does not
track `OCAMLPARAM` as a dependency, so after a normal build has populated the
cache the warning-32 run considers every target up to date, compiles nothing,
and exits 0 with no warnings -- a green that looks like a verified slice and
proves nothing. Confirmed by appending a comment to `lib/runtime/runtime.ml`,
which brought `unused value validate_runtime_model_capabilities` straight back
(`touch` does not: dune digests contents, not mtimes).

Matching is on token boundaries, not substrings: `cached_entry_count` is not
considered referenced by a call to `reset_cached_entry_count`. Conversely the
`.inc` and dune stanza files are scanned, so a test module registered only
from `test/stanzas/*.inc` is correctly seen as live.

WHAT THIS TOOL CANNOT DECIDE

Unreachable is not the same as removable, and the difference is a judgement no
scan makes for you. Categories found so far, each from an actual candidate:

  Spec bridges. A module may export an `all_*` symbol list or a
  `*_to_tla_symbol` mapper that nothing in OCaml or `scripts/` reads, on the
  theory that a conformance test enumerates it. Three questions decide whether
  that is a seam or dead weight:

    Does anything actually enumerate it? A consumer -- test, generator,
    codegen step -- makes it a seam, and deleting it removes the check.

    Is the type already pinned by an equality re-export (`type decision_stage
    = Keeper_registry.decision_stage = ...`)? That is what fails the build
    when a constructor is added upstream. A literal list cannot; it goes
    stale in silence, so its existence is not evidence of a seam.

    Does the spec it cites still exist? A `.tla` path in a comment outlives
    the file it points at.

  Answered once already, against the list: `keeper_composite_observer`
  exported `all_tla_actions`, `tla_action_of_string` and six `all_*` lists,
  deleted in #26988. Nothing enumerated them, the re-export was doing the
  work, and the spec file they named was gone.

  Naming today's live examples here is what made this paragraph go stale
  twice. State the test, not the roster.

  Alternative entry points onto a live path. `Audit_log` exported six wrappers
  over `log_action` and a second route into `Dated_jsonl.prune`. "Nothing calls
  the audit logger" reads like an incident; it was not one, because the live
  paths build the same variants directly and prune on a timer. Establish which
  path actually runs before concluding either way.

  Enumeration completeness. `tool_schema_dsl` exports one constructor per JSON
  Schema type; `boolean_prop` and `string_array_prop` have no callers, but they
  are two fifths of a five-value DSL that covers string/integer/boolean/array/
  object. Removing them leaves the enumeration with holes and the next caller
  writing a raw `` `Assoc `` instead.

  Documented entry points. `keeper_event_queue_persistence.mli:98` tells the
  reader to `use {!load_pending_result} in production control flow`. Nothing
  calls it yet; the doc says it is the intended route. `--exports` reports
  these separately via `odoc_referenced`.

  Callback registration. `dashboard.ml:604` wires `generate` into the
  `masc_dashboard` MCP tool through `Tool_misc.register_dashboard_handler`, so
  a grep for `Dashboard.generate` finds only tests and the module looks
  abandoned when it is not. This one is not detected -- check for a
  `register_*` seam before concluding a subsystem is unreachable.

Density does not separate these: `tool_schema_dsl` is 40% dead by count, the
same range as genuinely abandoned modules. Read the surface.

Usage:
    python3 scripts/audit-dead-surface.py --modules
    python3 scripts/audit-dead-surface.py --exports [--min-name-len N]
    python3 scripts/audit-dead-surface.py --exports --json
"""

from __future__ import annotations

import argparse
import json
import os
import functools
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path
from typing import TypedDict

ROOT = Path(__file__).resolve().parent.parent

# Trees that own OCaml compilation units.
SOURCE_ROOTS = ("lib", "bin", "test", "packages")

# Directories that never contain authored source.
#
# `.claude` holds tool state, and `.claude/worktrees` under it holds whole
# copies of this tree. Those copies made every export look referenced by its
# own duplicate: measured 2026-08-20 at the same commit, a checkout carrying
# 14,298 files there reported 21 dead exports where a clean one reported 539.
# `.worktrees` was already listed but does not match this path -- the name is
# `worktrees`, without the leading dot -- so the audit walked 25,507 files
# locally against CI's 9,491 and then advised lowering the baseline by 518.
SKIP_PARTS = frozenset({"_build", "node_modules", ".git", "_opam", ".worktrees", ".claude"})

# Short names collide with unrelated identifiers often enough that a token
# scan says little about them, so `--exports` skips them by default.
DEFAULT_MIN_NAME_LEN = 8

TOKEN_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_']*")
VAL_RE = re.compile(r"^val\s+(?:\(\s*)?([a-z_][A-Za-z0-9_']*)", re.M)
TYPE_RE = re.compile(r"^(?:type|and)\s+(?:[^=\n]*?\s)?([a-z_][A-Za-z0-9_']*)\s*(?:=|:=|$)", re.M)
DERIVING_RE = re.compile(r"\[@@deriving([^\]]*)\]")
# A `[@@deriving p]` on a type that embeds `M.t` makes ppx emit a call to the
# derived function `M` exports for `t`. The caller's name exists only in
# generated code, so a token scan of the sources cannot see it. Each entry maps
# an export shape to the deriving plugins that would generate a call to it.
PPX_DERIVED = (
    (r"^pp_(?P<t>.+)$", ("show",)),
    (r"^show_(?P<t>.+)$", ("show",)),
    (r"^equal_(?P<t>.+)$", ("eq", "equal")),
    (r"^compare_(?P<t>.+)$", ("ord", "compare")),
    (r"^hash_(?P<t>.+)$", ("hash",)),
    (r"^(?P<t>.+)_to_yojson$", ("yojson", "to_yojson")),
    (r"^(?P<t>.+)_of_yojson$", ("yojson", "of_yojson")),
    (r"^sexp_of_(?P<t>.+)$", ("sexp", "sexp_of")),
    (r"^(?P<t>.+)_of_sexp$", ("sexp", "of_sexp")),
)


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
    # An odoc `{!name}` link elsewhere in the same .mli names this value as an
    # intended entry point, so it is documented rather than forgotten.
    odoc_referenced: bool


def is_skipped(rel: Path) -> bool:
    return any(part in SKIP_PARTS or part.startswith(".worktree") for part in rel.parts)


def module_name(stem: str) -> str:
    return stem[0].upper() + stem[1:]


def is_skipped_name(name: str) -> bool:
    """One path component the walk must not descend into or collect.

    `is_skipped` tested every component of a relative path, the filename
    included, so a file whose own name is in SKIP_PARTS was dropped. Pruning
    only directories would quietly widen what the scan reads, so the same
    predicate is applied to filenames too.
    """
    return name in SKIP_PARTS or name.startswith(".worktree")


@functools.lru_cache(maxsize=None)
def tracked_files(root: Path) -> frozenset[Path] | None:
    """Absolute paths git tracks under [root], or [None] when git cannot say.

    `SKIP_PARTS` names the directories that hold copies of this tree, and each
    new place one appears has cost a wrong count before it was added: worktrees
    under `.claude` reported 21 dead exports where a clean checkout reported
    539 (see the note there). The list grows one entry per incident because it
    answers "which directory" when the question is "which files are ours".

    Git already knows. Measured 2026-08-23 at the same commit, a checkout
    holding campaign output under `reports/`, two `task-*/` directories with a
    stray `.ml` in each, and old `git.diff` files reported 13 dead exports
    where a fresh worktree reported 47 -- the names written in that leftover
    output counted as callers.

    A file that is not tracked yet reads as absent, so a caller written in one
    is not seen. That is the same thing CI sees, which is the point.

    [None] rather than an empty set when git is unavailable or [root] is not
    its own work tree: the self-test builds a tree in a temp directory, and
    an empty set there would report every symbol dead.
    """
    def git(*args: str) -> str | None:
        try:
            done = subprocess.run(
                ["git", "-C", str(root), *args],
                capture_output=True,
                text=True,
                timeout=120,
                check=False,
            )
        except (OSError, subprocess.SubprocessError):
            return None
        return done.stdout if done.returncode == 0 else None

    top = git("rev-parse", "--show-toplevel")
    if top is None:
        return None
    if Path(top.strip()).resolve() != root.resolve():
        return None
    listed = git("ls-files", "-z")
    if listed is None:
        return None
    return frozenset(root / name for name in listed.split("\0") if name)


def all_files(root: Path) -> list[Path]:
    """Every authored file in the tree, whatever its extension.

    Extension allow-lists are the failure mode this audit exists to avoid: an
    earlier ad-hoc version skipped `test/stanzas/*.inc` and reported three
    live, CI-running tests as orphans.

    Pruned during the walk, not filtered after it. `Path.rglob` descends into
    every directory and hands back what it found, so `SKIP_PARTS` could only
    discard paths already visited: on a checkout with worktrees under
    `.worktrees/`, each with its own `_build`, that is the whole tree many times
    over. Measured here, 2026-08-07, 192 worktrees present:

        rglob then filter   2,292,279 files and still going at 60s
        prune while walking     24,426 files in 0.4s

    That number is this checkout, not CI: 192 worktrees contribute nearly all of
    it and a fresh clone has none. What pruning is worth in CI is smaller and
    still real -- `.git` and, after a build, `_build` (42,237 files here) were
    both walked and then discarded.
    """
    # This file is excluded. Its own comments name the values it reports --
    # a baseline note saying which exports are held back, a docstring citing
    # the case that motivated a rule -- and the reference scan below is a
    # token scan, so those names read as call sites and the values disappear
    # from the report. That has now happened twice, each time making a rule
    # look like it worked when it had not run. The audit calls no OCaml value,
    # so nothing real is lost by not reading it.
    self_path = Path(__file__).resolve()
    tracked = tracked_files(root)
    out: list[Path] = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [name for name in dirnames if not is_skipped_name(name)]
        directory = Path(dirpath)
        for name in filenames:
            if is_skipped_name(name):
                continue
            path = directory / name
            if tracked is not None and path not in tracked:
                continue
            if path.resolve() == self_path:
                continue
            if path.is_file():
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


def ppx_derived_targets(name: str) -> list[tuple[str, tuple[str, ...]]]:
    """Type name plus the deriving plugins that would generate a call to [name]."""
    out = []
    for pattern, plugins in PPX_DERIVED:
        m = re.match(pattern, name)
        if m:
            out.append((m.group("t"), plugins))
    return out


def module_aliases(text: str, mod: str) -> set[str]:
    """Names [text] can use to reach [mod]: the module itself and its aliases."""
    names = {mod}
    for m in re.finditer(r"^\s*module\s+([A-Z][A-Za-z0-9_']*)\s*=\s*([A-Z][A-Za-z0-9_'.]*)", text, re.M):
        if m.group(2).split(".")[-1] == mod:
            names.add(m.group(1))
    return names


def ppx_reachable(name: str, mod: str, mli_text: str, others: list[tuple[Path, str]]) -> bool:
    """True when a `[@@deriving]` elsewhere would generate a call to [name].

    Deleting such a value breaks the build from a call site that exists only
    after ppx runs, which no source scan can find. Two values in this repo were
    reported dead for exactly that reason and nearly deleted (#34868). Naming
    them here would plant the very token this scan counts, so the evidence is
    the PR, not the identifiers.
    """
    declared = set(TYPE_RE.findall(mli_text))
    for type_name, plugins in ppx_derived_targets(name):
        if type_name not in declared:
            continue
        for _path, text in others:
            if not any(
                any(p in group for p in plugins)
                for group in DERIVING_RE.findall(text)
            ):
                continue
            if any(
                re.search(r"\b" + re.escape(alias) + r"\." + re.escape(type_name) + r"\b", text)
                for alias in module_aliases(text, mod)
            ):
                return True
    return False


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
    texts: list[tuple[Path, str]] = []
    for path in all_files(root):
        text = read_text(path)
        if not text:
            continue
        texts.append((path, text))
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
        others = [(p, t) for p, t in texts if p not in pair]
        if ppx_reachable(name, module_name(module), read_text(mli), others):
            continue
        # An odoc cross-reference from a sibling declaration's doc block --
        # `use {!load_pending_result} in production control flow` -- documents
        # the value as the intended entry point. No call site exists yet, but
        # the pointer is a contract someone wrote on purpose, so deleting it
        # silently breaks the doc it is named from.
        documented = bool(re.search(r"\{!" + re.escape(name) + r"\}", read_text(mli)))
        dead.append({
            "name": name,
            "module": module,
            "mli": str(mli.relative_to(root)),
            "reexported_by": sorted(republished.get(module, [])),
            "odoc_referenced": documented,
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
    # `\s` spans newlines, so the multi-line `include module type of struct
    # include X end` form (51 occurrences in this tree) matches as written.
    #
    # A `module X = Y` alias only republishes a signature when it is in a
    # `.mli`; in a `.ml` it is a local shorthand and republishes nothing.
    # Matching it everywhere flagged 702 aliases instead of the 55 real ones --
    # `bin/main_eio.ml:35`'s `module Types = Masc_domain` claimed to be a facade
    # over Masc_domain. `include X`, by contrast, is a `.ml` construct: it
    # republishes when the module's own `.mli` also exposes the signature.
    patterns = (
        (re.compile(r"include\s+module\s+type\s+of\s+(?:struct\s+include\s+)?([A-Z][A-Za-z0-9_]*)"),
         (".ml", ".mli")),
        (re.compile(r"^\s*module\s+[A-Z][A-Za-z0-9_]*\s*=\s*([A-Z][A-Za-z0-9_]*)\s*$", re.M),
         (".mli",)),
        (re.compile(r"^\s*include\s+([A-Z][A-Za-z0-9_]*)\s*$", re.M),
         (".ml",)),
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
            for pattern, suffixes in patterns:
                if path.suffix not in suffixes:
                    continue
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
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if not args.modules and not args.exports and not args.stanzas:
        print("choose --modules, --exports or --stanzas", file=sys.stderr)
        return 2

    payload: dict[str, object] = {}
    dead_export_count: int | None = None
    # Say which files were searched for callers. The same commit answers 13 or
    # 47 depending on what is lying around untracked, and both used to print
    # the same line.
    scanned = "git-tracked files" if tracked_files(ROOT) is not None else (
        "every file in the tree (git could not say what is tracked)")
    payload["reference_scope"] = scanned
    if not args.json and (args.modules or args.exports):
        print(f"callers searched in: {scanned}")
    if args.modules:
        dead_modules = find_dead_modules(ROOT)
        payload["dead_modules"] = dead_modules
        if not args.json:
            print(f"dead modules: {len(dead_modules)}")
            for entry in dead_modules:
                print(f"  {entry['loc']:6d} LoC  {entry['module']}  {entry['ml']}")
    if args.exports:
        dead_exports = find_dead_exports(ROOT, args.min_name_len)
        dead_export_count = len(dead_exports)
        per_module: dict[str, int] = defaultdict(int)
        for entry in dead_exports:
            per_module[entry["module"]] += 1
        payload["dead_exports"] = dead_exports
        behind_facade = [d for d in dead_exports if d.get("reexported_by")]
        documented = [d for d in dead_exports
                      if d.get("odoc_referenced") and not d.get("reexported_by")]
        if not args.json:
            print(f"dead exports: {len(dead_exports)} "
                  f"across {len(per_module)} modules "
                  f"(names >= {args.min_name_len} chars)")
            print(f"  directly removable: "
                  f"{len(dead_exports) - len(behind_facade) - len(documented)}")
            print(f"  behind a facade re-export (needs the facade edited too): "
                  f"{len(behind_facade)}")
            print(f"  named by an odoc link as an intended entry point: "
                  f"{len(documented)}")
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
