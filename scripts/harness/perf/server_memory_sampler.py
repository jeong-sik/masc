#!/usr/bin/env python3
"""Sample a masc server's memory from /health once per interval.

Each row keeps what /health reports under `process_memory` (resident bytes from
mach_task_info or /proc) and `gc` (Gc.quick_stat counters). The word counters
are cumulative since process start, so two rows give the allocation between
them: minor_words + major_words - promoted_words (promoted words are counted
in both). One word is 8 bytes on the 64-bit builds masc ships.

The sampler only reads /health. It does not start, stop or authenticate to the
server, so it can watch an owned harness server or the operator's live one.
Run alone it prints a summary and writes every row:

    server_memory_sampler.py --port 8935 --duration 600 --output memory.json
"""
import argparse
import http.client
import json
import math
from pathlib import Path
import threading
import time

WORD_BYTES = 8


def allocated_words(gc):
    return gc["minor_words"] + gc["major_words"] - gc["promoted_words"]


def read_health(port, timeout):
    client = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    try:
        client.request("GET", "/health", headers={"Accept": "application/json"})
        response = client.getresponse()
        body = response.read()
    finally:
        client.close()
    if response.status != 200:
        raise ValueError(f"/health answered {response.status}")
    return json.loads(body)


def row_of_health(health, phase, wall_ns, wire_ms):
    gc = health["gc"]
    memory = health["process_memory"]
    resident = memory.get("resident_bytes")
    return {"wall_ns": wall_ns, "phase": phase, "wire_ms": wire_ms,
            "pid": memory.get("pid"),
            "resident_bytes": None if resident is None else int(resident),
            "resident_source": memory.get("source"),
            "live_bytes": gc["live_words"] * WORD_BYTES,
            "heap_bytes": gc["heap_words"] * WORD_BYTES,
            "allocated_bytes": allocated_words(gc) * WORD_BYTES,
            "minor_collections": gc["minor_collections"],
            "major_collections": gc["major_collections"]}


class Sampler:
    """Background /health reader. `phase` is read on every sample, so the
    caller labels rows by assigning it."""

    def __init__(self, port, interval, timeout):
        self.port, self.interval, self.timeout = port, interval, timeout
        self.phase = "starting"
        self.rows, self.failures = [], []
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)

    def _run(self):
        while not self.stop.is_set():
            phase = self.phase
            wall_ns = time.time_ns()
            started = time.perf_counter_ns()
            try:
                health = read_health(self.port, self.timeout)
                wire_ms = (time.perf_counter_ns() - started) / 1e6
                self.rows.append(row_of_health(health, phase, wall_ns, wire_ms))
            except (OSError, http.client.HTTPException, ValueError, KeyError) as error:
                self.failures.append({"wall_ns": wall_ns, "phase": phase,
                                      "error": type(error).__name__, "detail": str(error)})
            self.stop.wait(self.interval)

    def start(self):
        self.thread.start()
        return self

    def finish(self):
        self.stop.set()
        self.thread.join(timeout=self.timeout + self.interval + 1)
        return not self.thread.is_alive()


def rates(rows):
    """Allocation rate between consecutive rows of one process, bytes/s.
    A pid change (server restart) starts a new series instead of producing a
    negative delta."""
    out = []
    for before, after in zip(rows, rows[1:]):
        if before["pid"] != after["pid"]:
            continue
        seconds = (after["wall_ns"] - before["wall_ns"]) / 1e9
        if seconds <= 0:
            continue
        out.append({"phase": after["phase"], "wall_ns": after["wall_ns"],
                    "allocated_bytes_per_s": (after["allocated_bytes"] - before["allocated_bytes"]) / seconds})
    return out


def percentile(sorted_values, fraction):
    if not sorted_values:
        return None
    return sorted_values[math.ceil(fraction * len(sorted_values)) - 1]


def summary(rows, failures):
    by_phase = {}
    rate_rows = rates(rows)
    for phase in dict.fromkeys(row["phase"] for row in rows):
        selected = [row for row in rows if row["phase"] == phase]
        resident = sorted(row["resident_bytes"] for row in selected if row["resident_bytes"] is not None)
        live = sorted(row["live_bytes"] for row in selected)
        phase_rates = sorted(row["allocated_bytes_per_s"] for row in rate_rows if row["phase"] == phase)
        by_phase[phase] = {"samples": len(selected),
                           "resident_max_bytes": resident[-1] if resident else None,
                           "live_max_bytes": live[-1] if live else None,
                           "live_p50_bytes": percentile(live, .5),
                           "heap_max_bytes": max(row["heap_bytes"] for row in selected),
                           "allocated_bytes_per_s_p50": percentile(phase_rates, .5),
                           "allocated_bytes_per_s_max": phase_rates[-1] if phase_rates else None}
    resident_all = [row["resident_bytes"] for row in rows if row["resident_bytes"] is not None]
    return {"samples": len(rows), "failures": len(failures),
            "pids": sorted({row["pid"] for row in rows if row["pid"] is not None}),
            "resident_max_bytes": max(resident_all) if resident_all else None,
            "live_max_bytes": max((row["live_bytes"] for row in rows), default=None),
            "by_phase": by_phase,
            "scope": "Gc.quick_stat and process resident size as /health reports them. live_words is "
                     "the runtime's figure from its last major cycle, not a heap walk."}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--duration", type=float, required=True, help="seconds to sample")
    parser.add_argument("--interval", type=float, default=1.0)
    parser.add_argument("--timeout", type=float, default=10.0)
    parser.add_argument("--label", default="observed", help="phase label for every row")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        parser.error(f"{args.output} exists; choose a new path")
    sampler = Sampler(args.port, args.interval, args.timeout)
    sampler.phase = args.label
    sampler.start()
    time.sleep(args.duration)
    stopped = sampler.finish()
    result = {"port": args.port, "interval_s": args.interval, "duration_s": args.duration,
              "sampler_stopped": stopped, "summary": summary(sampler.rows, sampler.failures),
              "rows": sampler.rows, "failures": sampler.failures}
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(result["summary"], indent=2))


if __name__ == "__main__":
    main()
