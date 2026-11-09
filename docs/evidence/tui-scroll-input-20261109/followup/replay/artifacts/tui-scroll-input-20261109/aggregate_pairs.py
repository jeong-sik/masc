#!/usr/bin/env python3
"""Summarize the retained native observations without dropping failed runs."""
import argparse
import collections
import hashlib
import json
from pathlib import Path
import statistics


def stats(xs):
    if not xs:
        return None
    ys = sorted(xs)
    return {"n": len(ys), "p50": statistics.median(ys),
            "p95": ys[int((len(ys)-1)*.95)], "p99": ys[int((len(ys)-1)*.99)],
            "max": max(ys), "mean": statistics.mean(ys)}


def gaps(sends, name):
    at = [s["at"] for s in sends if s["name"] == name]
    return stats([(b-a)*1000 for a,b in zip(at, at[1:])])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument("--pairs", type=int, default=5)
    parser.add_argument("--conditions", nargs="+", default=["typing","pageup","pagedown","wheelup","wheeldown"])
    a = parser.parse_args()
    order = json.loads((a.root / "order.json").read_text())
    expected = {(pair,label,c) for pair in range(a.pairs) for label in ("before","after") for c in a.conditions}
    found = [(e["pair"],e["label"],e["condition"]) for e in order]
    errors = []
    if len(found) != len(expected) or set(found) != expected:
        errors.append("cohort missing, duplicated or unexpected entries")
    rows = []
    grouped = collections.defaultdict(list)
    identities = collections.defaultdict(set)
    for e in order:
        path = Path(e["result"])
        raw = path.read_bytes()
        r = json.loads(raw)
        identity = e["label"],e["condition"]
        typed = r["records"][1:]
        latencies = [(x["ack_at"]-x["sent_at"])*1000 for x in typed if x["ack_at"] is not None]
        problems = list(r["errors"])
        if not r["observation"]["complete"]:
            problems.append("observation incomplete")
        if r["unacknowledged"] or len(typed) != 32 or len(latencies) != 32:
            problems.append("missing or unexpected typing sample count")
        if r["exe_sha256_before"] != r["exe_sha256"]:
            problems.append("executable changed")
        if any(x < 0 for x in latencies):
            problems.append("negative causal latency")
        if problems:
            errors.append({"run":path.as_posix(),"problems":problems})
        grouped[identity].extend(latencies)
        identities[e["label"]].add(r["exe_sha256"])
        identities["history"].add(r["history_sha256"])
        identities["probe"].add(r["probe_sha256"])
        row = {"pair":e["pair"],"label":e["label"],"condition":e["condition"],
               "result":path.as_posix(),"result_sha256":hashlib.sha256(raw).hexdigest(),
               "latency_ms":stats(latencies),"errors":problems,
               "cpu_lifecycle_s":r["child_cpu_user_s"]+r["child_cpu_system_s"],
               "load_before":r["load_before"],"load_after":r["load_after"],
               "typing_gap_ms":gaps(r["sends"],"type"),
               "scroll_gap_ms":gaps(r["sends"],e["condition"]),
               "scroll_writes":sum(s["name"]==e["condition"] for s in r["sends"])}
        rows.append(row)
    if any(len(v) != 1 for v in identities.values()):
        errors.append("binary, history or probe identity changed within a label/cohort")
    comparisons = {}
    for c in a.conditions:
        pairs = []
        for i in range(a.pairs):
            before = next((r for r in rows if (r["pair"],r["label"],r["condition"])==(i,"before",c)),None)
            after = next((r for r in rows if (r["pair"],r["label"],r["condition"])==(i,"after",c)),None)
            if before is None or after is None:
                continue
            pairs.append({"pair":i,"before_p95_ms":before["latency_ms"]["p95"],
                          "after_p95_ms":after["latency_ms"]["p95"],
                          "p95_delta_ms":after["latency_ms"]["p95"]-before["latency_ms"]["p95"],
                          "cpu_delta_s":after["cpu_lifecycle_s"]-before["cpu_lifecycle_s"]})
        comparisons[c] = {"pooled_descriptive_ms":{label:stats(grouped[(label,c)]) for label in ("before","after")},
                          "pairs":pairs,"p95_decreased_pairs":sum(p["p95_delta_ms"]<0 for p in pairs),
                          "median_paired_p95_delta_ms":statistics.median(p["p95_delta_ms"] for p in pairs) if pairs else None,
                          "cpu_decreased_pairs":sum(p["cpu_delta_s"]<0 for p in pairs)}
    result = {"scope":"PTY input write to causal draft prefix emission, not physical terminal paint; typing samples within each run are correlated",
              "expected_runs":len(expected),"observed_runs":len(order),"complete":not errors,
              "errors":errors,"identities":{k:sorted(v) for k,v in identities.items()},
              "comparisons":comparisons,"runs":rows}
    output = a.root / "paired-summary.json"
    with output.open("x") as f:
        json.dump(result,f,indent=2)
    print(json.dumps({"root":a.root.as_posix(),"complete":result["complete"],"errors":errors}))
    for c,v in comparisons.items():
        print(c,json.dumps({"pooled_p95_ms":{k:round(x["p95"],2) if x else None for k,x in v["pooled_descriptive_ms"].items()},
                            "p95_decreased_pairs":v["p95_decreased_pairs"],
                            "median_paired_p95_delta_ms":round(v["median_paired_p95_delta_ms"],2) if v["median_paired_p95_delta_ms"] is not None else None,
                            "cpu_decreased_pairs":v["cpu_decreased_pairs"]}))


if __name__ == "__main__":
    main()
