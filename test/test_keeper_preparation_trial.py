#!/usr/bin/env python3
"""One actual coordinator -> two driver processes -> Keeper protocol scenario."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import subprocess
import sys
import tempfile
import threading


def read(path):
    return json.loads(path.read_text(encoding="utf-8"))


def require(value, detail):
    if not value:
        raise AssertionError(detail)


def check_http_observation(directory, receipt, received, *, refused=False):
    metrics = receipt["http_metrics"]
    path = directory / "http-events.jsonl"
    events = [json.loads(line) for line in path.read_text().splitlines()]
    require(metrics["coverage"] == "complete" and metrics["delivery_failures"] == 0 and
            metrics["events_sha256"] == hashlib.sha256(path.read_bytes()).hexdigest(),
            "HTTP facts were incomplete or not durably retained")
    calls = {}
    for event in events:
        calls.setdefault(event["call_id"], []).append(event)
    entered = [rows[0] for rows in calls.values()]
    require(all([event["phase"] for event in rows] == ["client_entered", "dispatch_entered",
                "response_headers_received", "client_finished"] and
                rows[2]["status"] == (400 if refused else 200) and
                rows[-1]["completion"] == ("returned_error" if refused else "returned_ok")
                for rows in calls.values()), "HTTP dispatch/header/return ownership differs")
    require(sorted((row["body_bytes"], row["body_sha256"]) for row in entered) ==
            sorted((row["body_bytes"], row["body_sha256"]) for row in received),
            "native submitted body metadata differs from actual independently received bytes")
    require(all(metrics[key] == len(received) for key in
                ("calls_entered", "dispatch_entries", "response_headers_received")) and
            metrics["serialized_body_bytes"] == sum(row["body_bytes"] for row in received) and
            metrics["dispatched_body_bytes"] == metrics["serialized_body_bytes"],
            "complete native request/input counts disagree with the independent peer")


def configured_http_refusal(args, root, head):
    """A separate HTTP peer exercises operator Runtime binding, without a model."""
    output = root / "configured-http-refusal"
    requests = []

    class Refusal(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_POST(self):
            raw = self.rfile.read(int(self.headers["Content-Length"]))
            body = json.loads(raw)
            active = []
            for strategy in ("direct", "exact_skill"):
                directory = output / "pair-0000" / strategy
                receipt = directory / "attempt.json"
                if receipt.exists() and not (directory / "process.json").exists():
                    value = read(receipt)
                    if value.get("mode") == "run":
                        active.append(strategy)
            requests.append({"model": body.get("model"), "stream": body.get("stream"),
                             "body_bytes": len(raw), "body_sha256": hashlib.sha256(raw).hexdigest(),
                             "messages_present": bool(body.get("messages")), "active": active,
                             "auth_matches_fixture": self.headers.get("Authorization") == "Bearer isolated-http-fixture"})
            response = b'{"error":{"type":"invalid_request_error","message":"Declared external fixture refusal"}}'
            self.send_response(400)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(response)))
            self.end_headers()
            self.wfile.write(response)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Refusal)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    try:
        experiment = root / "configured-http-experiment.json"
        configuration = f'''[runtime]
default = "preparation_http.sample"
[providers.preparation_http]
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:{server.server_port}"
credentials = {{ type = "env", key = "OPENAI_API_KEY" }}
[models.sample]
api-name = "preparation-http-refusal-fixture"
max-context = 128000
tools-support = true
streaming = true
[models.sample.capabilities]
max-output-tokens = 4096
[preparation_http.sample]
'''
        experiment.write_text(json.dumps({"schema_version": 1, "case": "upstream_inline", "pairs": 1,
            "runtime": {"mode": "configured_http", "configuration": configuration}}) + "\n", encoding="utf-8")
        environment = dict(os.environ, OPENAI_API_KEY="isolated-http-fixture")
        code = subprocess.run([sys.executable, str(args.coordinator.resolve()),
            "--driver", str(args.driver.resolve()), "--source-head", head,
            "--experiment", str(experiment), "--prompts", str(args.prompts.resolve()),
            "--output", str(output)], env=environment, check=False).returncode
        require(code == 0, f"HTTP refusal coordinator failed; evidence: {root}")
        summary, manifest = read(output / "summary.json"), read(output / "manifest.json")
        require(summary["expected"] == 2 and summary["outcomes"] == {
            "correct": 0, "explicit_failure": 2, "unfinished": 0},
            f"external HTTP refusals disappeared from denominator: {summary}")
        require(summary["synthetic_only"] is False and manifest["claims"]["real_model"] is None and
                summary["speedup"] is None, "configured transport was relabelled as real-model proof")
        require({arm for request in requests for arm in request["active"]} == {"direct", "exact_skill"},
                "both actual configured Runtime arms must cross the external HTTP boundary")
        require(all(request["model"] == "preparation-http-refusal-fixture" and request["stream"] is True and
                    request["messages_present"] and request["auth_matches_fixture"] for request in requests),
                "Runtime did not bind the explicit model/streaming/environment credential")
        for attempt in manifest["expected_attempts"]:
            directory = (output / attempt["path"]).parent
            require(read(directory / "process.json")["returncode"] != 0,
                    "HTTP refusal was converted to success")
            received = [request for request in requests if request["active"] == [attempt["strategy"]]]
            check_http_observation(directory, read(output / attempt["path"]), received, refused=True)
        print("PREPARATION_CONFIGURED_HTTP_REFUSAL_PASS " + json.dumps({
            "expected": 2, "explicit_failure": 2, "unfinished": 0,
            "external_fixture_requests": requests, "real_model": False, "speedup": None}))
    finally:
        server.shutdown()
        server.server_close()
        worker.join()


def malformed_final_evidence(args, root, head):
    experiment = root / "malformed-final-experiment.json"
    experiment.write_text(json.dumps({"schema_version": 1, "case": "upstream_inline", "pairs": 1,
        "runtime": {"mode": "synthetic_streaming", "model_id": args.model_id,
                    "max_context_tokens": args.max_context_tokens, "max_output_tokens": args.max_output_tokens},
        "synthetic_outcome": "malformed_final"}) + "\n", encoding="utf-8")
    output = root / "malformed-final"
    code = subprocess.run([sys.executable, str(args.coordinator.resolve()),
        "--driver", str(args.driver.resolve()), "--source-head", head,
        "--experiment", str(experiment), "--prompts", str(args.prompts.resolve()),
        "--output", str(output)], check=False).returncode
    require(code == 0, f"malformed-final coordinator failed; evidence: {root}")
    summary, manifest = read(output / "summary.json"), read(output / "manifest.json")
    require(summary["expected"] == 2 and summary["outcomes"] == {
        "correct": 0, "explicit_failure": 2, "unfinished": 0},
        "a prose final containing the correct JSON must remain a failed attempt")
    instructions = []
    for entry in manifest["expected_attempts"]:
        receipt = read(output / entry["path"])
        timing = receipt["timing"]
        require(receipt["objective_validation"] == "malformed_json" and receipt["objective"] is None,
                "invalid final was extracted or quietly accepted")
        require(receipt["source_ack"] is True and receipt["strategy_compliant"] is True and
                receipt["verified_stdout_read_execution_ids"] and receipt["backend_calls_after_ready"] == 0,
                "failure lost independently verified original source and physical work")
        require(timing["first_useful_leaf"]["state"] == "observed" and
                timing["cycle_returned"]["monotonic_ns"] >= timing["cycle_entered"]["monotonic_ns"] and
                timing["validation_finished"]["monotonic_ns"] >= timing["cycle_returned"]["monotonic_ns"],
                "failed attempt lost its actual measurement clocks")
        turn = read((output / entry["path"]).parent / "turn-record.json")
        usage = receipt["provider_metrics"]["reported_usage"]
        require(receipt["provider_requests"] > 1 and all(
                usage[key] == turn.get(key) for key in ("input_tokens", "output_tokens",
                    "cache_creation_input_tokens", "cache_read_input_tokens", "usage_scope")),
                "failed attempt lost observed provider metrics or relabelled their scope")
        instructions.append(receipt["common_instruction_sha256"])
        peer = read((output / entry["path"]).parent / "provider-events.json")
        check_http_observation((output / entry["path"]).parent, receipt,
                               [row for row in peer if row["kind"] == "synthetic_provider_received"])
    require(instructions[0] == instructions[1], "failed pair used different common instructions")
    print("PREPARATION_MALFORMED_FINAL_PASS " + json.dumps({
        "expected": 2, "explicit_failure": 2, "unfinished": 0, "retained_measurements": True,
        "real_model": False, "speedup": None}))


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
        intake = receipt["timing"]["intake_turn_entry"]
        marker = read(directory / "turn-entry-manifest.json")
        require(intake["state"] == "observed" and marker in read(directory / "runtime-manifest.json"),
                "turn entry did not come from an actual persisted runtime manifest")
        require(marker["event"] == "turn_started" and marker["trace_id"] == turn["trace_id"] and
                marker["keeper_turn_id"] == turn["absolute_turn"] and marker["ts"] == intake["ts"],
                "intake marker lost its exact canonical turn identity")
        require(intake["sources"] == marker["decision"]["intake_sources"] == [{
                key: admission[key] for key in ("stimulus_id", "source_snapshot_ref",
                                               "admitted_revision", "first_admitted_at")}],
                "intake marker does not name the exact original admitted selection")
        require(intake["manifest_sha256"] == hashlib.sha256((directory / "turn-entry-manifest.json").read_bytes()).hexdigest(),
                "recorded intake manifest changed")
        require(intake["clock_refs"] == marker["decision"]["clock_refs"] and
                intake["clock_refs"]["source_clock"] == "wall",
                "wall clock evidence was relabelled as a monotonic timing")
        require(receipt["timing"]["replay_turn_started"]["state"] == "unknown",
                "observing Board intake must not add replay-owned reaction authority")
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
        stdout_ids = receipt["verified_stdout_read_execution_ids"]
        require(stdout_ids, "the final digest needs an actual complete stdout read")
        stdout_rows = [row for row in calls if row.get("execution_id") in stdout_ids]
        require(all(row["tool"] == "keeper_artifact_read" and
                    row["input"]["sha256"] == receipt["objective"]["stdout_sha256"] and
                    row["keeper_turn_id"] == turn["absolute_turn"] for row in stdout_rows),
                "copied result metadata must not stand in for physical stdout reading")
        if entry["strategy"] == "direct":
            require(set(stdout_ids) <= set(turn["execution_ids"]) and
                    all(row.get("composition_node_id") is None for row in stdout_rows),
                    "direct stdout read escaped the exact SDK turn")
        else:
            parents = [row for row in calls if row["tool"] == "keeper_composition_run" and
                       row.get("execution_id") in turn["execution_ids"]]
            require(len(parents) == 1, "nested stdout needs its unique original SDK parent")
            nodes = read(directory / "actual-composition-execution.json")["nodes"]
            require(all(row["parent_tool_use_id"] == parents[0]["tool_use_id"] and
                        any(node["node_id"] == row["composition_node_id"] and
                            node["execution_id"] == row["execution_id"] and
                            node["tool_name"] == row["tool"] and node["input"] == row["input"]
                            for node in nodes) for row in stdout_rows),
                    "nested physical stdout lost its canonical execution/SDK parent join")
            require(not (set(stdout_ids) & set(turn["execution_ids"])),
                    "this fixture must exercise child IDs outside the outer SDK trajectory")
        raw_records = read(directory / "exact-run-records.json")
        require(raw_records and all(record["worker_run_id"] == turn["raw_trace_run_ref"]["worker_run_id"]
                                    for record in raw_records), "tool evidence escaped the exact SDK run")
        useful_rows = [row for row in calls if row.get("execution_id") == useful["execution_id"]]
        require(len(useful_rows) == 1 and useful_rows[0]["tool"] == "keeper_artifact_read",
                "successful useful action was fabricated from an outer completion")
        require(useful_rows[0]["input"]["sha256"] == receipt["input"]["_blob"]["sha256"],
                "first useful leaf read a different immutable input")
        bodies = sorted(directory.glob("provider-request-*.json"))
        require(len(bodies) == receipt["provider_requests"] and len(bodies) > 1,
                "actual streaming provider loop was not crossed")
        peer = read(directory / "provider-events.json")
        check_http_observation(directory, receipt,
                               [row for row in peer if row["kind"] == "synthetic_provider_received"])
        require(all(read(path)["stream"] is True and read(path)["model"] == args.model_id for path in bodies),
                "model/streaming settings differ from explicit fixture")
        receipts.append(receipt)
        print("PREPARATION_FUNCTIONAL_RECEIPT " + json.dumps({
            "synthetic_only": True, "strategy": receipt["strategy"], "source": admission,
            "intake_turn_entry": intake, "useful": useful, "objective": receipt["objective"], "turn_ref": receipt["turn_ref"],
            "backend_calls_after_ready": 0, "driver_sha256": manifest["driver_sha256"]}, ensure_ascii=False))
    for field in ("fixture_sha256", "skill_reference", "input", "runtime", "first_offered_tools_sha256",
                  "common_instruction_sha256", "objective"):
        require(receipts[0][field] == receipts[1][field], "paired common identity differs: " + field)
    require(receipts[0]["timing"]["admission"]["stimulus_id"] != receipts[1]["timing"]["admission"]["stimulus_id"],
            "second arm reused first arm's measured source")
    print("PREPARATION_FUNCTIONAL_PASS " + json.dumps({"case": "upstream_inline", "expected": 2,
        "correct": 2, "unfinished": 0, "real_model": False, "speedup": None,
        "evidence": str(root), "summary_sha256": hashlib.sha256((output / "summary.json").read_bytes()).hexdigest()}))
    configured_http_refusal(args, root, head)
    malformed_final_evidence(args, root, head)


if __name__ == "__main__":
    main()
