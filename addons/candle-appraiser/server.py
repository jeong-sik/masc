"""Candle judgment contract; shared Exact storage and MCP transport own execution.

Only the captured prompt becomes model evidence. Payout/task identities stay in
the retained audit request. Settlement and complete domain validation remain host-owned.
"""
from __future__ import annotations

from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
from exact_worker import Contract, OBJECT, TEXT, canonical, closed, exact, serve, text
from protocol import InvalidInput, object_value

IDENTITY = {"type": "object", "additionalProperties": False,
            "properties": {key: TEXT for key in ("goal_id", "request_id", "verification_run_id")},
            "required": ["goal_id", "request_id", "verification_run_id"]}
REQUEST_FIELDS = {"request_id": TEXT, "identity": IDENTITY, "input": OBJECT,
                  "schema": OBJECT, "prompt": TEXT}


REQUEST = {"type": "object", "oneOf": [
    closed({**REQUEST_FIELDS, "stage": {"type": "string", "enum": ["grade", "weights"]}}),
    closed({**REQUEST_FIELDS, "stage": {"type": "string", "enum": ["relation"]}, "task_id": TEXT}),
]}
TOOL_INPUT = {"type": "object", "oneOf": [
    closed({"kind": {"type": "string", "const": "submit"}, "request": REQUEST}),
    closed({"kind": {"type": "string", "const": "read"}, "request_id": TEXT}),
]}


def request_of_json(raw) -> dict:
    raw = object_value(raw, "appraisal request")
    fields = set(REQUEST_FIELDS) | {"stage"}
    if raw.get("stage") == "relation":
        fields.add("task_id")
    request = exact(raw, fields, "appraisal request")
    text(request["request_id"], "request_id")
    identity = exact(request["identity"], set(IDENTITY["required"]), "identity")
    for key, value in identity.items():
        text(value, f"identity.{key}")
    match request["stage"], request.get("task_id"):
        case "relation", (str() as task_id):
            text(task_id, "task_id")
        case ("grade" | "weights"), None:
            pass
        case _:
            raise InvalidInput("only a Relation names its original task_id")
    object_value(request["input"], "input")
    object_value(request["schema"], "schema")
    text(request["prompt"], "prompt")
    canonical(request)
    return request



def host_request(request: dict) -> dict:
    return {"kind": "exact_output", "request_id": request["request_id"], "output": request["stage"],
            "messages": [{"role": "user", "text": request["prompt"]}], "schema": request["schema"]}


CONTRACT = Contract(package_id="candle-appraiser", tool_name="candle_appraise", row_id="appraisals",
                    lane_id="candle/appraisals", title="Candle appraisal requests",
                    tool_input=TOOL_INPUT, parse_request=request_of_json, host_request=host_request)


if __name__ == "__main__":
    serve(HERE, CONTRACT)
