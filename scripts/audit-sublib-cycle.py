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
  audit-sublib-cycle.py --self-test     # clean + buggy fixture dual-check

Exit codes: 0 = all leaves clean, 1 = boundary violation, 2 = usage/parse error.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from collections import deque
from dataclasses import dataclass
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
    "masc.worker_execution_backend",
    "masc.worker_runtime_config",
    "masc.worker_execution_spec",
    # Keeper-owned pure/type leaves extracted from lib/keeper/.
    "masc.keeper_accountability_claim_types",
    "masc.keeper_runtime_manifest_types",
    "masc.keeper_registry_types_kill_class",
    "masc.keeper_registry_types_turn_phase",
    "masc.keeper_registry_types_decision",
    "masc.keeper_registry_types_compaction",
    "masc.keeper_hooks_oas_types",
    "masc.keeper_binding_health_config",
    "masc.keeper_transition_audit_types",
    "masc.keeper_path_rejection",
    "masc.keeper_approval_queue_types",
    "masc.keeper_toml_parser",
    "masc.keeper_toml_loader",
    "masc.keeper_runtime_config",
    "masc.keeper_tool_name",
    "masc.keeper_id",
    "masc.keeper_terminal_reason",
    "masc.keeper_timing",
    "masc.keeper_token_count",
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
    "masc.keeper_prompt_names",
    "masc.keeper_event_bus",
    "masc.keeper_synthetic_marker",
    "masc.keeper_oas_timeout_message",
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
    requires: tuple[str, ...]


@dataclass(frozen=True)
class Violation:
    leaf: str
    path: tuple[str, ...]  # human-readable lib names: leaf -> ... -> mega


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


def _child(node: "list[Sexp]", key: str) -> "list[Sexp] | None":
    """Return the first child sublist whose head atom equals ``key``."""
    for ch in node:
        if isinstance(ch, list) and ch and ch[0] == key:
            return ch
    return None


def find_libraries(sexp: Sexp) -> list[Library]:
    """Walk the describe tree and collect every node with both name and uid.

    Library nodes carry ``(name ...)`` and ``(uid ...)``; module nodes carry
    ``(name ...)`` only, so requiring uid cleanly selects libraries.
    """
    libs: list[Library] = []

    def visit(node: Sexp) -> None:
        if not isinstance(node, list):
            return
        name_node = _child(node, "name")
        uid_node = _child(node, "uid")
        if (
            name_node is not None
            and uid_node is not None
            and len(name_node) >= 2
            and len(uid_node) >= 2
            and isinstance(name_node[1], str)
            and isinstance(uid_node[1], str)
        ):
            req_node = _child(node, "requires")
            requires: tuple[str, ...] = ()
            if (
                req_node is not None
                and len(req_node) >= 2
                and isinstance(req_node[1], list)
            ):
                requires = tuple(u for u in req_node[1] if isinstance(u, str))
            libs.append(Library(name=name_node[1], uid=uid_node[1], requires=requires))
        for ch in node:
            visit(ch)

    visit(sexp)
    return libs


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


# --- describe acquisition ----------------------------------------------------


def load_describe(root: str, describe_file: "str | None") -> Sexp:
    if describe_file is not None:
        text = open(describe_file, encoding="utf-8").read()
    else:
        proc = subprocess.run(
            ["dune", "describe", "--root", root],
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
    mega = Library(name="masc", uid="MEGA", requires=("LEAF", "OTHER"))
    neutral = Library(name="masc_core", uid="CORE", requires=())
    # clean: leaf depends only on neutral; mega depends on leaf (allowed direction)
    clean_leaf = Library(name="masc.masc_goal", uid="LEAF", requires=("CORE",))
    clean = [mega, neutral, clean_leaf]
    # buggy: leaf re-couples to the mega-lib (direct)
    buggy_leaf = Library(name="masc.masc_goal", uid="LEAF", requires=("CORE", "MEGA"))
    buggy = [mega, neutral, buggy_leaf]
    # buggy-transitive: leaf -> mid -> mega
    mid = Library(name="masc.mid", uid="MID", requires=("MEGA",))
    trans_leaf = Library(name="masc.masc_goal", uid="LEAF", requires=("MID",))
    buggy_trans = [mega, neutral, mid, trans_leaf]

    leaves = ("masc.masc_goal",)
    ok = True

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
        "--self-test",
        action="store_true",
        help="run the clean+buggy fixture dual-check and exit",
    )
    args = ap.parse_args(argv)

    if args.self_test:
        return self_test()

    leaves = DEFAULT_LEAVES + tuple(args.leaf)
    try:
        sexp = load_describe(args.root, args.describe_file)
    except (RuntimeError, ValueError, OSError) as exc:
        print(f"audit-sublib-cycle: {exc}", file=sys.stderr)
        return 2

    libs = find_libraries(sexp)
    if not libs:
        print(
            "audit-sublib-cycle: no libraries found in describe output", file=sys.stderr
        )
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

    checked = [name for name in leaves if any(lib.name == name for lib in libs)]
    noun = "library" if len(checked) == 1 else "libraries"
    print(
        f"audit-sublib-cycle: OK - {len(checked)} leaf {noun} clean: {', '.join(checked) or '(none present)'}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
