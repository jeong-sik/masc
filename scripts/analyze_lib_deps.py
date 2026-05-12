#!/usr/bin/env python3
"""Analyze module dependencies in lib/ monolith for sub-library extraction.

Phase 0 of #3593: dependency graph analysis. Feeds RFC-0056 §3.4 (the
fan-in/fan-out audit that prioritizes future sub-library extractions).

Usage:
    python3 scripts/analyze_lib_deps.py [--json] [--cycles] [--clusters]
    python3 scripts/analyze_lib_deps.py --self-test   # regression guard
"""

import re
import sys
import json
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LIB_DIR = ROOT / "lib"

# Sub-library directories (already extracted, skip these)
SUB_LIBRARY_DIRS: set[str] = set()


def discover_sub_libraries() -> None:
    """Find directories with their own dune library stanza."""
    for child in LIB_DIR.iterdir():
        if child.is_dir():
            dune_file = child / "dune"
            if dune_file.exists():
                content = dune_file.read_text()
                if "(library" in content:
                    SUB_LIBRARY_DIRS.add(child.name)


def get_monolith_modules() -> dict[str, Path]:
    """Discover every .ml file absorbed into the flat `masc_mcp` library.

    `lib/dune` declares the library with `(include_subdirs unqualified)` and no
    explicit `(modules ...)` stanza, so the module set is *every* `.ml` under
    `lib/` that is not inside a sub-library directory — a direct child of `lib/`
    whose `dune` declares its own `(library ...)`.  (Nested sub-libraries such as
    `lib/exec/parser/` live inside an already-skipped tree, so pruning at the
    top-level child name is sufficient.)

    Pre-2026-05 this parsed a `(modules ...)` stanza; after `lib/dune` switched
    to `(include_subdirs unqualified)` that stanza disappeared and the parser
    silently returned `{}`, making the whole analysis (and the CI "lib
    dependency delta" step) a no-op.  See `--self-test`.
    """
    modules: dict[str, Path] = {}
    for path in sorted(LIB_DIR.rglob("*.ml")):
        rel = path.relative_to(LIB_DIR)
        # Skip files inside an extracted sub-library directory.
        if len(rel.parts) > 1 and rel.parts[0] in SUB_LIBRARY_DIRS:
            continue
        # Skip build artifacts (`_build`, dune `.formatted`, etc.).
        if any(part == "_build" or part.startswith(".") for part in rel.parts):
            continue
        stem = path.stem
        # Within the flat namespace `(include_subdirs unqualified)` forbids
        # duplicate module names, so a stem collision means a stray file
        # (e.g. a vendored copy); keep the first deterministically.
        modules.setdefault(stem, path)
    return modules


def strip_ocaml_comments_and_strings(content: str) -> str:
    """Remove OCaml comments/strings while preserving line structure.

    This avoids false positives from module-like tokens in comments/docs and
    from dotted references inside string literals.
    """

    out: list[str] = []
    i = 0
    comment_depth = 0
    in_string = False
    length = len(content)

    while i < length:
        two = content[i:i + 2]
        ch = content[i]

        if comment_depth > 0:
            if two == "(*":
                comment_depth += 1
                out.extend("  ")
                i += 2
            elif two == "*)":
                comment_depth -= 1
                out.extend("  ")
                i += 2
            elif ch == "\n":
                out.append("\n")
                i += 1
            else:
                out.append(" ")
                i += 1
            continue

        if in_string:
            if ch == "\\" and i + 1 < length:
                if ch == "\n":
                    out.append("\n")
                else:
                    out.append(" ")
                next_ch = content[i + 1]
                if next_ch == "\n":
                    out.append("\n")
                else:
                    out.append(" ")
                i += 2
            elif ch == '"':
                in_string = False
                out.append(" ")
                i += 1
            elif ch == "\n":
                out.append("\n")
                i += 1
            else:
                out.append(" ")
                i += 1
            continue

        if two == "(*":
            comment_depth = 1
            out.extend("  ")
            i += 2
        elif ch == '"':
            in_string = True
            out.append(" ")
            i += 1
        else:
            out.append(ch)
            i += 1

    return "".join(out)


def local_module_defs(content: str) -> set[str]:
    """Find nested module definitions declared inside a file."""

    return set(
        m.group(1)
        for m in re.finditer(
            r"\bmodule\s+(?:rec\s+)?([A-Z][A-Za-z0-9_]*)\s*(?:\(|:|=)",
            content,
        )
    )


def extract_module_refs(filepath: Path) -> set[str]:
    """Extract module references from an OCaml source file."""
    if not filepath.exists():
        return set()

    content = filepath.read_text(errors="replace")
    sanitized = strip_ocaml_comments_and_strings(content)
    local_modules = local_module_defs(sanitized)
    refs: set[str] = set()

    # Pattern 1: open Module
    for m in re.finditer(r"\bopen\s+([A-Z][A-Za-z0-9_]*)", sanitized):
        module_name = m.group(1)
        if module_name not in local_modules:
            refs.add(module_name)

    # Pattern 2: Module.something (but not inside strings/comments)
    for line in sanitized.split("\n"):
        for m in re.finditer(r"\b([A-Z][A-Za-z0-9_]*)\.(?![A-Z])", line):
            module_name = m.group(1)
            if module_name not in local_modules:
                refs.add(module_name)

    # Pattern 3: Module.Constructor or Module.Type (Module.CapitalWord)
    for line in sanitized.split("\n"):
        for m in re.finditer(r"\b([A-Z][A-Za-z0-9_]*)\.[A-Z]", line):
            module_name = m.group(1)
            if module_name not in local_modules:
                refs.add(module_name)

    return refs


def module_name_of_file(name: str) -> str:
    """Convert file-level module name to OCaml module name."""
    # OCaml module names are capitalized
    return name[0].upper() + name[1:]


def build_dependency_graph(
    modules: dict[str, Path],
) -> dict[str, set[str]]:
    """Build adjacency list of module dependencies."""
    # Map: OCaml module name -> file-level name
    ocaml_to_file: dict[str, str] = {}
    for name in modules:
        ocaml_name = module_name_of_file(name)
        ocaml_to_file[ocaml_name] = name

    valid_modules = set(ocaml_to_file.keys())
    graph: dict[str, set[str]] = defaultdict(set)

    for name, filepath in modules.items():
        ocaml_name = module_name_of_file(name)
        refs = extract_module_refs(filepath)
        # Filter to internal monolith modules only
        internal_refs = refs & valid_modules
        internal_refs.discard(ocaml_name)  # no self-ref
        graph[ocaml_name] = internal_refs

    return dict(graph)


def find_cycles(graph: dict[str, set[str]]) -> list[list[str]]:
    """Find all strongly connected components with size > 1 (cycles)."""
    # Tarjan's SCC algorithm
    index_counter = [0]
    stack: list[str] = []
    lowlink: dict[str, int] = {}
    index: dict[str, int] = {}
    on_stack: dict[str, bool] = {}
    sccs: list[list[str]] = []

    def strongconnect(v: str) -> None:
        index[v] = index_counter[0]
        lowlink[v] = index_counter[0]
        index_counter[0] += 1
        stack.append(v)
        on_stack[v] = True

        for w in graph.get(v, set()):
            if w not in index:
                strongconnect(w)
                lowlink[v] = min(lowlink[v], lowlink[w])
            elif on_stack.get(w, False):
                lowlink[v] = min(lowlink[v], index[w])

        if lowlink[v] == index[v]:
            scc: list[str] = []
            while True:
                w = stack.pop()
                on_stack[w] = False
                scc.append(w)
                if w == v:
                    break
            if len(scc) > 1:
                sccs.append(sorted(scc))

    # Increase recursion limit for large graphs
    old_limit = sys.getrecursionlimit()
    sys.setrecursionlimit(max(old_limit, len(graph) * 2 + 100))

    for v in sorted(graph.keys()):
        if v not in index:
            strongconnect(v)

    sys.setrecursionlimit(old_limit)
    return sorted(sccs, key=lambda x: -len(x))


def compute_stats(
    graph: dict[str, set[str]],
) -> dict[str, object]:
    """Compute dependency statistics."""
    in_degree: dict[str, int] = defaultdict(int)
    out_degree: dict[str, int] = {}

    for node, deps in graph.items():
        out_degree[node] = len(deps)
        for dep in deps:
            in_degree[dep] += 1

    # Top importers (most dependencies)
    top_out = sorted(out_degree.items(), key=lambda x: -x[1])[:20]

    # Top imported (most dependents)
    top_in = sorted(in_degree.items(), key=lambda x: -x[1])[:20]

    # Leaf modules (no internal deps)
    leaves = [n for n, d in out_degree.items() if d == 0]

    # Root modules (nothing depends on them)
    all_nodes = set(graph.keys())
    depended_on = set()
    for deps in graph.values():
        depended_on |= deps
    roots = sorted(all_nodes - depended_on)

    return {
        "total_modules": len(graph),
        "total_edges": sum(out_degree.values()),
        "avg_out_degree": round(sum(out_degree.values()) / max(len(graph), 1), 2),
        "top_importers": top_out,
        "top_imported": top_in,
        "leaf_count": len(leaves),
        "root_count": len(roots),
        "roots_sample": roots[:20],
    }


def identify_clusters(
    graph: dict[str, set[str]],
    modules: dict[str, Path],
) -> list[dict[str, object]]:
    """Identify potential sub-library extraction candidates by prefix."""
    prefix_groups: dict[str, list[str]] = defaultdict(list)

    for name in modules:
        ocaml_name = module_name_of_file(name)
        # Group by common prefixes
        parts = name.split("_")
        if len(parts) >= 2:
            prefix = parts[0] + "_" + parts[1]
            prefix_groups[prefix].append(ocaml_name)

    # Filter to groups with 3+ modules
    candidates = []
    for prefix, members in sorted(prefix_groups.items(), key=lambda x: -len(x[1])):
        if len(members) < 3:
            continue

        # Count internal vs external deps
        member_set = set(members)
        internal_edges = 0
        external_deps: set[str] = set()
        for m in members:
            for dep in graph.get(m, set()):
                if dep in member_set:
                    internal_edges += 1
                else:
                    external_deps.add(dep)

        candidates.append({
            "prefix": prefix,
            "module_count": len(members),
            "members": sorted(members),
            "internal_edges": internal_edges,
            "external_dep_count": len(external_deps),
            "coupling_ratio": round(
                internal_edges / max(internal_edges + len(external_deps), 1), 3
            ),
        })

    return sorted(candidates, key=lambda x: (-x["coupling_ratio"], -x["module_count"]))


# Regression floor: the flat `masc_mcp` namespace has had 600+ modules for the
# whole life of this script.  If discovery returns far fewer, module discovery
# is broken (the pre-2026-05 `(modules ...)`-parsing bug returned 0).
_SELF_TEST_MIN_MODULES = 400
_SELF_TEST_MIN_EDGES = 200


def run_self_test() -> int:
    """Assert module discovery and graph construction are not silently empty."""
    discover_sub_libraries()
    modules = get_monolith_modules()
    graph = build_dependency_graph(modules)
    edges = sum(len(v) for v in graph.values())
    problems: list[str] = []
    if len(modules) < _SELF_TEST_MIN_MODULES:
        problems.append(
            f"discovered {len(modules)} flat-ns modules, expected >= "
            f"{_SELF_TEST_MIN_MODULES} (module discovery broken?)"
        )
    if edges < _SELF_TEST_MIN_EDGES:
        problems.append(
            f"graph has {edges} edges, expected >= {_SELF_TEST_MIN_EDGES}"
        )
    missing = [n for n, p in modules.items() if not p.exists()]
    if missing:
        problems.append(f"{len(missing)} discovered modules have no .ml file")
    if problems:
        for p in problems:
            print(f"SELF-TEST FAIL: {p}", file=sys.stderr)
        return 1
    print(
        f"SELF-TEST OK: {len(modules)} flat-ns modules, {edges} internal edges, "
        f"{len(SUB_LIBRARY_DIRS)} sub-libraries"
    )
    return 0


def main() -> None:
    args = set(sys.argv[1:])

    if "--self-test" in args:
        sys.exit(run_self_test())

    discover_sub_libraries()
    print(f"Sub-libraries already extracted: {len(SUB_LIBRARY_DIRS)}")
    print(f"  {', '.join(sorted(SUB_LIBRARY_DIRS))}")
    print()

    modules = get_monolith_modules()
    print(f"Flat-namespace modules (absorbed into masc_mcp): {len(modules)}")

    missing = [n for n, p in modules.items() if not p.exists()]
    if missing:
        print(f"  Missing .ml files: {len(missing)}")

    print()

    graph = build_dependency_graph(modules)
    stats = compute_stats(graph)

    print("=== Dependency Statistics ===")
    print(f"Total modules: {stats['total_modules']}")
    print(f"Total edges: {stats['total_edges']}")
    print(f"Avg out-degree: {stats['avg_out_degree']}")
    print(f"Leaf modules (no internal deps): {stats['leaf_count']}")
    print(f"Root modules (nothing depends on them): {stats['root_count']}")
    print()

    print("=== Top 20 Most-Imported Modules ===")
    for name, count in stats["top_imported"]:
        print(f"  {name}: {count} dependents")
    print()

    print("=== Top 20 Heaviest Importers ===")
    for name, count in stats["top_importers"]:
        print(f"  {name}: {count} dependencies")
    print()

    if "--cycles" in args or "--json" not in args:
        cycles = find_cycles(graph)
        print("=== Circular Dependencies ===")
        print(f"Strongly connected components (cycles): {len(cycles)}")
        for i, scc in enumerate(cycles[:10]):
            print(f"  SCC {i+1} ({len(scc)} modules): {', '.join(scc[:8])}{'...' if len(scc) > 8 else ''}")
        print()

    if "--clusters" in args or "--json" not in args:
        clusters = identify_clusters(graph, modules)
        print("=== Extraction Candidates (prefix-based, 3+ modules) ===")
        for c in clusters[:15]:
            print(
                f"  {c['prefix']}: {c['module_count']} modules, "
                f"coupling={c['coupling_ratio']}, "
                f"ext_deps={c['external_dep_count']}"
            )
        print()

    if "--json" in args:
        output = {
            "stats": {
                "total_modules": stats["total_modules"],
                "total_edges": stats["total_edges"],
                "avg_out_degree": stats["avg_out_degree"],
                "leaf_count": stats["leaf_count"],
                "root_count": stats["root_count"],
            },
            "top_imported": stats["top_imported"],
            "top_importers": stats["top_importers"],
            "cycles": find_cycles(graph),
            "clusters": identify_clusters(graph, modules),
            "graph": {k: sorted(v) for k, v in graph.items()},
        }
        json_path = ROOT / "reports" / "lib-dependency-graph.json"
        json_path.parent.mkdir(parents=True, exist_ok=True)
        json_path.write_text(json.dumps(output, indent=2))
        print(f"Full graph written to {json_path}")


if __name__ == "__main__":
    main()
