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


def received_tools(body):
    tools = body.get("tools", [])
    require(isinstance(tools, list), "received tools member is not a list")
    encoded = json.dumps(tools, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    return {"state": "present" if "tools" in body else "absent", "wire_entries": len(tools),
            "json_bytes": len(encoded), "json_sha256": hashlib.sha256(encoded).hexdigest()}


def received_components(raw):
    """Measure actual peer byte slices; JSONDecoder owns key/value parsing."""
    text = raw.decode("utf-8")
    require(isinstance(json.loads(text), dict), "peer request must be a JSON object")
    decoder = json.JSONDecoder()

    def skip_space(at):
        while at < len(text) and text[at] in " \t\r\n":
            at += 1
        return at

    cursor = skip_space(0)
    require(text[cursor] == "{", "peer object opening missing")
    cursor = skip_space(cursor + 1)
    members = []
    while text[cursor] != "}":
        key_start = cursor
        name, cursor = decoder.raw_decode(text, cursor)
        require(isinstance(name, str), "peer object key is not a string")
        cursor = skip_space(cursor)
        require(text[cursor] == ":", "peer member colon missing")
        value_start = skip_space(cursor + 1)
        _, value_end = decoder.raw_decode(text, value_start)
        value = text[value_start:value_end].encode("utf-8")
        members.append({"name": name,
                        "wire_bytes": len(text[key_start:value_end].encode("utf-8")),
                        "value_json_bytes": len(value),
                        "value_json_sha256": hashlib.sha256(value).hexdigest()})
        cursor = skip_space(value_end)
        if text[cursor] == "}":
            break
        require(text[cursor] == ",", "peer member separator missing")
        cursor = skip_space(cursor + 1)
    require(skip_space(cursor + 1) == len(text), "peer object has trailing content")
    return {"state": "observed", "members": members,
            "framing_bytes": len(raw) - sum(member["wire_bytes"] for member in members)}


def check_tool_commit_observation(directory, receipt):
    metrics = receipt["tool_commit_observation"]
    path = directory / "tool-commit-events.jsonl"
    events = [json.loads(line) for line in path.read_text().splitlines()]
    calls = [row for row in read(directory / "tool-calls.json") if row["record_kind"] == "tool_call"]
    identity = ("keeper", "tool", "execution_id", "tool_use_id", "trace_id", "task_id",
                "keeper_turn_id", "composition_node_id", "parent_tool_use_id")

    def matches(event, row):
        return all(event.get(key) == row.get(key) for key in identity)

    require(metrics["boundary"] == "durable_tool_call_commit" and
            metrics["mode"] == "scoped_synchronous_commit" and
            metrics["coverage"] == "complete" and metrics["delivery_failures"] == 0 and
            metrics["events"] == len(events) == len(calls) and
            metrics["events_sha256"] == hashlib.sha256(path.read_bytes()).hexdigest(),
            "committed Tool observation has a coverage or journal gap")
    require(all(set(event) == set(identity) | {"schema_version", "boundary", "observed"} and
                event["schema_version"] == 1 and event["boundary"] == metrics["boundary"] and
                event["execution_id"] and sum(matches(event, row) for row in calls) == 1
                for event in events) and
            all(sum(matches(event, row) for event in events) == 1 for row in calls),
            "commit metadata lost exact physical identity or copied Tool payload")
    useful = receipt["timing"]["first_useful_leaf"]
    if useful["state"] == "observed":
        joined = [event for event in events if event["execution_id"] == useful["execution_id"]]
        require(len(joined) == 1 and useful["boundary"] == metrics["boundary"] and
                joined[0]["observed"] == useful["observed"] and
                all(joined[0][key] == useful[key] for key in identity if key not in {"keeper", "tool"}),
                "useful clock was substituted from a parent completion or another execution")
        selection = [event for event in events if any(matches(event, row) and
                     row["tool"] == "keeper_artifact_read" and
                     row["input"].get("sha256") == receipt["input"]["_blob"]["sha256"] and
                     row.get("task_id") == useful["task_id"] for row in calls)]
        require(selection and joined[0] == selection[0],
                "first useful action skipped an earlier committed original input read")


def check_http_observation(directory, receipt, received, *, refused=False):
    check_tool_commit_observation(directory, receipt)
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
    inventories = {row["body_sha256"]: row["tool_inventory"] if "tool_inventory" in row else
                   received_tools(read(directory / f'provider-request-{row["index"]:03d}.json'))
                   for row in received}
    require(all(row["tool_inventory"] == inventories[row["body_sha256"]] for row in entered),
            "serializer-owned inventory differs from the actual peer's offered tools")
    def peer_components(row):
        if "request_components" in row:
            return row["request_components"]
        raw = (directory / f'provider-request-{row["index"]:03d}.body').read_bytes()
        require(len(raw) == row["body_bytes"] and
                hashlib.sha256(raw).hexdigest() == row["body_sha256"],
                "synthetic peer raw body lost its size/digest identity")
        return received_components(raw)

    components = {row["body_sha256"]: peer_components(row) for row in received}
    require(all(row["request_components"] == components[row["body_sha256"]] for row in entered),
            "serializer component attribution differs from independently received byte slices")
    first = next(row["call_id"] for row in events if row["phase"] == "dispatch_entered")
    expected = inventories[calls[first][0]["body_sha256"]]
    require(metrics["first_dispatched_tools"] == expected and
            receipt["first_offered_tools_sha256"] == expected["json_sha256"],
            "first offered inventory was inferred from a later request")
    require(metrics["first_dispatched_components"] == components[calls[first][0]["body_sha256"]],
            "first request component attribution was inferred from a later request")
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
                             "tool_inventory": received_tools(body),
                             "request_components": received_components(raw),
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
        if entry["strategy"] == "exact_skill":
            execution = read((output / entry["path"]).parent / "actual-composition-execution.json")
            require("execution_artifact" not in execution["source_result"] and
                    execution["source_result"]["actions"] == execution["nodes"],
                    "unprojected physical execution was not verified through its canonical full actions")
            calls = read((output / entry["path"]).parent / "tool-calls.json")
            parents = [row for row in calls if row["tool"] == "keeper_composition_run" and
                       row.get("execution_id") in turn["execution_ids"]]
            require(len(parents) == 1 and set(parents[0]["input"]) == {"recipe"} and
                    not any(row["tool"] == "keeper_composition_prepare" for row in calls),
                    "fresh recipe execution still required a separate prepare call")
        peer = read((output / entry["path"]).parent / "provider-events.json")
        check_http_observation((output / entry["path"]).parent, receipt,
                               [row for row in peer if row["kind"] == "synthetic_provider_received"])
    require(instructions[0] == instructions[1], "failed pair used different common instructions")
    print("PREPARATION_MALFORMED_FINAL_PASS " + json.dumps({
        "expected": 2, "explicit_failure": 2, "unfinished": 0, "retained_measurements": True,
        "real_model": False, "speedup": None}))


def fixed_child_is_not_upstream(args, root, head):
    experiment = root / "fixed-child-experiment.json"
    experiment.write_text(json.dumps({"schema_version": 1, "case": "upstream_inline", "pairs": 1,
        "runtime": {"mode": "synthetic_streaming", "model_id": args.model_id,
                    "max_context_tokens": args.max_context_tokens, "max_output_tokens": args.max_output_tokens},
        "synthetic_outcome": "fixed_child"}) + "\n", encoding="utf-8")
    output = root / "fixed-child"
    code = subprocess.run([sys.executable, str(args.coordinator.resolve()),
        "--driver", str(args.driver.resolve()), "--source-head", head,
        "--experiment", str(experiment), "--prompts", str(args.prompts.resolve()),
        "--output", str(output)], check=False).returncode
    require(code == 0, f"fixed-child scenario failed; preserved evidence: {root}")
    manifest, summary = read(output / "manifest.json"), read(output / "summary.json")
    require(summary["expected"] == len(manifest["expected_attempts"]) == 2 and
            summary["outcomes"] == {"correct": 2, "explicit_failure": 0, "unfinished": 0} and
            summary["strategy_compliant"] == 1,
            "a correct constant child must stay in the denominator without becoming upstream compliance")
    for entry in manifest["expected_attempts"]:
        directory = (output / entry["path"]).parent
        receipt = read(directory / "attempt.json")
        require(receipt["strategy_compliant"] is (entry["strategy"] == "direct") and
                receipt["source_ack"] is True and receipt["verified_stdout_read_execution_ids"] and
                receipt["remaining_queue"] == receipt["backend_calls_after_ready"] == 0,
                "noncompliance lost original physical work or changed objective completion")
        if entry["strategy"] == "exact_skill":
            calls = read(directory / "tool-calls.json")
            parents = [row for row in calls if row["tool"] == "keeper_composition_run"]
            require(len(parents) == 1 and set(parents[0]["input"]) == {"recipe"},
                    "constant-child reproduction did not cross the original public recipe call")
            nodes = parents[0]["input"]["recipe"]["nodes"]
            require(len(nodes) == 1 and nodes[0]["input"]["fields"][0]["value"]["kind"] == "literal",
                    "reproduction accidentally added an actual upstream producer")
        peer = read(directory / "provider-events.json")
        check_http_observation(directory, receipt,
                               [row for row in peer if row["kind"] == "synthetic_provider_received"])
    print("PREPARATION_FIXED_CHILD_PASS " + json.dumps({"expected": 2, "correct": 2,
        "strategy_compliant": 1, "real_model": False, "speedup": None}))


def named_skill_reuse(args, root, head):
    experiment = root / "named-inline-experiment.json"
    experiment.write_text(json.dumps({"schema_version": 1, "case": "named_inline", "pairs": 1,
        "runtime": {"mode": "synthetic_streaming", "model_id": args.model_id,
                    "max_context_tokens": args.max_context_tokens, "max_output_tokens": args.max_output_tokens},
        "synthetic_outcome": "success"}) + "\n", encoding="utf-8")
    output = root / "named-inline"
    code = subprocess.run([sys.executable, str(args.coordinator.resolve()),
        "--driver", str(args.driver.resolve()), "--source-head", head,
        "--experiment", str(experiment), "--prompts", str(args.prompts.resolve()),
        "--output", str(output)], check=False).returncode
    require(code == 0, f"named Inline Skill scenario failed; preserved evidence: {root}")
    manifest, summary = read(output / "manifest.json"), read(output / "summary.json")
    require(summary["expected"] == len(manifest["expected_attempts"]) == 2 and
            summary["outcomes"] == {"correct": 2, "explicit_failure": 0, "unfinished": 0} and
            summary["strategy_compliant"] == 2, "named reuse lost an assigned arm or objective")
    require(summary["speedup"] is None and summary["latency_percentiles"] is None,
            "named synthetic calls cannot establish model speedup")
    for entry in manifest["expected_attempts"]:
        directory = (output / entry["path"]).parent
        receipt, turn = read(directory / "attempt.json"), read(directory / "turn-record.json")
        fixture = read(output / f"pair-{entry['pair']:04d}" / "base" / "preparation-fixture.json")
        require(receipt["case"] == "named_inline" and receipt["source_ack"] is True and
                receipt["remaining_queue"] == receipt["backend_calls_after_ready"] == 0,
                "named reuse lost the case or original completed source")
        calls, activations = read(directory / "tool-calls.json"), read(directory / "skill-activations.json")
        stdout_rows = [row for row in calls if row.get("execution_id") in
                       receipt["verified_stdout_read_execution_ids"]]
        require(stdout_rows and all(row["tool"] == "keeper_artifact_read" and
                    row["input"]["sha256"] == receipt["objective"]["stdout_sha256"] and
                    row["task_id"] == fixture["task_id"] and row["trace_id"] == turn["trace_id"] and
                    row["keeper_turn_id"] == turn["absolute_turn"] for row in stdout_rows),
                "named reuse substituted a digest for an original physical stdout read")
        if entry["strategy"] == "direct":
            require(activations == [] and all(row.get("composition_node_id") is None and
                    row["execution_id"] in turn["execution_ids"] for row in stdout_rows),
                    "named-case direct baseline escaped its actual SDK trajectory")
        else:
            require(len(activations) == 1, "named reuse needs one original Skill activation")
            activation = activations[0]
            invocation = activation["invocation"]
            require(invocation == {"kind": "composition", "origin": {"kind": "task_composition",
                    "task_ids": [fixture["task_id"]]}, "tool_name": fixture["skill_tool_name"]} and
                    activation["identity"] == fixture["skill_reference"]["identity"] and
                    activation["content_revision"] == fixture["skill_reference"]["content_revision"] and
                    activation["turn_ref"] == turn["turn_ref"] and
                    activation["runtime_id"] == turn["runtime_profile"],
                    "named reuse was not the exact Task Skill in this turn and Runtime")
            parents = [row for row in calls if row["tool"] == fixture["skill_tool_name"] and
                       row.get("execution_id") in turn["execution_ids"] and
                       row["tool_use_id"] == activation["skill_tool_use_id"] and
                       row["turn"] == activation["agent_core_turn"]]
            require(len(parents) == 1 and parents[0]["input"] == {"job_id": fixture["selected_job_id"]},
                    "named reuse lost its original SDK invocation or selected job")
            execution = read(directory / "actual-composition-execution.json")
            summaries = [row for row in calls if row["tool"] == "keeper_composition_run_summary" and
                         row.get("parent_tool_use_id") == parents[0]["tool_use_id"] and
                         row["tool_use_id"] == parents[0]["tool_use_id"]]
            require(len(summaries) == 1, "named reuse lost its original durable run summary")
            require(all(row["parent_tool_use_id"] == parents[0]["tool_use_id"] and
                    row["composition_run_id"] == summaries[0]["composition_run_id"] and
                    any(node["node_id"] == row["composition_node_id"] and
                        node["execution_id"] == row["execution_id"] and
                        node["tool_use_id"] == row["tool_use_id"] and
                        node["tool_name"] == row["tool"] and node["input"] == row["input"]
                        for node in execution["nodes"]) for row in stdout_rows) and
                    not any(row["tool"] in ("keeper_composition_prepare", "keeper_composition_run")
                            for row in calls), "named reuse required a new plan or lost physical parent ownership")
        peer = read(directory / "provider-events.json")
        check_http_observation(directory, receipt,
                               [row for row in peer if row["kind"] == "synthetic_provider_received"])
    print("PREPARATION_NAMED_INLINE_PASS " + json.dumps({"case": "named_inline", "expected": 2,
        "correct": 2, "strategy_compliant": 2, "real_model": False, "speedup": None}))


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
        stdout_ids = receipt["verified_stdout_read_execution_ids"]
        require(stdout_ids, "the final digest needs an actual complete stdout read")
        stdout_rows = [row for row in calls if row.get("execution_id") in stdout_ids]
        require(all(row["tool"] == "keeper_artifact_read" and
                    row["input"]["sha256"] == receipt["objective"]["stdout_sha256"] and
                    row["keeper_turn_id"] == turn["absolute_turn"] for row in stdout_rows),
                "copied result metadata must not stand in for physical stdout reading")
        if entry["strategy"] == "direct":
            require(set(stdout_ids + [useful["execution_id"]]) <= set(turn["execution_ids"]) and
                    all(row.get("composition_node_id") is None and row.get("parent_tool_use_id") is None
                        for row in stdout_rows + useful_rows),
                    "direct physical read escaped the exact SDK turn")
        else:
            parents = [row for row in calls if row["tool"] == "keeper_composition_run" and
                       row.get("execution_id") in turn["execution_ids"]]
            require(len(parents) == 1, "nested stdout needs its unique original SDK parent")
            nodes = read(directory / "actual-composition-execution.json")["nodes"]
            require(all(row["parent_tool_use_id"] == parents[0]["tool_use_id"] and
                        any(node["node_id"] == row["composition_node_id"] and
                            node["execution_id"] == row["execution_id"] and
                            node["tool_name"] == row["tool"] and node["input"] == row["input"]
                            for node in nodes) for row in stdout_rows + useful_rows),
                    "nested physical read lost its canonical execution/SDK parent join")
            require(not (set(stdout_ids + [useful["execution_id"]]) & set(turn["execution_ids"])),
                    "this fixture must exercise child IDs outside the outer SDK trajectory")
            require(set(parents[0]["input"]) == {"recipe"} and
                    [row["tool"] for row in calls if row.get("execution_id") in turn["execution_ids"]] ==
                    ["keeper_composition_run"],
                    "one-call recipe still used a preliminary read, loader or prepare exchange")
            selection_reads = [row for row in calls if row["tool"] == "keeper_artifact_read" and
                               row["input"].get("sha256") == receipt["input"]["_blob"]["sha256"]]
            require(selection_reads == useful_rows, "upstream recipe physically reread its immutable selection")
        raw_records = read(directory / "exact-run-records.json")
        require(raw_records and all(record["worker_run_id"] == turn["raw_trace_run_ref"]["worker_run_id"]
                                    for record in raw_records), "tool evidence escaped the exact SDK run")
        bodies = sorted(directory.glob("provider-request-*.json"))
        require(len(bodies) == receipt["provider_requests"] and len(bodies) > 1,
                "actual streaming provider loop was not crossed")
        first_tools = {tool["function"]["name"] for tool in read(bodies[0]).get("tools", [])}
        require("keeper_job_result" in first_tools,
                "the current Task's exact declared result Tool was absent from the first actual POST")
        require("keeper_composition_run" in first_tools,
                "the current Task's one-call recipe control was absent from the first actual POST")
        redundant_loads = [row for row in calls if row["tool"] == "keeper_tool_search" and
                           "keeper_job_result" in row["input"].get("names", [])]
        require(not redundant_loads,
                "the actual model loop still needed a loader call for its exact Task plan's result Tool")
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
    named_skill_reuse(args, root, head)
    fixed_child_is_not_upstream(args, root, head)


if __name__ == "__main__":
    main()
