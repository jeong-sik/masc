#!/usr/bin/env python3
"""Print the Markdown tables of one http_multiplex_probe.py run.

    python3 scripts/harness/perf/summarize_http_multiplex.py artifacts/http-multiplex/<run>

Each cell is the median over the run's repeats of the per-repeat value, so a
slow first repeat (cold file cache, connection setup) does not stand for the
run. The repeat count and the identity facts are printed above the tables.
"""
from __future__ import annotations

import json
import statistics
import sys
from collections import defaultdict
from pathlib import Path

TRANSPORT_ORDER = ("h1-6", "h1", "h2c", "tls-h1", "tls-h2")


def median(values: list[float]) -> float | None:
    return statistics.median(values) if values else None


def cell(value: float | None, digits: int = 1) -> str:
    return "—" if value is None else f"{value:.{digits}f}"


def by_key(rows: list[dict], scenario: str) -> dict[tuple[str, str], list[dict]]:
    groups: dict[tuple[str, str], list[dict]] = defaultdict(list)
    for row in rows:
        if row["scenario"] == scenario and "skipped" not in row:
            groups[(row.get("path", ""), row["transport"])].append(row)
    return groups


def transports_in(groups: dict[tuple[str, str], list[dict]]) -> list[str]:
    present = {transport for _, transport in groups}
    return [t for t in TRANSPORT_ORDER if t in present]


def latency_table(rows: list[dict], scenario: str, with_rate: bool) -> list[str]:
    groups = by_key(rows, scenario)
    if not groups:
        return [f"_{scenario}: no rows_", ""]
    paths = sorted({path for path, _ in groups})
    transports = transports_in(groups)
    header = "| path | " + " | ".join(transports) + " |"
    lines = [f"### {scenario}", "", header, "|---|" + "---|" * len(transports)]
    metrics = [("p50 ms", "p50_ms"), ("p99 ms", "p99_ms")]
    for path in paths:
        for label, key in metrics:
            cells = []
            for transport in transports:
                repeats = groups.get((path, transport), [])
                cells.append(cell(median([r["latency"][key] for r in repeats if r["latency"].get("n")])))
            lines.append(f"| `{path}` {label} | " + " | ".join(cells) + " |")
        if with_rate:
            cells = []
            for transport in transports:
                repeats = groups.get((path, transport), [])
                cells.append(cell(median([r["requests_per_s"] for r in repeats if r.get("requests_per_s")])))
            lines.append(f"| `{path}` req/s | " + " | ".join(cells) + " |")
        cells = []
        for transport in transports:
            repeats = groups.get((path, transport), [])
            total = sum(r["requests"] for r in repeats)
            ok = sum(r["ok"] for r in repeats)
            cells.append(f"{ok}/{total}")
        lines.append(f"| `{path}` ok | " + " | ".join(cells) + " |")
    lines.append("")
    return lines


def download_table(rows: list[dict]) -> list[str]:
    groups = by_key(rows, "download")
    skipped = [row for row in rows if row["scenario"] == "download" and "skipped" in row]
    if not groups:
        reason = skipped[0]["skipped"] if skipped else "no rows"
        return [f"_download: {reason}_", ""]
    transports = transports_in(groups)
    (path, _), = list(groups)[:1]
    size = sorted({b for repeats in groups.values() for r in repeats for b in r["body_bytes_each"]})
    lines = [f"### download `{path}` ({', '.join(str(s) for s in size)} B each, 4 at once)", "",
             "| | " + " | ".join(transports) + " |", "|---|" + "---|" * len(transports)]
    lines.append("| MB/s | " + " | ".join(
        cell(median([r["megabytes_per_s"] for r in groups[(path, t)] if r.get("megabytes_per_s")])) for t in transports) + " |")
    lines.append("| wall s | " + " | ".join(
        cell(median([r["wall_s"] for r in groups[(path, t)]]), 2) for t in transports) + " |")
    lines.append("| ok | " + " | ".join(
        f"{sum(r['ok'] for r in groups[(path, t)])}/{sum(r['concurrency'] for r in groups[(path, t)])}" for t in transports) + " |")
    lines.append("")
    return lines


def sse_table(rows: list[dict]) -> list[str]:
    groups = by_key(rows, "sse")
    if not groups:
        return ["_sse: no rows_", ""]
    transports = transports_in(groups)
    (path, _), = list(groups)[:1]
    sample = groups[(path, transports[0])][0]
    lines = [f"### sse `{path}` ({sample['streams']} streams held {sample['hold_s']:.0f} s)", "",
             "| | " + " | ".join(transports) + " |", "|---|" + "---|" * len(transports)]
    lines.append("| established | " + " | ".join(
        f"{round(median([r['established'] for r in groups[(path, t)]]) or 0)}/{sample['streams']}" for t in transports) + " |")
    lines.append("| established p99 ms | " + " | ".join(
        cell(median([r["established_ms"].get("p99_ms") for r in groups[(path, t)] if r["established_ms"].get("n")]))
        for t in transports) + " |")
    lines.append("| frames per stream p50 | " + " | ".join(
        cell(median([r["frames_per_stream"].get("p50_ms") for r in groups[(path, t)] if r["frames_per_stream"].get("n")]), 0)
        for t in transports) + " |")
    lines.append("| statuses | " + " | ".join(
        ",".join(str(s) for s in sorted({s for r in groups[(path, t)] for s in r["statuses"]})) for t in transports) + " |")
    lines.append("| first error | " + " | ".join(
        (sorted({e for r in groups[(path, t)] for e in r["errors"]}) or ["—"])[0].replace("|", "/") for t in transports) + " |")
    lines.append("")
    return lines


def curl_table(rows: list[dict]) -> list[str]:
    samples = [row for row in rows if row["scenario"] == "curl" and "skipped" not in row]
    if not samples:
        return []
    path = samples[0].get("path", "")
    transports = [t for t in TRANSPORT_ORDER if any(r["transport"] == t for r in samples)]
    lines = [f"### curl `{path}` (one download per sample, all repeats pooled)", "",
             "| | " + " | ".join(transports) + " |", "|---|" + "---|" * len(transports)]
    for label, pick in (("MB/s median", statistics.median), ("MB/s min", min), ("MB/s max", max)):
        lines.append(f"| {label} | " + " | ".join(
            cell(pick([r["megabytes_per_s"] for r in samples if r["transport"] == t and "megabytes_per_s" in r]))
            for t in transports) + " |")
    lines.append("| samples ok | " + " | ".join(
        f"{sum(1 for r in samples if r['transport'] == t and r.get('status') == 200)}/"
        f"{sum(1 for r in samples if r['transport'] == t)}" for t in transports) + " |")
    lines.append("")
    return lines


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    run = Path(sys.argv[1])
    identity = json.loads((run / "identity.json").read_text())
    rows = json.loads((run / "results.json").read_text())
    repeats = sorted({row.get("repeat", 0) for row in rows})
    binary = identity.get("binary", {})
    server = identity.get("server", {})
    listener = (identity.get("health") or {}).get("http_listener") or {}
    print(f"Run `{run.name}`: {identity['started_at']} → {identity['finished_at']}, {len(repeats)} repeats, "
          f"medians over repeats.")
    print()
    print(f"- binary: `{binary.get('path')}` version {binary.get('version')} build-commit `{binary.get('build_commit')}` "
          f"sha256 `{binary.get('sha256')}`")
    print(f"- server: owned={server.get('owned')} listener mode `{listener.get('mode')}` h2_mode_env={server.get('h2_mode_env')} "
          f"boot {cell(server.get('boot_s'), 1)} s exit {server.get('exit_code')}")
    print("- client: " + ", ".join(f"{k} {v}" for k, v in identity.get("client", {}).items())
          + f"; host {identity['host']['system']} {identity['host']['machine']}")
    args = identity.get("arguments", {})
    print(f"- arguments: requests {args.get('requests')} at concurrency {args.get('concurrency')}, serial {args.get('serial_requests')}, "
          f"download concurrency {args.get('download_concurrency')}, sse {args.get('sse_streams')} streams for {args.get('sse_hold_s')} s")
    print()
    for scenario, with_rate in (("serial", False), ("burst", True)):
        if any(row["scenario"] == scenario for row in rows):
            for line in latency_table(rows, scenario, with_rate=with_rate):
                print(line)
    if any(row["scenario"] == "download" for row in rows):
        for line in download_table(rows):
            print(line)
    if any(row["scenario"] == "sse" for row in rows):
        for line in sse_table(rows):
            print(line)
    for line in curl_table(rows):
        print(line)


if __name__ == "__main__":
    main()
