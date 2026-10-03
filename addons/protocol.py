"""MCP stdio framing and the presentation contract shared by example packages.

There is no domain dispatch here. A package supplies its own observe function;
the host only sees the rows and coverage described by outputSchema.
"""

from __future__ import annotations

import hashlib
import json
import math
import sys
from dataclasses import dataclass
from typing import Any, Callable


class InvalidInput(ValueError):
    pass


class UnknownMethod(ValueError):
    pass


def validate_json(value: Any) -> None:
    """Refuse values that cannot be encoded as finite UTF-8 JSON."""
    pending = [(value, False)]
    active = set()
    while pending:
        item, leaving = pending.pop()
        if leaving:
            active.remove(id(item))
            continue
        if isinstance(item, float) and not math.isfinite(item):
            raise InvalidInput("JSON data must contain only finite numbers")
        if isinstance(item, str):
            try:
                item.encode("utf-8")
            except UnicodeEncodeError as error:
                raise InvalidInput("JSON strings must be valid UTF-8") from error
        elif isinstance(item, dict):
            if id(item) in active:
                raise InvalidInput("JSON data must not contain reference cycles")
            active.add(id(item))
            pending.append((item, True))
            for key, child in item.items():
                pending.extend(((key, False), (child, False)))
        elif isinstance(item, (list, tuple)):
            if id(item) in active:
                raise InvalidInput("JSON data must not contain reference cycles")
            active.add(id(item))
            pending.append((item, True))
            pending.extend((child, False) for child in item)


def object_value(value: Any, field: str) -> dict:
    if not isinstance(value, dict):
        raise InvalidInput(f"{field} must be an object")
    return value


def string(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value:
        raise InvalidInput(f"{field} must be a nonempty string")
    return value


def optional_string(value: Any, field: str) -> str | None:
    return None if value is None else string(value, field)


def number(value: Any, field: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise InvalidInput(f"{field} must be a finite number")
    try:
        converted = float(value)
    except OverflowError as error:
        raise InvalidInput(f"{field} must be a finite number") from error
    if not math.isfinite(converted):
        raise InvalidInput(f"{field} must be a finite number")
    return converted


def decode_json(value: str) -> Any:
    try:
        return json.loads(value)
    except json.JSONDecodeError:
        raise
    except RecursionError as error:
        raise InvalidInput("JSON nesting exceeds the decoder limit") from error
    except ValueError as error:
        raise InvalidInput("JSON value exceeds the decoder limits") from error


def finite_json(value: Any, field: str) -> None:
    """Validate retained JSON without copying or normalizing its payload."""
    pending = [value]
    while pending:
        item = pending.pop()
        if isinstance(item, float) and not math.isfinite(item):
            raise InvalidInput(f"{field} must contain only finite JSON numbers")
        if isinstance(item, dict):
            pending.extend(item.values())
        elif isinstance(item, list):
            pending.extend(item)


def boolean(value: Any, field: str) -> bool:
    if not isinstance(value, bool):
        raise InvalidInput(f"{field} must be a boolean")
    return value


def evidence(value: Any) -> list[dict]:
    if not isinstance(value, list):
        raise InvalidInput("evidence must be an array")
    result = []
    for item in value:
        item = object_value(item, "evidence item")
        digest = optional_string(item.get("sha256"), "sha256")
        if digest is not None and (len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest)):
            raise InvalidInput("sha256 must be a lowercase SHA-256 digest or null")
        result.append({"uri": string(item.get("uri"), "evidence.uri"), "sha256": digest})
    return result


def stable_id(*parts: Any) -> str:
    encoded = json.dumps(parts, sort_keys=True, separators=(",", ":"), allow_nan=False)
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()


@dataclass(frozen=True)
class Source:
    source_id: str
    incarnation: str
    cursor: str | None
    complete: bool
    detail: str | None
    observations: tuple[dict, ...]

    def coverage(self, skipped: set[str]) -> dict:
        details = [self.detail] if self.detail is not None else []
        if skipped:
            details.append("Kinds outside this package: " + ", ".join(sorted(skipped)))
        return {"source_id": self.source_id, "incarnation": self.incarnation,
                "cursor": self.cursor, "complete": self.complete,
                "detail": "; ".join(details) if details else None}


def sources_from_json(value: Any) -> tuple[Source, ...]:
    if not isinstance(value, list):
        raise InvalidInput("sources must be an array")
    sources = []
    for item in value:
        item = object_value(item, "source")
        observations = item.get("observations")
        if not isinstance(observations, list):
            raise InvalidInput("source.observations must be an array")
        sources.append(Source(
            string(item.get("source_id"), "source_id"),
            string(item.get("incarnation"), "incarnation"),
            optional_string(item.get("cursor"), "cursor"),
            boolean(item.get("complete"), "complete"),
            optional_string(item.get("detail"), "detail"),
            tuple(object_value(obs, "observation") for obs in observations)))
    return tuple(sources)


def row(source: Source, observation: dict, *, lane: str, subject: str,
        title: str, fields: dict, kind: str = "event", clock: dict | None = None) -> dict:
    event_id = string(observation.get("id"), "observation.id")
    return {"id": stable_id(source.source_id, source.incarnation, event_id),
            "lane_id": lane, "kind": kind, "title": title,
            "observed_at": number(observation.get("observed_at"), "observed_at"),
            "subject_id": subject, "clock": clock,
            "actor": optional_string(observation.get("actor"), "actor"),
            "fields": {"source_id": source.source_id, "incarnation": source.incarnation,
                       "source_event_id": event_id, **fields},
            "evidence": evidence(observation.get("evidence")), "related_ids": []}


NULLABLE_STRING = {"type": ["string", "null"]}
EVIDENCE_SCHEMA = {
    "type": "object", "required": ["uri", "sha256"],
    "properties": {"uri": {"type": "string"}, "sha256": NULLABLE_STRING},
    "additionalProperties": False}
ROW_SCHEMA = {
    "type": "object", "additionalProperties": False,
    "required": ["id", "lane_id", "kind", "title", "observed_at", "subject_id",
                 "clock", "actor", "fields", "evidence", "related_ids"],
    "properties": {
        **{key: {"type": "string"} for key in ("id", "lane_id", "title", "subject_id")},
        "kind": {"enum": ["event", "value", "relation"]}, "observed_at": {"type": "number"},
        "actor": NULLABLE_STRING, "fields": {"type": "object"},
        "clock": {"anyOf": [{"type": "null"}, {"type": "object",
                  "properties": {"domain": {"type": "string"}, "value": {"type": "string"}},
                  "required": ["domain", "value"], "additionalProperties": False}]},
        "evidence": {"type": "array", "items": EVIDENCE_SCHEMA},
        "related_ids": {"type": "array", "items": {"type": "string"}}}}
OUTPUT_SCHEMA = {
    "type": "object", "required": ["rows", "coverage"], "additionalProperties": False,
    "properties": {
        "rows": {"type": "array", "items": ROW_SCHEMA},
        "coverage": {"type": "array", "items": {
            "type": "object", "additionalProperties": False,
            "required": ["source_id", "incarnation", "cursor", "complete", "detail"],
            "properties": {"source_id": {"type": "string"},
                           "incarnation": {"type": "string"}, "cursor": NULLABLE_STRING,
                           "complete": {"type": "boolean"}, "detail": NULLABLE_STRING}}}}}
INPUT_SCHEMA = {
    "type": "object", "required": ["binding", "sources"], "additionalProperties": False,
    "properties": {"binding": {"type": "object"}, "sources": {"type": "array",
                                                                            "items": {"type": "object"}}}}


class SamplingFailure(Exception):
    """The host returned an actual JSON-RPC sampling error."""

    def __init__(self, error: dict):
        self.error = error
        super().__init__(str(error.get("message", "Sampling failed")))


class SamplingClient:
    """Synchronous MCP sampling on this worker's existing stdio connection.

    Each installed worker has its own connection. This client never recursively
    invokes a tool and never selects credentials or a host runtime.
    """

    def __init__(self, *, max_request_bytes: int):
        if type(max_request_bytes) is not int or max_request_bytes <= 0:
            raise InvalidInput("max_request_bytes must be a positive integer")
        self.max_request_bytes = max_request_bytes
        self.supported = False
        self.sequence = 0

    def initialize(self, params: dict) -> None:
        capabilities = object_value(params.get("capabilities", {}), "client capabilities")
        self.supported = isinstance(capabilities.get("sampling"), dict)

    def create_message(self, params: dict) -> dict:
        if not self.supported:
            raise InvalidInput("Host did not advertise MCP sampling")
        self.sequence += 1
        request_id = f"lane-sampling-{self.sequence}"
        encoded = json.dumps({"jsonrpc": "2.0", "id": request_id,
                          "method": "sampling/createMessage", "params": params},
                         ensure_ascii=False, allow_nan=False)
        if len((encoded + "\n").encode("utf-8")) > self.max_request_bytes:
            raise InvalidInput("Sampling request exceeds the declared message envelope; no model call was attempted")
        print(encoded, flush=True)
        while True:
            # The manifest's envelope is a byte boundary, including newline.
            # Share the binary buffer with serve so neither text wrapper can
            # read ahead and hide a duplex response or a following request.
            line = sys.stdin.buffer.readline(self.max_request_bytes + 1)
            if len(line) > self.max_request_bytes:
                while line and not line.endswith(b"\n"):
                    line = sys.stdin.buffer.readline(self.max_request_bytes + 1)
                raise InvalidInput("Host sampling response exceeds the declared message envelope; "
                                   "no response was accepted and the model-call outcome is unconfirmed")
            if not line:
                raise InvalidInput("Host closed stdio before answering sampling")
            try:
                decoded = decode_json(line.decode("utf-8"))
            except (json.JSONDecodeError, UnicodeDecodeError) as error:
                raise InvalidInput("Malformed host sampling response") from error
            except ValueError as error:
                raise InvalidInput("Host sampling response exceeds the JSON decoder limits; "
                                   "no response was accepted and the model-call outcome is unconfirmed") from error
            response = object_value(decoded, "sampling response")
            validate_json(response)
            if response.get("jsonrpc") != "2.0":
                raise InvalidInput("Expected JSON-RPC sampling response")
            if "method" in response:
                if "id" not in response:
                    continue
                nested_id = response["id"]
                if (not isinstance(response["method"], str)
                        or not (nested_id is None or isinstance(nested_id, (str, int, float))
                                and not isinstance(nested_id, bool))):
                    raise InvalidInput("Interleaved host request requires a string method and scalar JSON-RPC id")
                if response["method"] == "ping":
                    reply = {"result": {}}
                else:
                    reply = {"error": {"code": -32000,
                                       "message": "Worker is awaiting host sampling"}}
                encoded = json.dumps({"jsonrpc": "2.0", "id": nested_id, **reply},
                                     ensure_ascii=False, allow_nan=False)
                if len((encoded + "\n").encode("utf-8")) > self.max_request_bytes:
                    encoded = json.dumps({"jsonrpc": "2.0", "id": nested_id,
                        "error": {"code": -32603, "message": "Reply too large"}},
                        ensure_ascii=False, allow_nan=False)
                    if len((encoded + "\n").encode("utf-8")) > self.max_request_bytes:
                        raise InvalidInput("Interleaved host request cannot receive an exact-id reply "
                                           "within the declared envelope; the model-call outcome is unconfirmed")
                print(encoded, flush=True)
                continue
            if response.get("id") != request_id:
                raise InvalidInput("Sampling response ID does not match the request")
            if "error" in response:
                raise SamplingFailure(object_value(response["error"], "sampling error"))
            return object_value(response.get("result"), "sampling result")


def reply_id(value: Any) -> str | int | float | None:
    if value is None:
        return None
    if isinstance(value, str):
        try:
            value.encode("utf-8")
        except UnicodeEncodeError as error:
            raise InvalidInput("JSON-RPC ID must be valid UTF-8") from error
        return value
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise InvalidInput("JSON-RPC ID must be a string, number or null")
    if isinstance(value, float) and not math.isfinite(value):
        raise InvalidInput("JSON-RPC ID must be finite")
    return value


def encode_output(value: Any) -> str:
    try:
        encoded = json.dumps(value, ensure_ascii=False, allow_nan=False)
        encoded.encode("utf-8")
        return encoded
    except (ValueError, TypeError, RecursionError, UnicodeEncodeError) as error:
        raise InvalidInput("Observation must be serializable finite JSON with valid UTF-8") from error


def serve(name: str, observe: Callable[[dict, tuple[Source, ...]], dict],
          *, version: str = "0.1.0", sampling_client: SamplingClient | None = None,
          text_summary: Callable[[dict], str] | None = None, max_reply_bytes: int | None = None) -> None:
    """One synchronous package worker. Host owns isolation and cancellation."""
    if max_reply_bytes is not None and (isinstance(max_reply_bytes, bool)
            or not isinstance(max_reply_bytes, int) or max_reply_bytes <= 0):
        raise InvalidInput("max_reply_bytes must be a positive integer")
    for line in sys.stdin.buffer:
        request_id = None
        method = None
        try:
            request = object_value(decode_json(line.decode("utf-8")), "request")
            request_id = reply_id(request.get("id"))
            method = request.get("method")
            if request.get("jsonrpc") != "2.0":
                raise InvalidInput("expected a JSON-RPC 2.0 request")
            if "method" not in request and ("result" in request or "error" in request):
                # A sampling completion can already be queued when its nested
                # host request is refused. Responses are not new requests and
                # must not produce either a tool answer or a response loop.
                continue
            if not isinstance(method, str):
                raise InvalidInput("expected a JSON-RPC 2.0 request")
            if "id" not in request:
                continue
            params = object_value(request.get("params", {}), "params")
            if method == "initialize":
                if sampling_client is not None:
                    sampling_client.initialize(params)
                result = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
                          "serverInfo": {"name": name, "version": version}}
            elif method == "ping":
                result = {}
            elif method == "tools/list":
                result = {"tools": [{"name": "lane_observe",
                           "description": ("Read supplied source snapshots and derive Lane rows; no external actions."
                                           if sampling_client is None else
                                           "Analyze supplied retained inputs through host MCP sampling; no publication."),
                           "inputSchema": INPUT_SCHEMA, "outputSchema": OUTPUT_SCHEMA,
                           "annotations": {"readOnlyHint": sampling_client is None, "destructiveHint": False,
                                           "idempotentHint": sampling_client is None,
                                           "openWorldHint": sampling_client is not None}}]}
            elif method == "tools/call":
                if params.get("name") != "lane_observe":
                    raise InvalidInput("unknown tool")
                arguments = object_value(params.get("arguments"), "arguments")
                try:
                    validate_json(arguments)
                    output = observe(object_value(arguments.get("binding"), "binding"),
                                     sources_from_json(arguments.get("sources")))
                    validate_json(output)
                    encoded_output = encode_output(output)
                    encoded = (encoded_output if text_summary is None
                               else string(text_summary(output), "output summary"))
                    encode_output(encoded)
                    result = {"content": [{"type": "text", "text": encoded}],
                              "structuredContent": output, "isError": False}
                except InvalidInput as error:
                    result = {"content": [{"type": "text", "text": str(error)}], "isError": True}
                except RecursionError:
                    result = {"content": [{"type": "text", "text": "JSON nesting exceeds the encoder limit"}], "isError": True}
            else:
                raise UnknownMethod
            response = {"jsonrpc": "2.0", "id": request_id, "result": result}
        except UnknownMethod:
            response = {"jsonrpc": "2.0", "id": request_id,
                        "error": {"code": -32601, "message": "Method not found"}}
        except (json.JSONDecodeError, UnicodeDecodeError):
            response = {"jsonrpc": "2.0", "id": None,
                        "error": {"code": -32700, "message": "Parse error"}}
        except InvalidInput as error:
            response = {"jsonrpc": "2.0", "id": request_id,
                        "error": {"code": -32602, "message": str(error)}}
        except RecursionError:
            response = {"jsonrpc": "2.0", "id": request_id,
                        "error": {"code": -32602, "message": "JSON nesting exceeds the decoder limit"}}
        try:
            encoded = encode_output(response)
        except InvalidInput:
            if method == "tools/call":
                response = {"jsonrpc": "2.0", "id": request_id, "result": {
                    "content": [{"type": "text", "text": "Tool response must be valid UTF-8 JSON"}],
                    "isError": True}}
            else:
                response = {"jsonrpc": "2.0", "id": request_id,
                            "error": {"code": -32602, "message": "Response must be valid UTF-8 JSON"}}
            encoded = encode_output(response)
        if max_reply_bytes is not None and len((encoded + "\n").encode("utf-8")) > max_reply_bytes:
            if method == "tools/call":
                response = {"jsonrpc": "2.0", "id": request_id, "result": {
                    "content": [{"type": "text", "text": "Observation exceeds the declared reply envelope; no output was accepted"}],
                    "isError": True}}
            else:
                response = {"jsonrpc": "2.0", "id": request_id,
                            "error": {"code": -32603, "message": "Reply too large"}}
            encoded = json.dumps(response, ensure_ascii=False, allow_nan=False)
            if len((encoded + "\n").encode("utf-8")) > max_reply_bytes:
                raise RuntimeError("Declared reply envelope cannot contain an exact JSON-RPC error response")
        print(encoded, flush=True)
