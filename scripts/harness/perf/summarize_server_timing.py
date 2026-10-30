"""Reanalyse retained server comparison receipts without starting a server.

This accepts the emitted Server-Timing dialect (token;dur=milliseconds), not
arbitrary HTTP headers. Archive hashes and receipt coverage are checked here;
the original comparison's provenance and semantic validator remain required.
"""
import argparse
from collections import Counter, defaultdict
import gzip
import hashlib
import json
import math
from pathlib import Path
import re
import statistics
import tarfile


def require(condition, message):
    if not condition:
        raise ValueError(message)


def timing_metrics(header):
    if header is None:
        return {}
    require(isinstance(header, str) and header, "invalid timing header")
    metrics = {}
    for part in header.split(","):
        match = re.fullmatch(r"([A-Za-z0-9_.-]+);dur=([0-9]+(?:\.[0-9]+)?)", part.strip())
        require(match is not None, "unexpected Server-Timing dialect: " + part)
        name, value = match.groups()
        duration = float(value)
        require(name not in metrics and math.isfinite(duration), "duplicate/nonfinite timing")
        metrics[name] = duration
    return metrics


def distribution(values):
    ordered = sorted(values)
    return {"n": len(ordered), "min_ms": ordered[0],
            "median_ms": statistics.median(ordered),
            "p95_ms": ordered[math.ceil(.95 * len(ordered)) - 1], "max_ms": ordered[-1]}


def analyse(evidence):
    archive_path = evidence / "raw.tar.gz"
    manifest = json.loads((evidence / "raw-files.json").read_text())
    plan = json.loads((evidence / "plan.json").read_text())
    rows_by_session = {}
    with tarfile.open(archive_path, "r:gz") as archive:
        members = archive.getmembers()
        require(len(members) == len(manifest) and {m.name for m in members} == set(manifest),
                "archive membership differs from manifest")
        for member in members:
            require(member.isfile(), "archive contains a non-file")
            raw = archive.extractfile(member).read()  # Never extract paths to disk.
            require(hashlib.sha256(raw).hexdigest() == manifest[member.name],
                    "archive member hash differs: " + member.name)
            if member.name.endswith("/requests.jsonl.gz"):
                name = member.name.removeprefix("raw/").removesuffix("/requests.jsonl.gz")
                rows_by_session[name] = [json.loads(line) for line in gzip.decompress(raw).splitlines()]
    sessions = plan["sessions"]
    require(len({s["name"] for s in sessions}) == len(sessions)
            and set(rows_by_session) == {s["name"] for s in sessions}, "session coverage differs")
    cycle_phases = ("mutation", "cold", "warm", "concurrent_mutation", "concurrent_liveness")
    counts = {phase: plan["cycles"] for phase in cycle_phases}
    counts.update(initialize=1, registry=1, seed=math.ceil(plan["tasks"] / 20), prime=1)
    samples, grouped, coverage = [], defaultdict(list), Counter()
    for session in sessions:
        rows = rows_by_session[session["name"]]
        require(Counter(r["phase"] for r in rows) == counts, "incomplete receipt phases")
        for phase in cycle_phases:
            require(sorted(r["cycle"] for r in rows if r["phase"] == phase)
                    == list(range(1, plan["cycles"] + 1)), "incomplete/duplicate cycle IDs")
        for ordinal, row in enumerate(rows):
            require(row["status"] == 200, "unsuccessful response")
            expected_encoding = session["encoding"] if row["phase"] in ("prime", "cold", "warm") else "identity"
            require(row["requested_encoding"] == expected_encoding, "request encoding differs")
            actual_encoding = row["encoding"] or "identity"
            require(actual_encoding in ("identity", "gzip"), "unknown response encoding")
            require(row["end_ns"] >= row["start_ns"] and math.isclose(
                row["wire_ms"], (row["end_ns"] - row["start_ns"]) / 1e6, abs_tol=1e-9),
                "request interval differs")
            metrics = timing_metrics(row["server_timing"])
            coverage[(row["phase"], tuple(sorted(metrics)))] += 1
            values = {"client." + field: row[field] for field in ("wire_ms", "headers_ms", "body_read_ms")}
            values.update({"server." + k: v for k, v in metrics.items()})
            require(all(type(v) in (int, float) and math.isfinite(v) and v >= 0 for v in values.values()),
                    "invalid duration")
            sample = {"session": session["name"], "receipt_ordinal": ordinal,
                      "role": session["role"], "repetition": session["repetition"],
                      "text_kind": session["text_kind"], "phase": row["phase"], "cycle": row["cycle"],
                      "requested_encoding": session["encoding"], "request_accept_encoding": expected_encoding,
                      "actual_encoding": actual_encoding,
                      "server_timing": row["server_timing"], "durations_ms": values}
            samples.append(sample)
            # Keep requested and actual encoding separate. Pool only repetitions
            # of the same cell; retain every repetition and every raw observation.
            for repetition in (session["repetition"], "pooled_repetitions"):
                for metric, value in values.items():
                    key = (session["text_kind"], session["encoding"], actual_encoding,
                           session["role"], row["phase"], repetition, metric)
                    grouped[key].append(value)
    fields = ("text_kind", "requested_encoding", "actual_encoding", "role", "phase", "repetition", "metric")
    return {"archive_sha256": hashlib.sha256(archive_path.read_bytes()).hexdigest(),
            "verified_archive_members": len(manifest), "session_count": len(sessions),
            "receipt_count": len(samples), "tasks": plan["tasks"], "workers": plan["workers"],
            "scope": "Offline attribution of existing wall-clock receipts; no new runtime measurement. "
                     "Server spans may nest; do not sum arbitrary metrics or infer CPU time. "
                     "Missing spans are absent, not zero. Original provenance/semantic audit is separate.",
            "p95_definition": "nearest rank ceil(0.95*n), without outlier exclusion",
            "coverage": [{"phase": phase, "metrics": list(metrics), "n": n}
                         for (phase, metrics), n in sorted(coverage.items())],
            "groups": [{**dict(zip(fields, key)), **distribution(values)}
                       for key, values in sorted(grouped.items(), key=lambda item: str(item[0]))],
            "samples": samples}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = analyse(args.evidence)
    with args.output.open("x") as output:
        json.dump(result, output, indent=2)
        output.write("\n")
    print(json.dumps({key: result[key] for key in (
        "archive_sha256", "verified_archive_members", "session_count", "receipt_count")}))


if __name__ == "__main__":
    main()
