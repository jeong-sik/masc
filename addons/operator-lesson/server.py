"""The operator lesson worker (RFC operator-lesson §4.1).

`compose` opens a session; the host then asks this worker what it waits for
(`lane_host_requests`) and delivers each result (`lane_host_result`). Every
decision is in lesson_flow, every row in lesson_projection, and every fact in
the log under the persistent state directory, so a restarted worker on the
same volume carries on where the last one stopped.

The binding comes with each observation. A compose before the first
observation of this worker fails before effect: the worker does not yet know
what to read.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
from pathlib import Path
import sys
import time
import tomllib

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent))

from protocol import InvalidInput, OUTPUT_SCHEMA, decode_json, encode_output, object_value, reply_id  # noqa: E402
import lesson_flow as f  # noqa: E402
import lesson_log as l  # noqa: E402
import lesson_projection as p  # noqa: E402

TEXT = {"type": "string", "minLength": 1}
CONTEXT_SCHEMA = {"type": "object", "additionalProperties": False, "required": ["instance_id", "incarnation"],
                  "properties": {"instance_id": TEXT, "incarnation": TEXT}}
ACTION_SCHEMA = {
    "type": "object", "additionalProperties": False, "required": ["context", "request_id", "action"],
    "properties": {
        "context": CONTEXT_SCHEMA, "request_id": TEXT,
        "action": {"type": "object", "additionalProperties": False, "required": ["kind"],
                   "properties": {
                       "kind": {"type": "string", "enum": ["compose", "export"],
                                "description": "compose starts a lesson; export returns the whole log"},
                       "scenes": {"type": "integer", "minimum": 1,
                                  "description": "compose only: how many scenes to write"}}}}}
OBSERVE_SCHEMA = {"type": "object", "additionalProperties": False, "required": ["context", "binding", "sources"],
                  "properties": {"context": CONTEXT_SCHEMA, "binding": {"type": "object"},
                                 "sources": {"type": "array", "items": {"type": "object"}}}}
EMPTY_SCHEMA = {"type": "object", "additionalProperties": False, "properties": {}}
RESULT_SCHEMA = {"type": "object", "additionalProperties": False, "required": ["request_id", "result"],
                 "properties": {"request_id": TEXT, "result": {"type": "object"}}}
# The largest JSON-RPC id the host can send, so a measured reply is an upper bound.
WIDEST_ID = 2 ** 53
EMPTY_OUTPUT = {"rows": [], "coverage": []}


def exact(value, keys: set[str], label: str) -> dict:
    value = object_value(value, label)
    if set(value) != keys:
        raise InvalidInput(f"{label} fields must be exactly {sorted(keys)}")
    return value


def tool_result(output: dict, summary: str) -> dict:
    return {"content": [{"type": "text", "text": summary}], "structuredContent": output, "isError": False}


def reply(request_id, result: dict) -> str:
    return encode_output({"jsonrpc": "2.0", "id": request_id, "result": result})


class Worker:
    def __init__(self, state: Path, prompts: f.Prompts, max_reply_bytes: int):
        self.max_reply_bytes = max_reply_bytes
        self.flow = f.Flow(state, prompts, self.fits)
        self.binding: dict | None = None
        self.context: dict | None = None

    def fits(self, request: dict) -> bool:
        return self.listing_bytes([request]) <= self.max_reply_bytes

    def listing_bytes(self, requests: list[dict]) -> int:
        line = reply(WIDEST_ID, tool_result({"requests": requests}, f"{len(requests)} host requests"))
        return len((line + "\n").encode("utf-8"))

    def bind(self, raw) -> None:
        context = exact(raw, {"instance_id", "incarnation"}, "context")
        if self.context is not None and self.context != context:
            raise InvalidInput("request targets a different worker incarnation")
        self.context = context

    def observation(self, export: dict | None = None) -> dict:
        return p.observation(self.flow.sessions(), time.time(), export)

    def observe(self, args) -> dict:
        args = exact(args, {"context", "binding", "sources"}, "observe arguments")
        self.bind(args["context"])
        binding = object_value(args["binding"], "binding")
        try:
            f.grants_of_binding(binding)
            f.language_of_binding(binding)
            f.since_of_binding(binding)
        except f.InvalidBinding as error:
            raise InvalidInput(str(error)) from error
        self.binding = binding
        try:
            return self.observation()
        except l.LogError as error:
            raise InvalidInput(f"the lesson log cannot be read: {error}") from error

    def refuse(self, request_id: str | None, reason: str) -> dict:
        try:
            output = self.observation()
        except l.LogError:
            output = EMPTY_OUTPUT
        return {"status": "failed_before_effect", "result": {"reason": reason, "request_id": request_id},
                "output": output}

    def act(self, args) -> dict:
        try:
            args = exact(args, {"context", "request_id", "action"}, "action arguments")
            self.bind(args["context"])
            request_id = args["request_id"]
            if not isinstance(request_id, str) or not request_id.strip():
                raise InvalidInput("request_id must be a non-blank string")
            action = object_value(args["action"], "action")
        except InvalidInput as error:
            return self.refuse(None, str(error))
        if self.binding is None:
            return self.refuse(request_id, "no observation has given this worker its binding yet")
        try:
            match action.get("kind"):
                case "compose":
                    scenes = action.get("scenes")
                    if set(action) != {"kind", "scenes"} or isinstance(scenes, bool) \
                            or not isinstance(scenes, int) or scenes < 1:
                        return self.refuse(request_id, "compose names how many scenes to write")
                    session_id = self.flow.compose(request_id, scenes, self.binding, time.time())
                    return {"status": "confirmed", "result": {"session_id": session_id},
                            "output": self.observation()}
                case "export":
                    if set(action) != {"kind"}:
                        return self.refuse(request_id, "export takes no other field")
                    path = self.flow.log.path
                    data = path.read_bytes() if path.exists() else b""
                    self.flow.sessions()  # an unreadable log is not exported as if it were the record
                    artifact = {"id": "log", "mime_type": "application/x-ndjson",
                                "data_base64": base64.b64encode(data).decode("ascii")}
                    return {"status": "confirmed",
                            "result": {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)},
                            "output": self.observation(export=artifact)}
                case other:
                    return self.refuse(request_id, f"{other!r} is not an action of this package")
        except l.LogError as error:
            return self.refuse(request_id, f"the lesson log cannot be read: {error}")
        except f.InvalidBinding as error:
            return self.refuse(request_id, str(error))

    def host_requests(self, args) -> dict:
        exact(args, set(), "lane_host_requests arguments")
        try:
            listing = self.flow.listing()
        except l.LogError as error:
            raise InvalidInput(f"the lesson log cannot be read: {error}") from error
        listed: list[dict] = []
        for request in listing:
            # A request that does not fit with those before it is listed in a
            # later reply; each request fits alone.
            if self.listing_bytes(listed + [request]) <= self.max_reply_bytes:
                listed.append(request)
        return {"requests": listed}

    def host_result(self, args) -> dict:
        args = exact(args, {"request_id", "result"}, "lane_host_result arguments")
        if not isinstance(args["request_id"], str):
            raise InvalidInput("request_id must be a string")
        try:
            return {"accepted": self.flow.deliver(args["request_id"], args["result"], time.time())}
        except (f.InvalidResult, l.LogError) as error:
            raise InvalidInput(str(error)) from error


TOOLS = [
    {"name": "lane_observe", "description": "Publish the lesson scenes, sessions and measures.",
     "inputSchema": OBSERVE_SCHEMA, "outputSchema": OUTPUT_SCHEMA,
     "annotations": {"readOnlyHint": True, "destructiveHint": False, "idempotentHint": True,
                     "openWorldHint": False}},
    {"name": "lane_act", "description": "compose: start a lesson; export: return the whole log.",
     "inputSchema": ACTION_SCHEMA,
     "annotations": {"readOnlyHint": False, "destructiveHint": False, "idempotentHint": True,
                     "openWorldHint": False}},
    {"name": "lane_host_requests", "description": "The host requests this package waits for.",
     "inputSchema": EMPTY_SCHEMA,
     "annotations": {"readOnlyHint": True, "destructiveHint": False, "idempotentHint": True,
                     "openWorldHint": False}},
    {"name": "lane_host_result", "description": "Consume one delivered host request result.",
     "inputSchema": RESULT_SCHEMA,
     "annotations": {"readOnlyHint": False, "destructiveHint": False, "idempotentHint": True,
                     "openWorldHint": False}},
]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--state", type=Path, required=True)
    options = parser.parse_args()
    manifest = tomllib.loads((HERE / "lane.toml").read_text(encoding="utf-8"))
    prompts = f.Prompts(outline=(HERE / "prompts" / "outline.md").read_text(encoding="utf-8"),
                        scene=(HERE / "prompts" / "scene.md").read_text(encoding="utf-8"))
    worker = Worker(options.state, prompts, manifest["resources"]["max_reply_bytes"])
    for line in sys.stdin.buffer:
        request_id = None
        try:
            request = object_value(decode_json(line.decode("utf-8")), "request")
            request_id = reply_id(request.get("id"))
            if "id" not in request or "method" not in request:
                continue
            method, params = request["method"], object_value(request.get("params", {}), "params")
            if method == "initialize":
                result = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
                          "serverInfo": {"name": "masc-operator-lesson", "version": manifest["revision"]}}
            elif method == "ping":
                result = {}
            elif method == "tools/list":
                result = {"tools": TOOLS}
            elif method == "tools/call":
                name, arguments = params.get("name"), params.get("arguments")
                try:
                    match name:
                        case "lane_observe":
                            output = worker.observe(arguments)
                            result = tool_result(output, f"{len(output['rows'])} rows")
                        case "lane_act":
                            output = worker.act(arguments)
                            result = tool_result(output, output["status"])
                        case "lane_host_requests":
                            output = worker.host_requests(arguments)
                            result = tool_result(output, f"{len(output['requests'])} host requests")
                        case "lane_host_result":
                            output = worker.host_result(arguments)
                            result = tool_result(output, json.dumps(output))
                        case _:
                            raise InvalidInput("unknown tool")
                except InvalidInput as error:
                    result = {"content": [{"type": "text", "text": str(error)}], "isError": True}
            else:
                response = {"jsonrpc": "2.0", "id": request_id, "error": {"code": -32601, "message": "Method not found"}}
                print(encode_output(response), flush=True)
                continue
            encoded = reply(request_id, result)
            if method == "tools/call" and len((encoded + "\n").encode("utf-8")) > worker.max_reply_bytes:
                encoded = reply(request_id, {"content": [{"type": "text", "text":
                                "the reply exceeds the declared max_reply_bytes; nothing was sent"}],
                                             "isError": True})
        except (json.JSONDecodeError, UnicodeDecodeError):
            encoded = encode_output({"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}})
        except InvalidInput as error:
            encoded = encode_output({"jsonrpc": "2.0", "id": request_id,
                                     "error": {"code": -32602, "message": str(error)}})
        print(encoded, flush=True)


if __name__ == "__main__":
    main()
