#!/usr/bin/env python3
"""Summarise where a `dune build --trace-file` run spent its time.

Dune 3.24 writes the trace as a stream of csexp records. Every finished
process is one `(process finish (start duration) ...)` record carrying the
program, its arguments and the files it made. This reads those records and
sorts each process into one kind: compile, link, test run, dependency scan,
preprocessor or other.

The trace also records dune's whole environment (`(config init ...)`), which
can hold credentials, so the summary keeps only program kinds, target names
and durations, and the CI wrapper deletes the trace once it is summarised.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import dataclass
from typing import Union

Sexp = Union[str, list["Sexp"]]

NANOSECONDS = 1_000_000_000
SLOWEST_PER_KIND = 40
OCAML_COMPILERS = ("ocamlopt", "ocamlc", "ocamlfind")


def parse_stream(data: bytes) -> list[Sexp]:
    """Every complete record in [data]. A trace cut short by a killed build
    ends in a partial record, which is dropped."""
    records: list[Sexp] = []
    index = 0
    while index < len(data):
        try:
            record, index = _parse(data, index)
        except (ValueError, IndexError):
            break
        records.append(record)
    return records


def _parse(data: bytes, index: int) -> tuple[Sexp, int]:
    if data[index:index + 1] == b"(":
        index += 1
        items: list[Sexp] = []
        while data[index:index + 1] != b")":
            if index >= len(data):
                raise ValueError("unterminated list")
            item, index = _parse(data, index)
            items.append(item)
        return items, index + 1
    colon = data.index(b":", index)
    length = int(data[index:colon])
    end = colon + 1 + length
    if end > len(data):
        raise ValueError("truncated atom")
    return data[colon + 1:end].decode("utf-8", "replace"), end


def _field(record: list[Sexp], name: str) -> Sexp | None:
    for item in record:
        if isinstance(item, list) and item and item[0] == name and len(item) > 1:
            return item[1]
    return None


@dataclass(frozen=True, slots=True)
class Process:
    kind: str
    name: str
    start_ns: int
    duration_ns: int

    @property
    def seconds(self) -> float:
        return self.duration_ns / NANOSECONDS


def _strings(value: Sexp | None) -> list[str]:
    if isinstance(value, list):
        return [item for item in value if isinstance(item, str)]
    return []


def classify(prog: str, args: list[str], targets: list[str]) -> tuple[str, str]:
    """(kind, name) for one finished process."""
    base = os.path.basename(prog)
    if base.startswith("ocamldep"):
        return "dependency scan", base
    if base.startswith(OCAML_COMPILERS):
        if "-o" in args:
            output = args[args.index("-o") + 1] if args.index("-o") + 1 < len(args) else ""
            if output.endswith((".exe", ".bc", ".bc.js")):
                return "link", os.path.basename(output)
            if output.endswith((".cmxa", ".cma", ".cmxs")):
                return "library archive", os.path.basename(output)
        named = next((t for t in targets if t.endswith((".cmx", ".cmo", ".cmi", ".cmt"))), "")
        return "compile", os.path.basename(named) if named else base
    if base.startswith("python") and args:
        script = os.path.basename(args[0])
        if script.startswith("test_"):
            return "test run", script
        return "other", script
    if base.startswith("test_") or (base.endswith(".exe") and "test" in base):
        return "test run", base
    if "ppx" in base:
        return "preprocessor", base
    return "other", base


def _timing(value: Sexp) -> tuple[int, int] | None:
    """(start, duration) in nanoseconds from a `(start duration)` pair."""
    if isinstance(value, list) and len(value) == 2:
        start, duration = value
        if isinstance(start, str) and isinstance(duration, str):
            try:
                return int(start), int(duration)
            except ValueError:
                return None
    return None


def processes(records: list[Sexp]) -> list[Process]:
    found: list[Process] = []
    for record in records:
        if not (isinstance(record, list) and len(record) > 2
                and record[0] == "process" and record[1] == "finish"):
            continue
        timing = _timing(record[2])
        prog = _field(record, "prog")
        if timing is None or not isinstance(prog, str):
            continue
        kind, name = classify(prog, _strings(_field(record, "process_args")),
                              _strings(_field(record, "target_files")))
        found.append(Process(kind, name, timing[0], timing[1]))
    return found


def summarise(records: list[Sexp]) -> dict[str, object]:
    found = processes(records)
    wall = ((max(p.start_ns + p.duration_ns for p in found) - min(p.start_ns for p in found))
            / NANOSECONDS if found else 0.0)
    kinds: dict[str, dict[str, object]] = {}
    for kind in sorted({p.kind for p in found}):
        mine = sorted((p for p in found if p.kind == kind), key=lambda p: -p.seconds)
        kinds[kind] = {
            "processes": len(mine),
            "seconds": round(sum(p.seconds for p in mine), 1),
            "slowest": [[p.name, round(p.seconds, 1)] for p in mine[:SLOWEST_PER_KIND]],
        }
    return {"wall_seconds": round(wall, 1), "kinds": kinds}


def main() -> int:
    parser = argparse.ArgumentParser(description="Summarise a dune --trace-file run.")
    parser.add_argument("trace")
    parser.add_argument("--out", required=True, help="where the JSON summary is written")
    args = parser.parse_args()
    with open(args.trace, "rb") as handle:
        summary = summarise(parse_stream(handle.read()))
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(summary, handle, indent=1)
    kinds = summary["kinds"]
    assert isinstance(kinds, dict)
    print(f"[test-suite] dune processes over {summary['wall_seconds']}s of wall time "
          "(seconds are summed across parallel jobs):")
    for kind, row in sorted(kinds.items(), key=lambda item: -item[1]["seconds"]):
        print(f"  {kind:16} {row['processes']:6} processes {row['seconds']:10.1f}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
