#!/usr/bin/env python3
"""audit-sublib-cycle.py - dune-graph leaf boundary gate (RFC-0056 G1).

Purpose
-------
Verify that designated *leaf* / domain sub-libraries do NOT depend
(transitively) on the mega-library ``masc``. A leaf that pulls the
mega-lib back into its ``requires`` closure is a boundary violation: either
the extraction never actually severed the coupling, or a later change
re-coupled it.

This reads dune's OWN dependency graph via ``dune describe`` - the declared
``(requires ...)`` edges between libraries, keyed by UID - not source text.
It is therefore structural, not a grep/substring classifier (cf. CLAUDE.md
workaround bar): the violation signal is the mega-lib's UID appearing in a
leaf's transitive requires closure, which the OCaml compiler itself computed.

Why this gate exists
--------------------
The flat ``masc`` library ((wrapped false) + (include_subdirs unqualified))
disables OCaml's acyclic-library DAG guarantee for ~2.6k modules. Extracting a
domain into its own library (e.g. ``masc_goal``) restores that guarantee - but
only as long as nobody adds the mega-lib to the leaf's ``(libraries ...)``.
This script turns that regression into a CI failure instead of a silent
re-coupling, and gates every future extraction the same way.

Relationship to existing tooling (complementary, not duplicate)
---------------------------------------------------------------
- ``scripts/analyze_lib_deps.py`` works at the *module* level inside the flat
  namespace (regex over ``.ml``, SCC cycle finder, leaf count) to *prioritize
  which directory to extract next* (RFC-0056 sec 3.4). Pre-extraction analysis.
- ``scripts/lib_dep_report.py`` summarizes extraction *progress* (before/after).
- This script works at the *library* level via ``dune describe`` UID edges to
  *enforce that an already-extracted leaf stays severed* (RFC-0056 G1). It is
  the post-extraction regression gate the other two do not provide.

Usage
-----
  audit-sublib-cycle.py [--root DIR] [--describe-file FILE] [--leaf LIB]...
  audit-sublib-cycle.py --describe-file FILE \
    --closed-source-root packages/agent_core \
    --required-local-library masc.agent_core
  audit-sublib-cycle.py --self-test     # clean + buggy fixture dual-check

Exit codes: 0 = all leaves clean, 1 = boundary violation, 2 = usage/parse error.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from collections import deque
from dataclasses import dataclass
from pathlib import PurePosixPath
from typing import Union

MEGA_LIB = "masc"

# Leaf / domain libraries that MUST NOT depend on the mega-library.
# Extend as each domain is extracted (RFC-0056 / boundary campaign).
DEFAULT_LEAVES: tuple[str, ...] = (
    "masc.masc_goal",
    # RFC-0056 Phase 1L: Attribution envelope and phantom-tagged wrappers.
    "masc.attribution",
    # RFC-0056 Phase 1M: Shell IR execution policy and typed path errors.
    "masc.exec_policy",
    # RFC-0056 Phase 1N: Keeper deterministic lifecycle FSM cluster.
    "masc.keeper_registry",
    "masc.keeper_contract",
    "masc.keeper_runtime",
    "masc.keeper_tooling",
    # Model inference aggregate domain and its runtime label boundary.
    "masc.runtime_provider_labels",
    "masc.runtime_model",
    "masc.model_inference_metrics",
    # Shared helper leaves carved out of lib/ subdirectories that were still
    # owned by the unqualified mega-library include.
    "masc.lockfree_atomic",
    "masc.json_field",
    "masc.pool_metrics",
    "masc.otel_spans",
    "masc.otel_genai",
    "masc.otel_trace_context",
    "masc.otel_dispatch_hook",
    "masc.telemetry_coverage_gap",
    "masc.telemetry_unified_source",
    "masc.telemetry_unified",
    # Board MCP adapter: depends on board domain + neutral tool substrate;
    # neither side should depend back on the adapter.
    "masc.board_tool_adapter",
    "masc.voice_config",
    "masc.voice_runtime_overlay",
    "masc.voice_bridge_core",
    "masc.discovery_cache",
    "masc.local_runtime_pool",
    # Keeper-owned pure/type leaves extracted from lib/keeper/.
    "masc.keeper_accountability_claim_types",
    "masc.keeper_runtime_manifest_types",
    "masc.keeper_registry_types_kill_class",
    "masc.keeper_registry_types_turn_phase",
    "masc.keeper_registry_types_decision",
    "masc.keeper_hooks_agent_core_types",
    "masc.keeper_binding_health_config",
    "masc.keeper_transition_audit_types",
    "masc.keeper_path_rejection",
    "masc.keeper_approval_queue_rules_types",
    "masc.keeper_toml_parser",
    "masc.keeper_toml_loader",
    "masc.keeper_runtime_config",
    "masc.keeper_tool_name",
    "masc.keeper_id",
    "masc.keeper_terminal_reason",
    "masc.keeper_timing",
    "masc.keeper_sandbox_error",
    "masc.keeper_provider_error_class",
    "masc.keeper_failure_taxonomy",
    "masc.keeper_world_observation_turn_types",
    "masc.keeper_memory_taxonomy",
    "masc.keeper_outcome_taxonomy",
    "masc.keeper_metrics",
    "masc.keeper_types",
    "masc.keeper_types_profile_sandbox",
    "masc.keeper_pressure",
    "masc.keeper_lifecycle_events",
    "masc.keeper_usage_trust",
    "masc.keeper_measurement",
    "masc.prompt_names",
    # [masc.keeper_event_bus] and [masc.masc_event_bus] were merged into this
    # single library. The name must be updated here, not just dropped: [check]
    # silently [continue]s past a leaf that is absent from the dune graph, so a
    # stale entry does not fail — it makes the RFC-0056 G1 backsliding gate
    # no-op for that leaf family without any signal.
    "masc.event_bus_slots",
    "masc.keeper_synthetic_marker",
    "masc.keeper_agent_core_timeout_message",
    "masc.keeper_tool_response",
    "masc.keeper_discovered_tools",
    "masc.keeper_tool_execute_timeout",
    "masc.keeper_tool_execute_shell_ir",
    "masc.keeper_workspace_op",
    "masc.keeper_attempt_liveness",
    # PR-S3 (LANE 2): Tool dispatch substrate. The gate enforces that the
    # Tool layer cannot pull keeper/runtime/telemetry back in via the mega-lib.
    "masc.masc_tool_dispatch",
    # RFC-0056 Phase 2 (LANE 6): Pure tool surface leaf (schema/vocab/policy/
    # shard-type) extracted above the dispatch substrate. The gate enforces that
    # this layer cannot pull keeper/runtime/goal/task/board/server back in.
    "masc.masc_tool_surface",
)

# Recursive s-expression value: an atom (str) or a list of values.
Sexp = Union[str, "list[Sexp]"]


@dataclass(frozen=True)
class Library:
    """A dune library node distilled to the boundary-relevant fields."""

    name: str
    uid: str
    local: bool
    requires: tuple[str, ...]
    source_dir: str


@dataclass(frozen=True)
class Violation:
    leaf: str
    path: tuple[str, ...]  # human-readable lib names: leaf -> ... -> mega


@dataclass(frozen=True)
class SourceRootViolation:
    library: str
    source_dir: str


# --- minimal s-expression parser (atoms + lists; no external deps) -----------


def tokenize(text: str) -> list[str]:
    tokens: list[str] = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c in "()":
            tokens.append(c)
            i += 1
        elif c.isspace():
            i += 1
        elif c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            tokens.append(text[i : j + 1])
            i = j + 1
        else:
            j = i
            while j < n and not text[j].isspace() and text[j] not in "()":
                j += 1
            tokens.append(text[i:j])
            i = j
    return tokens


def parse(tokens: list[str]) -> list[Sexp]:
    pos = 0

    def walk() -> Sexp:
        nonlocal pos
        tok = tokens[pos]
        if tok == "(":
            pos += 1
            node: list[Sexp] = []
            while pos < len(tokens) and tokens[pos] != ")":
                node.append(walk())
            if pos >= len(tokens):
                raise ValueError("unbalanced s-expression: missing ')'")
            pos += 1  # consume ')'
            return node
        if tok == ")":
            raise ValueError("unbalanced s-expression: unexpected ')'")
        pos += 1
        return tok

    items: list[Sexp] = []
    while pos < len(tokens):
        items.append(walk())
    return items


def _required_field(record: "list[Sexp]", key: str) -> Sexp:
    matches = [
        child
        for child in record
        if isinstance(child, list) and child and child[0] == key
    ]
    if len(matches) != 1 or len(matches[0]) != 2:
        raise ValueError(
            f"library record requires exactly one single-valued {key!r} field"
        )
    return matches[0][1]


def find_libraries(sexp: Sexp) -> list[Library]:
    """Walk the Dune 0.1 describe tree and decode library variants strictly."""
    libs: list[Library] = []

    def visit(node: Sexp) -> None:
        if not isinstance(node, list):
            return
        if node and node[0] == "library":
            if len(node) != 2 or not isinstance(node[1], list):
                raise ValueError("malformed library variant in describe output")
            record = node[1]
            name = _required_field(record, "name")
            uid = _required_field(record, "uid")
            local = _required_field(record, "local")
            requires = _required_field(record, "requires")
            source_dir = _required_field(record, "source_dir")
            if not isinstance(name, str) or not isinstance(uid, str):
                raise ValueError("library name and uid must be atoms")
            if not isinstance(local, str) or local not in ("true", "false"):
                raise ValueError(f"library {name!r} has malformed local field")
            if not isinstance(requires, list) or not all(
                isinstance(dependency_uid, str) for dependency_uid in requires
            ):
                raise ValueError(f"library {name!r} has malformed requires field")
            if not isinstance(source_dir, str):
                raise ValueError(f"library {name!r} has malformed source_dir field")
            libs.append(
                Library(
                    name=name,
                    uid=uid,
                    local=local == "true",
                    requires=tuple(requires),
                    source_dir=source_dir,
                )
            )
        for ch in node:
            visit(ch)

    visit(sexp)
    seen_uids: dict[str, Library] = {}
    for lib in libs:
        previous = seen_uids.get(lib.uid)
        if previous is not None:
            raise ValueError(
                f"duplicate library uid {lib.uid!r}: {previous.name!r} and {lib.name!r}"
            )
        seen_uids[lib.uid] = lib
    return libs


def find_build_context(sexp: Sexp) -> str:
    contexts: list[str] = []

    def visit(node: Sexp) -> None:
        if not isinstance(node, list):
            return
        if len(node) == 2 and node[0] == "build_context" and isinstance(node[1], str):
            contexts.append(node[1])
        for child in node:
            visit(child)

    visit(sexp)
    unique = sorted(set(contexts))
    if len(unique) != 1:
        raise ValueError(
            f"expected exactly one build_context, found {len(unique)}: {unique}"
        )
    return unique[0]


# --- core boundary check (pure; operates on a list of Library) ---------------


def check(
    libs: list[Library], leaves: tuple[str, ...], mega: str = MEGA_LIB
) -> list[Violation]:
    """Return a Violation for each leaf whose transitive requires reach mega.

    Pure over its inputs so the self-test can feed synthetic graphs.
    """
    by_uid: dict[str, Library] = {lib.uid: lib for lib in libs}
    by_name: dict[str, Library] = {lib.name: lib for lib in libs}

    mega_lib = by_name.get(mega)
    if mega_lib is None:
        # No mega-lib in the graph at all -> nothing to violate.
        return []
    mega_uid = mega_lib.uid

    violations: list[Violation] = []
    for leaf_name in leaves:
        leaf = by_name.get(leaf_name)
        if leaf is None:
            # Leaf not present in this graph (e.g. not extracted yet) - skip,
            # not a violation. Presence is asserted separately if desired.
            continue
        path = _path_to(leaf.uid, mega_uid, by_uid)
        if path is not None:
            names = tuple(by_uid[u].name if u in by_uid else u for u in path)
            violations.append(Violation(leaf=leaf_name, path=names))
    return violations


def _path_to(start: str, target: str, by_uid: dict[str, Library]) -> "list[str] | None":
    """BFS shortest dependency path of UIDs from start to target, or None."""
    if start == target:
        return [start]
    parent: dict[str, str] = {start: start}
    q: deque[str] = deque([start])
    while q:
        u = q.popleft()
        lib = by_uid.get(u)
        if lib is None:
            continue
        for dep in lib.requires:
            if dep in parent:
                continue
            parent[dep] = u
            if dep == target:
                # reconstruct
                path = [dep]
                while path[-1] != start:
                    path.append(parent[path[-1]])
                path.reverse()
                return path
            q.append(dep)
    return None


def validate_graph(libs: list[Library]) -> None:
    """Fail closed when describe output is not a complete UID graph."""
    by_uid = {lib.uid: lib for lib in libs}
    dangling = sorted(
        (lib.name, uid) for lib in libs for uid in lib.requires if uid not in by_uid
    )
    if dangling:
        rendered = ", ".join(f"{name} -> {uid}" for name, uid in dangling[:8])
        suffix = " ..." if len(dangling) > 8 else ""
        raise ValueError(
            f"describe graph has dangling requires UIDs: {rendered}{suffix}"
        )


def _source_root_path(value: str) -> PurePosixPath:
    path = PurePosixPath(value)
    if path.is_absolute() or not path.parts or ".." in path.parts:
        raise ValueError(
            f"closed source root must be a normalized relative path: {value!r}"
        )
    return path


def _local_source_relative(lib: Library, build_context: str) -> PurePosixPath:
    if not lib.local:
        raise ValueError(f"cannot classify external library {lib.name!r} as local")
    source = PurePosixPath(lib.source_dir)
    context = PurePosixPath(build_context)
    try:
        relative = source.relative_to(context)
    except ValueError as exc:
        raise ValueError(
            f"local library {lib.name!r} source_dir {lib.source_dir!r} "
            f"is outside build_context {build_context!r}"
        ) from exc
    if ".." in relative.parts:
        raise ValueError(
            f"local library {lib.name!r} has non-normal source_dir {lib.source_dir!r}"
        )
    return relative


def check_closed_source_root(
    libs: list[Library],
    *,
    build_context: str,
    source_root: str,
    required_local_library: "str | None" = None,
) -> list[SourceRootViolation]:
    """Reject local libraries outside a directory-restricted describe graph.

    The caller must capture ``dune describe workspace SOURCE_ROOT``. Dune then
    emits the libraries declared below SOURCE_ROOT plus their resolved
    dependency closure. External libraries are represented explicitly as
    ``local false`` and remain allowed; any ``local true`` node owned elsewhere
    in the workspace is a reverse dependency across the package boundary.
    """
    root = _source_root_path(source_root)
    local_libs = [lib for lib in libs if lib.local]
    if not local_libs:
        raise ValueError("closed source-root graph contains no local libraries")

    relative_by_uid = {
        lib.uid: _local_source_relative(lib, build_context) for lib in local_libs
    }

    if required_local_library is not None:
        anchors = [lib for lib in local_libs if lib.name == required_local_library]
        if len(anchors) != 1:
            raise ValueError(
                f"required local library {required_local_library!r} must appear "
                f"exactly once, found {len(anchors)}"
            )
        anchor_path = relative_by_uid[anchors[0].uid]
        if anchor_path != root and root not in anchor_path.parents:
            raise ValueError(
                f"required local library {required_local_library!r} is owned by "
                f"{anchors[0].source_dir!r}, not {source_root!r}"
            )

    violations: list[SourceRootViolation] = []
    for lib in local_libs:
        relative = relative_by_uid[lib.uid]
        if relative != root and root not in relative.parents:
            violations.append(
                SourceRootViolation(library=lib.name, source_dir=lib.source_dir)
            )
    return sorted(violations, key=lambda item: (item.library, item.source_dir))


# --- describe acquisition ----------------------------------------------------


def load_describe(
    root: str,
    describe_file: "str | None",
    closed_source_root: "str | None" = None,
) -> Sexp:
    if describe_file is not None:
        text = open(describe_file, encoding="utf-8").read()
    else:
        command = [
            "dune",
            "describe",
            "workspace",
            "--root",
            root,
            "--format",
            "sexp",
            "--lang",
            "0.1",
        ]
        if closed_source_root is not None:
            command.extend(["--with-pps", closed_source_root])
        proc = subprocess.run(
            command,
            capture_output=True,
            text=True,
            check=False,
        )
        if proc.returncode != 0:
            raise RuntimeError(
                f"`dune describe` failed (rc={proc.returncode}):\n{proc.stderr.strip()}"
            )
        text = proc.stdout
    parsed = parse(tokenize(text))
    # describe emits a single top-level sexp; unwrap if wrapped in a 1-list.
    return parsed[0] if len(parsed) == 1 else parsed


# --- self-test (clean + buggy fixture dual-check) ----------------------------


def self_test() -> int:
    """RFC-0001 / TLA bug-model homolog: a gate is only valid if it PASSES on a
    clean graph AND FAILS on a graph with the bug injected. Both must hold."""

    described = parse(
        tokenize(
            """(
              (root /WORKSPACE_ROOT)
              (build_context _build/default)
              (executables
                ((names (probe))
                 (requires (AGENT_CORE))
                 (modules ())
                 (include_dirs ())))
              (library
                ((name masc.agent_core)
                 (uid AGENT_CORE)
                 (local true)
                 (requires (YOJSON))
                 (source_dir _build/default/packages/agent_core/lib)
                 (modules ())
                 (include_dirs ())))
              (library
                ((name yojson)
                 (uid YOJSON)
                 (local false)
                 (requires ())
                 (source_dir /FINDLIB/yojson)
                 (modules ())
                 (include_dirs ()))))
            """
        )
    )
    described = described[0] if len(described) == 1 else described
    decoded = find_libraries(described)
    if [lib.name for lib in decoded] != ["masc.agent_core", "yojson"]:
        print(
            f"SELF-TEST FAIL: describe schema decoded unexpected libraries: {decoded}"
        )
        return 1
    if find_build_context(described) != "_build/default":
        print("SELF-TEST FAIL: describe schema decoded unexpected build context")
        return 1
    validate_graph(decoded)
    print("self-test: Dune 0.1 describe schema decodes strictly (PASS)")

    def local(
        name: str, uid: str, requires: tuple[str, ...], source_dir: str
    ) -> Library:
        return Library(
            name=name,
            uid=uid,
            local=True,
            requires=requires,
            source_dir=source_dir,
        )

    def external(name: str, uid: str, requires: tuple[str, ...] = ()) -> Library:
        return Library(
            name=name,
            uid=uid,
            local=False,
            requires=requires,
            source_dir=f"/FINDLIB/{name}",
        )

    mega = local("masc", "MEGA", ("LEAF", "OTHER"), "_build/default/lib")
    neutral = local("masc_core", "CORE", (), "_build/default/lib/core")
    other = external("other", "OTHER")
    # clean: leaf depends only on neutral; mega depends on leaf (allowed direction)
    clean_leaf = local("masc.masc_goal", "LEAF", ("CORE",), "_build/default/lib/goal")
    clean = [mega, neutral, clean_leaf, other]
    # buggy: leaf re-couples to the mega-lib (direct)
    buggy_leaf = local(
        "masc.masc_goal", "LEAF", ("CORE", "MEGA"), "_build/default/lib/goal"
    )
    buggy = [mega, neutral, buggy_leaf, other]
    # buggy-transitive: leaf -> mid -> mega
    mid = local("masc.mid", "MID", ("MEGA",), "_build/default/lib/mid")
    trans_leaf = local("masc.masc_goal", "LEAF", ("MID",), "_build/default/lib/goal")
    buggy_trans = [mega, neutral, mid, trans_leaf, other]

    leaves = ("masc.masc_goal",)
    ok = True

    validate_graph(clean)
    validate_graph(buggy)
    validate_graph(buggy_trans)

    v_clean = check(clean, leaves)
    if v_clean:
        ok = False
        print(f"SELF-TEST FAIL: clean graph reported violation {v_clean}")
    else:
        print("self-test: clean graph -> no violation (PASS)")

    v_buggy = check(buggy, leaves)
    if not v_buggy:
        ok = False
        print("SELF-TEST FAIL: buggy graph (direct) reported NO violation")
    else:
        print(f"self-test: buggy graph (direct) -> violation {v_buggy[0].path} (PASS)")

    v_trans = check(buggy_trans, leaves)
    if not v_trans:
        ok = False
        print("SELF-TEST FAIL: buggy graph (transitive) reported NO violation")
    else:
        print(
            f"self-test: buggy graph (transitive) -> violation {v_trans[0].path} (PASS)"
        )

    build_context = "_build/default"
    source_root = "packages/agent_core"
    agent_core = local(
        "masc.agent_core",
        "AGENT_CORE",
        ("AGENT_STRINGS", "YOJSON"),
        "_build/default/packages/agent_core/lib",
    )
    agent_strings = local(
        "masc.agent_core.strings",
        "AGENT_STRINGS",
        (),
        "_build/default/packages/agent_core/lib/strings",
    )
    yojson = external("yojson", "YOJSON")
    closed_clean = [agent_core, agent_strings, yojson]
    validate_graph(closed_clean)
    v_closed_clean = check_closed_source_root(
        closed_clean,
        build_context=build_context,
        source_root=source_root,
        required_local_library="masc.agent_core",
    )
    if v_closed_clean:
        ok = False
        print(
            f"SELF-TEST FAIL: clean closed source-root graph reported {v_closed_clean}"
        )
    else:
        print("self-test: closed source root with external deps -> clean (PASS)")

    coordinator = local(
        "masc.keeper_runtime",
        "KEEPER",
        (),
        "_build/default/lib/keeper_runtime",
    )
    closed_buggy = [
        Library(
            name=agent_core.name,
            uid=agent_core.uid,
            local=agent_core.local,
            requires=("AGENT_STRINGS", "KEEPER"),
            source_dir=agent_core.source_dir,
        ),
        agent_strings,
        coordinator,
    ]
    validate_graph(closed_buggy)
    v_closed_buggy = check_closed_source_root(
        closed_buggy,
        build_context=build_context,
        source_root=source_root,
        required_local_library="masc.agent_core",
    )
    if len(v_closed_buggy) != 1 or v_closed_buggy[0].library != coordinator.name:
        ok = False
        print(
            "SELF-TEST FAIL: closed source-root graph did not reject local "
            f"coordinator dependency: {v_closed_buggy}"
        )
    else:
        print("self-test: closed source root rejects local coordinator dep (PASS)")

    try:
        check_closed_source_root(
            [agent_strings, yojson],
            build_context=build_context,
            source_root=source_root,
            required_local_library="masc.agent_core",
        )
    except ValueError:
        print("self-test: missing required local library fails closed (PASS)")
    else:
        ok = False
        print("SELF-TEST FAIL: missing required local library was accepted")

    try:
        validate_graph(
            [
                Library(
                    name=agent_core.name,
                    uid=agent_core.uid,
                    local=agent_core.local,
                    requires=("MISSING",),
                    source_dir=agent_core.source_dir,
                )
            ]
        )
    except ValueError:
        print("self-test: dangling UID fails closed (PASS)")
    else:
        ok = False
        print("SELF-TEST FAIL: dangling UID was accepted")

    print("SELF-TEST: ALL PASS" if ok else "SELF-TEST: FAILED")
    return 0 if ok else 1


# --- cli ---------------------------------------------------------------------


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--root", default=".", help="dune project root (default: .)")
    ap.add_argument(
        "--describe-file",
        default=None,
        help="read a captured `dune describe` sexp instead of invoking dune",
    )
    ap.add_argument(
        "--leaf",
        action="append",
        default=[],
        metavar="LIB",
        help="leaf library that must not depend on the mega-lib (repeatable; adds to defaults)",
    )
    ap.add_argument(
        "--closed-source-root",
        default=None,
        metavar="DIR",
        help=(
            "require every local library in this directory-restricted describe "
            "graph to be owned below DIR"
        ),
    )
    ap.add_argument(
        "--required-local-library",
        default=None,
        metavar="LIB",
        help=(
            "with --closed-source-root, require exactly one local anchor library "
            "named LIB below that source root"
        ),
    )
    ap.add_argument(
        "--self-test",
        action="store_true",
        help="run the clean+buggy fixture dual-check and exit",
    )
    args = ap.parse_args(argv)

    if args.self_test:
        return self_test()

    if args.required_local_library is not None and args.closed_source_root is None:
        ap.error("--required-local-library requires --closed-source-root")

    leaves = DEFAULT_LEAVES + tuple(args.leaf)
    try:
        sexp = load_describe(args.root, args.describe_file, args.closed_source_root)
        libs = find_libraries(sexp)
    except (RuntimeError, ValueError, OSError) as exc:
        print(f"audit-sublib-cycle: {exc}", file=sys.stderr)
        return 2

    if not libs:
        print(
            "audit-sublib-cycle: no libraries found in describe output", file=sys.stderr
        )
        return 2

    try:
        validate_graph(libs)
    except ValueError as exc:
        print(f"audit-sublib-cycle: {exc}", file=sys.stderr)
        return 2

    violations = check(libs, leaves)
    if violations:
        print(
            "BOUNDARY VIOLATION: leaf library depends on the mega-library",
            file=sys.stderr,
        )
        for v in violations:
            print(f"  {v.leaf}: " + " -> ".join(v.path), file=sys.stderr)
        print(
            f"\nA leaf must not require `{MEGA_LIB}`. Remove the offending entry from the\n"
            f"leaf's dune `(libraries ...)`, or invert the dependency (callback/interface).",
            file=sys.stderr,
        )
        return 1

    if args.closed_source_root is not None:
        try:
            build_context = find_build_context(sexp)
            source_root_violations = check_closed_source_root(
                libs,
                build_context=build_context,
                source_root=args.closed_source_root,
                required_local_library=args.required_local_library,
            )
        except ValueError as exc:
            print(f"audit-sublib-cycle: {exc}", file=sys.stderr)
            return 2
        if source_root_violations:
            print(
                "BOUNDARY VIOLATION: directory-restricted graph contains "
                "workspace-local libraries owned outside the package",
                file=sys.stderr,
            )
            for violation in source_root_violations:
                print(f"  {violation.library}: {violation.source_dir}", file=sys.stderr)
            print(
                f"\nLibraries described from `{args.closed_source_root}` may depend only "
                "on libraries owned below that source root or on external installed "
                "libraries.",
                file=sys.stderr,
            )
            return 1

    checked = [name for name in leaves if any(lib.name == name for lib in libs)]
    noun = "library" if len(checked) == 1 else "libraries"
    print(
        f"audit-sublib-cycle: OK - {len(checked)} leaf {noun} clean: {', '.join(checked) or '(none present)'}"
    )
    if args.closed_source_root is not None:
        local_count = sum(1 for lib in libs if lib.local)
        print(
            "audit-sublib-cycle: OK - "
            f"{local_count} local libraries remain below {args.closed_source_root}"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
