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
    python3 scripts/audit-dead-surface.py --self-test
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
        # A plain leaf with no facade over it must come back with an empty
        # `reexported_by`, or the two groups stop meaning anything.
        (root / "lib" / "plain_surface.mli").write_text("val unfacaded_helper : unit -> int\n")
        (root / "lib" / "plain_surface.ml").write_text("let unfacaded_helper () = 0\n")

        # The multi-line `include module type of struct include X end` form,
        # 51 occurrences in this tree, must match as well as the one-line form.
        (root / "lib" / "wrapped_surface.mli").write_text("val wrapped_helper : unit -> int\n")
        (root / "lib" / "wrapped_surface.ml").write_text("let wrapped_helper () = 0\n")
        (root / "lib" / "multiline_facade.ml").write_text("include Wrapped_surface\n")
        (root / "lib" / "multiline_facade.mli").write_text(
            "include module type of struct\n  include Wrapped_surface\nend\n"
        )

        # A `module X = Y` alias in a .ml is a local shorthand, not a facade.
        (root / "lib" / "aliasing_consumer.ml").write_text(
            "module Alias = Plain_surface\nlet _ = 0\n"
        )

        # Skipped trees are pruned during the walk, and pruning must not change
        # what the scan sees. Both halves are asserted below: a reference parked
        # inside a skipped tree must not keep a value alive, and the pruning
        # must not swallow the sibling directories it walks past.
        stale = root / ".worktrees" / "old-checkout" / "lib"
        stale.mkdir(parents=True)
        (stale / "stale_consumer.ml").write_text("let _ = Plain_surface.unfacaded_helper ()\n")
        build = root / "lib" / "_build" / "default"
        build.mkdir(parents=True)
        (build / "generated_consumer.ml").write_text(
            "let _ = Wrapped_surface.wrapped_helper ()\n"
        )

        entries = {d["name"]: d for d in find_dead_exports(root, DEFAULT_MIN_NAME_LEN)}
        republished = entries.get("republished_helper")
        if republished is None:
            failures.append("value behind a facade not reported at all")
        elif not republished.get("reexported_by"):
            failures.append("facade re-export not recorded on the finding")

        plain = entries.get("unfacaded_helper")
        if plain is None:
            failures.append("plain dead export not reported")
        elif plain.get("reexported_by"):
            failures.append("a .ml module alias was mistaken for a facade")

        wrapped = entries.get("wrapped_helper")
        if wrapped is None:
            failures.append("value behind a multi-line facade not reported")
        elif not wrapped.get("reexported_by"):
            failures.append("multi-line include module type of not matched")

        # Both of these were still reported above: a call sitting in
        # .worktrees/ or _build/ is not a reference. They are asserted here so
        # that a walk which stops pruning fails loudly instead of quietly
        # shrinking the report -- the direction that hides dead surface.
        if "unfacaded_helper" not in entries:
            failures.append("a reference under .worktrees/ was counted as live")
        if "wrapped_helper" not in entries:
            failures.append("a reference under _build/ was counted as live")

        (root / "lib" / "_build").parent.joinpath("_opam").write_text("not a directory\n")

        walked = {path.name for path in all_files(root)}
        if "_opam" in walked:
            failures.append("a file whose own name is skipped was collected")
        if "stale_consumer.ml" in walked:
            failures.append(".worktrees/ was walked instead of pruned")
        if "generated_consumer.ml" in walked:
            failures.append("_build/ was walked instead of pruned")
        if "plain_surface.ml" not in walked:
            failures.append("pruning removed a sibling it should have walked")

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
    parser.add_argument("--ratchet", action="store_true",
                        help="With --exports, fail when the count exceeds DEAD_EXPORT_BASELINE.")
    parser.add_argument("--json", action="store_true", help="Emit JSON instead of text.")
    parser.add_argument("--self-test", action="store_true", help="Run the regression guard and exit.")
    return parser.parse_args(argv)


# Exact current count. The audit's documented categories explain why every
# reported entry is not mechanically removable; the ratchet still forbids
# adding another dead public export.
#
# Lowered from 548 to 545 on 2026-08-14 (#28656): three
# keeper_official_client_host hook helpers (hook_error,
# illegal_hook_decision, invoke_turn_hook) lost their last external callers
# when the three runtime modules were consolidated onto
# invoke_turn_completion_hooks, and keeper_tool_descriptor.composable_output_to_json
# / keeper_tool_plan.output_value never had one. All three .mli exports
# were dropped (implementations kept where still used internally,
# output_value's implementation removed as unused).
# 545 -> 541: tightened to the measured count. The four counts of slack
# predate the Keeper_compact_audit purge (main already measured 541 against
# the stale 545 baseline); the purge itself did not change the count.
# 540 -> 539: tightened to the measured count on the RFC-0387 stage-1 tree
# (measured 2026-08-20: 539). The one count of slack predates this change;
# goal_verification's exports all have callers (dashboard joins + tests), so
# the ledger added none.
# 536 -> 532: tightened to the measured count (measured 2026-08-22: 532
# before and after this change). The four counts of slack predate it; the
# change itself is count-neutral because the four exports it orphaned
# (audit_log.entry_of_json_r, common.keeper_runtime_store_dirname,
# workspace_utils_paths_backend tasks_dirname / backlog_filename) were
# dropped from their .mli in the same PR, implementations kept where still
# used internally.
# 532 -> 529: the #29396 A22 purge deleted three exports this audit already
# listed (keeper_memory_recall.recent_lines_or_record,
# runtime_observation.model_label_of_config, session.add_mcp_session_header)
# and orphaned nothing. 529 -> 528: measured on the merge with main after
# #29515 (2026-08-22).
# 528 -> 526: measured on the merge with main (PR #29539, 2026-08-22).
# 526 -> 522: the agent JSON repair path (#29396 A15) removed four more
# exports (normalize_agent_last_seen, short_json_repr,
# agent_json_needs_repair, read_agent_with_repair_result).
# 522 -> 521: dropping the Mcp_server JSON-RPC aliases removed one more
# export (mcp_server.jsonrpc_request_to_yojson).
# 521 -> 519: dropping server_routes_http_common.state_switch_opt and
# state_clock_opt removed two more dead exports.
# 519 -> 55: swept every export the audit could reach. The facades here mirror
# their sub-modules with `include module type of` and never re-declare what
# they forward, so dropping the declaration at the owning module narrowed the
# facade with it and no facade needed editing. Declarations went first; the
# compiler then reported the orphaned implementations, and each round exposed
# more, so the count fell further than the declarations removed. Held back:
# twelve names carrying the spec-bridge shape this file warns about above.
# Those need the three questions answered one at a time, not a scan. What
# remains is those twelve plus the entries an odoc link names as an intended
# entry point.
#
# Do not name the survivors here. A first draft of this note listed three of
# them, and the token scan read its own comment as a caller: the gate counted
# three fewer than the tree held. State the test, not the roster -- as the
# paragraph above already says.
# 43 -> 45, measured on 2026-08-27 after the skills-proof merge train. The
# train and the same-day merges around it left the tree five over the old
# floor; this change purges every export the skills audit could justify on
# its own authority and re-measures the floor at what the tree now holds.
# The remainder predates the train and sits outside the skills surface, so
# it waits for its own reviewed purge rather than a blind sweep here.
# 1 -> 0, measured on 2026-08-30: the MCP 2026-07-28 conformance pass removed
# the mime-derived resource icon palette, which held the last one.
DEAD_EXPORT_BASELINE = 0


def run_ratchet(count: int) -> int:
    """Compare the dead-export count against the frozen baseline.

    Below the baseline passes and says by how much, rather than failing until
    someone edits the number. The other direction is wrong for a measured
    reason: failing on your own improvement turned main red three times in an
    hour while people were wiring suites.
    """
    if count > DEAD_EXPORT_BASELINE:
        print(
            f"[dead-surface] FAIL - {count} dead exports, over the "
            f"{DEAD_EXPORT_BASELINE} baseline by {count - DEAD_EXPORT_BASELINE}.\n"
            "\n"
            "An export with no caller anywhere in the tree is usually a surface\n"
            "someone meant to wire and did not. Remove it, wire it, or raise\n"
            f"DEAD_EXPORT_BASELINE in {Path(__file__).name} with the reason.",
            file=sys.stderr,
        )
        return 1
    if count < DEAD_EXPORT_BASELINE:
        print(
            f"[dead-surface] OK - {count} dead exports, {DEAD_EXPORT_BASELINE} "
            f"baseline - lower DEAD_EXPORT_BASELINE to hold the "
            f"{DEAD_EXPORT_BASELINE - count} you removed"
        )
        return 0
    print(f"[dead-surface] OK - {count} dead exports, at baseline")
    return 0


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        return run_self_test()
    if not args.modules and not args.exports and not args.stanzas:
        print("choose --modules, --exports or --stanzas (or --self-test)", file=sys.stderr)
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
    if args.ratchet:
        if dead_export_count is None:
            print("--ratchet needs --exports", file=sys.stderr)
            return 2
        return run_ratchet(dead_export_count)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
