#!/usr/bin/env python3
"""Compare complete frozen appraiser runs without assigning an acceptance score."""
import argparse
from collections import Counter
from fractions import Fraction
import hashlib
import json
from pathlib import Path


def require(condition, message):
    if not condition:
        raise ValueError(message)


def load_run(directory):
    plan = json.loads((directory / "plan.json").read_text())
    cases_raw = (directory / "cases.json").read_bytes()
    require((hashlib.sha256(cases_raw).hexdigest() == plan["cases_sha256"]), 'validation failed: hashlib.sha256(cases_raw).hexdigest() == plan["cases_sha256"]')
    cases = {case["id"]: case for case in json.loads(cases_raw)}
    raw = (directory / "results.jsonl").read_bytes()
    require((raw.endswith(b"\n")), "partial result line")
    rows = [json.loads(line) for line in raw.splitlines()]
    require((len(rows) == plan["planned_calls"]), "wait for the entire frozen run")
    pairs = {(row["case_id"], row["trial"]) for row in rows}
    require((pairs == {(case_id, trial) for case_id in cases for trial in range(1, plan["trials"] + 1)}), 'validation failed: pairs == {(case_id, trial) for case_id in cases for trial in range(1, plan["trials"] + 1)}')
    require((len(pairs) == len(rows)), "duplicate case/trial")
    require((len({row["receipt"]["run_id"] for row in rows}) == len(rows)), 'validation failed: len({row["receipt"]["run_id"] for row in rows}) == len(rows)')
    metadata = json.loads((directory / "metadata.json").read_text())
    require((metadata["plan"] == plan), 'validation failed: metadata["plan"] == plan')
    require((metadata["build"]["commit"] == plan["source_commit"]), 'validation failed: metadata["build"]["commit"] == plan["source_commit"]')
    require((json.loads((directory / "exit.json").read_text())["exit_code"] == 0), 'validation failed: json.loads((directory / "exit.json").read_text())["exit_code"] == 0')
    summaries = {}
    for case_id, case in cases.items():
        selected = [row for row in rows if row["case_id"] == case_id]
        require((all(row["stage"] == case["stage"] for row in selected)), 'validation failed: all(row["stage"] == case["stage"] for row in selected)')
        valid = [row for row in selected if row["status"] == "ok"]
        tally = {"statuses": dict(Counter(row["status"] for row in selected))}
        if case["stage"] == "weights":
            comparison = case["comparison"]
            contributor = comparison["candidate_keeper"] if comparison else case["input"]["keepers"][0]
            ratios = [Fraction(row["answer"]["weights"][contributor], sum(row["answer"]["weights"].values())) for row in valid]
            counts = Counter(str(ratio) for ratio in ratios)
            tally.update({"contributor": contributor, "share_counts": dict(sorted(counts.items())),
                          "mean_share_exact": str(sum(ratios, Fraction()) / len(ratios)) if ratios else None})
        else:
            counts = Counter(row["answer"][case["stage"]] for row in valid)
            tally["answers"] = dict(sorted(counts.items()))
        tally["modes"] = sorted(value for value, count in counts.items() if count == max(counts.values())) if counts else []
        tally["modal_count"] = max(counts.values()) if counts else 0
        summaries[case_id] = tally
    return plan, metadata, summaries, hashlib.sha256(raw).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    args = parser.parse_args()
    baseline, base_meta, base_cases, base_hash = load_run(args.baseline)
    candidate, candidate_meta, candidate_cases, candidate_hash = load_run(args.candidate)
    require(({key: value for key, value in baseline.items() if key != "prompt_sha256"} == {
        key: value for key, value in candidate.items() if key != "prompt_sha256"}), 'validation failed: {key: value for key, value in baseline.items() if key != "prompt_sha256"} == {\n        key: value for key, value in candidate.items() if key != "prompt_sha256"}')
    require((base_meta["build"]["executable_sha256"] == candidate_meta["build"]["executable_sha256"]), 'validation failed: base_meta["build"]["executable_sha256"] == candidate_meta["build"]["executable_sha256"]')
    changed = [name for name in baseline["prompt_sha256"] if baseline["prompt_sha256"][name] != candidate["prompt_sha256"][name]]
    require((changed == ["candle_appraiser_grade.md"]), "only the reviewed Grade prompt may change")
    prompt_source = json.loads((args.candidate / "prompt-source.json").read_text())
    require((prompt_source["binary_commit"] == candidate["source_commit"]), 'validation failed: prompt_source["binary_commit"] == candidate["source_commit"]')
    require((prompt_source["prompt_sha256"] == candidate["prompt_sha256"]), 'validation failed: prompt_source["prompt_sha256"] == candidate["prompt_sha256"]')
    print(json.dumps({
        "scope": "Complete same-corpus measurements, not an acceptance or calibration verdict",
        "binary_commit": baseline["source_commit"], "prompt_commit": prompt_source["prompt_commit"],
        "runtime_id": baseline["runtime_id"], "calls_each": baseline["planned_calls"],
        "cases_sha256": baseline["cases_sha256"], "runtime_config_sha256": baseline["runtime_config_sha256"],
        "changed_prompt_files": changed,
        "baseline_results_sha256": base_hash, "candidate_results_sha256": candidate_hash,
        "calibration": baseline["calibration"],
        "cases": {case_id: {"baseline": base_cases[case_id], "candidate": candidate_cases[case_id]} for case_id in base_cases},
        "acceptance": "Operator thresholds are unset; no global PASS is inferred."
    }, indent=2))


if __name__ == "__main__":
    main()
