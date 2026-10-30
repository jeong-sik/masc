#!/usr/bin/env python3
"""Owned loopback Keeper/model/queue workload using an installed binary.

No build, operator credentials, live workspace, or sandbox execution. Keepers
declare the lazy microVM lane; its image pin is fixture metadata, not evidence
that a guest/image exists. The scripted provider emits only final text. Queue
batching is observed rather than forced into one model call per message.
"""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import concurrent.futures
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
import hashlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import math
import os
from pathlib import Path
import shutil
import signal
import socket
import sqlite3
import subprocess
import sys
import threading
import time
import tomllib
from urllib.parse import urlsplit
import uuid

import keeper_scale_trace

EVIDENCE_SCHEMA = "masc.keeper-scale-evidence.v3"
OPERATION_FIELDS = ("operation_id", "state", "started_at", "completed_at", "outcome_ref", "failure_kind")


class ProbeError(RuntimeError):
    def __init__(self, detail, row=None):
        super().__init__(detail)
        self.row = row


def require(condition, detail):
    if not condition:
        raise ProbeError(detail)


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def operation_key(operation):
    return operation["keeper"], operation["operation_id"]


def index_operations(operations):
    indexed = {}
    inputs = set()
    for operation in operations:
        key = operation_key(operation)
        require(key not in indexed, "two original inputs share one authoritative Keeper operation identity")
        original_input = operation["keeper"], operation["sequence"]
        require(original_input not in inputs, "original workload input occurs more than once")
        indexed[key] = operation
        inputs.add(original_input)
    return indexed


def terminal_receipt(operations, terminal):
    return {"schema": EVIDENCE_SCHEMA, "operations": [
        {"keeper": operation["keeper"], "sequence": operation["sequence"],
         "operation_id": operation["operation_id"], "status": terminal[operation_key(operation)]}
        for operation in operations if operation_key(operation) in terminal]}


def validate_completed_operation(operation, status, marker):
    require(status.get("operation_id") == operation["operation_id"], "public operation identity differs from requested input")
    require(status.get("state") == "Succeeded", "operation failed; inspect terminal.json/requests.jsonl")
    replies = [obj for obj in objects(status.get("completed_reply"))
               if obj.get("schema") == "masc.keeper-scale-reply.v1"
               and obj.get("marker") == marker and obj.get("keeper") == operation["keeper"]
               and isinstance(obj.get("sequences"), list)
               and all(type(sequence) is int for sequence in obj["sequences"])
               and operation["sequence"] in obj["sequences"]]
    require(len(replies) == 1, "full completed reply does not cover its exact original queued input")


def typed_rows(columns, rows):
    return [[(column, type(row[column]).__name__, row[column]) for column in columns] for row in rows]


def typed_rows_digest(columns, rows):
    canonical = [[(column, kind, value.hex() if isinstance(value, bytes) else repr(value))
                  for column, kind, value in row] for row in typed_rows(columns, rows)]
    return hashlib.sha256(json.dumps(canonical, ensure_ascii=False, separators=(",", ":")).encode()).hexdigest()


def canonical_payload(value):
    # This fixture generates ASCII strings, nulls, lists and objects only.
    # Within that domain sorted compact JSON equals the producer's Yojson
    # canonical bytes. Reject extensions instead of claiming a general codec.
    def check(item):
        if item is None:
            return
        if isinstance(item, str):
            require(item.isascii(), "payload canonicalizer requires ASCII fixture strings")
        elif isinstance(item, list):
            for child in item:
                check(child)
        elif isinstance(item, dict):
            for key, child in item.items():
                require(isinstance(key, str), "payload object key is not a string")
                check(key)
                check(child)
        else:
            raise ProbeError("payload canonicalizer refuses non-fixture JSON types")
    check(value)
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"))


def payload_digest(value):
    return hashlib.sha256(canonical_payload(value).encode()).hexdigest()


def original_payload(name, message):
    thread = "keeper:" + name
    source = {"schema": "masc.keeper_chat_operation.source.v2", "submitted_by": "dashboard",
        "thread_id": thread, "continuation_channel": {"kind": "dashboard", "thread_id": thread},
        "surface": {"kind": "agent"}, "channel": "agent", "channel_user_id": "",
        "channel_user_name": "", "channel_workspace_id": "", "conversation_id": None,
        "external_message_id": None, "workspace_id": None, "extra_mentions": [],
        "sender_keeper": None, "user_row_origin": "needs_append"}
    input_ = {"schema": "masc.keeper_chat_operation.input.v1", "message": message,
        "user_blocks": [], "turn_instructions": None, "surface_context": None, "attachments": []}
    return {"source": source, "input": input_}


def read_admission_snapshot(path):
    connection = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True)
    try:
        connection.row_factory = sqlite3.Row
        connection.execute("BEGIN")
        snapshot = {}
        for table, order in (("operations", "sequence"), ("operation_batch_members", "execution_id,position")):
            cursor = connection.execute("SELECT * FROM " + table + " ORDER BY " + order)
            snapshot[table] = {"columns": [item[0] for item in cursor.description],
                               "rows": [dict(row) for row in cursor]}
        connection.rollback()
        return snapshot
    finally:
        connection.close()


def validate_original_payloads(operations, snapshots, public, terminal):
    expected = index_operations(operations)
    require(len(snapshots) == len({op["keeper"] for op in operations}), "snapshot population differs")
    seen = set()
    for snapshot in snapshots:
        name, tables = snapshot["keeper"], snapshot["snapshot"]
        rows = tables["operations"]["rows"]
        by_id = {row["operation_id"]: row for row in rows}
        owned = {key[1]: op for key, op in expected.items() if key[0] == name}
        require(len(by_id) == len(rows) and set(by_id) == set(owned), "snapshot operation coverage differs")
        groups = defaultdict(list)
        members = {}
        for member in tables["operation_batch_members"]["rows"]:
            opid = member["operation_id"]
            require(opid in owned and opid not in members and member["execution_id"] in owned,
                    "batch membership identity differs")
            members[opid] = member
            groups[member["execution_id"]].append(member)
            original = owned[opid]["original"]["input"]
            require(member["admitted_digest"] == payload_digest(original), "batch original digest differs")
            require(member["admitted_input_json"] == (None if terminal else canonical_payload(original)),
                    "batch original input differs")
        combined = {}
        for leader, group in groups.items():
            group.sort(key=lambda item: item["position"])
            sequence = [by_id[item["operation_id"]]["sequence"] for item in group]
            require(len(group) >= 2 and [item["position"] for item in group] == list(range(len(group)))
                    and group[0]["operation_id"] == leader
                    and sequence == list(range(sequence[0], sequence[0] + len(group))),
                    "batch is not a contiguous ordered prefix with its leader")
            inputs = [owned[item["operation_id"]]["original"]["input"] for item in group]
            combined[leader] = {**inputs[0], "message": "\n\n".join(item["message"] for item in inputs),
                "user_blocks": [{"type": "text", "text": item["message"]} for item in inputs]}
        for opid, row in by_id.items():
            key = name, opid
            require(key not in seen, "snapshot Keeper occurs twice")
            seen.add(key)
            original = owned[opid]["original"]
            status = public[key]
            execution = combined.get(opid, original["input"])
            member = members.get(opid)
            # Exact-operation reads project a batch leader's state onto each
            # follower; its physical row can still be queued while Running.
            public_state = by_id[member["execution_id"]]["state"] if member else row["state"]
            require(row["source_json"] == canonical_payload(original["source"])
                    and row["admission_digest"] == payload_digest(original)
                    and row["execution_digest"] == payload_digest(execution)
                    and row["input_json"] == (None if terminal else canonical_payload(execution)),
                    "stored source/input/digests differ from original fixture input")
            require(status["source"] == original["source"]
                    and status["admission_digest"] == row["admission_digest"]
                    and status["execution_digest"] == row["execution_digest"]
                    and status["input"] == (None if terminal else execution)
                    and status["sequence"] == str(row["sequence"])
                    and status["created_at"] == row["created_at"]
                    and status["state"].lower() == public_state,
                    "public original payload differs from exact SQLite snapshot")
            require(status.get("batch_execution_id") == (None if member is None else member["execution_id"])
                    and status.get("batch_input_digest") == (None if member is None else member["admitted_digest"]),
                    "public batch binding differs from original SQLite member")
    require(seen == set(expected), "original payload snapshot coverage differs")


def read_operation_store(path):
    connection = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True)
    try:
        require(connection.execute("PRAGMA integrity_check").fetchall() == [("ok",)],
                "operation store integrity_check failed: " + str(path))
        connection.row_factory = sqlite3.Row
        cursor = connection.execute("SELECT * FROM operations ORDER BY sequence")
        columns = [item[0] for item in cursor.description]
        return columns, [dict(row) for row in cursor]
    finally:
        connection.close()


def verify_operation_backup(source_columns, source_rows, backup_path):
    columns, rows = read_operation_store(backup_path)
    require(columns == source_columns and typed_rows(columns, rows) == typed_rows(source_columns, source_rows),
            "closed backup rows differ from closed source store")
    return {"backup_path": str(backup_path), "integrity_check": "ok", "read_only_reopened": True,
            "source_connection_closed": True, "exact_typed_rows_equal": True,
            "columns": columns, "row_count": len(rows), "typed_rows_sha256": typed_rows_digest(columns, rows)}


def copy_operation_store(database, backup_path):
    columns, source_rows = read_operation_store(database)
    connection = sqlite3.connect(database.resolve().as_uri() + "?mode=ro", uri=True)
    try:
        backup = sqlite3.connect(backup_path)
        try:
            connection.backup(backup)
            backup.commit()
        finally:
            backup.close()
    finally:
        connection.close()
    # Both source and writable backup connections are closed before verification.
    validation = verify_operation_backup(columns, source_rows, backup_path)
    rows = [{field: row[field] for field in OPERATION_FIELDS} for row in source_rows]
    return rows, validation


def validate_durable_operations(operations, names, durable, terminal, marker):
    expected = index_operations(operations)
    require(set(terminal) == set(expected), "public terminal coverage differs from original inputs")
    require(Counter(item["keeper"] for item in durable) == Counter(names), "durable Keeper population differs")
    stored = {}
    for item in durable:
        owner = item["keeper"]
        owned = {key for key in expected if key[0] == owner}
        keys = [(owner, row["operation_id"]) for row in item["rows"]]
        require(len(keys) == len(set(keys)) and set(keys) == owned,
                "durable rows do not cover each exact original Keeper input")
        for row in item["rows"]:
            key = owner, row["operation_id"]
            public = terminal[key]
            validate_completed_operation(expected[key], public, marker)
            require(row["state"] == "succeeded" and row["outcome_ref"]
                    and row["outcome_ref"] == public["outcome_ref"]
                    and row["started_at"] is not None and row["completed_at"] is not None
                    and row["completed_at"] == public["completed_at"] and row["failure_kind"] is None,
                    "offline operation state/outcome differs from exact public input")
            stored[key] = row
    require(set(stored) == set(expected) and len(stored) == len(operations), "durable original input coverage differs")
    return stored


def denied_inventory_kind(row, guard_dir, names):
    """Classify denied observations only; wrappers still refuse every command."""
    argv = row.get("argv", [])
    if not argv:
        return None
    command = Path(argv[0])
    if command.parent != guard_dir:
        return None
    if command.name == "container" and argv[1:] == ["list", "--all", "--format", "json"]:
        return "container_list"
    if (command.name == "nerdctl" and len(argv) == 6
            and argv[1:5] == ["ps", "-a", "--no-trunc", "--format"]):
        return "nerdctl_ps"
    if command.name == "container" and len(argv) == 4 and argv[1:3] == ["volume", "inspect"]:
        expected = {"masc-keeper-" + kind + "-" + name for kind in ("work", "build") for name in names}
        if argv[3] in expected:
            return "container_volume_inspect"
    return None


def objects(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from objects(child)
    elif isinstance(value, list):
        for child in value:
            yield from objects(child)
    elif isinstance(value, str):
        for line in value.splitlines():
            try:
                decoded = json.loads(line)
            except ValueError:
                continue
            if not isinstance(decoded, str):
                yield from objects(decoded)


def decode_rpc(raw, request_id):
    try:
        document = json.loads(raw)
    except ValueError:
        events = []
        for block in raw.decode().replace("\r\n", "\n").split("\n\n"):
            data = "\n".join(line[5:].lstrip() for line in block.splitlines()
                             if line.startswith("data:"))
            if data:
                events.append(json.loads(data))
        matches = [event for event in events if event.get("id") == request_id]
        require(len(matches) == 1, "MCP response has no unique matching result")
        document = matches[0]
    require(document.get("id") == request_id and "error" not in document,
            "JSON-RPC failed; inspect requests.jsonl")
    return document["result"]


class Client:
    def __init__(self, port, token, output, timeout):
        self.port, self.token, self.output, self.timeout = port, token, output, timeout
        self.sequence = 0
        self.sequence_lock = threading.Lock()
        self.log_lock = threading.Lock()
        self.session = None
        self.protocol = "2025-11-25"

    def request(self, method, path, payload=None, phase=None):
        headers = {"Accept": "application/json, text/event-stream", "Accept-Encoding": "identity"}
        if self.token:
            headers["Authorization"] = "Bearer " + self.token
        if self.session and path == "/mcp":
            headers.update({"Mcp-Session-Id": self.session,
                            "Mcp-Protocol-Version": self.protocol})
        body = None if payload is None else json.dumps(payload).encode()
        if body is not None:
            headers["Content-Type"] = "application/json"
        client = http.client.HTTPConnection("127.0.0.1", self.port, timeout=self.timeout)
        started = time.perf_counter_ns()
        row = {"method": method, "path": path, "phase": phase, "start_ns": started}
        if payload is not None:
            row["payload"] = payload
        try:
            client.request(method, path, body, headers)
            response = client.getresponse()
            wire = response.read()
            finished = time.perf_counter_ns()
            row.update(status=response.status, end_ns=finished,
                       wire_ms=(finished-started)/1e6, wire_bytes=len(wire),
                       body_utf8=wire.decode(), body_sha256=hashlib.sha256(wire).hexdigest(),
                       server_timing=response.getheader("Server-Timing"))
            row["rate_headers"] = {key: value for key, value in response.getheaders()
                                   if key.lower().startswith("x-ratelimit")
                                   or key.lower() == "retry-after"}
            if response.status != 200:
                raise ProbeError("HTTP failure; inspect requests.jsonl", row=row)
            return wire, dict(response.getheaders()), row
        except (OSError, http.client.HTTPException) as error:
            row.update(error=type(error).__name__, error_detail=str(error),
                       end_ns=time.perf_counter_ns())
            raise
        finally:
            client.close()
            if phase is not None:
                with self.log_lock, (self.output / "requests.jsonl").open("a") as log:
                    log.write(json.dumps(row, ensure_ascii=False) + "\n")

    def get(self, path, phase=None):
        raw, _, row = self.request("GET", path, phase=phase)
        return json.loads(raw), row

    def rpc(self, method, params, phase):
        with self.sequence_lock:
            self.sequence += 1
            request_id = self.sequence
        payload = {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}
        first_attempt = time.perf_counter_ns()
        deadline = time.monotonic() + self.timeout
        retries = []
        while True:
            try:
                raw, headers, row = self.request("POST", "/mcp", payload, phase)
                break
            except ProbeError as error:
                # Server_auth rejects 429 before tool dispatch. No ambiguous
                # transport/server failures are retried, and limits stay on.
                failed = error.row
                if failed is None or failed.get("status") != 429:
                    raise
                raw_retry = next((value for key, value in failed["rate_headers"].items()
                                  if key.lower() == "retry-after"), None)
                delay, source = 1.0, "client_fallback_no_retry_after"
                if raw_retry is not None:
                    try:
                        delay = float(raw_retry)
                        require(math.isfinite(delay) and delay >= 0, "invalid Retry-After")
                        source = "server_retry_after_seconds"
                    except ValueError:
                        until = parsedate_to_datetime(raw_retry)
                        require(until.tzinfo is not None, "Retry-After date has no timezone")
                        delay = max(0.0, until.timestamp() - time.time())
                        source = "server_retry_after_date"
                require(time.monotonic() + delay < deadline, "rate-limit observation deadline")
                retry = {"request_id": request_id, "phase": phase, "raw_retry_after": raw_retry,
                         "delay_s": delay, "source": source, "wait_started_ns": time.perf_counter_ns()}
                time.sleep(delay)
                retry["wait_finished_ns"] = time.perf_counter_ns()
                retries.append(retry)
                with self.log_lock, (self.output / "rate-limit-waits.jsonl").open("a") as log:
                    log.write(json.dumps(retry) + "\n")
        row["first_attempt_to_response_ms"] = (time.perf_counter_ns() - first_attempt)/1e6
        with self.log_lock, (self.output / "rpc-intervals.jsonl").open("a") as log:
            log.write(json.dumps({"request_id": request_id, "phase": phase,
                "tool": params.get("name"), "total_ms": row["first_attempt_to_response_ms"],
                "successful_attempt_wire_ms": row["wire_ms"], "rejected_429_count": len(retries),
                "rate_wait_s": sum((item["wait_finished_ns"] - item["wait_started_ns"])/1e9
                                   for item in retries)}) + "\n")
        result = decode_rpc(raw, request_id)
        if method == "initialize":
            lowered = {k.lower(): v for k, v in headers.items()}
            self.session = lowered.get("mcp-session-id")
            self.protocol = lowered.get("mcp-protocol-version", self.protocol)
            require(self.session, "MCP initialize omitted its session")
        return result, row

    def tool(self, name, arguments, phase):
        result, row = self.rpc("tools/call", {"name": name, "arguments": arguments}, phase)
        require(not result.get("isError", False), "tool failure; inspect requests.jsonl")
        data = result.get("structuredContent")
        if data is None:
            text = "\n".join(item["text"] for item in result.get("content", [])
                             if item.get("type") == "text")
            data = json.loads(text)
        return data, row


class Fixture:
    def __init__(self, output, marker, keepers, delay_ms):
        self.output, self.marker, self.keepers = output, marker, set(keepers)
        self.delay_ms = delay_ms
        self.release = threading.Event()
        self.stopping = threading.Event()
        self.handlers_idle = threading.Event()
        self.handlers_idle.set()
        self.lock = threading.Lock()
        self.requests, self.errors, self.active = [], [], 0
        self.max_active = 0
        self.handler_count = 0

    def coverage_snapshot(self):
        with self.lock:
            coverage = defaultdict(list)
            for row in self.requests:
                coverage[row["keeper"]].extend(row["sequences"])
            return {"actual_model_calls": len(self.requests),
                    "max_provider_requests_in_flight": self.max_active,
                    "per_keeper_sequences": dict(coverage), "errors": list(self.errors)}

    def serve(self):
        fixture = self

        class Handler(BaseHTTPRequestHandler):
            def setup(self):
                super().setup()
                self.connection.settimeout(30)

            def log_message(self, *_args):
                pass

            def log_error(self, format, *args):
                # BaseHTTPRequestHandler handles malformed HTTP, unsupported
                # methods and request-read timeouts without raising them.
                with fixture.lock:
                    fixture.errors.append({"stage": "provider_http_protocol",
                                           "error": "http_protocol_error", "detail": format % args})

            def send(self, status, data, content_type="application/json"):
                self.send_response(status)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                if self.path != "/v1/models":
                    with fixture.lock:
                        fixture.errors.append({"method": "GET", "path": self.path})
                    return self.send(404, b'{}')
                self.send(200, json.dumps({"object": "list", "data": [{
                    "id": "deepseek-v4.1-flash", "object": "model", "owned_by": "fixture"}]}).encode())

            def do_POST(self):
                started = time.perf_counter_ns()
                row = {"path": self.path, "start_ns": started}
                active = False
                try:
                    require(self.path == "/v1/chat/completions", "unexpected provider route")
                    request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                    row["request"] = request
                    require(isinstance(request, dict), "provider input must be a JSON object")
                    require(request.get("model") == "deepseek-v4.1-flash", "unexpected provider model")
                    messages = [m for m in request.get("messages", []) if m.get("role") == "user"]
                    require(messages, "provider input has no user message")
                    # The runtime can append recall/context as another user
                    # message. Select the latest typed workload message, not
                    # whichever message happens to be last on the wire.
                    probes = []
                    for message in reversed(messages):
                        probes = [item for item in objects(message.get("content"))
                                  if item.get("schema") == "masc.keeper-scale-input.v1"
                                  and item.get("marker") == fixture.marker]
                        if probes:
                            break
                    require(probes, "provider input has no typed workload input")
                    names = {item.get("keeper") for item in probes}
                    require(len(names) == 1 and names <= fixture.keepers, "provider input mixes or invents Keeper identity")
                    name = next(iter(names))
                    sequences = [item["sequence"] for item in probes]
                    require(all(type(n) is int and n > 0 for n in sequences)
                            and len(sequences) == len(set(sequences)), "invalid workload sequences")
                    row.update(keeper=name, sequences=sequences)
                    with fixture.lock:
                        fixture.active += 1
                        active = True
                        fixture.max_active = max(fixture.max_active, fixture.active)
                        fixture.requests.append(row)
                        with (fixture.output / "model-requests.jsonl").open("a") as log:
                            log.write(json.dumps(row, ensure_ascii=False) + "\n")
                    fixture.release.wait()
                    require(not fixture.stopping.wait(fixture.delay_ms/1000),
                            "owned provider fixture is stopping")
                    reply = json.dumps({"schema": "masc.keeper-scale-reply.v1",
                                        "marker": fixture.marker, "keeper": name,
                                        "sequences": sequences}, sort_keys=True)
                    response = {"id": "fixture-" + uuid.uuid4().hex,
                                "object": "chat.completion", "model": request["model"],
                                "choices": [{"index": 0, "message": {
                                    "role": "assistant", "content": reply}, "finish_reason": "stop"}],
                                "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}}
                    if request.get("stream"):
                        chunks = [{"id": response["id"], "object": "chat.completion.chunk",
                            "model": request["model"], "choices": [{"index": 0,
                                "delta": {"role": "assistant", "content": reply}, "finish_reason": None}]},
                            {"id": response["id"], "object": "chat.completion.chunk",
                             "model": request["model"], "choices": [{"index": 0, "delta": {},
                                "finish_reason": "stop"}], "usage": response["usage"]}]
                        data = ("".join("data: " + json.dumps(chunk) + "\n\n" for chunk in chunks)
                                + "data: [DONE]\n\n").encode()
                        self.send(200, data, "text/event-stream")
                    else:
                        self.send(200, json.dumps(response).encode())
                    row["end_ns"] = time.perf_counter_ns()
                except (ProbeError, ValueError, KeyError, OSError) as error:
                    row.update(error=type(error).__name__, detail=str(error))
                    with fixture.lock:
                        fixture.errors.append(row.copy())
                    try:
                        self.send(500, json.dumps({"error": {"message": str(error)}}).encode())
                    except OSError:
                        pass
                finally:
                    if active:
                        with fixture.lock:
                            fixture.active -= 1
                    with fixture.lock, (fixture.output / "model-outcomes.jsonl").open("a") as log:
                        log.write(json.dumps(row, ensure_ascii=False) + "\n")

        class Server(ThreadingHTTPServer):
            # Failure cleanup must not wait forever for a handler. Success
            # still requires the exact active/handler counters to drain below.
            daemon_threads = True
            block_on_close = False
            request_queue_size = max(5, len(fixture.keepers))

            def handle_error(self, request, client_address):
                # Includes unexpected parser/setup errors and failures writing
                # the handler's final outcome record. They must survive a
                # handler that otherwise drains normally.
                error = sys.exception()
                with fixture.lock:
                    fixture.errors.append({"stage": "provider_handler",
                                           "error": type(error).__name__, "detail": str(error)})
                super().handle_error(request, client_address)

            def process_request(self, request, client_address):
                with fixture.lock:
                    fixture.handler_count += 1
                    fixture.handlers_idle.clear()
                try:
                    super().process_request(request, client_address)
                except BaseException:
                    with fixture.lock:
                        fixture.handler_count -= 1
                        if fixture.handler_count == 0:
                            fixture.handlers_idle.set()
                    raise

            def process_request_thread(self, request, client_address):
                try:
                    super().process_request_thread(request, client_address)
                finally:
                    with fixture.lock:
                        fixture.handler_count -= 1
                        if fixture.handler_count == 0:
                            fixture.handlers_idle.set()

        server = Server(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        try:
            thread.start()
        except BaseException:
            server.server_close()
            raise
        return server, thread


def wait_for(description, predicate, process, timeout):
    deadline = time.monotonic() + timeout
    last = None
    while True:
        require(process.poll() is None, "owned server exited while waiting for " + description)
        last = predicate()
        if last:
            return last
        require(time.monotonic() < deadline, "observation deadline for " + description)
        time.sleep(.1)


def run(args, owner):
    require(not args.output.is_symlink(), "output path must not be a symlink")
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    owner["output"] = out
    shutil.copy2(Path(__file__), out / Path(__file__).name)
    shutil.copy2(Path(keeper_scale_trace.__file__), out / "keeper_scale_trace.py")
    binary = args.binary.resolve(strict=True)
    pinned = out / "masc-installed-copy"
    shutil.copy2(binary, pinned)
    pinned.chmod(0o700)
    binary_hash = digest(binary)
    require(digest(pinned) == binary_hash, "binary changed while copied")
    # The owned base is evidence, including on copy/integrity/validation
    # failures. Keep the original SQLite/WAL and runtime logs in the packet.
    base = out / "owned-base"
    base.mkdir()
    owner["base"] = base
    config = base / ".masc/config"
    (config / "keepers").mkdir(parents=True)
    (config / "prompts").mkdir()
    home = base / "home"
    home.mkdir()
    names = [f"scale-keeper-{index:04d}" for index in range(args.keepers)]
    marker = uuid.uuid4().hex
    fixture = Fixture(out, marker, names, args.model_delay_ms)
    owner["fixture"] = fixture
    model, model_thread = fixture.serve()
    owner.update(model=model, model_thread=model_thread)
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    runtime_fixture = args.repo / "scripts/fixtures/release-evidence/runtime.toml"
    runtime = runtime_fixture.read_text()
    require(runtime.count("http://127.0.0.1:9/v1") == 1, "release fixture model endpoint changed")
    require(runtime.count("streaming = true") == 1
            and runtime.count("max-concurrent = 1") == 1, "release fixture replacement scope changed")
    runtime = runtime.replace("http://127.0.0.1:9/v1", f"http://127.0.0.1:{model.server_port}/v1")
    runtime = runtime.replace("streaming = true", "streaming = false")
    runtime = runtime.replace("max-concurrent = 1", f"max-concurrent = {args.keepers}")
    parsed = tomllib.loads(runtime)
    require(set(parsed["providers"]) == {"ollama_cloud"}, "fixture added an unreviewed provider")
    provider = parsed["providers"]["ollama_cloud"]
    endpoint = urlsplit(provider["endpoint"])
    require(endpoint.scheme == "http" and endpoint.hostname == "127.0.0.1"
            and endpoint.port == model.server_port and endpoint.path == "/v1"
            and provider["credentials"] == {"type": "inline", "value": "release-evidence-loopback"}
            and parsed["ollama_cloud"]["deepseek-v4.1-flash"]["max-concurrent"] == args.keepers,
            "fixture endpoint, credential or concurrency isolation differs")
    (config / "runtime.toml").write_text(runtime)
    (config / "sandbox-image-builds.toml").write_text(
        '[images.base.apple_container]\nreference = "keeper-scale-unused:fixture"\n')
    write_json(out / "workload.json", {"keepers": names, "messages_per_keeper": args.messages_per_keeper,
        "marker": marker, "model_delay_ms": args.model_delay_ms,
        "scope": "Real Keeper model turns and durable chat operations, no sandbox or external tools; multiple queued inputs may batch."})
    shutil.copytree(config, out / "initial-config")
    # Unexpected guest launch must fail inside this fixture, never find a
    # real host daemon or SSH configuration through the inherited PATH.
    guard_dir = base / "deny-guest-commands"
    guard_dir.mkdir()
    guard_log = base / "guest-command-attempts.jsonl"
    guard_body = ("#!" + sys.executable + "\nimport json,sys,time\n"
                  "with open(" + repr(str(guard_log)) + ", 'a') as log:\n"
                  "    log.write(json.dumps({'argv':sys.argv,'time_ns':time.time_ns()})+'\\n')\n"
                  "sys.exit(126)\n")
    for command in ("docker", "container", "msb", "nerdctl", "ssh"):
        path = guard_dir / command
        path.write_text(guard_body)
        path.chmod(0o700)
    env = {"PATH": str(guard_dir) + os.pathsep + os.environ["PATH"], "LANG": "C.UTF-8", "HOME": str(home),
           "MASC_BASE_PATH": str(base), "MASC_CONFIG_DIR": str(config),
           "MASC_CONFIG_BOOTSTRAP": "skip", "MASC_KEEPER_AUTONOMOUS_ENABLED": "true",
           "MASC_GRPC_ENABLED": "0", "MASC_WS_ENABLED": "0"}
    built = subprocess.run([str(pinned), "build-commit"], env=env, cwd=base,
                           capture_output=True, text=True, check=True)
    source = built.stdout.strip()
    require(len(source) == 40 and all(c in "0123456789abcdef" for c in source), "binary has no exact embedded commit")
    identity = {"source": source, "sha256": binary_hash, "original_binary": str(binary),
                "copied_binary": str(pinned), "base": str(base), "port": port,
                "model_port": model.server_port, "environment_keys": sorted(env),
                "runner_sha256": digest(Path(__file__)), "runtime_fixture_sha256": digest(runtime_fixture),
                "evidence_schema": EVIDENCE_SCHEMA,
                "sandbox_scope": "Explicit lazy microVM declaration, unexecuted fixture image pin; no daemon preflight disabled and no guest execution proven."}
    write_json(out / "identity.json", identity)
    process = None
    stop_samples = threading.Event()
    owner["stop_samples"] = stop_samples
    sampler = None
    samples = []
    phase = ["starting"]
    phase_events = []

    def record_phase_event(event):
        event["wall_time_ns"] = time.time_ns()
        phase_events.append(event)
        with (out / "workload-phases.jsonl").open("a") as stream:
            stream.write(json.dumps(event) + "\n")

    def change_phase(label):
        phase[0] = label
        record_phase_event({"phase": label, "started_ns": time.perf_counter_ns()})
    operations = []
    terminal = {}
    success = False
    try:
        with (out / "server.log").open("wb") as log:
            process = subprocess.Popen([str(pinned), "--host", "127.0.0.1", "--base-path", str(base),
                                        "--port", str(port)], env=env, cwd=base, stdout=log, stderr=log,
                                       start_new_session=True)
            owner["process"] = process
            write_json(out / "owned-process.json", {"pid": process.pid, "base": str(base),
                "source": source, "binary_sha256": binary_hash, "started_ns": time.perf_counter_ns()})
            anonymous = Client(port, None, out, args.request_timeout)

            def ready():
                try:
                    health, _ = anonymous.get("/health?full=1")
                    return health if health.get("startup", {}).get("state_ready") is True else None
                except (OSError, http.client.HTTPException):
                    return None

            before = wait_for("readiness", ready, process, args.settle_timeout)
            require(before["paths"]["effective_masc_root"] == str(base / ".masc")
                    and before["build"]["binary_commit"] == source
                    and before["build"]["executable_sha256"] == binary_hash
                    and before["keeper_fibers"] == 0, "runtime source or isolation mismatch")
            write_json(out / "health-before.json", before)
            token_result, _ = anonymous.get("/api/v1/dashboard/dev-token")
            require(isinstance(token_result.get("token"), str)
                    and token_result.get("actor") == "dashboard" and token_result.get("role") == "admin",
                    "isolated dashboard admin principal unavailable")
            write_json(out / "principal.json", {key: token_result[key] for key in ("actor", "role")})
            client = Client(port, token_result["token"], out, args.request_timeout)
            client.rpc("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                "clientInfo": {"name": "keeper-scale-session", "version": "1"}}, "initialize")
            if args.tracers is not None:
                owner["traces"] = keeper_scale_trace.start(
                    output=out, base=base, tools=args.tracers.resolve(strict=True), server=process,
                    seconds=args.settle_timeout * 4, ready_timeout=args.request_timeout)
                owner["trace_workload_start"] = time.time()
            for name in names:
                client.tool("masc_keeper_up", {"name": name, "create_only": True,
                    "sandbox_profile": "microvm", "microvm_backend": "apple_container",
                    "sandbox_image": "base", "network_mode": "none", "skills": {"names": []},
                    "board_interests": [], "activation_mode": "on_demand",
                    "instructions": "Reply to each isolated workload input with its typed fixture result. Do not call tools."}, "create")

            def all_live():
                health, _ = client.get("/health?full=1")
                return health if health.get("keeper_fibers") == args.keepers else None

            resident = wait_for("all Keeper owners", all_live, process, args.settle_timeout)
            write_json(out / "health-resident.json", resident)

            def sample():
                probe = Client(port, token_result["token"], out, args.request_timeout)
                while not stop_samples.is_set():
                    label = phase[0]
                    try:
                        body, row = probe.get("/health/live")
                        row["valid"] = body.get("live") is True
                    except (OSError, http.client.HTTPException, ProbeError, ValueError) as error:
                        row = (getattr(error, "row", None) or {}).copy()
                        row.update(valid=False, error=type(error).__name__, detail=str(error))
                    row["workload_phase"] = label
                    samples.append(row)
                    stop_samples.wait(args.sample_interval)

            change_phase("submitting_model_held")
            sampler = threading.Thread(target=sample, daemon=True)
            owner["sampler"] = sampler
            sampler.start()
            for sequence in range(1, args.messages_per_keeper + 1):
                for name in names:
                    message = json.dumps({"schema": "masc.keeper-scale-input.v1", "marker": marker,
                                          "keeper": name, "sequence": sequence}, sort_keys=True)
                    accepted, row = client.tool("masc_keeper_msg", {"name": name, "message": message}, "enqueue")
                    require(isinstance(accepted.get("operation_id"), str), "enqueue omitted operation identity")
                    operations.append({"keeper": name, "sequence": sequence, "operation_id": accepted["operation_id"],
                                       "original": original_payload(name, message),
                                       "admission": accepted, "admission_wire_ms": row["wire_ms"],
                                       "first_attempt_to_accepted_ms": row["first_attempt_to_response_ms"]})
            write_json(out / "operations-admitted.json", operations)
            indexed_operations = index_operations(operations)

            def all_model_started():
                with fixture.lock:
                    require(not fixture.errors, "scripted provider rejected a request; inspect model-outcomes.jsonl")
                    return {row["keeper"] for row in fixture.requests} == set(names)

            wait_for("actual model request from every Keeper", all_model_started, process, args.settle_timeout)
            change_phase("model_held_queue_observation")
            held, _ = client.get("/health?full=1")
            write_json(out / "health-model-held.json", held)

            def observe_operation(operation, label, deadline):
                while True:
                    require(process.poll() is None, "owned server exited during operation observation")
                    require(time.monotonic() < deadline,
                            "read-only operation observation deadline; owner still live")
                    try:
                        status, _ = client.tool("masc_keeper_delegate_status", {
                            "target": {"kind": "keeper", "name": operation["keeper"]},
                            "operation_id": operation["operation_id"]}, label)
                        require(status.get("operation_id") == operation["operation_id"],
                                "public operation identity differs from requested input")
                        return status
                    except (OSError, http.client.HTTPException) as error:
                        # This is a read of an exact already-admitted operation.
                        # A lost observation never says the owner/turn stopped.
                        observation = {"keeper": operation["keeper"],
                            "operation_id": operation["operation_id"], "phase": label,
                            "error": type(error).__name__, "detail": str(error),
                            "server_pid": process.pid, "server_returncode": process.poll(),
                            "runtime_instance_id": before["build"]["runtime_instance_id"],
                            "observed_at_ns": time.perf_counter_ns()}
                        with (out / "operation-observation-failures.jsonl").open("a") as log:
                            log.write(json.dumps(observation) + "\n")
                        require(process.poll() is None, "owned server exited after lost observation")
                        require(time.monotonic() < deadline,
                                "read-only operation observation deadline; owner still live")

            queue_before = []
            held_deadline = time.monotonic() + args.settle_timeout
            for operation in operations:
                status = observe_operation(operation, "queue-held", held_deadline)
                queue_before.append({"keeper": operation["keeper"], "sequence": operation["sequence"], "status": status})
                require(status.get("state") in ("Queued", "Running"), "operation settled before provider release")
            write_json(out / "queue-held.json", queue_before)
            held_snapshots = [{"keeper": database.parent.name, "source_path": str(database),
                "snapshot": read_admission_snapshot(database)}
                for database in sorted((base / ".masc").rglob("chat-operations.sqlite3"))]
            write_json(out / "admission-snapshots.json", held_snapshots)
            held_public = {(item["keeper"], item["status"]["operation_id"]): item["status"] for item in queue_before}
            validate_original_payloads(operations, held_snapshots, held_public, terminal=False)
            with fixture.lock:
                require(fixture.active == args.keepers, "not every Keeper has an actual held provider request")
                record_phase_event({"event": "provider_release", "at_ns": time.perf_counter_ns(),
                                    "active_provider_requests": fixture.active})
            change_phase("running_model_released")
            fixture.release.set()
            pending = dict(indexed_operations)
            deadline = time.monotonic() + args.settle_timeout
            while pending:
                require(process.poll() is None, "owned server exited during workload")
                with fixture.lock:
                    require(not fixture.errors, "scripted provider failed; inspect model-outcomes.jsonl")
                for key, operation in list(pending.items()):
                    status = observe_operation(operation, "settlement", deadline)
                    state = status.get("state")
                    if state in ("Succeeded", "Failed", "Cancelled"):
                        terminal[key] = status
                        validate_completed_operation(operation, status, marker)
                        pending.pop(key)
                write_json(out / "terminal.json", terminal_receipt(operations, terminal))
                require(not pending or time.monotonic() < deadline, "Keeper operation observation deadline")
                if pending:
                    time.sleep(.1)
            change_phase("settled")
            after, _ = client.get("/health?full=1")
            require(after["build"]["runtime_instance_id"] == before["build"]["runtime_instance_id"]
                    and after["keeper_fibers"] == args.keepers, "runtime identity or Keeper population changed")
            write_json(out / "health-after.json", after)
            write_json(out / "model-coverage-before-shutdown.json", fixture.coverage_snapshot())
            shutil.copytree(config, out / "final-config")
            owner["trace_workload_end"] = time.time()
            success = True
    except BaseException as error:
        owner["workload_error"] = error
        raise
    finally:
        fixture.stopping.set()
        fixture.release.set()
        stop_samples.set()
        if sampler is not None:
            sampler.join(timeout=args.request_timeout + 1)
        write_json(out / "latency-samples.json", samples)
        write_json(out / "workload-phases.json", phase_events)
        write_json(out / "terminal.json", terminal_receipt(operations, terminal))
        traces = owner.get("traces")
        if traces is not None:
            owner["trace_receipt"] = keeper_scale_trace.finish(
                traces, started_at_unix=owner.get("trace_workload_start"),
                ended_at_unix=owner.get("trace_workload_end"))
            owner.pop("traces")
        forced = False
        if process is not None and process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                forced = True
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
        model.shutdown()
        model.server_close()
        model_thread.join(timeout=5)
        fixture.handlers_idle.wait(timeout=5)
        owner["model_stopped"] = not model_thread.is_alive()
        with fixture.lock:
            model_drained = fixture.active == 0 and fixture.handler_count == 0
        guest_commands = ([json.loads(line) for line in guard_log.read_text().splitlines()]
                          if guard_log.exists() else [])
        write_json(out / "guest-command-attempts.json", guest_commands)
        denied_inventory = [row for row in guest_commands if denied_inventory_kind(row, guard_dir, names)]
        unexpected_guest_commands = [row for row in guest_commands if row not in denied_inventory]
        write_json(out / "denied-inventory.json", denied_inventory)
        durable = []
        for database in sorted((base / ".masc").rglob("chat-operations.sqlite3")):
            target = out / "durable" / database.parent.name
            target.mkdir(parents=True, exist_ok=True)
            rows, validation = copy_operation_store(database, target / database.name)
            snapshot = read_admission_snapshot(database)
            require(snapshot == read_admission_snapshot(target / database.name),
                    "closed backup operation/batch snapshot differs from retained original")
            durable.append({"keeper": database.parent.name, "source_path": str(database),
                            "rows": rows, "backup_validation": validation, "snapshot": snapshot})
        write_json(out / "durable-operations.json", durable)
        cleanup = {"server_returncode": None if process is None else process.poll(),
                   "server_reaped": process is not None and process.poll() is not None,
                   "forced_kill": forced, "sampler_stopped": sampler is None or not sampler.is_alive(),
                   "model_server_stopped": not model_thread.is_alive(),
                   "base_retained": base.is_dir(), "base_path": str(base)}
        cleanup.update(provider_requests_drained=model_drained,
                       active_provider_requests=fixture.active, provider_handler_threads=fixture.handler_count)
        write_json(out / "cleanup.json", cleanup)
    require(success and not unexpected_guest_commands and model_drained
            and cleanup["server_returncode"] == 0 and not cleanup["forced_kill"]
            and cleanup["server_reaped"] and cleanup["model_server_stopped"] and cleanup["sampler_stopped"]
            and cleanup["base_retained"], "workload or owned cleanup incomplete")
    # No listener or handler can add a late request/error after this snapshot.
    # A successful earlier projection must not hide a shutdown-time failure.
    coverage_snapshot = fixture.coverage_snapshot()
    write_json(out / "model-coverage.json", coverage_snapshot)
    coverage = coverage_snapshot["per_keeper_sequences"]
    require(not coverage_snapshot["errors"], "provider error recorded through shutdown")
    require(set(coverage) == set(names) and all(sorted(value) == list(range(1, args.messages_per_keeper+1))
            for value in coverage.values()), "final model request coverage is missing or duplicated")
    if args.tracers is not None:
        require(owner.get("trace_receipt", {}).get("complete") is True,
                "runtime-events capture incomplete; inspect runtime-events/receipt.json")
    stored = validate_durable_operations(operations, names, durable, terminal, marker)
    validate_original_payloads(operations, durable, terminal, terminal=True)
    valid = sorted(row["wire_ms"] for row in samples if row.get("valid"))
    summary = {"keepers": args.keepers, "messages": len(operations), "succeeded_operations": len(stored),
               "actual_model_calls": len(fixture.requests), "max_provider_requests_in_flight": fixture.max_active,
               "latency_samples": len(samples), "valid_latency_samples": len(valid),
               "scope": "Installed-source real Keeper turns with a loopback scripted text-only model, durable queued operations and offline SQLite reread. No guest/tool execution, browser/TUI or production throughput proof."}
    summary["latency_by_phase"] = {}
    for label in dict.fromkeys(row["workload_phase"] for row in samples):
        selected = [row for row in samples if row["workload_phase"] == label]
        elapsed = sorted(row["wire_ms"] for row in selected if row.get("valid"))
        summary["latency_by_phase"][label] = {"samples": len(selected), "valid": len(elapsed),
            "failures": len(selected)-len(elapsed),
            "p50_ms": elapsed[math.ceil(.5*len(elapsed))-1] if elapsed else None,
            "p95_ms": elapsed[math.ceil(.95*len(elapsed))-1] if elapsed else None,
            "max_ms": max(elapsed) if elapsed else None}
    waits = ([json.loads(line) for line in (out / "rate-limit-waits.jsonl").read_text().splitlines()]
             if (out / "rate-limit-waits.jsonl").exists() else [])
    summary.update(rejected_429_count=len(waits),
                   rate_limit_wait_s=sum((row["wait_finished_ns"]-row["wait_started_ns"])/1e9 for row in waits),
                   rate_limit_wait_by_source_s={source: sum(
                       (row["wait_finished_ns"]-row["wait_started_ns"])/1e9
                       for row in waits if row["source"] == source)
                       for source in dict.fromkeys(row["source"] for row in waits)},
                   denied_read_only_inventory_attempts=len(denied_inventory),
                   unexpected_guest_command_attempts=len(unexpected_guest_commands))
    write_json(out / "summary.json", summary)
    print(json.dumps(summary, indent=2))


def cleanup_failed_run(owner, args):
    """Attempt every owned cleanup even when another cleanup or disk write fails."""
    errors = []

    def attempt(name, action):
        try:
            action()
        except BaseException as error:
            errors.append({"stage": name, "type": type(error).__name__,
                           "message": str(error), "notes": getattr(error, "__notes__", [])})

    if "fixture" in owner:
        attempt("provider_stop", owner["fixture"].stopping.set)
        attempt("provider_release", owner["fixture"].release.set)
    if "stop_samples" in owner:
        attempt("sampler_stop", owner["stop_samples"].set)
    sampler = owner.get("sampler")
    if sampler is not None and sampler.is_alive():
        attempt("sampler_join", lambda: sampler.join(timeout=args.request_timeout + 1))
    traces = owner.get("traces")
    if traces is not None:
        attempt("trace_finish", lambda: keeper_scale_trace.finish(
            traces, started_at_unix=owner.get("trace_workload_start"),
            ended_at_unix=owner.get("trace_workload_end")))
    process = owner.get("process")
    if process is not None:
        if process.poll() is None:
            attempt("server_term", lambda: os.killpg(process.pid, signal.SIGTERM))
            attempt("server_wait", lambda: process.wait(timeout=20))
        if process.poll() is None:
            attempt("server_kill", lambda: os.killpg(process.pid, signal.SIGKILL))
        attempt("server_reap", lambda: process.wait(timeout=5))
    model, thread = owner.get("model"), owner.get("model_thread")
    if model is not None:
        if thread is not None and thread.is_alive():
            attempt("model_shutdown", model.shutdown)
        attempt("model_close", model.server_close)
    if thread is not None and thread.is_alive():
        attempt("model_join", lambda: thread.join(timeout=5))
    if "fixture" in owner:
        fixture = owner["fixture"]
        attempt("model_handlers_join", lambda: fixture.handlers_idle.wait(timeout=5))
        if not fixture.handlers_idle.is_set():
            errors.append({"stage": "model_handlers_join", "type": "IncompleteCleanup",
                           "message": "owned provider handlers remain active"})
    if sampler is not None and sampler.is_alive():
        attempt("sampler_final_join", lambda: sampler.join(timeout=args.request_timeout + 1))
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--keepers", type=int, default=2)
    parser.add_argument("--messages-per-keeper", type=int, default=2)
    parser.add_argument("--model-delay-ms", type=float, default=10)
    parser.add_argument("--sample-interval", type=float, default=.1)
    parser.add_argument("--request-timeout", type=float, default=15)
    parser.add_argument("--settle-timeout", type=float, default=120)
    parser.add_argument("--tracers", type=Path,
                        help="optional directory containing rtev_watch.exe and rtev_fibers.exe")
    args = parser.parse_args()
    require(all(math.isfinite(value) for value in (args.model_delay_ms, args.sample_interval,
                args.request_timeout, args.settle_timeout))
            and args.keepers > 0 and args.messages_per_keeper > 0 and args.model_delay_ms >= 0
            and args.sample_interval > 0 and args.request_timeout > 0 and args.settle_timeout > 0,
            "workload sizes and observation durations must be positive")
    owner = {}
    try:
        run(args, owner)
    except BaseException as error:
        # This also owns failures before the server's main try/finally (for
        # example fixture/config validation), and failures copying a damaged
        # store. Never leave a server or model listener behind on those paths.
        original_error = owner.get("workload_error", error)
        cleanup_errors = cleanup_failed_run(owner, args)
        if original_error is not error:
            cleanup_errors.insert(0, {"stage": "run_finalization", "type": type(error).__name__,
                                      "message": str(error), "notes": getattr(error, "__notes__", [])})
        process = owner.get("process")
        thread = owner.get("model_thread")
        base = owner.get("base")
        owned_output = owner.get("output")
        if owned_output is not None and owned_output.is_dir():
            receipts = {
                "fallback-cleanup.json": {"fallback_cleanup": True,
                    "server_reaped": process is None or process.poll() is not None,
                    "server_returncode": None if process is None else process.poll(),
                    "model_server_stopped": thread is None or not thread.is_alive(),
                    "base_retained": base is not None and base.is_dir(),
                    "base_path": None if base is None else str(base), "cleanup_errors": cleanup_errors},
                "failure.json": {"type": type(original_error).__name__, "message": str(original_error),
                                 "notes": getattr(original_error, "__notes__", []), "cleanup_errors": cleanup_errors}}
            for name, receipt in receipts.items():
                try:
                    write_json(owned_output / name, receipt)
                except BaseException as receipt_error:
                    cleanup_errors.append({"stage": name, "type": type(receipt_error).__name__,
                                           "message": str(receipt_error)})
        print(json.dumps({"original_error_type": type(original_error).__name__,
                          "cleanup_errors": cleanup_errors}), file=sys.stderr)
        if original_error is not error:
            raise original_error from None
        raise


if __name__ == "__main__":
    main()
