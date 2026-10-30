"""Probe the real Messages binding contract without recording reasoning or secrets.

Run with the selected account's key already in the environment:
  python3 probe.py --key-env ANTHROPIC_API_KEY_MASC_VINCENT --workspace-id ID
The probe creates a fresh arithmetic conversation and executes no external tools.
"""
import argparse
import copy
import json
import os
import urllib.error
import urllib.request


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--key-env", required=True)
    parser.add_argument("--workspace-id")
    parser.add_argument("--model", default="claude-sonnet-5-5")
    args = parser.parse_args()
    headers = {
        "content-type": "application/json",
        "anthropic-version": "2023-06-01",
        "anthropic-beta": "thinking-binding-controls-2026-08-01",
        "x-api-key": os.environ[args.key_env],
    }
    if args.workspace_id:
        headers["anthropic-workspace-id"] = args.workspace_id

    def call(body):
        req = urllib.request.Request("https://api.anthropic.com/v1/messages",
                                     json.dumps(body).encode(), headers)
        try:
            with urllib.request.urlopen(req, timeout=180) as response:
                if body.get("stream"):
                    started = None
                    stopped = False
                    for line in response:
                        if line.startswith(b"data: "):
                            event = json.loads(line[6:])
                            if event.get("type") == "message_start":
                                started = event.get("message", {})
                            if event.get("type") == "message_stop":
                                stopped = True
                    assert started is not None and stopped, "stream did not complete"
                    return response.status, started
                return response.status, json.load(response)
        except urllib.error.HTTPError as exc:
            return exc.code, json.load(exc)

    body = {
        "model": args.model, "max_tokens": 8192,
        "thinking": {"type": "adaptive", "block_binding": {"prefix_mismatch_behavior": "error"}},
        "output_config": {"effort": "high"},
        "tools": [{"name": "record_answer", "description": "Record the computed integer answer.",
                   "input_schema": {"type": "object", "properties": {"answer": {"type": "integer"}},
                                    "required": ["answer"]}}],
        "messages": [{"role": "user", "content": [
            {"type": "text", "text": "How many positive integers below 500 have exactly six positive divisors? Work through all cases carefully before calling record_answer exactly once with the integer count."},
            {"type": "text", "text": "Temporary request context: the arithmetic result will be checked."}]}],
    }
    status, first = call(body)
    assert status == 200, ("first", status, first.get("error", {}).get("type"))
    thinking_count = sum(b["type"] == "thinking" for b in first["content"])
    calls = [b for b in first["content"] if b["type"] == "tool_use"]
    print(json.dumps({"scenario": "first_response", "status": status,
                      "stop_reason": first.get("stop_reason"),
                      "block_types": [b["type"] for b in first["content"]]}), flush=True)
    assert thinking_count > 0 and calls, "probe inconclusive: no signed thinking/tool call"
    body["messages"] += [
        {"role": "assistant", "content": first["content"]},
        {"role": "user", "content": [{"type": "tool_result", "tool_use_id": b["id"], "content": "Recorded."} for b in calls]},
    ]
    status, good = call(body)
    assert status == 200 and not good.get("input_transformations"), "append-only continuation failed"
    print(json.dumps({"scenario": "preserved_context", "status": status, "thinking_blocks": thinking_count,
                      "transformations": good.get("input_transformations", [])}), flush=True)
    broken = copy.deepcopy(body)
    broken["messages"][0]["content"].pop()
    status, failed = call(broken)
    assert status == 400, ("missing_context", status)
    print(json.dumps({"scenario": "missing_context", "status": status,
                      "error_type": failed.get("error", {}).get("type")}), flush=True)
    broken["thinking"]["block_binding"]["prefix_mismatch_behavior"] = "drop_block"
    status, recovered = call(broken)
    transformations = recovered.get("input_transformations", [])
    assert status == 200 and any(t.get("reason") == "prefix_binding_mismatch" for t in transformations), "recovery was not observed"
    print(json.dumps({"scenario": "missing_context_recovery", "status": status,
                      "transformations": transformations}), flush=True)
    broken["stream"] = True
    status, streamed = call(broken)
    transformations = streamed.get("input_transformations", [])
    assert status == 200 and any(t.get("reason") == "prefix_binding_mismatch" for t in transformations), "stream recovery was not observed"
    print(json.dumps({"scenario": "streamed_missing_context_recovery", "status": status,
                      "stream_completed": True, "transformations": transformations}), flush=True)


if __name__ == "__main__":
    main()
