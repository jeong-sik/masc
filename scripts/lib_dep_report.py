#!/usr/bin/env python3
"""Summarize lib dependency graph progress for extraction work.

Input: JSON written by scripts/analyze_lib_deps.py --json.
Output: stable Markdown or JSON for before/after comparison in extraction PRs.
"""

from __future__ import annotations

import argparse
import json
import tempfile
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_GRAPH = ROOT / "reports" / "lib-dependency-graph.json"
DEFAULT_OUTPUT = ROOT / "reports" / "lib-dependency-summary.md"
ROOM_COORDINATION_MODULES = (
    "Room",
    "Room_state",
    "Room_task",
    "Room_utils",
    "Coord",
    "Coord_task",
    "Coord_task_schedule",
)


Json = dict[str, Any]
Pair = dict[str, int | str]
Candidate = dict[str, float | int | str]


def load_json(path: Path) -> Json:
    raw = json.loads(path.read_text())
    if not isinstance(raw, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return raw


def stats(raw: Json) -> dict[str, int | float]:
    value = raw.get("stats", {})
    if not isinstance(value, dict):
        return {}
    return {
        str(key): item for key, item in value.items() if isinstance(item, (int, float))
    }


def graph(raw: Json) -> dict[str, list[str]]:
    value = raw.get("graph", {})
    if not isinstance(value, dict):
        return {}
    out: dict[str, list[str]] = {}
    for node, deps in value.items():
        if isinstance(node, str) and isinstance(deps, list):
            out[node] = [dep for dep in deps if isinstance(dep, str)]
    return out


def cycles(raw: Json) -> list[list[str]]:
    value = raw.get("cycles", [])
    if not isinstance(value, list):
        return []
    return [
        [item for item in cycle if isinstance(item, str)]
        for cycle in value
        if isinstance(cycle, list)
    ]


def pairs(raw: Json, key: str) -> list[Pair]:
    value = raw.get(key, [])
    if not isinstance(value, list):
        return []
    out: list[Pair] = []
    for item in value:
        if (
            isinstance(item, list)
            and len(item) == 2
            and isinstance(item[0], str)
            and isinstance(item[1], int)
        ):
            out.append({"module": item[0], "count": item[1]})
    return out


def clusters(raw: Json) -> list[Candidate]:
    value = raw.get("clusters", [])
    if not isinstance(value, list):
        return []
    out: list[Candidate] = []
    for item in value:
        if not isinstance(item, dict):
            continue
        prefix = item.get("prefix")
        module_count = item.get("module_count")
        coupling_ratio = item.get("coupling_ratio")
        external_dep_count = item.get("external_dep_count")
        internal_edges = item.get("internal_edges")
        if (
            isinstance(prefix, str)
            and isinstance(module_count, int)
            and isinstance(coupling_ratio, (int, float))
            and isinstance(external_dep_count, int)
            and isinstance(internal_edges, int)
        ):
            out.append(
                {
                    "prefix": prefix,
                    "module_count": module_count,
                    "coupling_ratio": round(float(coupling_ratio), 3),
                    "external_dep_count": external_dep_count,
                    "internal_edges": internal_edges,
                }
            )
    return out


def largest_scc(raw: Json) -> int:
    return max((len(component) for component in cycles(raw)), default=0)


def scc_key(component: list[str]) -> tuple[str, ...]:
    return tuple(sorted(component))


def scc_delta(current: Json, baseline: Json, *, limit: int) -> list[Json]:
    current_sccs = {scc_key(component) for component in cycles(current)}
    baseline_sccs = {scc_key(component) for component in cycles(baseline)}
    changes: list[Json] = []
    for status, components in (
        ("added", current_sccs - baseline_sccs),
        ("removed", baseline_sccs - current_sccs),
    ):
        for component in sorted(components, key=lambda item: (-len(item), item)):
            changes.append(
                {
                    "status": status,
                    "size": len(component),
                    "members": list(component),
                }
            )
    return changes[:limit]


def room_dependents(raw: Json) -> list[Pair]:
    reverse: dict[str, set[str]] = {}
    for node, deps in graph(raw).items():
        for dep in deps:
            reverse.setdefault(dep, set()).add(node)
    rows = [
        {"module": module, "count": len(reverse.get(module, set()))}
        for module in ROOM_COORDINATION_MODULES
        if module in reverse or module in graph(raw)
    ]
    return sorted(rows, key=lambda item: (-int(item["count"]), str(item["module"])))


def number_delta(
    current: dict[str, int | float],
    baseline: dict[str, int | float],
) -> dict[str, int | float]:
    out: dict[str, int | float] = {}
    for key in sorted(set(current) | set(baseline)):
        cur = current.get(key, 0)
        old = baseline.get(key, 0)
        out[key] = (
            round(float(cur) - float(old), 3)
            if isinstance(cur, float) or isinstance(old, float)
            else int(cur) - int(old)
        )
    return out


def pair_delta(current: list[Pair], baseline: list[Pair]) -> list[Pair]:
    cur = {str(item["module"]): int(item["count"]) for item in current}
    old = {str(item["module"]): int(item["count"]) for item in baseline}
    return [
        {"module": module, "count": cur.get(module, 0) - old.get(module, 0)}
        for module in sorted(set(cur) | set(old))
        if cur.get(module, 0) != old.get(module, 0)
    ]


def candidate_delta(current: list[Candidate], baseline: list[Candidate]) -> list[Json]:
    cur = {str(item["prefix"]): item for item in current}
    old = {str(item["prefix"]): item for item in baseline}
    out: list[Json] = []
    for prefix in sorted(set(cur) | set(old)):
        if prefix not in old:
            item = cur[prefix]
            out.append(
                {
                    "prefix": prefix,
                    "status": "added",
                    "module_count_delta": item["module_count"],
                    "coupling_ratio_delta": item["coupling_ratio"],
                    "external_dep_count_delta": item["external_dep_count"],
                }
            )
            continue
        if prefix not in cur:
            item = old[prefix]
            out.append(
                {
                    "prefix": prefix,
                    "status": "removed",
                    "module_count_delta": -int(item["module_count"]),
                    "coupling_ratio_delta": -float(item["coupling_ratio"]),
                    "external_dep_count_delta": -int(item["external_dep_count"]),
                }
            )
            continue
        now = cur[prefix]
        before = old[prefix]
        delta = {
            "prefix": prefix,
            "status": "changed",
            "module_count_delta": int(now["module_count"])
            - int(before["module_count"]),
            "coupling_ratio_delta": round(
                float(now["coupling_ratio"]) - float(before["coupling_ratio"]), 3
            ),
            "external_dep_count_delta": int(now["external_dep_count"])
            - int(before["external_dep_count"]),
        }
        if (
            delta["module_count_delta"]
            or delta["coupling_ratio_delta"]
            or delta["external_dep_count_delta"]
        ):
            out.append(delta)
    return out


def build_report(
    current: Json,
    *,
    source: Path,
    baseline: Json | None,
    baseline_path: Path | None,
    limit: int,
) -> Json:
    current_room = room_dependents(current)
    current_candidates = clusters(current)[:limit]
    return {
        "source": str(source),
        "baseline": str(baseline_path) if baseline_path is not None else None,
        "stats": stats(current),
        "stats_delta": number_delta(stats(current), stats(baseline))
        if baseline is not None
        else None,
        "scc_count": len(cycles(current)),
        "scc_count_delta": len(cycles(current)) - len(cycles(baseline))
        if baseline is not None
        else None,
        "largest_scc_size": largest_scc(current),
        "largest_scc_delta": largest_scc(current) - largest_scc(baseline)
        if baseline is not None
        else None,
        "scc_delta": scc_delta(current, baseline, limit=limit)
        if baseline is not None
        else None,
        "room_coordination_dependents": current_room,
        "room_coordination_dependents_delta": pair_delta(
            current_room, room_dependents(baseline)
        )
        if baseline is not None
        else None,
        "top_hubs": pairs(current, "top_imported")[:limit],
        "top_importers": pairs(current, "top_importers")[:limit],
        "batch2_candidates": current_candidates,
        "batch2_candidate_delta": candidate_delta(
            current_candidates, clusters(baseline)[:limit]
        )
        if baseline is not None
        else None,
    }


def fmt_delta(value: object) -> str:
    if value is None:
        return "-"
    if isinstance(value, (int, float)) and value > 0:
        return f"+{value}"
    return str(value)


def table(headers: list[str], rows: list[list[str]]) -> str:
    return "\n".join(
        [
            "| " + " | ".join(headers) + " |",
            "| " + " | ".join("---" for _ in headers) + " |",
        ]
        + ["| " + " | ".join(row) + " |" for row in rows]
    )


def render_markdown(report: Json) -> str:
    stats_delta = report["stats_delta"] or {}
    summary = table(
        ["Metric", "Current", "Delta"],
        [
            [
                name,
                str(report["stats"].get(name, "-")),
                fmt_delta(stats_delta.get(name)),
            ]
            for name in ("total_modules", "total_edges", "avg_out_degree")
        ]
        + [
            [
                "scc_count",
                str(report["scc_count"]),
                fmt_delta(report["scc_count_delta"]),
            ],
            [
                "largest_scc_size",
                str(report["largest_scc_size"]),
                fmt_delta(report["largest_scc_delta"]),
            ],
        ],
    )
    room_delta = {
        str(item["module"]): item["count"]
        for item in report["room_coordination_dependents_delta"] or []
    }
    room = table(
        ["Module", "Dependents", "Delta"],
        [
            [
                str(item["module"]),
                str(item["count"]),
                fmt_delta(room_delta.get(str(item["module"]))),
            ]
            for item in report["room_coordination_dependents"]
        ],
    )
    hubs = table(
        ["Rank", "Module", "Dependents"],
        [
            [str(index), str(item["module"]), str(item["count"])]
            for index, item in enumerate(report["top_hubs"], 1)
        ],
    )
    importers = table(
        ["Rank", "Module", "Dependencies"],
        [
            [str(index), str(item["module"]), str(item["count"])]
            for index, item in enumerate(report["top_importers"], 1)
        ],
    )
    candidates = table(
        ["Prefix", "Modules", "Coupling", "External Deps", "Internal Edges"],
        [
            [
                str(item["prefix"]),
                str(item["module_count"]),
                f"{float(item['coupling_ratio']):.3f}",
                str(item["external_dep_count"]),
                str(item["internal_edges"]),
            ]
            for item in report["batch2_candidates"]
        ],
    )
    sections = [
        "# Lib Dependency Decomposition Report",
        "",
        f"- Source: `{report['source']}`",
        f"- Baseline: `{report['baseline']}`"
        if report["baseline"]
        else "- Baseline: none",
        "",
        "## Summary",
        "",
        summary,
        "",
        "## Room/Coordination Dependents",
        "",
        room
        if report["room_coordination_dependents"]
        else "No room/coordination modules found in graph.",
        "",
        "## Top Hub Modules",
        "",
        hubs,
        "",
        "## Heaviest Importers",
        "",
        importers,
        "",
        "## Batch 2 Extraction Candidates",
        "",
        candidates,
    ]
    if report["scc_delta"] is not None:
        scc_delta_rows = [
            [
                str(item["status"]),
                str(item["size"]),
                ", ".join(str(member) for member in item["members"][:12])
                + ("..." if len(item["members"]) > 12 else ""),
            ]
            for item in report["scc_delta"]
        ]
        sections += [
            "",
            "## SCC Delta",
            "",
            table(["Status", "Size", "Members"], scc_delta_rows)
            if scc_delta_rows
            else "No SCC changes.",
        ]
    if report["batch2_candidate_delta"] is not None:
        delta_rows = [
            [
                str(item["prefix"]),
                str(item["status"]),
                fmt_delta(item["module_count_delta"]),
                fmt_delta(item["coupling_ratio_delta"]),
                fmt_delta(item["external_dep_count_delta"]),
            ]
            for item in report["batch2_candidate_delta"]
        ]
        sections += [
            "",
            "## Batch 2 Candidate Delta",
            "",
            table(
                [
                    "Prefix",
                    "Status",
                    "Module Delta",
                    "Coupling Delta",
                    "External Dep Delta",
                ],
                delta_rows,
            )
            if delta_rows
            else "No Batch 2 candidate changes.",
        ]
    sections += [
        "",
        "## Regeneration",
        "",
        "```sh",
        "python3 scripts/analyze_lib_deps.py --json",
        "python3 scripts/lib_dep_report.py --graph reports/lib-dependency-graph.json --output reports/lib-dependency-summary.md",
        "python3 scripts/lib_dep_report.py --graph reports/lib-dependency-graph.json --baseline reports/lib-dependency-graph.baseline.json --format json",
        "```",
        "",
    ]
    return "\n".join(sections)


def self_test() -> None:
    current = {
        "stats": {"total_modules": 4, "total_edges": 5, "avg_out_degree": 1.25},
        "top_imported": [["Coord", 3]],
        "top_importers": [["Main", 2]],
        "cycles": [["A", "B", "C"]],
        "clusters": [
            {
                "prefix": "server_mcp",
                "module_count": 4,
                "coupling_ratio": 0.75,
                "external_dep_count": 2,
                "internal_edges": 6,
            }
        ],
        "graph": {"Main": ["Coord"], "Worker": ["Coord"], "Other": ["Coord"]},
    }
    baseline = {
        **current,
        "stats": {"total_modules": 5, "total_edges": 7, "avg_out_degree": 1.4},
        "cycles": [["A", "B", "C", "D"]],
        "clusters": [
            {
                "prefix": "server_mcp",
                "module_count": 5,
                "coupling_ratio": 0.8,
                "external_dep_count": 3,
                "internal_edges": 7,
            }
        ],
        "graph": {**current["graph"], "Legacy": ["Coord"]},
    }
    with tempfile.TemporaryDirectory() as tmp:
        source = Path(tmp) / "current.json"
        baseline_path = Path(tmp) / "baseline.json"
        source.write_text(json.dumps(current))
        baseline_path.write_text(json.dumps(baseline))
        report = build_report(
            load_json(source),
            source=source,
            baseline=load_json(baseline_path),
            baseline_path=baseline_path,
            limit=5,
        )
    assert report["stats_delta"] == {
        "avg_out_degree": -0.15,
        "total_edges": -2,
        "total_modules": -1,
    }
    assert report["largest_scc_delta"] == -1
    assert report["scc_count_delta"] == 0
    assert report["scc_delta"] == [
        {"status": "added", "size": 3, "members": ["A", "B", "C"]},
        {"status": "removed", "size": 4, "members": ["A", "B", "C", "D"]},
    ]
    assert report["room_coordination_dependents_delta"] == [
        {"module": "Coord", "count": -1}
    ]
    assert report["batch2_candidate_delta"][0]["module_count_delta"] == -1
    print("self-test ok")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--graph", type=Path, default=DEFAULT_GRAPH)
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--format", choices=("markdown", "json"), default="markdown")
    parser.add_argument("--limit", type=int, default=10)
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.self_test:
        self_test()
        return
    current = load_json(args.graph)
    baseline = load_json(args.baseline) if args.baseline is not None else None
    report = build_report(
        current,
        source=args.graph,
        baseline=baseline,
        baseline_path=args.baseline,
        limit=args.limit,
    )
    content = (
        json.dumps(report, indent=2, ensure_ascii=False) + "\n"
        if args.format == "json"
        else render_markdown(report)
    )
    if args.output == Path("-"):
        print(content)
        return
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(content)
    print(f"Wrote {args.output}")


if __name__ == "__main__":
    main()
