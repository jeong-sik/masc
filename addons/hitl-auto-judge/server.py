"""Retain original HITL judgment Exact requests; every decision stays on the host."""
from __future__ import annotations

from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
from exact_worker import Contract, OBJECT, TEXT, canonical, closed, exact, serve, text
from protocol import InvalidInput

MESSAGE = closed({"role": {"type": "string", "enum": ["user", "assistant"]}, "text": TEXT})
REQUEST = {
    "type": "object", "additionalProperties": False,
    "properties": {
        "kind": {"type": "string", "const": "exact_output"},
        "request_id": TEXT,
        "output": {"type": "string", "const": "judgment"},
        "system": TEXT,
        "messages": {"type": "array", "minItems": 1, "items": MESSAGE},
        "schema": OBJECT,
    },
    "required": ["kind", "request_id", "output", "messages", "schema"],
}
TOOL_INPUT = {"type": "object", "oneOf": [
    closed({"kind": {"type": "string", "const": "submit"}, "request": REQUEST}),
    closed({"kind": {"type": "string", "const": "read"}, "request_id": TEXT}),
]}


def request_of_json(raw) -> dict:
    fields = set(REQUEST["required"])
    if isinstance(raw, dict) and "system" in raw:
        fields.add("system")
    request = exact(raw, fields, "HITL judgment Exact request")
    if request["kind"] != "exact_output" or request["output"] != "judgment":
        raise InvalidInput("HITL Auto Judge needs an original judgment Exact request")
    text(request["request_id"], "request_id")
    if not isinstance(request["schema"], dict):
        raise InvalidInput("HITL judgment output schema must be an object")
    if "system" in request:
        text(request["system"], "system")
    messages = request["messages"]
    if not isinstance(messages, list) or not messages:
        raise InvalidInput("HITL judgment messages must retain the original nonempty conversation")
    for message in messages:
        message = exact(message, {"role", "text"}, "original message")
        if message["role"] not in ("user", "assistant"):
            raise InvalidInput("HITL judgment messages accept only original user/assistant roles")
        text(message["text"], "message.text")
    canonical(request)
    return request


def host_request(request: dict) -> dict:
    # Do not flatten roles, reconstruct the prompt or substitute today's schema.
    # The shared host validates the full digest against the retained original.
    return request


CONTRACT = Contract(package_id="hitl-auto-judge", tool_name="judge", row_id="requests",
                    lane_id="hitl/auto-judge", title="HITL Auto Judge requests",
                    tool_input=TOOL_INPUT, parse_request=request_of_json, host_request=host_request)


if __name__ == "__main__":
    serve(HERE, CONTRACT)
