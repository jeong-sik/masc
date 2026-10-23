"""Retain original Librarian proposals; Memory, absorption and ACK remain host-owned."""
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
        "output": {"type": "string", "enum": ["admission"]},
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
    request = exact(raw, fields, "Librarian Exact request")
    if request["kind"] != "exact_output" or request["output"] not in ("admission",):
        raise InvalidInput("Librarian needs an original explicit-candidate admission request")
    text(request["request_id"], "request_id")
    exact_schema = request["schema"]
    if not isinstance(exact_schema, dict):
        raise InvalidInput("Librarian output schema must be an object")
    if "system" in request:
        text(request["system"], "system")
    messages = request["messages"]
    if not isinstance(messages, list) or not messages:
        raise InvalidInput("Librarian messages must retain the original nonempty conversation")
    for message in messages:
        message = exact(message, {"role", "text"}, "original message")
        if message["role"] not in ("user", "assistant"):
            raise InvalidInput("Librarian messages accept only original user/assistant roles")
        text(message["text"], "message.text")
    canonical(request)
    return request


def host_request(request: dict) -> dict:
    # Do not flatten roles, reconstruct the prompt or substitute today's schema.
    # The shared host validates its full digest against the retained host capture.
    return request


CONTRACT = Contract(package_id="keeper-librarian", tool_name="admit_memory", row_id="requests",
                    lane_id="keeper/librarian", title="Librarian admission proposals",
                    tool_input=TOOL_INPUT, parse_request=request_of_json, host_request=host_request)


if __name__ == "__main__":
    serve(HERE, CONTRACT)
