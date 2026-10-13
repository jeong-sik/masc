"""Figma Studio's isolated MCP worker; all external I/O belongs to the relay."""

from __future__ import annotations

import base64
import json
import sys
import tomllib
from pathlib import Path
from typing import Any

from store import Access, Json, Refused, Store, encode, fields, text
from rest_queue import RestQueue
from verify import validate

ROOT = Path(__file__).resolve().parent
MANIFEST = tomllib.loads((ROOT / "lane.toml").read_text())
MAX_BYTES = MANIFEST["resources"]["max_reply_bytes"]
STRING = {"type": "string", "minLength": 1}
OBJECT = {"type": "object"}


def schema(required: dict, optional: dict | None = None) -> Json:
    return {
        "type": "object",
        "required": list(required),
        "properties": {**required, **(optional or {})},
        "additionalProperties": False,
    }


SCHEMAS = {
    "masc_figma_rest_capture": schema(
        {"operation_id": STRING, "file_key": STRING, "root_id": STRING},
        {"version": STRING},
    ),
    "masc_figma_rest_operation": schema({"operation_id": STRING}),
    "masc_figma_status": schema({}),
    "masc_figma_bind": schema({"session_id": STRING}),
    "masc_figma_submit": schema(
        {
            "operation_id": STRING,
            "session_id": STRING,
            "root_id": STRING,
            "kind": {"type": "string", "enum": ["capture", "apply"]},
        },
        {"snapshot_id": STRING, "ops": {"type": "array", "items": OBJECT}},
    ),
    "masc_figma_operation": schema({"operation_id": STRING}),
    "masc_figma_snapshot": schema({"snapshot_id": STRING}),
    "masc_figma_validate": schema(
        {
            "snapshot_id": STRING,
            "checks": {
                "type": "array",
                "items": schema(
                    {
                        "node_id": STRING,
                        "path": {
                            "type": "array",
                            "items": {
                                "oneOf": [STRING, {"type": "integer", "minimum": 0}]
                            },
                        },
                        "equals": {},
                    }
                ),
            },
        }
    ),
    "masc_figma_relay": schema(
        {
            "kind": {
                "type": "string",
                "enum": [
                    "status",
                    "session",
                    "poll",
                    "result",
                    "rest_poll",
                    "rest_result",
                ],
            }
        },
        {
            "worker_boot_id": STRING,
            "session_id": STRING,
            "document": OBJECT,
            "operation_id": STRING,
            "ok": {"type": "boolean"},
            "payload": OBJECT,
        },
    ),
}
DESCRIPTIONS = {
    "masc_figma_rest_capture": "Queue a PAT-backed server-version capture. Does not require an open Plugin.",
    "masc_figma_rest_operation": "Read a retained REST capture outcome without replaying the request.",
    "masc_figma_status": "List reported Plugin sessions and the latest retained design snapshot.",
    "masc_figma_bind": "Select an explicit Plugin session before capture or editing.",
    "masc_figma_submit": "Retain an idempotent capture/edit request. A receipt is not edit completion.",
    "masc_figma_operation": "Read a retained operation without replaying it.",
    "masc_figma_snapshot": "Read native design JSON and its exact PNG for vision review.",
    "masc_figma_validate": "Check explicit node property expectations on one retained snapshot; no visual verdict.",
    "masc_figma_relay": "Private-authority relay port; only the configured authenticated agent may use it.",
}


def result(value: Json, image: bytes | None = None) -> Json:
    # Keeper consumes MCP content, while lane_observe uses structuredContent.
    # Send each exported result once as model-visible JSON, plus the exact PNG.
    content = [{"type": "text", "text": encode(value)}]
    if image is not None:
        content.append(
            {
                "type": "image",
                "mimeType": "image/png",
                "data": base64.b64encode(image).decode(),
            }
        )
    return {"content": content, "isError": False}


def observation_result(value: Json) -> Json:
    return {
        "content": [
            {"type": "text", "text": "Figma Studio state and retained artifacts."}
        ],
        "structuredContent": value,
        "isError": False,
    }


def response_bytes(identity: str | int | None, output: Json) -> bytes:
    return (
        encode({"jsonrpc": "2.0", "id": identity, "result": output}) + "\n"
    ).encode()


def check_response(identity: str | int | None, output: Json) -> None:
    if len(response_bytes(identity, output)) > MAX_BYTES:
        raise Refused("Result exceeds the package's declared UTF-8 envelope")


def summary(operation: Json) -> Json:
    outcome = operation["result"]
    if outcome and "relay_result" in outcome:
        payload = outcome["relay_result"]["payload"]
        outcome = {
            key: value for key, value in outcome.items() if key != "relay_result"
        }
        outcome["completed"] = payload.get("completed", [])
        outcome["error"] = payload.get("error")
    return {
        **operation,
        "result": outcome,
        "request": {
            key: value for key, value in operation["request"].items() if key != "ops"
        },
    }


class Worker:
    def __init__(self, directory: Path):
        self.store = Store(directory)
        self.rest = RestQueue(self.store)

    def call(
        self, name: str, arguments: Json, *, response_id: str | int | None = 0
    ) -> Json:
        def check_snapshot(identity: str, metadata: Json, image: bytes | None) -> None:
            check_response(
                response_id, result({"snapshot_id": identity, **metadata}, image)
            )
            check_response(
                response_id,
                observation_result(
                    self.store.observe(snapshot=(identity, metadata, image))
                ),
            )

        def check_report(identity: str, content: str) -> None:
            check_response(
                response_id, result({"report_id": identity, **json.loads(content)})
            )
            check_response(
                response_id,
                observation_result(self.store.observe(report=(identity, content))),
            )

        def check_session(identity: str, document: Json) -> None:
            session = (identity, document)
            check_response(response_id, result(self.store.status(session=session)))
            check_response(
                response_id, observation_result(self.store.observe(session=session))
            )

        if name == "lane_observe":
            fields(arguments, {"binding", "sources"})
            if arguments["sources"] != []:
                raise Refused("Unexpected observation sources")
            self.store.configure(arguments["binding"])
            return observation_result(self.store.observe())
        if name != "lane_call":
            raise Refused("Exported tools must use the host-owned lane_call envelope")
        fields(arguments, {"tool", "arguments", "caller"})
        tool = text(arguments["tool"])
        args = fields(arguments["arguments"], set(arguments["arguments"]))
        access = {
            "masc_figma_relay": Access.RELAY,
            "masc_figma_snapshot": Access.SNAPSHOT,
        }.get(tool, Access.OWNER)
        self.store.authorize(arguments["caller"], access=access)
        if tool == "masc_figma_relay":
            if args == {"kind": "status"}:
                return result(
                    {
                        "worker_boot_id": self.store.boot_id,
                        "max_request_bytes": MAX_BYTES,
                    }
                )
            if args.get("kind") in ("rest_poll", "rest_result"):
                response = self.rest.relay(
                    args,
                    check_poll=lambda value: check_response(response_id, result(value)),
                    check_snapshot=check_snapshot,
                )
                return result(
                    self.rest.summary(response)
                    if "operation_id" in response
                    else response
                )
            response = self.store.relay(
                args,
                check_poll=lambda value: check_response(response_id, result(value)),
                check_snapshot=check_snapshot,
                check_session=check_session,
            )
            return result(summary(response) if "operation_id" in response else response)
        if tool == "masc_figma_status":
            fields(args, set())
            return result(self.store.status())
        if tool == "masc_figma_rest_capture":
            return result(self.rest.summary(self.rest.submit(args)))
        if tool == "masc_figma_rest_operation":
            fields(args, {"operation_id"})
            return result(self.rest.summary(self.rest.get(args["operation_id"])))
        if tool == "masc_figma_bind":
            fields(args, {"session_id"})
            return result(self.store.bind(args["session_id"]))
        if tool == "masc_figma_submit":
            return result(summary(self.store.submit(args)))
        if tool == "masc_figma_operation":
            fields(args, {"operation_id"})
            return result(summary(self.store.operation(args["operation_id"])))
        if tool == "masc_figma_snapshot":
            fields(args, {"snapshot_id"})
            metadata, image = self.store.snapshot(args["snapshot_id"])
            return result({"snapshot_id": args["snapshot_id"], **metadata}, image)
        if tool == "masc_figma_validate":
            fields(args, {"snapshot_id", "checks"})
            metadata, _ = self.store.snapshot(args["snapshot_id"])
            report = validate(args["snapshot_id"], metadata, args["checks"])
            return result(
                self.store.record_validation(
                    {**report, "evaluator": arguments["caller"]}, check=check_report
                )
            )
        raise Refused("Unknown Studio tool")


def reject(message: str, *, pre_effect: bool) -> Json:
    return {
        "isError": True,
        "content": [{"type": "text", "text": message}],
        "_meta": {
            "io.github.jeong-sik/masc.lane.failure": {
                "class": "workflow_rejection" if pre_effect else "runtime_failure",
                "effect": "proven_pre_effect"
                if pre_effect
                else "effect_outcome_unknown",
            }
        },
    }


def serve(worker: Worker) -> None:
    while True:
        line = sys.stdin.buffer.readline(MAX_BYTES + 1)
        if not line:
            return
        identity: Any = None
        try:
            if len(line) > MAX_BYTES:
                while line and not line.endswith(b"\n"):
                    line = sys.stdin.buffer.readline(MAX_BYTES + 1)
                raise Refused("Request exceeds the package's declared envelope")
            request = json.loads(
                line,
                parse_constant=lambda _: (_ for _ in ()).throw(
                    Refused("Non-finite JSON")
                ),
            )
            if not isinstance(request, dict) or request.get("jsonrpc") != "2.0":
                raise Refused("Expected JSON-RPC 2.0")
            if "id" not in request:
                continue
            identity = request["id"]
            if not isinstance(identity, (str, int)) or isinstance(identity, bool):
                raise Refused("JSON-RPC id must be a string or integer")
            method = request.get("method")
            if method == "initialize":
                output = {
                    "protocolVersion": "2025-06-18",
                    "serverInfo": {"name": "figma-studio", "version": "0.1.0"},
                    "capabilities": {"tools": {}},
                }
            elif method == "ping":
                output = {}
            elif method == "tools/list":
                private = {
                    "lane_call": schema(
                        {"tool": STRING, "arguments": OBJECT, "caller": OBJECT}
                    ),
                    "lane_observe": schema(
                        {
                            "binding": OBJECT,
                            "sources": {"type": "array", "items": OBJECT},
                        }
                    ),
                }
                output = {
                    "tools": [
                        {
                            "name": name,
                            "description": DESCRIPTIONS.get(
                                name, "Host-owned Studio control port"
                            ),
                            "inputSchema": tool_schema,
                        }
                        for name, tool_schema in {**SCHEMAS, **private}.items()
                    ]
                }
            elif method == "tools/call":
                params = fields(request.get("params"), {"name", "arguments"})
                try:
                    output = worker.call(
                        params["name"], params["arguments"], response_id=identity
                    )
                except Refused as error:
                    output = reject(str(error), pre_effect=True)
            else:
                raise Refused("Unknown method")
            response = {"jsonrpc": "2.0", "id": identity, "result": output}
            encoded = encode(response)
            if len(encoded.encode()) + 1 > MAX_BYTES:
                response["result"] = reject(
                    "Result exceeds declared envelope; read retained operation before retrying",
                    pre_effect=False,
                )
                encoded = encode(response)
        except (
            ValueError,
            TypeError,
            KeyError,
            AttributeError,
            RecursionError,
        ) as error:
            encoded = encode(
                {
                    "jsonrpc": "2.0",
                    "id": identity,
                    "result": reject(str(error), pre_effect=False),
                }
            )
        print(encoded, flush=True)


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--state-dir", type=Path, default=Path("/state"))
    serve(Worker(parser.parse_args().state_dir))
