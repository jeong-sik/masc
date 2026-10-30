"""Retain original Curator Exact requests; all domain authority stays on the host."""
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
        "output": {"type": "string", "enum": ["classification", "briefing"]},
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
    request = exact(raw, fields, "Curator Exact request")
    if request["kind"] != "exact_output" or request["output"] not in ("classification", "briefing"):
        raise InvalidInput("Curator needs an original classification or briefing Exact request")
    text(request["request_id"], "request_id")
    exact_schema = request["schema"]
    if not isinstance(exact_schema, dict):
        raise InvalidInput("Curator output schema must be an object")
    if "system" in request:
        text(request["system"], "system")
    messages = request["messages"]
    if not isinstance(messages, list) or not messages:
        raise InvalidInput("Curator messages must retain the original nonempty conversation")
    for message in messages:
        message = exact(message, {"role", "text"}, "original message")
        if message["role"] not in ("user", "assistant"):
            raise InvalidInput("Curator messages accept only original user/assistant roles")
        text(message["text"], "message.text")
    canonical(request)
    return request


def host_request(request: dict) -> dict:
    # Do not flatten roles, reconstruct the prompt or substitute today's schema.
    # The shared host validates its full digest against the retained host capture.
    return request


CONTRACT = Contract(package_id="workspace-curator", tool_name="curate", row_id="requests",
                    lane_id="workspace/curator", title="Workspace Curator requests",
                    tool_input=TOOL_INPUT, parse_request=request_of_json, host_request=host_request)


if __name__ == "__main__":
    serve(HERE, CONTRACT)
