#!/usr/bin/env python3
"""Deterministic OpenAI chat-completions contract provider.

The contract harness exercises the production task-completion boundary.  This
provider accepts only the request shape that boundary promises: a native JSON
schema request plus the ``report_review_verdict`` tool.  It returns one real
OpenAI-compatible tool call, requires the matching tool result on the next
request, and then ends the model turn.

Malformed or incomplete requests fail explicitly with a non-2xx response; the
fixture never guesses a verdict from prompt text and never treats provider
unavailability as approval.
"""

from __future__ import annotations

import argparse
import itertools
import json
import sys
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import ClassVar, Final, TypeAlias


JsonScalar: TypeAlias = None | bool | int | float | str
JsonValue: TypeAlias = JsonScalar | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]

VERDICT_TOOL: Final = "report_review_verdict"
VERDICT_CALL_ID: Final = "contract-verdict-1"
CHAT_COMPLETIONS_PATH: Final = "/v1/chat/completions"
HEALTH_PATH: Final = "/health"


def object_field(value: JsonValue | None) -> JsonObject | None:
    return value if isinstance(value, dict) else None


def list_field(value: JsonValue | None) -> list[JsonValue] | None:
    return value if isinstance(value, list) else None


class ContractHandler(BaseHTTPRequestHandler):
    """Strict two-request verifier conversation."""

    log_path: ClassVar[Path]
    request_ids: ClassVar[itertools.count[int]] = itertools.count(1)

    def _respond(self, status: HTTPStatus, body: JsonObject) -> None:
        payload = json.dumps(body, separators=(",", ":")).encode("utf-8")
        self.send_response(status.value)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _record(self, record: JsonObject) -> None:
        with self.log_path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, separators=(",", ":")) + "\n")

    def _reject(self, request_id: int, detail: str) -> None:
        record: JsonObject = {
            "request_id": request_id,
            "status": "rejected",
            "detail": detail,
        }
        try:
            self._record(record)
        except OSError as exc:
            detail = f"{detail}; request log write failed: {exc}"
        self._respond(
            HTTPStatus.UNPROCESSABLE_ENTITY,
            {"error": {"type": "contract_request_rejected", "message": detail}},
        )

    @staticmethod
    def _has_verdict_tool(request: JsonObject) -> bool:
        tools = list_field(request.get("tools"))
        if tools is None:
            return False
        for candidate in tools:
            tool = object_field(candidate)
            function = object_field(tool.get("function")) if tool is not None else None
            if function is not None and function.get("name") == VERDICT_TOOL:
                return True
        return False

    @staticmethod
    def _has_verdict_tool_result(request: JsonObject) -> bool:
        messages = list_field(request.get("messages"))
        if messages is None:
            return False
        for candidate in messages:
            message = object_field(candidate)
            if message is None:
                continue
            if (
                message.get("role") == "tool"
                and message.get("tool_call_id") == VERDICT_CALL_ID
            ):
                return True
        return False

    @staticmethod
    def _native_schema_requested(request: JsonObject) -> bool:
        response_format = object_field(request.get("response_format"))
        json_schema = (
            object_field(response_format.get("json_schema"))
            if response_format is not None
            else None
        )
        return (
            response_format is not None
            and response_format.get("type") == "json_schema"
            and json_schema is not None
            and object_field(json_schema.get("schema")) is not None
        )

    @staticmethod
    def _model_name(request: JsonObject) -> str:
        model = request.get("model")
        return model if isinstance(model, str) and model else "contract-verifier"

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler protocol
        if self.path != HEALTH_PATH:
            self._respond(
                HTTPStatus.NOT_FOUND,
                {"error": {"type": "not_found", "message": self.path}},
            )
            return
        self._respond(HTTPStatus.OK, {"ok": True})

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler protocol
        request_id = next(self.request_ids)
        if self.path != CHAT_COMPLETIONS_PATH:
            self._reject(request_id, f"unexpected request path: {self.path}")
            return

        raw_length = self.headers.get("Content-Length")
        try:
            content_length = int(raw_length) if raw_length is not None else 0
        except ValueError:
            self._reject(request_id, "Content-Length must be an integer")
            return
        if content_length <= 0:
            self._reject(request_id, "request body is required")
            return

        raw = self.rfile.read(content_length)
        try:
            decoded: JsonValue = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            self._reject(request_id, f"request body must be UTF-8 JSON: {exc}")
            return
        request = object_field(decoded)
        if request is None:
            self._reject(request_id, "request JSON must be an object")
            return
        if request.get("stream") is True:
            self._reject(
                request_id, "contract verifier requires non-streaming chat completions"
            )
            return
        if not self._native_schema_requested(request):
            self._reject(request_id, "response_format.type=json_schema is required")
            return
        if not self._has_verdict_tool(request):
            self._reject(request_id, f"{VERDICT_TOOL} tool declaration is required")
            return

        has_tool_result = self._has_verdict_tool_result(request)
        phase = "tool_result" if has_tool_result else "verdict_call"
        try:
            self._record(
                {
                    "request_id": request_id,
                    "status": "accepted",
                    "phase": phase,
                    "model": self._model_name(request),
                }
            )
        except OSError as exc:
            self._respond(
                HTTPStatus.INTERNAL_SERVER_ERROR,
                {
                    "error": {
                        "type": "contract_observation_failed",
                        "message": f"request log write failed: {exc}",
                    }
                },
            )
            return

        if has_tool_result:
            message: JsonObject = {
                "role": "assistant",
                "content": "Completion verdict was reported through the required tool.",
            }
            finish_reason = "stop"
        else:
            message = {
                "role": "assistant",
                "content": None,
                "tool_calls": [
                    {
                        "id": VERDICT_CALL_ID,
                        "type": "function",
                        "function": {
                            "name": VERDICT_TOOL,
                            "arguments": json.dumps(
                                {
                                    "verdict": "APPROVE",
                                    "reason": "The contract evidence names every completed live MCP step.",
                                },
                                separators=(",", ":"),
                            ),
                        },
                    }
                ],
            }
            finish_reason = "tool_calls"

        self._respond(
            HTTPStatus.OK,
            {
                "id": f"chatcmpl-contract-{request_id}",
                "object": "chat.completion",
                "created": 0,
                "model": self._model_name(request),
                "choices": [
                    {
                        "index": 0,
                        "message": message,
                        "finish_reason": finish_reason,
                    }
                ],
                "usage": {
                    "prompt_tokens": 1,
                    "completion_tokens": 1,
                    "total_tokens": 2,
                },
            },
        )

    def log_message(self, format: str, *args: object) -> None:  # noqa: A002
        # Accepted and rejected requests are recorded as structured JSON above.
        del format, args


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--log", type=Path, required=True)
    args = parser.parse_args()

    ContractHandler.log_path = args.log
    server = ThreadingHTTPServer(("127.0.0.1", args.port), ContractHandler)
    sys.stderr.write(f"[contract-verifier] listening on 127.0.0.1:{args.port}\n")
    sys.stderr.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
