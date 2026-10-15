#!/usr/bin/env python3
"""One actual coordinator -> two driver processes -> Keeper protocol scenario."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import subprocess
import sys
import tempfile


def read(path):
    return json.loads(path.read_text(encoding="utf-8"))


def require(value, detail):
    if not value:
        raise AssertionError(detail)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--driver", type=Path, required=True)
    parser.add_argument("--coordinator", type=Path, required=True)
    parser.add_argument("--prompts", type=Path, required=True)
    parser.add_argument("--repository-root", type=Path, required=True)
    parser.add_argument("--model-id", required=True)
    parser.add_argument("--max-context-tokens", type=int, required=True)
    parser.add_argument("--max-output-tokens", type=int, required=True)
    args = parser.parse_args()
    # This is source identity, not a claim that an external binary was built
    # from it. The actual driver SHA is independently recorded by coordinator.
    head = subprocess.check_output(["git", "-C", str(args.repository_root.resolve()),
                                    "rev-parse", "HEAD"], text=True).strip()
    root = Path(tempfile.mkdtemp(prefix="masc-preparation-functional-")).resolve()
    experiment = root / "explicit-synthetic-experiment.json"
    experiment.write_text(json.dumps({"schema_version": 1, "case": "upstream_inline", "pairs": 1,
        "runtime": {"mode": "synthetic_streaming", "model_id": args.model_id,
                    "max_context_tokens": args.max_context_tokens, "max_output_tokens": args.max_output_tokens},
        "synthetic_outcome": "success"}) + "\n", encoding="utf-8")
    output = root / "trial"
    code = subprocess.run([sys.executable, str(args.coordinator.resolve()),
        "--driver", str(args.driver.resolve()), "--source-head", head,
        "--experiment", str(experiment), "--prompts", str(args.prompts.resolve()),
        "--output", str(output)], check=False).returncode
    require(code == 0, f"actual coordinator failed; preserved evidence: {root}")
    manifest, summary = read(output / "manifest.json"), read(output / "summary.json")
    require(len(manifest["expected_attempts"]) == 2 and summary["expected"] == 2,
            "both preallocated arms must remain in denominator")
    require(summary["outcomes"] == {"correct": 2, "explicit_failure": 0, "unfinished": 0},
            f"actual paired objective did not finish: {summary}; evidence: {root}")
    require(summary["strategy_compliant"] == 2, "actual execution ignored an assigned strategy")
    require(summary["speedup"] is None and summary["latency_percentiles"] is None,
            "synthetic protocol case must not manufacture speedup")
    require({entry["strategy"] for entry in manifest["expected_attempts"]} == {"direct", "exact_skill"},
            "assigned arms changed")
    receipts = []
    for entry in manifest["expected_attempts"]:
        receipt_path = output / entry["path"]
        receipt = read(receipt_path)
        directory = receipt_path.parent
        admission = read(directory / "admission.json")
        turn = read(directory / "turn-record.json")
        accepted = read(directory / "accepted-final-answer.json")
        require(accepted["source"] == "TurnRecord_exact_raw_run" and
                accepted["turn_ref"] == turn["turn_ref"] and
                accepted["raw_trace_run_ref"] == turn["raw_trace_run_ref"],
                "final answer was not read from this exact canonical run")
        require(json.loads(accepted["final_text"]) == receipt["objective"],
                "persisted run final answer differs from the independently checked objective")
        useful = receipt["timing"]["first_useful_leaf"]
        require(receipt["strategy"] == entry["strategy"] and receipt["source_ack"] is True,
                "receipt does not belong to the assigned admitted source")
        require(receipt["remaining_queue"] == 0 and receipt["backend_calls_after_ready"] == 0,
                "setup source or backend work contaminated measured turn")
        require(useful["state"] == "observed", "successful first useful leaf needs real physical join")
        require(useful["execution_id"] in turn["execution_ids"], "leaf execution is outside actual turn")
        require(useful["trace_id"] == turn["trace_id"] and useful["keeper_turn_id"] == turn["absolute_turn"],
                "leaf trace/turn identity differs from canonical turn")
        require(useful["task_id"] == read(output / f"pair-{entry['pair']:04d}" / "base" /
                "preparation-fixture.json")["task_id"], "leaf lost original Task")
        require(isinstance(useful["sdk_turn"], int) and isinstance(useful["planned_index"], int),
                "actual SDK occurrence coordinates were not observed")
        require(useful["execution_mode"] == "concurrent", "ordinary readonly baseline was forced serial")
        require(admission["source_snapshot_ref"] and admission["stimulus_id"] and admission["admitted_revision"],
                "canonical admission identity was not joined")
        require(isinstance(admission["first_admitted_at"], (float, int)) and
                math.isfinite(admission["first_admitted_at"]), "durable admission clock is unknown")
        start, end = admission["enqueue_entered"]["monotonic_ns"], useful["observed"]["monotonic_ns"]
        require(math.isfinite(start) and math.isfinite(end) and end >= start,
                "within-process admission/useful observations regress")
        require(read(directory / "process.json")["returncode"] == 0, "driver did not finish cleanly")
        activations = read(directory / "skill-activations.json")
        require(len(activations) == (0 if entry["strategy"] == "direct" else 1),
                "actual exact Skill admission differs from assigned arm")
        calls = read(directory / "tool-calls.json")
        useful_rows = [row for row in calls if row.get("execution_id") == useful["execution_id"]]
        require(len(useful_rows) == 1 and useful_rows[0]["tool"] == "keeper_artifact_read",
                "successful useful action was fabricated from an outer completion")
        require(useful_rows[0]["input"]["sha256"] == receipt["input"]["_blob"]["sha256"],
                "first useful leaf read a different immutable input")
        bodies = sorted(directory.glob("provider-request-*.json"))
        require(len(bodies) == receipt["provider_requests"] and len(bodies) > 1,
                "actual streaming provider loop was not crossed")
        require(all(read(path)["stream"] is True and read(path)["model"] == args.model_id for path in bodies),
                "model/streaming settings differ from explicit fixture")
        receipts.append(receipt)
        print("PREPARATION_FUNCTIONAL_RECEIPT " + json.dumps({
            "synthetic_only": True, "strategy": receipt["strategy"], "source": admission,
            "useful": useful, "objective": receipt["objective"], "turn_ref": receipt["turn_ref"],
            "backend_calls_after_ready": 0, "driver_sha256": manifest["driver_sha256"]}, ensure_ascii=False))
    for field in ("fixture_sha256", "skill_reference", "input", "runtime", "first_offered_tools_sha256", "objective"):
        require(receipts[0][field] == receipts[1][field], "paired common identity differs: " + field)
    require(receipts[0]["timing"]["admission"]["stimulus_id"] != receipts[1]["timing"]["admission"]["stimulus_id"],
            "second arm reused first arm's measured source")
    print("PREPARATION_FUNCTIONAL_PASS " + json.dumps({"case": "upstream_inline", "expected": 2,
        "correct": 2, "unfinished": 0, "real_model": False, "speedup": None,
        "evidence": str(root), "summary_sha256": hashlib.sha256((output / "summary.json").read_bytes()).hexdigest()}))


if __name__ == "__main__":
    main()
