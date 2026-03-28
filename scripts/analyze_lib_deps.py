#!/usr/bin/env python3
"""Analyze module dependencies in lib/ monolith for sub-library extraction.

Phase 0 of #3593: dependency graph analysis.

Usage:
    python3 scripts/analyze_lib_deps.py [--json] [--cycles] [--clusters]
"""

import os
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
    """Parse lib/dune to get explicit module list."""
    dune_path = LIB_DIR / "dune"
    content = dune_path.read_text()

    # Extract modules from (modules ...) stanza
    modules: dict[str, Path] = {}
    in_modules = False
    paren_depth = 0

    for line in content.split("\n"):
        stripped = line.strip()
        if "(modules" in stripped:
            in_modules = True
            paren_depth = 1
            # Extract any modules on same line after (modules
            after = stripped.split("(modules")[1]
            for word in after.split():
                w = word.strip(")")
                if w and not w.startswith("("):
                    modules[w] = _find_ml_file(w)
            continue

        if in_modules:
            paren_depth += stripped.count("(") - stripped.count(")")
            if paren_depth <= 0:
                in_modules = False
                continue
            for word in stripped.split():
                w = word.strip(")")
                if w and not w.startswith(";") and not w.startswith("("):
                    modules[w] = _find_ml_file(w)

    return modules


def _find_ml_file(module_name: str) -> Path:
    """Find .ml file for a module name, searching lib/ and subdirs."""
    # Direct in lib/
    direct = LIB_DIR / f"{module_name}.ml"
    if direct.exists():
        return direct

    # Search subdirectories (non-sub-library ones only)
    for child in LIB_DIR.iterdir():
        if child.is_dir() and child.name not in SUB_LIBRARY_DIRS:
            candidate = child / f"{module_name}.ml"
            if candidate.exists():
                return candidate

    return direct  # fallback even if missing


def extract_module_refs(filepath: Path) -> set[str]:
    """Extract module references from an OCaml source file."""
    if not filepath.exists():
        return set()

    content = filepath.read_text(errors="replace")
    refs: set[str] = set()

    # Pattern 1: open Module
    for m in re.finditer(r"\bopen\s+([A-Z][A-Za-z0-9_]*)", content):
        refs.add(m.group(1))

    # Pattern 2: Module.something (but not inside strings/comments)
    # Simple heuristic: skip lines starting with (* or inside strings
    for line in content.split("\n"):
        stripped = line.strip()
        if stripped.startswith("(*") or stripped.startswith("\""):
            continue
        for m in re.finditer(r"\b([A-Z][A-Za-z0-9_]*)\.(?![A-Z])", line):
            refs.add(m.group(1))

    # Pattern 3: Module.Constructor or Module.Type (Module.CapitalWord)
    for line in content.split("\n"):
        stripped = line.strip()
        if stripped.startswith("(*"):
            continue
        for m in re.finditer(r"\b([A-Z][A-Za-z0-9_]*)\.[A-Z]", line):
            refs.add(m.group(1))

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


def main() -> None:
    args = set(sys.argv[1:])

    discover_sub_libraries()
    print(f"Sub-libraries already extracted: {len(SUB_LIBRARY_DIRS)}")
    print(f"  {', '.join(sorted(SUB_LIBRARY_DIRS))}")
    print()

    modules = get_monolith_modules()
    print(f"Monolith modules in lib/dune: {len(modules)}")

    missing = [n for n, p in modules.items() if not p.exists()]
    if missing:
        print(f"  Missing .ml files: {len(missing)}")

    print()

    graph = build_dependency_graph(modules)
    stats = compute_stats(graph)

    print(f"=== Dependency Statistics ===")
    print(f"Total modules: {stats['total_modules']}")
    print(f"Total edges: {stats['total_edges']}")
    print(f"Avg out-degree: {stats['avg_out_degree']}")
    print(f"Leaf modules (no internal deps): {stats['leaf_count']}")
    print(f"Root modules (nothing depends on them): {stats['root_count']}")
    print()

    print(f"=== Top 20 Most-Imported Modules ===")
    for name, count in stats["top_imported"]:
        print(f"  {name}: {count} dependents")
    print()

    print(f"=== Top 20 Heaviest Importers ===")
    for name, count in stats["top_importers"]:
        print(f"  {name}: {count} dependencies")
    print()

    if "--cycles" in args or "--json" not in args:
        cycles = find_cycles(graph)
        print(f"=== Circular Dependencies ===")
        print(f"Strongly connected components (cycles): {len(cycles)}")
        for i, scc in enumerate(cycles[:10]):
            print(f"  SCC {i+1} ({len(scc)} modules): {', '.join(scc[:8])}{'...' if len(scc) > 8 else ''}")
        print()

    if "--clusters" in args or "--json" not in args:
        clusters = identify_clusters(graph, modules)
        print(f"=== Extraction Candidates (prefix-based, 3+ modules) ===")
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
