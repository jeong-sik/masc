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
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise InvalidInput(f"{field} must be a finite number")
    return float(value)


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


def serve(name: str, observe: Callable[[dict, tuple[Source, ...]], dict]) -> None:
    """One synchronous package worker. Host owns isolation and cancellation."""
    for line in sys.stdin:
        request_id = None
        try:
            request = object_value(json.loads(line), "request")
            request_id = request.get("id")
            method = request.get("method")
            if request.get("jsonrpc") != "2.0" or not isinstance(method, str):
                raise InvalidInput("expected a JSON-RPC 2.0 request")
            if "id" not in request:
                continue
            params = object_value(request.get("params", {}), "params")
            if method == "initialize":
                result = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
                          "serverInfo": {"name": name, "version": "0.1.0"}}
            elif method == "ping":
                result = {}
            elif method == "tools/list":
                result = {"tools": [{"name": "lane_observe",
                           "description": "Read supplied source snapshots and derive Lane rows; no external actions.",
                           "inputSchema": INPUT_SCHEMA, "outputSchema": OUTPUT_SCHEMA,
                           "annotations": {"readOnlyHint": True, "destructiveHint": False,
                                           "idempotentHint": True, "openWorldHint": False}}]}
            elif method == "tools/call":
                if params.get("name") != "lane_observe":
                    raise InvalidInput("unknown tool")
                arguments = object_value(params.get("arguments"), "arguments")
                try:
                    output = observe(object_value(arguments.get("binding"), "binding"),
                                     sources_from_json(arguments.get("sources")))
                    encoded = json.dumps(output, ensure_ascii=False, allow_nan=False)
                    result = {"content": [{"type": "text", "text": encoded}],
                              "structuredContent": output, "isError": False}
                except InvalidInput as error:
                    result = {"content": [{"type": "text", "text": str(error)}], "isError": True}
            else:
                response = {"jsonrpc": "2.0", "id": request_id,
                            "error": {"code": -32601, "message": "Method not found"}}
                print(json.dumps(response), flush=True)
                continue
            response = {"jsonrpc": "2.0", "id": request_id, "result": result}
        except json.JSONDecodeError:
            response = {"jsonrpc": "2.0", "id": None,
                        "error": {"code": -32700, "message": "Parse error"}}
        except InvalidInput as error:
            response = {"jsonrpc": "2.0", "id": request_id,
                        "error": {"code": -32602, "message": str(error)}}
        print(json.dumps(response, ensure_ascii=False, allow_nan=False), flush=True)
