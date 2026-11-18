#!/usr/bin/env python3
"""Approximate which file-read sites each HTTP route and the Keeper turn reach.

Builds a name-based call graph over `lib/` and `bin/` `.ml` files:
- a node is a top-level binding (or a two-space binding inside a column-0
  `module X = struct`), named `File_module.binding`
- an edge is any reference from a binding body to another binding, either
  qualified (`Module.name`, `Lib.Module.name`, file-level `module X = Y`
  aliases followed) or unqualified to a binding of the same file or of a
  module the file `open`s / `include`s
- a route node is one `Server_route.<verb>` (or `Server_route.Serving.<verb>`)
  registration, named by its path argument: the string literal after the
  permission, the `~path:` argument of `add`, or the single-line top-level
  string constant an identifier names (`stream_path`,
  `Server_health_paths.health`). A path that resolves to no literal keeps the
  identifier, as `<Module.name>`. Its body runs to the next registration in the
  same file. A path registered in two files (the account server's `/health`
  and the main server's) gets one node per file, suffixed `@File_module`
- `--edge FROM=TO` adds a declared edge for a call the names do not show, such
  as a function stored in a ref; both ends must resolve or the run fails
- neighbours are visited in sorted order, so the output does not depend on
  Python's hash seed

References are not calls: a function passed as a value is an edge too, and a
call through a record field or closure is missed. Reachability is therefore
an upper bound on what a request may read and says nothing about caching.

Inputs: the repository and code-read-sites.tsv from code_read_sites.py.
Outputs (TSV): route-reads.tsv (route x reachable read site, with depth and
one shortest path) and site-triggers.tsv (read site x reaching entries).
"""

from __future__ import annotations

import argparse
import csv
import re
import sys
from collections import defaultdict, deque
from dataclasses import dataclass
from pathlib import Path

from code_read_sites import binding_spans, blank_comments_and_strings

MAX_DEPTH = 30
QUALIFIED_RE = re.compile(r"\b((?:[A-Z][\w']*\.)+)([a-z_][\w']*)")
UNQUALIFIED_RE = re.compile(r"(?<![\w.'~?`#])([a-z_][\w']*)\b(?!\s*:)")
ALIAS_RE = re.compile(r"^module\s+([A-Z][\w']*)\s*=\s*([A-Z][\w'.]*)\s*$")
OPEN_RE = re.compile(r"^(open|include)!?\s+([A-Z][\w'.]*)\s*$")
ROUTE_RE = re.compile(r"\bServer_route\.(?:Serving\.)?(get|post|put|patch|delete|prefix_get|prefix_post|prefix_put|prefix_delete|ws_get|add)\b")
TOKEN_RE = re.compile(r"[A-Za-z_][\w'.]*")
LABELLED_PATH_RE = re.compile(r"~path:\s*")
CONST_RE = re.compile(r'^let\s+([a-z_][\w\']*)\s*=\s*"(/[^"]*)"\s*$')
KEYWORDS = frozenset(
    "let in and rec match with fun function if then else begin end true false "
    "when as of type module struct sig open include try raise not mod land lor "
    "lxor lsl lsr asr or val external exception mutable private virtual object "
    "method inherit new lazy assert do done for to downto while ignore".split()
)


@dataclass(frozen=True, slots=True)
class Binding:
    node: str
    start: int
    end: int


@dataclass(frozen=True, slots=True)
class SourceFile:
    rel: str
    module: str
    lines: tuple[str, ...]
    raw_lines: tuple[str, ...]
    bindings: tuple[Binding, ...]
    aliases: dict[str, str]
    opens: tuple[str, ...]
    includes: tuple[str, ...]
    path_constants: dict[str, str]


def module_of(path: Path) -> str:
    stem = path.stem
    return stem[:1].upper() + stem[1:]


def load(repo: Path) -> list[SourceFile]:
    files: list[SourceFile] = []
    for path in sorted(p for d in ("lib", "bin") for p in (repo / d).rglob("*.ml")):
        raw = path.read_text(encoding="utf-8", errors="replace")
        clean = blank_comments_and_strings(raw)
        lines = clean.split("\n")
        module = module_of(path)
        spans = binding_spans(lines)
        bindings: list[Binding] = []
        for i, (start, name) in enumerate(spans):
            end = spans[i + 1][0] if i + 1 < len(spans) else len(lines)
            bindings.append(Binding(f"{module}.{name}", start, end))
        aliases: dict[str, str] = {}
        opens: list[str] = []
        includes: list[str] = []
        raw_lines = raw.split("\n")
        path_constants = {m.group(1): m.group(2) for t in raw_lines if (m := CONST_RE.match(t))}
        for text in lines:
            alias = ALIAS_RE.match(text)
            if alias:
                aliases[alias.group(1)] = alias.group(2)
            opened = OPEN_RE.match(text)
            if opened:
                target = opened.group(2).split(".")[-1]
                (includes if opened.group(1) == "include" else opens).append(target)
        files.append(
            SourceFile(
                rel=str(path.relative_to(repo)),
                module=module,
                lines=tuple(lines),
                raw_lines=tuple(raw_lines),
                bindings=tuple(bindings),
                aliases=aliases,
                opens=tuple(opens),
                includes=tuple(includes),
                path_constants=path_constants,
            )
        )
    return files


class Resolver:
    def __init__(self, files: list[SourceFile]) -> None:
        self.by_module: dict[str, list[SourceFile]] = defaultdict(list)
        self.nodes: set[str] = set()
        self.names_by_module: dict[str, set[str]] = defaultdict(set)
        self.includes: dict[str, list[str]] = defaultdict(list)
        for f in files:
            self.by_module[f.module].append(f)
            self.includes[f.module].extend(f.includes)
            for b in f.bindings:
                self.nodes.add(b.node)
                self.names_by_module[f.module].add(b.node.split(".", 1)[1])

    def export(self, module: str, name: str, seen: frozenset[str] = frozenset()) -> str | None:
        """The node `module.name` resolves to, following top-level includes."""
        node = f"{module}.{name}"
        if node in self.nodes:
            return node
        for inc in self.includes.get(module, ()):
            if inc in seen or inc == module:
                continue
            found = self.export(inc, name, seen | {module})
            if found:
                return found
        return None

    def unqualified(self, here: SourceFile, name: str) -> str | None:
        found = self.export(here.module, name)
        if found:
            return found
        for om in reversed(here.opens):
            found = self.export(here.aliases.get(om, om), name)
            if found:
                return found
        return None

    def resolve_body(self, here: SourceFile, body: str, self_node: str) -> set[str]:
        out: set[str] = set()
        for modpath, ident in QUALIFIED_RE.findall(body):
            target = self.target(here, modpath, ident)
            if target and target != self_node:
                out.add(target)
        for ident in set(UNQUALIFIED_RE.findall(body)):
            if ident in KEYWORDS:
                continue
            target = self.unqualified(here, ident)
            if target and target != self_node:
                out.add(target)
        return out

    def target(self, here: SourceFile, modpath: str, ident: str) -> str | None:
        parts = modpath.rstrip(".").split(".")
        if parts[0] in here.aliases:
            parts = here.aliases[parts[0]].split(".") + parts[1:]
        # Try the longest suffix that names a file module, so Lib.Mod.f and
        # Mod.Sub.f both land: Mod.f, then Mod.Sub.f inside Mod's file.
        for i, part in enumerate(parts):
            if part in self.by_module:
                inner = parts[i + 1 :]
                node = ".".join([part, *inner, ident])
                if node in self.nodes:
                    return node
                if not inner:
                    return self.export(part, ident)
        return None


def build_graph(files: list[SourceFile], resolver: Resolver) -> dict[str, set[str]]:
    edges: dict[str, set[str]] = defaultdict(set)
    for f in files:
        for b in f.bindings:
            body = "\n".join(f.lines[b.start : b.end])
            edges[b.node] |= resolver.resolve_body(f, body, b.node)
    return edges


@dataclass(frozen=True, slots=True)
class Route:
    node: str
    file: str
    line: int
    resolved: bool


def skip_space(text: str, i: int) -> int:
    while i < len(text) and text[i].isspace():
        i += 1
    return i


def skip_group(text: str, i: int) -> int:
    """Index after the parenthesised group that opens at text[i]."""
    depth = 0
    while i < len(text):
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return i


def path_argument(clean: str, raw: str, i: int) -> tuple[bool, str] | None:
    """(is_literal, text) of the argument at i: a string literal or an identifier."""
    i = skip_space(clean, i)
    if i < len(clean) and clean[i] == '"':
        return (True, raw[i + 1 : clean.index('"', i + 1)])
    m = TOKEN_RE.match(clean, i)
    return (False, m.group(0)) if m else None


def resolve_constant(here: SourceFile, by_module: dict[str, list[SourceFile]], ident: str) -> str | None:
    parts = ident.split(".")
    if len(parts) == 1:
        candidates = [here.module, *(here.aliases.get(o, o) for o in reversed(here.opens))]
    else:
        head = here.aliases.get(parts[0], parts[0]).split(".")[-1] if len(parts) == 2 else parts[-2]
        candidates = [head]
    for module in candidates:
        for f in by_module.get(module, ()):
            if parts[-1] in f.path_constants:
                return f.path_constants[parts[-1]]
    return None


def route_path(f: SourceFile, by_module: dict[str, list[SourceFile]], verb: str, clean: str, raw: str, after: int) -> tuple[str, bool]:
    if verb == "add":
        labelled = LABELLED_PATH_RE.search(clean, after)
        arg = path_argument(clean, raw, labelled.end()) if labelled else None
    else:
        i = skip_space(clean, after)
        if i < len(clean) and clean[i] == "(":
            i = skip_group(clean, i)
        else:
            m = TOKEN_RE.match(clean, i)
            i = m.end() if m else i
        arg = path_argument(clean, raw, i)
    if arg is None:
        return ("<unparsed>", False)
    is_literal, text = arg
    if is_literal:
        return (text, True)
    constant = resolve_constant(f, by_module, text)
    return (constant, True) if constant is not None else (f"<{text}>", False)


def route_entries(files: list[SourceFile], resolver: Resolver, edges: dict[str, set[str]]) -> list[Route]:
    """One node per (verb, path); a path registered in two files gets one node per file module."""
    found: list[tuple[str, SourceFile, int, str, bool]] = []
    for f in files:
        starts = [i for i, text in enumerate(f.lines) if ROUTE_RE.search(text)]
        for k, start in enumerate(starts):
            verb_match = ROUTE_RE.search(f.lines[start])
            assert verb_match is not None
            end = starts[k + 1] if k + 1 < len(starts) else next(
                (b.end for b in f.bindings if b.start <= start < b.end), len(f.lines)
            )
            clean = "\n".join(f.lines[start:end])
            raw = "\n".join(f.raw_lines[start:end])
            verb = verb_match.group(1)
            path, resolved = route_path(f, resolver.by_module, verb, clean, raw, verb_match.end())
            found.append((f"ROUTE {verb.upper()} {path}", f, start, clean, resolved))
    modules_by_node: dict[str, set[str]] = defaultdict(set)
    for base, f, _start, _clean, _resolved in found:
        modules_by_node[base].add(f.module)
    routes: list[Route] = []
    for base, f, start, clean, resolved in found:
        node = base if len(modules_by_node[base]) == 1 else f"{base} @{f.module}"
        edges[node] |= resolver.resolve_body(f, clean, node)
        routes.append(Route(node, f.rel, start + 1, resolved))
    return routes


def bfs(edges: dict[str, set[str]], start: str) -> dict[str, tuple[int, str]]:
    """Node -> (depth, parent) for nodes within MAX_DEPTH of start."""
    seen: dict[str, tuple[int, str]] = {start: (0, "")}
    queue: deque[str] = deque([start])
    while queue:
        node = queue.popleft()
        depth = seen[node][0]
        if depth >= MAX_DEPTH:
            continue
        for nxt in sorted(edges.get(node, ())):
            if nxt not in seen:
                seen[nxt] = (depth + 1, node)
                queue.append(nxt)
    return seen


def path_to(seen: dict[str, tuple[int, str]], node: str) -> str:
    chain: list[str] = []
    cur = node
    while cur:
        chain.append(cur)
        cur = seen[cur][1]
    return " <- ".join(chain)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repo", type=Path)
    parser.add_argument("--sites", type=Path, required=True)
    parser.add_argument("--route-out", type=Path, required=True)
    parser.add_argument("--site-out", type=Path, required=True)
    parser.add_argument("--entry", action="append", default=[], help="extra entry node, e.g. Keeper_agent_run.run_turn")
    parser.add_argument("--edge", action="append", default=[], help="declared edge FROM=TO, e.g. a function stored in a ref")
    parser.add_argument("--no-routes", action="store_true", help="use only --entry nodes as entries")
    args = parser.parse_args(argv)
    repo: Path = args.repo
    files = load(repo)
    resolver = Resolver(files)
    edges = build_graph(files, resolver)
    for declared in args.edge:
        source, _, target = declared.partition("=")
        module, _, name = target.rpartition(".")
        resolved_target = resolver.export(module, name)
        if source not in resolver.nodes or resolved_target is None:
            print(f"unresolved --edge {declared}", file=sys.stderr)
            return 2
        edges[source].add(resolved_target)
    routes = route_entries(files, resolver, edges)
    route_nodes = [] if args.no_routes else [r.node for r in routes]
    entries: list[str] = list(dict.fromkeys([*route_nodes, *args.entry]))
    missing = [e for e in args.entry if e not in resolver.nodes]
    if missing:
        print(f"unresolved --entry {missing}", file=sys.stderr)
        return 2

    sites_by_node: dict[str, list[dict[str, str]]] = defaultdict(list)
    with args.sites.open(encoding="utf-8") as handle:
        for row in csv.DictReader(handle, delimiter="\t"):
            module = module_of(Path(row["path"]))
            sites_by_node[f"{module}.{row['binding']}"].append(row)

    site_triggers: dict[str, dict[str, int]] = defaultdict(dict)
    with args.route_out.open("w", encoding="utf-8") as out:
        out.write("entry\tdepth\tsite\tprimitive\tshape\tmech\tpath_from_entry\n")
        for entry in entries:
            seen = bfs(edges, entry)
            for node, (depth, _parent) in seen.items():
                for row in sites_by_node.get(node, ()):
                    site = f"{row['path']}:{row['line']}"
                    known = site_triggers[site].get(entry)
                    site_triggers[site][entry] = depth if known is None else min(known, depth)
                    out.write(
                        f"{entry}\t{depth}\t{site}\t{row['primitive']}\t{row['shape']}\t{row['mech']}\t{path_to(seen, node)}\n"
                    )
    with args.site_out.open("w", encoding="utf-8") as out:
        out.write("site\tprimitive\tshape\tentries\tmin_depth\tnearest_entry\n")
        for node, rows in sorted(sites_by_node.items()):
            for row in rows:
                site = f"{row['path']}:{row['line']}"
                reached = site_triggers.get(site, {})
                nearest = min(reached.items(), key=lambda e: (e[1], e[0])) if reached else ("-", -1)
                out.write(
                    f"{site}\t{row['primitive']}\t{row['shape']}\t{len(reached)}\t{nearest[1]}\t{nearest[0]}\n"
                )
    edge_count = sum(len(v) for v in edges.values())
    unresolved = sorted({r.node for r in routes if not r.resolved})
    print(
        f"files={len(files)} nodes={len(resolver.nodes)} edges={edge_count} registrations={len(routes)} "
        f"routes={len({r.node for r in routes})} unresolved_paths={len(unresolved)} entries={len(entries)}"
    )
    for node in unresolved:
        print(f"unresolved path: {node}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
