#!/usr/bin/env python3
"""Measure real OpenAI-compatible requests over immutable MASC fixture receipts.

The producer and artifact pages have already executed in the captured focused
suite. Only the model executes here. This is a result-recovery experiment, not a
live Keeper or preparation-latency benchmark. Failed/unfinished samples remain
in the output. Credentials and HTTP headers are never written.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import statistics
import time
import urllib.error
import urllib.request


CORPUS_PREFIX = "composition_provider_trial_corpus="
SYSTEM = (
    "Use only the supplied composition result and keeper_artifact_read to answer "
    "the task. Never rerun the producer. Preserve failures and unknown effects. "
    "Return the requested JSON object without prose when enough evidence is available."
)


def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def write_json(path, value):
    path.write_bytes(encode(value) + b"\n")


def read_corpus(path):
    raw = path.read_bytes()
    text = raw.decode("utf-8")
    if text.lstrip().startswith("{"):
        corpus = json.loads(text)
    else:
        lines = [line.split(CORPUS_PREFIX, 1)[1] for line in text.splitlines() if CORPUS_PREFIX in line]
        if len(lines) != 1:
            raise ValueError("log must contain exactly one completed corpus receipt")
        corpus = json.loads(lines[0])
    if corpus.get("schema_version") != 1 or not corpus.get("scenarios"):
        raise ValueError("unsupported or empty corpus")
    names = set()
    for scenario in corpus["scenarios"]:
        for field in ("scenario", "task", "expected", "tool_name", "baseline_content", "selected_content",
                      "reader_tool", "reader_default_max_bytes", "pages"):
            if field not in scenario:
                raise ValueError("incomplete corpus scenario: " + field)
        if scenario["scenario"] in names:
            raise ValueError("duplicate scenario")
        names.add(scenario["scenario"])
    return corpus, hashlib.sha256(raw).hexdigest()


def replay_page(scenario, call):
    if call.get("type") != "function" or call.get("function", {}).get("name") != "keeper_artifact_read":
        raise ValueError("uncaptured tool requested")
    args = call["function"]["arguments"]
    if isinstance(args, str):
        args = json.loads(args)
    if not isinstance(args, dict) or set(args) - {"sha256", "offset", "max_bytes"}:
        raise ValueError("invalid artifact read arguments")
    offset = args.get("offset", 0)
    maximum = args.get("max_bytes", scenario["reader_default_max_bytes"])
    if type(offset) is not int or type(maximum) is not int or maximum != scenario["reader_default_max_bytes"]:
        raise ValueError("only captured default full pages are available")
    normalized = {"sha256": args.get("sha256"), "offset": offset}
    matches = [page for page in scenario["pages"] if page["args"] == normalized]
    if len(matches) != 1:
        raise ValueError("requested artifact/offset has no captured observation")
    return matches[0]["content"]


def request_body(args, options, scenario, messages):
    # Transport/model settings are identical for both result conditions.
    return dict(options, model=args.model, messages=messages, stream=False,
                tools=[scenario["reader_tool"]])


def run_sample(args, options, key, scenario, condition, directory):
    directory.mkdir()
    initial_content = scenario[condition + "_content"]
    messages = [
        {"role": "system", "content": SYSTEM},
        {"role": "user", "content": scenario["task"]},
        {"role": "assistant", "content": None, "tool_calls": [{
            "id": "export-fixture", "type": "function",
            "function": {"name": scenario["tool_name"], "arguments": "{}"}}]},
        {"role": "tool", "tool_call_id": "export-fixture", "content": initial_content},
    ]
    started = time.perf_counter()
    sample = dict(scenario=scenario["scenario"], condition=condition, outcome="unfinished",
                  initial_tool_content_bytes=len(initial_content.encode("utf-8")),
                  requests=[], artifact_reads=0, first_useful_action_seconds=None)
    for index in range(args.max_requests):
        body = encode(request_body(args, options, scenario, messages))
        stem = directory / str(index)
        stem.with_suffix(".request.json").write_bytes(body)
        request = urllib.request.Request(args.endpoint, data=body, method="POST", headers={
            "Content-Type": "application/json", "Authorization": "Bearer " + key})
        before = time.perf_counter()
        row = dict(index=index, request_body_bytes=len(body), request_body_sha256=hashlib.sha256(body).hexdigest())
        sample["requests"].append(row)
        try:
            with urllib.request.urlopen(request, timeout=args.timeout) as response:
                raw = response.read()
                row["http_status"] = response.status
        except urllib.error.HTTPError as error:
            raw = error.read()
            row["http_status"] = error.code
            sample["outcome"] = "provider_error"
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            row["transport_error"] = str(error).replace(key, "[REDACTED]")
            row["seconds"] = time.perf_counter() - before
            sample["outcome"] = "transport_error"
            break
        row["seconds"] = time.perf_counter() - before
        row["response_body_bytes"] = len(raw)
        # Preserve the response while redacting a credential echoed by a provider.
        stem.with_suffix(".response.json").write_bytes(raw.replace(key.encode(), b"[REDACTED]"))
        if sample["outcome"] == "provider_error":
            break
        try:
            response = json.loads(raw)
            row["usage"] = response.get("usage")
            row["reported_model"] = response.get("model")
            choices = response["choices"]
            if len(choices) != 1:
                raise ValueError("expected exactly one assistant choice")
            choice = choices[0]
            row["finish_reason"] = choice.get("finish_reason")
            message = choice["message"]
            if message.get("role") != "assistant":
                raise ValueError("missing assistant role")
            calls = message.get("tool_calls") or []
            if calls:
                # Preserve unmodified reasoning and tool calls in the next request.
                messages.append(message)
                for call in calls:
                    content = replay_page(scenario, call)
                    call_id = call["id"]
                    if not isinstance(call_id, str) or not call_id:
                        raise ValueError("missing artifact tool call identity")
                    messages.append({"role": "tool", "tool_call_id": call_id, "content": content})
                    sample["artifact_reads"] += 1
                    if sample["first_useful_action_seconds"] is None:
                        sample["first_useful_action_seconds"] = time.perf_counter() - started
                continue
            answer = json.loads(message["content"])
            sample["answer"] = answer
            # JSON object key order is irrelevant; types and complete fields matter.
            correct = encode(answer) == encode(scenario["expected"]) if not isinstance(answer, dict) else (
                json.dumps(answer, sort_keys=True) == json.dumps(scenario["expected"], sort_keys=True))
            sample["outcome"] = "correct" if correct else "incorrect"
            if correct and sample["first_useful_action_seconds"] is None:
                sample["first_useful_action_seconds"] = time.perf_counter() - started
            break
        except (KeyError, TypeError, ValueError) as error:
            sample["outcome"] = "invalid_or_uncaptured_response"
            sample["response_error"] = str(error).replace(key, "[REDACTED]")
            break
    sample["completion_seconds"] = time.perf_counter() - started
    sample["request_count"] = len(sample["requests"])
    sample["request_body_bytes"] = sum(row["request_body_bytes"] for row in sample["requests"])
    sample["usage_complete"] = all(isinstance(row.get("usage"), dict) and
        all(type(row["usage"].get(field)) is int for field in ("prompt_tokens", "completion_tokens", "total_tokens"))
        for row in sample["requests"])
    sample["usage"] = ({field: sum(row["usage"][field] for row in sample["requests"])
                        for field in ("prompt_tokens", "completion_tokens", "total_tokens")}
                       if sample["usage_complete"] else None)
    write_json(directory / "sample.json", sample)
    return sample


def summarize(samples):
    groups = []
    for scenario, condition in sorted({(sample["scenario"], sample["condition"]) for sample in samples}):
        selected = [s for s in samples if (s["scenario"], s["condition"]) == (scenario, condition)]
        correct = [s for s in selected if s["outcome"] == "correct"]
        groups.append(dict(scenario=scenario, condition=condition, attempted=len(selected), correct=len(correct),
            outcomes={name: sum(s["outcome"] == name for s in selected) for name in sorted({s["outcome"] for s in selected})},
            all_request_body_bytes=sum(s["request_body_bytes"] for s in selected),
            all_request_count=sum(s["request_count"] for s in selected),
            all_artifact_reads=sum(s["artifact_reads"] for s in selected),
            reported_models=sorted({row["reported_model"] for s in selected for row in s["requests"]
                                    if isinstance(row.get("reported_model"), str)}),
            unreported_model_requests=sum(not isinstance(row.get("reported_model"), str)
                                          for s in selected for row in s["requests"]),
            complete_usage_samples=sum(s["usage_complete"] for s in selected),
            correct_completion_seconds_median=(statistics.median(s["completion_seconds"] for s in correct) if correct else None),
            correct_first_useful_action_seconds_median=(statistics.median(s["first_useful_action_seconds"] for s in correct) if correct else None)))
    return groups


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--producer-head", required=True)
    parser.add_argument("--producer-run", required=True)
    parser.add_argument("--endpoint", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--api-key-env", required=True)
    parser.add_argument("--request-options", type=Path, required=True)
    parser.add_argument("--pairs", type=int, required=True)
    parser.add_argument("--max-requests", type=int, required=True)
    parser.add_argument("--timeout", type=float, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.pairs <= 0 or args.max_requests <= 0 or args.timeout <= 0:
        parser.error("experiment pairs, request ceiling and transport timeout must be positive")
    key = os.environ.get(args.api_key_env)
    if not key:
        parser.error("requested credential environment variable is missing")
    options = json.loads(args.request_options.read_text())
    if not isinstance(options, dict) or set(options) & {"model", "messages", "stream", "tools"}:
        parser.error("request options must be an object without experiment-owned fields")
    corpus, digest = read_corpus(args.corpus)
    args.output.mkdir(mode=0o700)
    write_json(args.output / "corpus.json", corpus)
    manifest = dict(schema_version=1, started_at_unix=time.time(), producer_head=args.producer_head,
                    producer_run=args.producer_run, corpus_input_sha256=digest, model=args.model,
                    runner_source_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                    endpoint=args.endpoint, request_options=options, pairs=args.pairs,
                    max_requests=args.max_requests, timeout_seconds=args.timeout,
                    scope="Real provider requests over captured fixture results/default artifact pages; result recovery only. No live Keeper, preparation latency or effect execution.",
                    expected_samples=len(corpus["scenarios"]) * args.pairs * 2, samples=[], summary=[])
    write_json(args.output / "manifest.json", manifest)
    for pair in range(args.pairs):
        order = ("baseline", "selected") if pair % 2 == 0 else ("selected", "baseline")
        for scenario_index, scenario in enumerate(corpus["scenarios"]):
            for condition in order:
                directory = args.output / f"{pair}-{scenario_index}-{condition}"
                sample = run_sample(args, options, key, scenario, condition, directory)
                sample["pair"] = pair
                manifest["samples"].append(sample)
                manifest["summary"] = summarize(manifest["samples"])
                write_json(args.output / "manifest.json", manifest)
                print(json.dumps({field: sample[field] for field in ("scenario", "condition", "outcome", "request_count", "artifact_reads", "completion_seconds", "request_body_bytes", "usage")}), flush=True)
    manifest["finished_at_unix"] = time.time()
    write_json(args.output / "manifest.json", manifest)
    print(json.dumps(manifest["summary"], ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
