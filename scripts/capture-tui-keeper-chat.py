#!/usr/bin/env python3
"""Reproducible exact-head ttyd/Chromium proof for Keeper chat causality.

The capture measures ordinary NEXT promotion, first-submission clock and
composer-slot preservation, plus the distinct STEER -> interrupt -> replacement
path. Every scenario records rendered xterm DOM text, HTTP bodies, timing
measurements, and rehashed screenshots.
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import datetime, timezone
from hashlib import sha256
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from importlib.metadata import version as package_version
import json
import os
from pathlib import Path
import re
import signal
import socket
import stat
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
from typing import Any, Callable, Iterator, Literal
from urllib.parse import unquote, urlsplit

from playwright.sync_api import (
    Browser,
    Frame,
    Page,
    TimeoutError as PlaywrightTimeoutError,
    sync_playwright,
)


# fmt: off
WORKTREE = Path(
    os.environ.get("MASC_CAPTURE_WORKTREE", Path(__file__).resolve().parents[1])
).resolve()
BUILD_WRAPPER = WORKTREE / "scripts/dune-local.sh"
TTYD = Path("/opt/homebrew/bin/ttyd")
KEEPER = "alpha"
SUCCESS_MESSAGE = "Aé한🙂👍🏽🇰🇷❤️-proof"
LONG_TAIL = ("❤️" * 10) + "-TAIL"
LONG_DRAFT = "prefix-" + ("x" * 100) + LONG_TAIL
CHAT_POST = "/api/v1/keepers/chat/stream"
INTERRUPT_POST = "/api/v1/keepers/turn/interrupt"
MCP_POST = "/mcp"
CHAT_HISTORY_GET = f"/api/v1/keepers/{KEEPER}/chat/history"
MEMORY_JOURNAL_GET = f"/api/v1/keepers/{KEEPER}/memory-journal?limit=20"
OPERATOR_GET = "/api/v1/operator?view=summary&include_messages=0&include_keepers=0"
OPERATION_RE = re.compile(r"^/api/v1/keepers/([^/]+)/chat/operations/([^/?]+)$")
UUID7_RE = re.compile(
    r"^tui-[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-"
    r"[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
)
SAFE_ENV_KEYS = ("LANG", "LC_ALL", "PATH", "TMPDIR", "TZ")
BUILD_ENV_KEYS = SAFE_ENV_KEYS + (
    "CAML_LD_LIBRARY_PATH", "HOME", "OCAML_TOPLEVEL_PATH", "OPAMROOT", "OPAMSWITCH",
    "OPAM_SWITCH_PREFIX",
)
# fmt: on


def utc_now() -> str:
    now = datetime.now(timezone.utc)
    return now.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def digest_bytes(value: bytes) -> str:
    return sha256(value).hexdigest()


def digest_file(path: Path) -> str:
    return digest_bytes(path.read_bytes())


def run_text(*command: str, cwd: Path = WORKTREE) -> str:
    return subprocess.check_output(command, cwd=cwd, text=True).strip()


def safe_env(keys: tuple[str, ...]) -> dict[str, str]:
    return {key: os.environ[key] for key in keys if key in os.environ}


def require(condition: bool, detail: str) -> None:
    if not condition:
        raise AssertionError(detail)


def current_keeper_meta() -> dict[str, object]:
    meta: dict[str, object] = {
        "schema": "masc.keeper_meta.v2",
        "name": KEEPER,
        "instructions": "Runtime evidence fixture for Keeper chat recovery.",
        "trace_id": "trace-capture-v3",
        "trace_history": [],
        "created_at": "2026-08-22T00:00:00Z",
        "updated_at": "2026-08-22T00:00:00Z",
        "last_proactive_outcome": "never_started",
        "last_proactive_reason": "",
        "last_proactive_preview": "",
        "message_scope_ack_id": None,
        "last_runtime_attempt": None,
        "paused": False,
        "latched_reason": None,
        "current_task_id": None,
        "keeper_id": None,
        "agent_core_env": {},
        "usage_cursor": None,
        "last_usage_resolution": None,
    }
    for key in (
        "last_handoff_ts",
        "total_turns",
        "total_input_tokens",
        "total_output_tokens",
        "total_tokens",
        "total_cost_usd",
        "last_turn_ts",
        "last_input_tokens",
        "last_output_tokens",
        "last_total_tokens",
        "last_latency_ms",
        "proactive_count_total",
        "last_proactive_ts",
        "proactive_visible_count_total",
        "last_visible_proactive_ts",
    ):
        meta[key] = 0
    return meta


def prepare_base(base: Path) -> None:
    keepers = base / ".masc/keepers"
    keepers.mkdir(parents=True)
    (keepers / f"{KEEPER}.json").write_text(
        json.dumps(current_keeper_meta(), indent=2) + "\n", encoding="utf-8"
    )


def write_recovery(
    base: Path,
    *,
    phase: Literal["prepared", "dispatching", "replayable", "accepted", "rejected"],
    request: dict[str, str],
) -> Path:
    recovery = base / ".masc/tui-keeper-chat-recovery.json"
    payload = {
        "schema": "masc.tui_keeper_chat_recovery.v3",
        "phase": phase,
        "request_id": request["request_id"],
        "keeper_name": request["name"],
        "message": request["message"],
    }
    recovery.write_text(
        json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )
    recovery.chmod(0o600)
    return recovery


def event(request: dict[str, str], kind: str, **fields: object) -> object:
    # fmt: off
    return {"type": kind, "threadId": f"keeper:{request['name']}", "timestamp": 1.0, **fields}
    # fmt: on


def acceptance(request: dict[str, str]) -> object:
    # fmt: off
    return {
        "type": "CUSTOM", "threadId": "default", "timestamp": 1.0,
        "name": "KEEPER_CHAT_OPERATION_ACCEPTED",
        "value": {"operation_id": request["request_id"], "state": "Queued", "queued_count": 0},
    }
    # fmt: on


def sse(values: list[object]) -> bytes:
    return "".join(
        "data: " + json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n\n"
        for value in values
    ).encode()


def stream_payload(
    request: dict[str, str],
    complete: bool,
    *,
    reply: str = "reply-v3",
    turn_sequence: int = 1,
) -> bytes:
    request_id = request["request_id"]
    run_id = f"keeper-operation-run-{request_id}"
    message_id = f"keeper-operation-message-{request_id}"
    # fmt: off
    values = [
        acceptance(request),
        event(request, "RUN_STARTED", runId=run_id),
    ]
    if turn_sequence == 1:
        tool_call_id = f"tool-call-{request_id}"
        occurrence = {
            "toolStreamScope": 0,
            "toolCallBlockIndex": 0,
            "toolCallId": tool_call_id,
        }
        values.extend([
            event(request, "TOOL_CALL_START", runId=run_id, **occurrence,
                  toolCallName="evidence_probe"),
            event(request, "TOOL_CALL_ARGS", runId=run_id, **occurrence,
                  delta='{"probe":"causal-order"}'),
            event(request, "TOOL_CALL_END", runId=run_id, **occurrence),
            event(request, "CUSTOM", runId=run_id, name="KEEPER_TOOL_RESULT_READY",
                  value={**occurrence, "executionId": f"execution-{request_id}"}),
        ])
    values.extend([
        event(request, "TEXT_MESSAGE_START", runId=run_id, messageId=message_id, role="assistant"),
        event(request, "TEXT_MESSAGE_CONTENT", runId=run_id, messageId=message_id,
              delta=reply if complete else "partial-must-not-be-promoted"),
    ])
    if complete:
        values.extend([
            event(request, "CUSTOM", runId=run_id, name="KEEPER_REPLY_DETAILS",
                  value={"reply": reply, "turn_outcome": "visible_reply",
                         "turn_ref": f"trace-chat#{turn_sequence}"}),
            event(request, "TEXT_MESSAGE_END", runId=run_id, messageId=message_id),
            event(request, "RUN_FINISHED", runId=run_id),
        ])
    # fmt: on
    return sse(values)


def execution_digest(message: str) -> str:
    # fmt: off
    value = {
        "schema": "masc.keeper_chat_operation.input.v1", "message": message,
        "user_blocks": [], "turn_instructions": None, "surface_context": None, "attachments": [],
    }
    canonical = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    # fmt: on
    return digest_bytes(canonical.encode())


def operation_payload(request: dict[str, str], succeeded: bool) -> object:
    # fmt: off
    value: dict[str, object] = {
        "schema": "masc.keeper_chat_operation.v1", "operation_id": request["request_id"],
        "sequence": "7", "created_at": 1.0,
        "execution_digest": execution_digest(request["message"]),
        "source": {}, "input": None, "state": "Succeeded" if succeeded else "Running",
    }
    # fmt: on
    if succeeded:
        value.update({"completed_at": 3.0, "outcome_ref": "turn:v3"})
    else:
        value["started_at"] = 2.0
    return value


# fmt: off
OVERVIEW = {
    "summary": {"workspace_health": "ok", "cluster": "cluster-v3", "project": "keeper-chat-v3", "active_agents": 1, "incident_count": 0},
    "command_focus": None, "incidents": [], "attention_queue": [], "attention_items": [],
    "agent_briefs": [], "generated_at": "2026-08-22T00:00:00Z",
}
PLANNING = {
    "goals": [], "rollup": {"active_count": 0, "paused_count": 0, "verifying_count": 0, "done_count": 0, "dropped_count": 0},
    "task_backlog": {"todo": 0, "claimed": 0, "in_progress": 0, "done": 0, "cancelled": 0},
    "generated_at": "2026-08-22T00:00:00Z",
}
OPERATOR = {"pending_confirm_envelope": {"items": [], "summary": {
    "actor_filter": "masc-tui", "filter_active": True, "visible_count": 0, "total_count": 0,
    "hidden_count": 0, "hidden_actors": [], "confirm_required_actions": [],
}}}
# fmt: on


@dataclass
class Fixture:
    mode: Literal["success", "recovery", "rejection", "causal", "steer"]
    lock: threading.Lock = field(default_factory=threading.Lock)
    request: dict[str, str] | None = None
    requests: list[dict[str, str]] = field(default_factory=list)
    submitted_at_by_message: dict[str, float] = field(default_factory=dict)
    completed_request_ids: set[str] = field(default_factory=set)
    records: list[dict[str, Any]] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)
    operation_sequence: int = 0
    get2_received_monotonic: float | None = None
    workspace_base_path: str | None = None
    post_seen: threading.Event = field(default_factory=threading.Event)
    post_release: threading.Event = field(default_factory=threading.Event)
    post2_release: threading.Event = field(default_factory=threading.Event)
    interrupt_seen: threading.Event = field(default_factory=threading.Event)
    get1_seen: threading.Event = field(default_factory=threading.Event)
    get1_release: threading.Event = field(default_factory=threading.Event)
    get1_done: threading.Event = field(default_factory=threading.Event)
    get2_seen: threading.Event = field(default_factory=threading.Event)
    get2_release: threading.Event = field(default_factory=threading.Event)

    def note_submission(self, message: str, submitted_at: float) -> None:
        with self.lock:
            self.submitted_at_by_message[message] = submitted_at

    def complete_request(self, request_id: str) -> None:
        with self.lock:
            self.completed_request_ids.add(request_id)

    def record(self, method: str, path: str) -> dict[str, Any]:
        with self.lock:
            operation_ordinal = None
            if method == "GET" and OPERATION_RE.fullmatch(urlsplit(path).path):
                self.operation_sequence += 1
                operation_ordinal = self.operation_sequence
                if operation_ordinal == 2:
                    self.get2_received_monotonic = time.monotonic()
            record = {
                "method": method,
                "path": path,
                "received_monotonic": time.monotonic(),
                "operation_ordinal": operation_ordinal,
                "request_body_bytes": 0,
                "request_body_sha256": digest_bytes(b""),
                "request_body_utf8": "",
                "response_body_bytes": None,
                "response_body_sha256": None,
                "response_body_utf8": None,
                "response_content_type": None,
                "response_status": None,
                "response_handler_completed": False,
                "response_write_completed": False,
                "client_disconnected": False,
            }
            self.records.append(record)
            return record

    def parse_request(self, body: bytes) -> dict[str, str] | None:
        try:
            value = json.loads(body)
        except (json.JSONDecodeError, UnicodeDecodeError) as error:
            self.errors.append(f"invalid chat JSON: {type(error).__name__}")
            return None
        if not isinstance(value, dict) or set(value) != {
            "request_id",
            "name",
            "message",
        }:
            self.errors.append("chat request shape mismatch")
            return None
        if not all(isinstance(value[key], str) for key in value):
            self.errors.append("chat request fields are not strings")
            return None
        request = {key: value[key] for key in ("request_id", "name", "message")}
        with self.lock:
            self.submitted_at_by_message.setdefault(request["message"], time.time())
            if any(
                previous["request_id"] == request["request_id"] and previous != request
                for previous in self.requests
            ):
                self.errors.append("a request ID changed payload")
            elif self.mode in ("causal", "steer"):
                self.requests.append(request)
            elif self.request is None:
                self.requests.append(request)
                self.request = request
            elif self.request != request:
                self.errors.append("a second POST changed request identity")
            if self.request is None:
                self.request = request
        return request

    def summary(self) -> dict[str, Any]:
        with self.lock:
            records = [dict(record) for record in self.records]
            errors = list(self.errors)
            request = None
            if self.request is not None:
                message = self.request["message"].encode()
                request = {
                    "request_id": self.request["request_id"],
                    "name": self.request["name"],
                    "message_bytes": len(message),
                    "message_sha256": digest_bytes(message),
                }
            requests = [
                {
                    "request_id": request["request_id"],
                    "name": request["name"],
                    "message": request["message"],
                }
                for request in self.requests
            ]
            # fmt: off
            posts = sum(r["method"] == "POST" and r["path"] == CHAT_POST for r in records)
            interrupts = sum(r["method"] == "POST" and r["path"] == INTERRUPT_POST for r in records)
            gets = sum(r["operation_ordinal"] is not None for r in records)
            mcp_initializes = sum(r["method"] == "POST" and r["path"] == MCP_POST
                                  and r.get("mcp_method") == "initialize"
                                  for r in records)
            other_posts = sum(r["method"] == "POST"
                              and r["path"] not in (CHAT_POST, INTERRUPT_POST)
                              and not (r["path"] == MCP_POST
                                       and r.get("mcp_method") == "initialize")
                              for r in records)
            unexpected_chat = sum("/chat/" in urlsplit(r["path"]).path
                                  and not (r["method"] == "POST" and r["path"] == CHAT_POST)
                                  and not (r["method"] == "GET" and r["path"] == CHAT_HISTORY_GET)
                                  and r["operation_ordinal"] is None for r in records)
        return {
            "chat_stream_post_count": posts,
            "interrupt_post_count": interrupts,
            "chat_operation_get_count": gets,
            "other_post_count": other_posts,
            "mcp_initialize_count": mcp_initializes,
            "unexpected_chat_route_count": unexpected_chat,
            "request": request,
            "requests": requests,
            "errors": errors,
            "records": records,
        }
        # fmt: on

    def chat_history(self) -> list[dict[str, object]]:
        with self.lock:
            completed = set(self.completed_request_ids)
            requests = [
                dict(request)
                for request in self.requests
                if request["request_id"] in completed
            ]
            submitted_at_by_message = dict(self.submitted_at_by_message)
        rows: list[dict[str, object]] = []
        for turn_sequence, request in enumerate(requests, 1):
            request_id = request["request_id"]
            submitted_at = submitted_at_by_message[request["message"]]
            delivery_key = {"kind": "operation", "operation_id": request_id}
            turn_ref = f"trace-chat#{turn_sequence}"
            rows.append(
                {
                    "id": f"user-{request_id}",
                    "role": "user",
                    "content": request["message"],
                    "ts": submitted_at,
                    "speaker_authority": "owner",
                    "delivery_key": delivery_key,
                    "transcript_slot": {"kind": "accepted_user"},
                    "turn_ref": turn_ref,
                }
            )
            if turn_sequence == 1:
                tool_call_id = f"tool-call-{request_id}"
                execution_id = f"execution-{request_id}"
                rows.append(
                    {
                        "id": f"tool-{request_id}",
                        "role": "tool",
                        "content": '{"probe":"causal-order"}',
                        "ts": submitted_at,
                        "delivery_key": delivery_key,
                        "transcript_slot": {
                            "kind": "tool_call",
                            "execution_id": execution_id,
                            "ordinal": 0,
                        },
                        "turn_ref": turn_ref,
                        "tool_call_id": tool_call_id,
                        "execution_id": execution_id,
                        "tool_call_name": "evidence_probe",
                    }
                )
            rows.append(
                {
                    "id": f"assistant-{request_id}",
                    "role": "assistant",
                    "content": f"reply-{request['message']}",
                    "ts": submitted_at,
                    "delivery_key": delivery_key,
                    "transcript_slot": {"kind": "terminal_assistant"},
                    "turn_ref": turn_ref,
                }
            )
        return rows


class FixtureServer(ThreadingHTTPServer):
    daemon_threads = False


def fixture_static_response(state: Fixture, path: str) -> object | None:
    base_path = state.workspace_base_path or str(WORKTREE)
    paths = {
        "cwd": base_path,
        "effective_base_path": base_path,
        "effective_masc_root": str(Path(base_path) / ".masc"),
        "effective_has_masc_dir": True,
    }
    roster = {
        "count": 1,
        "total": 1,
        "truncated": False,
        "keepers": [
            {
                "runtime_class": "keeper",
                "name": KEEPER,
                "meta": {
                    "name": KEEPER,
                    "trace_id": "trace-capture-v3",
                    "created_at": "2026-08-22T00:00:00Z",
                    "updated_at": "2026-08-22T00:00:00Z",
                    "sandbox_profile": "docker",
                },
                "status": "active",
                "health": "healthy",
                "paused": False,
                "phase": "running",
                "keepalive_running": True,
                "autoboot_enabled": True,
                "proactive_enabled": True,
                "runtime_id": "capture.fixture",
            }
        ],
    }
    if path == CHAT_HISTORY_GET:
        return state.chat_history()
    return {
        "/health": {"paths": paths},
        "/health?full=1": {
            "paths": paths,
            "keeper_fleet_safety": {"status": "ok"},
        },
        "/api/v1/dashboard/transport-health": {
            "summary": {
                "primary_path": "sse",
                "queue_pressure": "steady",
            },
            "sse": {"sessions_total": 1},
            "websocket": {"listening": False},
            "grpc": {"listening": False, "events_dropped": 0},
        },
        "/api/v1/dashboard/briefing": OVERVIEW,
        OPERATOR_GET: OPERATOR,
        "/api/v1/board": {"posts": []},
        "/api/v1/board?sort_by=hot": {"posts": []},
        "/api/v1/dashboard/planning": PLANNING,
        "/api/v1/gate/keepers?detailed=true": roster,
        # Read-only surfaces every refresh asks for whichever pane is showing.
        # Empty readings, in the shape the TUI decoders take (the same ones
        # the PTY suite's fake server answers with).
        "/api/v1/dashboard/gate": {
            "approval_queue": [],
            "approval_queue_state": None,
            "hitl": {
                "gate_mode": {"mode": "auto_judge"},
                "external_gate_mode": {"mode": "manual"},
            },
            "approval_rules": None,
            "approval_rules_state": None,
        },
        "/api/v1/dashboard/gate/keeper-settings": {"modes": [], "judges": []},
        "/api/v1/keepers/tool-approval-mode": {"overrides": []},
        "/api/v1/keepers/tool-approvals": {"pending": []},
        "/api/v1/keepers/turns": {"schema": "masc.keeper_turns.v1", "keepers": []},
        "/api/v1/keepers/asks": {"keeper": None, "open_count": 0, "asks": []},
        "/api/v1/dashboard/scheduled-automation": {
            "status": "ok",
            "schedule_store_read_error": None,
            "request_count": 0,
            "truncated": False,
            "fsm": {"next_due_at_iso": None},
            "requests": [],
        },
        "/api/v1/keepers/composite": {
            "generated_at": 1787557669.715736,
            "count": 0,
            "snapshots": [],
        },
        MEMORY_JOURNAL_GET: {
            "keeper": KEEPER,
            "returned": 0,
            "undecodable_lines": 0,
            "entries": [],
        },
    }.get(path)


@contextmanager
def fixture_server(state: Fixture) -> Iterator[int]:
    class Handler(BaseHTTPRequestHandler):
        def reply(
            self,
            record: dict[str, Any],
            status: int,
            payload: bytes,
            content_type: str = "application/json",
        ) -> None:
            decoded_payload = payload.decode("utf-8")
            write_completed = False
            client_disconnected = False
            try:
                self.send_response(status)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(payload)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(payload)
                self.wfile.flush()
                write_completed = True
            except (BrokenPipeError, ConnectionResetError):
                client_disconnected = True
            finally:
                with state.lock:
                    record.update(
                        {
                            "response_body_bytes": len(payload),
                            "response_body_sha256": digest_bytes(payload),
                            "response_body_utf8": decoded_payload,
                            "response_content_type": content_type,
                            "response_status": status,
                            "response_handler_completed": True,
                            "response_write_completed": write_completed,
                            "client_disconnected": client_disconnected,
                        }
                    )

        def reply_json(
            self, record: dict[str, Any], status: int, value: object
        ) -> None:
            self.reply(record, status, json.dumps(value).encode())

        def do_GET(self) -> None:  # noqa: N802
            record = state.record("GET", self.path)
            static = fixture_static_response(state, self.path)
            if static is not None:
                self.reply_json(record, 200, static)
                return
            match = OPERATION_RE.fullmatch(urlsplit(self.path).path)
            request = state.request
            if match is None or request is None or state.mode == "success":
                state.errors.append("unexpected GET endpoint")
                self.reply_json(record, 503, {"error": "unexpected GET"})
                return
            keeper, request_id = map(unquote, match.groups())
            if keeper != request["name"] or request_id != request["request_id"]:
                state.errors.append("operation GET identity mismatch")
                self.reply_json(record, 409, {"error": "identity mismatch"})
                return
            if state.mode == "rejection":
                self.reply_json(record, 404, {"error": "operation not found"})
                return
            ordinal = record["operation_ordinal"]
            if ordinal == 1:
                state.get1_seen.set()
                if not state.get1_release.wait(30):
                    state.errors.append("GET1 gate timeout")
                    self.reply_json(record, 504, {"error": "gate timeout"})
                    state.get1_done.set()
                    return
                self.reply_json(record, 200, operation_payload(request, False))
                state.get1_done.set()
            elif ordinal == 2:
                state.get2_seen.set()
                if not state.get2_release.wait(30):
                    state.errors.append("GET2 gate timeout")
                    self.reply_json(record, 504, {"error": "gate timeout"})
                    return
                self.reply_json(record, 200, operation_payload(request, True))
            else:
                state.errors.append(f"unexpected operation GET ordinal {ordinal}")
                self.reply_json(record, 500, {"error": "extra operation GET"})

        def do_POST(self) -> None:  # noqa: N802
            body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
            record = state.record("POST", self.path)
            with state.lock:
                record.update(
                    {
                        "request_body_bytes": len(body),
                        "request_body_sha256": digest_bytes(body),
                        "request_body_utf8": body.decode("utf-8"),
                    }
                )
            if self.path == MCP_POST:
                # The TUI opens one MCP session for its observer feed, whichever
                # pane is showing; the handshake is a read-side session open,
                # not a write the chat turn caused. This fixture serves no
                # observer feed, so it answers the JSON-RPC way a server says
                # so, and the summary counts the handshake on its own row.
                try:
                    rpc = json.loads(body)
                except (json.JSONDecodeError, UnicodeDecodeError):
                    rpc = {}
                method = rpc.get("method") if isinstance(rpc, dict) else None
                with state.lock:
                    record["mcp_method"] = method
                if method == "initialize":
                    self.reply_json(record, 200, {
                        "jsonrpc": "2.0", "id": rpc.get("id"),
                        "error": {"code": -32601,
                                  "message": "this fixture serves no observer feed"},
                    })
                    return
            if self.path == INTERRUPT_POST and state.mode == "steer":
                try:
                    target = json.loads(body)
                except (json.JSONDecodeError, UnicodeDecodeError) as error:
                    state.errors.append(
                        f"invalid interrupt JSON: {type(error).__name__}"
                    )
                    self.reply_json(record, 400, {"error": "bad interrupt request"})
                    return
                request = state.request
                expected = (
                    None
                    if request is None
                    else {
                        "name": request["name"],
                        "request_id": request["request_id"],
                    }
                )
                if target != expected:
                    state.errors.append("interrupt target identity mismatch")
                    self.reply_json(record, 409, {"error": "identity mismatch"})
                    return
                state.interrupt_seen.set()
                self.reply_json(
                    record,
                    200,
                    {
                        "signalled": True,
                        "request_id": request["request_id"],
                    },
                )
                return
            if self.path != CHAT_POST:
                state.errors.append("unexpected POST endpoint")
                self.reply_json(record, 500, {"error": "unexpected POST"})
                return
            request = state.parse_request(body)
            state.post_seen.set()
            if request is None:
                self.reply_json(record, 400, {"error": "bad request"})
                return
            with state.lock:
                ordinal = next(
                    (
                        index
                        for index, observed in enumerate(state.requests, 1)
                        if observed["request_id"] == request["request_id"]
                    ),
                    1,
                )
            if state.mode in ("causal", "steer"):
                gate = (
                    state.post_release
                    if ordinal == 1
                    else state.post2_release
                    if ordinal == 2
                    else None
                )
                if gate is not None and not gate.wait(30):
                    state.errors.append(f"POST{ordinal} gate timeout")
                    self.reply_json(record, 504, {"error": "gate timeout"})
                    return
                reply = f"reply-{request['message']}"
                payload = stream_payload(
                    request,
                    True,
                    reply=reply,
                    turn_sequence=ordinal,
                )
                state.complete_request(request["request_id"])
            elif state.mode in ("success", "rejection"):
                if not state.post_release.wait(30):
                    state.errors.append("POST gate timeout")
                    self.reply_json(record, 504, {"error": "gate timeout"})
                    return
                if state.mode == "rejection":
                    self.reply_json(
                        record,
                        403,
                        {"error": "synthetic definitive pre-acceptance rejection"},
                    )
                    return
                payload = stream_payload(request, True)
                state.complete_request(request["request_id"])
            else:
                # Clean EOF after acceptance, but before any terminal SSE event.
                payload = stream_payload(request, False)
            self.reply(record, 200, payload, "text/event-stream")

        def log_message(self, format: str, *args: object) -> None:
            del format, args

    server = FixtureServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield int(server.server_address[1])
    finally:
        for gate in (
            state.post_release,
            state.post2_release,
            state.get1_release,
            state.get2_release,
        ):
            gate.set()
        server.shutdown()
        thread.join(timeout=3)
        server_stopped = not thread.is_alive()
        server.server_close()  # waits for non-daemon request threads
        require(server_stopped, "fixture server thread did not stop")


def wait_port(port: int, process: subprocess.Popen[bytes]) -> None:
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        if process.poll() is not None:
            log = b"" if process.stdout is None else process.stdout.read()
            raise RuntimeError(f"ttyd exited early; log_sha256={digest_bytes(log)}")
        with socket.socket() as sock:
            if sock.connect_ex(("127.0.0.1", port)) == 0:
                return
        time.sleep(0.05)
    raise TimeoutError("ttyd did not listen")


def stop_process(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    try:
        process.communicate(timeout=4)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate(timeout=4)


@contextmanager
def held_file_lock(path: Path) -> Iterator[Callable[[], None]]:
    helper = """
import fcntl
import os
import sys
path = sys.argv[1]
fd = os.open(path, os.O_CREAT | os.O_WRONLY, 0o600)
try:
    fcntl.lockf(fd, fcntl.LOCK_EX)
    sys.stdout.buffer.write(b'R')
    sys.stdout.buffer.flush()
    sys.stdin.buffer.read(1)
finally:
    os.close(fd)
"""
    process = subprocess.Popen(
        [sys.executable, "-c", helper, str(path)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    helper_closed = False

    def release() -> None:
        nonlocal helper_closed
        if helper_closed:
            return
        try:
            stdout, stderr = process.communicate(input=b"X", timeout=5)
        except subprocess.TimeoutExpired as error:
            process.kill()
            stdout, stderr = process.communicate(timeout=5)
            helper_closed = True
            raise AssertionError(
                f"lock helper timed out: stdout={stdout!r}, stderr={stderr!r}"
            ) from error
        helper_closed = True
        require(process.returncode == 0, f"lock helper failed: {stderr!r}")
        require(stdout == b"", f"lock helper emitted trailing output: {stdout!r}")

    try:
        helper_stdout = process.stdout
        assert helper_stdout is not None
        ready = helper_stdout.read(1)
        require(ready == b"R", f"lock helper did not become ready: {ready!r}")
        yield release
    finally:
        if not helper_closed:
            release()


def file_lock_available(path: Path) -> bool:
    helper = """
import fcntl
import os
import sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY, 0o600)
try:
    try:
        fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise SystemExit(2)
finally:
    os.close(fd)
"""
    result = subprocess.run(
        [sys.executable, "-c", helper, str(path)],
        capture_output=True,
        timeout=5,
    )
    require(
        result.returncode in (0, 2),
        f"lock probe failed: rc={result.returncode}, stderr={result.stderr!r}",
    )
    require(result.stdout == b"", f"lock probe emitted output: {result.stdout!r}")
    return result.returncode == 0


@contextmanager
def ttyd_session(
    browser: Browser,
    base: Path,
    api_port: int,
    executable: Path,
) -> Iterator[tuple[Page, float]]:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        web_port = int(sock.getsockname()[1])
    environment = safe_env(SAFE_ENV_KEYS)
    environment.update(
        {
            "MASC_BASE_PATH": str(base),
            "MASC_HOST": "127.0.0.1",
            "MASC_TUI_SYNC": "off",
            "TERM": "xterm-256color",
            "NO_PROXY": "127.0.0.1,localhost",
            "no_proxy": "127.0.0.1,localhost",
        }
    )
    # fmt: off
    command = [
        str(TTYD), "-p", str(web_port), "-i", "127.0.0.1", "-W",
        "-t", "rendererType=dom", "-t", "fontSize=14", "-t", "fontFamily=Menlo",
        "-T", "xterm-256color", str(executable), "--base-path", str(base),
        "--workspace", "keeper-chat-v3", "--port", str(api_port), "--refresh", "60",
    ]
    # fmt: on
    started = time.monotonic()
    process = subprocess.Popen(
        command,
        cwd=WORKTREE,
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    context = None
    try:
        wait_port(web_port, process)
        context = browser.new_context(
            viewport={"width": 860, "height": 496}, device_scale_factor=1
        )
        page = context.new_page()
        page.goto(f"http://127.0.0.1:{web_port}", wait_until="domcontentloaded")
        page.wait_for_selector(".xterm-helper-textarea", timeout=10_000)
        page.wait_for_function(
            "window.term && window.term.cols === 99 && window.term.rows === 30",
            timeout=10_000,
        )
        wait_text(page, "MASC Overview")
        # ttyd briefly paints a centered terminal-size overlay after connect.
        page.wait_for_timeout(3_000)
        yield page, started
    finally:
        try:
            if context is not None:
                context.close()
        finally:
            stop_process(process)


def screen_text(page: Page) -> str:
    return page.locator(".xterm-screen").inner_text()


def unique_screen_line(text: str, *markers: str) -> tuple[int, str]:
    matches = [
        (index, line)
        for index, line in enumerate(text.splitlines())
        if all(marker in line for marker in markers)
    ]
    require(
        len(matches) == 1,
        f"expected one screen line containing {markers!r}, found {len(matches)}",
    )
    return matches[0]


def wait_text(
    page: Page, needle: str, timeout: int = 10_000, *, present: bool = True
) -> None:
    try:
        page.wait_for_function(
            """expected => {
              const screen = document.querySelector('.xterm-screen');
              return screen && screen.innerText.includes(expected.text) === expected.present;
            }""",
            arg={"text": needle, "present": present},
            timeout=timeout,
        )
    except PlaywrightTimeoutError as error:
        visible = screen_text(page)
        raise TimeoutError(
            f"screen text {needle!r} present={present}; visible={visible!r}"
        ) from error


def press(page: Page, key: str, expected: str | None = None) -> None:
    page.locator(".xterm-helper-textarea").focus()
    page.keyboard.press(key)
    if expected:
        wait_text(page, expected)


def type_text(page: Page, value: str) -> None:
    page.locator(".xterm-helper-textarea").focus()
    page.keyboard.type(value)


def open_message(page: Page) -> None:
    for _ in range(12):
        if "MASC Keepers" in screen_text(page):
            break
        press(page, "Tab")
        page.wait_for_timeout(100)
    else:
        raise TimeoutError(
            f"Keepers tab was not reached by visible navigation: {screen_text(page)!r}"
        )
    press(page, "Enter")
    wait_text(page, "Identity")
    press(page, "m", f"Keepers ▸ {KEEPER} ▸ chat")


def cursor_position(page: Page) -> dict[str, int]:
    return page.evaluate(
        "({x: window.term.buffer.active.cursorX, y: window.term.buffer.active.cursorY})"
    )


def cursor_visible(page: Page) -> bool:
    return page.evaluate(
        """() => {
          const cursor = document.querySelector('.xterm-cursor');
          if (!cursor) return false;
          const style = window.getComputedStyle(cursor);
          return style.display !== 'none'
            && style.visibility !== 'hidden'
            && Number.parseFloat(style.opacity || '1') > 0;
        }"""
    )


def buffer_line(page: Page, row: int) -> str:
    return page.evaluate(
        """row => {
          const buffer = window.term.buffer.active;
          const line = buffer.getLine(buffer.baseY + row);
          return line ? line.translateToString(false) : '';
        }""",
        row,
    )


def find_composer_row(page: Page) -> int:
    return page.evaluate(
        r"""() => {
          const buffer = window.term.buffer.active;
          for (let row = 0; row < window.term.rows; row += 1) {
            const line = buffer.getLine(buffer.baseY + row);
            if (line && /^\s*> /.test(line.translateToString(false))) return row;
          }
          return -1;
        }"""
    )


def wait_cursor(page: Page, expected_x: int, expected_y: int) -> dict[str, int]:
    try:
        page.wait_for_function(
            """expected => {
              if (!window.term
                  || window.term.buffer.active.cursorX !== expected.x
                  || window.term.buffer.active.cursorY !== expected.y) return false;
              const cursor = document.querySelector('.xterm-cursor');
              if (!cursor) return false;
              const style = window.getComputedStyle(cursor);
              return style.display !== 'none'
                && style.visibility !== 'hidden'
                && Number.parseFloat(style.opacity || '1') > 0;
            }""",
            arg={"x": expected_x, "y": expected_y},
            timeout=10_000,
        )
    except PlaywrightTimeoutError as error:
        actual = cursor_position(page)
        raise TimeoutError(
            f"cursor expected x={expected_x} y={expected_y}; actual={actual}; "
            f"visible={cursor_visible(page)}; screen={screen_text(page)!r}"
        ) from error
    actual = cursor_position(page)
    require(actual == {"x": expected_x, "y": expected_y}, f"cursor: {actual}")
    require(cursor_visible(page), "cursor coordinates are correct but cursor is hidden")
    return actual


def wait_cursor_hidden(page: Page) -> None:
    page.wait_for_function(
        """() => {
          const cursor = document.querySelector('.xterm-cursor');
          if (!cursor) return true;
          const style = window.getComputedStyle(cursor);
          return style.display === 'none'
            || style.visibility === 'hidden'
            || Number.parseFloat(style.opacity || '1') === 0;
        }""",
        timeout=10_000,
    )
    require(not cursor_visible(page), "compact resize gate left cursor visible")


def resize_terminal(page: Page, cols: int, rows: int) -> None:
    page.evaluate(
        "size => window.term.resize(size.cols, size.rows)",
        {"cols": cols, "rows": rows},
    )
    page.wait_for_function(
        "size => window.term.cols === size.cols && window.term.rows === size.rows",
        arg={"cols": cols, "rows": rows},
        timeout=10_000,
    )
    page.wait_for_function(
        r"""() => !Array.from(document.querySelectorAll('.terminal.xterm > div'))
          .some(node => /^\d+x\d+$/.test((node.textContent || '').trim()))""",
        timeout=10_000,
    )


def await_event(value: threading.Event, label: str) -> None:
    if not value.wait(10):
        raise TimeoutError(label)


def wait_until(
    predicate: Callable[[], bool], label: str, timeout: float = 10.0
) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    raise TimeoutError(label)


def capture(
    page: Page,
    output: Path,
    filename: str,
    *markers: str,
    expected_cursor: tuple[int, int] | None = None,
    expected_dimensions: tuple[int, int] = (99, 30),
    input_row_markers: tuple[str, ...] = (),
    input_row_absent: tuple[str, ...] = (),
    absent_markers: tuple[str, ...] = (),
) -> dict[str, Any]:
    path = output / filename
    require(not path.exists(), f"capture path already exists: {path}")
    dimensions = page.evaluate("({cols: window.term.cols, rows: window.term.rows})")
    require(
        dimensions == {"cols": expected_dimensions[0], "rows": expected_dimensions[1]},
        f"wrong dimensions: {dimensions}",
    )
    resize_overlays = page.locator(".terminal.xterm > div").evaluate_all(
        "nodes => nodes.map(node => (node.textContent || '').trim()).filter(text => /^\\d+x\\d+$/.test(text))"
    )
    require(
        resize_overlays == [], f"{filename} retains resize overlay: {resize_overlays}"
    )
    visible = screen_text(page)
    for marker in markers:
        require(marker in visible, f"{filename} does not show {marker!r}")
    for marker in absent_markers:
        require(marker not in visible, f"{filename} unexpectedly shows {marker!r}")
    screen = page.locator(".xterm-screen")
    cursor = cursor_position(page)
    input_row = buffer_line(page, cursor["y"])
    if expected_cursor is not None:
        require(
            cursor == {"x": expected_cursor[0], "y": expected_cursor[1]},
            f"{filename} cursor {cursor}, expected {expected_cursor}",
        )
        require(cursor_visible(page), f"{filename} cursor is hidden")
    for marker in input_row_markers:
        require(
            marker in input_row,
            f"{filename} input row omits {marker!r}: {input_row!r}",
        )
    for marker in input_row_absent:
        require(
            marker not in input_row,
            f"{filename} input row retains {marker!r}: {input_row!r}",
        )
    box = screen.bounding_box()
    require(box is not None, f"{filename} has no screen bounds")
    screen.screenshot(path=str(path))
    payload = path.read_bytes()
    assert box is not None
    # fmt: off
    return {
        "file": filename, "captured_at": utc_now(), "bytes": len(payload),
        "sha256": digest_bytes(payload), "visible_text_sha256": digest_bytes(visible.encode()),
        "visible_text": visible,
        "terminal_columns": dimensions["cols"], "terminal_rows": dimensions["rows"],
        "width_px": int(box["width"]), "height_px": int(box["height"]),
        "cursor_zero_based": cursor, "cursor_visible": cursor_visible(page),
        "xterm_unicode_active_version": page.evaluate("window.term.unicode.activeVersion"),
        "input_row_text_sha256": digest_bytes(input_row.encode()),
        "input_row_text": input_row, "markers": markers,
    }
    # fmt: on


def request_identity(state: Fixture, expected_message: str) -> dict[str, str]:
    with state.lock:
        matches = [
            request
            for request in state.requests
            if request["message"] == expected_message
        ]
    require(
        len(matches) == 1,
        f"expected one request for {expected_message!r}, found {len(matches)}",
    )
    request = matches[0]
    require(request["name"] == KEEPER, "Keeper identity mismatch")
    require(request["message"] == expected_message, "message identity mismatch")
    require(UUID7_RE.fullmatch(request["request_id"]) is not None, "invalid UUIDv7")
    return request


def compact_request_label(request: dict[str, str]) -> str:
    request_id = request["request_id"]
    return request_id if len(request_id) <= 20 else request_id[:6] + ".." + request_id[-12:]


def show_full_metadata(page: Page) -> None:
    press(page, "Control+F", "metadata:inline")
    press(page, "Control+F", "metadata:full")


def final_http(
    state: Fixture,
    posts: int,
    gets: int,
    *,
    interrupts: int = 0,
) -> dict[str, Any]:
    summary = state.summary()
    counts = {
        key: summary[key]
        for key in (
            "chat_stream_post_count",
            "interrupt_post_count",
            "chat_operation_get_count",
            "other_post_count",
            "unexpected_chat_route_count",
        )
    }
    expected = {
        "chat_stream_post_count": posts,
        "interrupt_post_count": interrupts,
        "chat_operation_get_count": gets,
        "other_post_count": 0,
        "unexpected_chat_route_count": 0,
    }
    require(counts == expected, f"final HTTP counts: {counts}, expected {expected}")
    require(summary["errors"] == [], f"fixture errors: {summary['errors']}")
    settled = all(
        record["response_status"] == 200 and record["response_handler_completed"]
        for record in summary["records"]
    )
    require(settled, "not all fixture responses settled")
    return summary


def success_scenario(
    browser: Browser,
    output: Path,
    prefix: str,
    executable: Path,
) -> dict[str, Any]:
    state = Fixture("causal")
    shots: list[dict[str, Any]] = []
    measurements: dict[str, Any] = {}
    with fixture_server(state) as api_port:
        with tempfile.TemporaryDirectory(prefix="masc-tui-keeper-chat-success-") as raw:
            base = Path(raw)
            prepare_base(base)
            state.workspace_base_path = str(base)
            with ttyd_session(browser, base, api_port, executable) as (page, _started):
                open_message(page)
                show_full_metadata(page)
                resize_terminal(page, 99, 7)
                wait_text(page, "terminal too small")
                wait_cursor_hidden(page)
                type_text(page, "blocked-tiny")
                page.wait_for_timeout(2_000)
                wait_cursor_hidden(page)
                require(
                    "blocked-tiny" not in screen_text(page),
                    "compact resize gate accepted hidden input",
                )
                # fmt: off
                shots.append(capture(page, output, prefix + "01-chat-tiny-resize-gate.png",
                                     "terminal too small", "resize to at least 14 rows", "q: quit",
                                     expected_dimensions=(99, 7)))
                # fmt: on
                resize_terminal(page, 99, 30)
                wait_text(page, f"Keepers ▸ {KEEPER} ▸ chat")
                wait_text(page, "blocked-tiny", present=False)
                composer_row = find_composer_row(page)
                require(
                    composer_row >= 0,
                    "composer prompt row was not found in the xterm buffer",
                )
                cursor = cursor_position(page)
                require(
                    cursor["y"] == composer_row,
                    f"cursor y {cursor['y']} does not match composer row {composer_row}",
                )
                measurements["resize_restore_cursor_zero_based"] = wait_cursor(
                    page, 6, composer_row
                )
                type_text(page, "👍🏽")
                wait_text(page, "👍🏽")
                measurements["compound_before_backspace_cursor_zero_based"] = (
                    wait_cursor(page, 10, composer_row)
                )
                press(page, "Backspace")
                wait_text(page, "👍")
                wait_text(page, "👍🏽", present=False)
                measurements["compound_after_backspace_cursor_zero_based"] = (
                    wait_cursor(page, 8, composer_row)
                )
                press(page, "Control+U")
                wait_text(page, "👍", present=False)
                type_text(page, LONG_DRAFT)
                wait_text(page, "❤️❤️❤️-TAIL")
                wait_text(page, "prefix-", present=False)
                measurements["long_tail_cursor_zero_based"] = wait_cursor(
                    page, 97, composer_row
                )
                # fmt: off
                shots.append(capture(page, output, prefix + "02-chat-long-tail.png",
                                     "> ~", "❤️❤️❤️-TAIL", expected_cursor=(97, composer_row),
                                     input_row_markers=("> ~", "❤️❤️❤️-TAIL"),
                                     input_row_absent=("prefix-",)))
                # fmt: on
                press(page, "Backspace")
                wait_text(page, "❤️❤️❤️-TAI")
                wait_text(page, "❤️❤️❤️-TAIL", present=False)
                measurements["backspace_cursor_zero_based"] = wait_cursor(
                    page, 97, composer_row
                )
                # fmt: off
                shots.append(capture(page, output, prefix + "03-chat-long-tail-backspace.png",
                                     "> ~", "❤️❤️❤️-TAI", expected_cursor=(97, composer_row),
                                     input_row_markers=("> ~", "❤️❤️❤️-TAI"),
                                     input_row_absent=("prefix-", "❤️❤️❤️-TAIL")))
                # fmt: on
                press(page, "Control+U")
                wait_text(page, "❤️❤️❤️-TAI", present=False)
                type_text(page, SUCCESS_MESSAGE)
                wait_text(page, SUCCESS_MESSAGE)
                measurements["unicode_draft_cursor_zero_based"] = wait_cursor(
                    page, 25, composer_row
                )
                # fmt: off
                shots.append(capture(page, output, prefix + "04-chat-unicode-draft.png",
                                     SUCCESS_MESSAGE, "Enter:send", expected_cursor=(25, composer_row),
                                     input_row_markers=(f"> {SUCCESS_MESSAGE}",)))
                # fmt: on
                state.note_submission(SUCCESS_MESSAGE, time.time())
                started = time.monotonic()
                press(page, "Enter")
                await_event(state.post_seen, "success POST")
                measurements["enter_to_post_ms"] = round(
                    (time.monotonic() - started) * 1000, 3
                )
                request = request_identity(state, SUCCESS_MESSAGE)
                request_label = compact_request_label(request)
                wait_text(page, "ACTIVE TURN")
                wait_text(page, request_label)
                measurements["enter_to_sending_ui_ms"] = round(
                    (time.monotonic() - started) * 1000, 3
                )
                sending_text = screen_text(page)
                footer_before_queue, _ = unique_screen_line(
                    sending_text, "Enter:queue(0)"
                )
                composer_row_before_queue = cursor_position(page)["y"]
                started = time.monotonic()
                type_text(page, "draft-during-send")
                wait_text(page, "> draft-during-send")
                latency = (time.monotonic() - started) * 1000
                measurements["draft_visible_latency_ms"] = round(latency, 3)
                measurements[
                    "draft_visible_before_post_release"
                ] = not state.post_release.is_set()
                require(
                    latency <= 500 and not state.post_release.is_set(),
                    f"draft latency/release violated: {latency:.3f}ms",
                )
                state.note_submission("draft-during-send", time.time())
                queue_enter_started = time.monotonic()
                press(page, "Enter")
                wait_text(page, "NEXT 1")
                wait_text(page, "Enter:queue(1)")
                require(
                    state.summary()["chat_stream_post_count"] == 1,
                    "inflight Enter sent a second POST",
                )
                queued_visible_at = time.monotonic()
                queued_text = screen_text(page)
                composer_row_with_queue = cursor_position(page)["y"]
                next_row, next_line = unique_screen_line(queued_text, "NEXT 1")
                next_body_row, _ = unique_screen_line(queued_text, "draft-during-send")
                require(
                    next_body_row == next_row + 1,
                    "NEXT header and body do not reserve one USER-shaped slot",
                )
                footer_with_queue, _ = unique_screen_line(queued_text, "Enter:queue(1)")
                require(
                    footer_with_queue == footer_before_queue,
                    "NEXT changed the composer's visual slot",
                )
                require(
                    composer_row_with_queue == composer_row_before_queue,
                    "NEXT moved the composer cursor row",
                )
                queued_clock_match = re.search(
                    r"NEXT\s+1\s+·\s+(\d{2}:\d{2}:\d{2})",
                    next_line,
                )
                require(queued_clock_match is not None, "NEXT omitted submitted_at")
                assert queued_clock_match is not None
                queued_clock = queued_clock_match.group(1)
                current_user_row, _ = unique_screen_line(
                    queued_text, request_label, "YOU"
                )
                require(
                    current_user_row < next_row,
                    "NEXT was drawn inside or ahead of the causal transcript",
                )
                measurements.update(
                    {
                        "queue_enter_to_next_visible_ms": round(
                            (queued_visible_at - queue_enter_started) * 1000,
                            3,
                        ),
                        "queued_submitted_clock": queued_clock,
                        "composer_row_before_queue_zero_based": composer_row_before_queue,
                        "composer_row_with_queue_zero_based": composer_row_with_queue,
                        "footer_row_before_queue_zero_based": footer_before_queue,
                        "footer_row_with_queue_zero_based": footer_with_queue,
                    }
                )
                # fmt: off
                shots.append(capture(page, output, prefix + "05-chat-next-separated.png",
                                  SUCCESS_MESSAGE, "ACTIVE TURN",
                                  "NEXT 1", "draft-during-send", "Enter:queue(1)",
                                  absent_markers=("QUEUED",)))
                # fmt: on
                hold_started = time.monotonic()
                page.wait_for_timeout(1_250)
                queued_hold_ms = (time.monotonic() - hold_started) * 1000
                require(
                    queued_hold_ms >= 1_000,
                    f"queued hold was too short to distinguish clocks: {queued_hold_ms}",
                )
                measurements["queued_hold_before_promotion_ms"] = round(
                    queued_hold_ms, 3
                )
                started = time.monotonic()
                state.post_release.set()
                wait_until(
                    lambda: len(state.summary()["requests"]) == 2,
                    "NEXT did not dispatch after the active turn settled",
                )
                queued_request = request_identity(state, "draft-during-send")
                queued_request_label = compact_request_label(queued_request)
                wait_text(page, f"reply-{SUCCESS_MESSAGE}")
                wait_text(page, "NEXT 1", present=False)
                wait_text(page, queued_request_label)
                queue_active_at = time.monotonic()
                active_text = screen_text(page)
                queued_user_row, queued_user_line = unique_screen_line(
                    active_text, queued_request_label, "YOU"
                )
                composer_row_queued_active = cursor_position(page)["y"]
                active_footer_row, _ = unique_screen_line(active_text, "Enter:queue(0)")
                require(
                    queued_clock in queued_user_line,
                    "queued USER lost its first submitted_at when it became active",
                )
                require(
                    active_footer_row == footer_before_queue,
                    "queue-to-active promotion moved the composer's visual slot",
                )
                require(
                    queued_user_row == next_row,
                    "NEXT did not hand its physical row to the promoted USER",
                )
                require(
                    composer_row_queued_active == composer_row_before_queue,
                    "queue-to-active promotion moved the composer cursor row",
                )
                measurements.update(
                    {
                        "first_release_to_queued_active_ms": round(
                            (queue_active_at - started) * 1000,
                            3,
                        ),
                        "queued_user_active_row_zero_based": queued_user_row,
                        "composer_row_queued_active_zero_based": composer_row_queued_active,
                        "footer_row_queued_active_zero_based": active_footer_row,
                    }
                )
                # fmt: off
                shots.append(capture(page, output, prefix + "06-chat-next-active-same-slot.png",
                                  "ACTIVE TURN", queued_request_label,
                                  "draft-during-send", queued_clock, "Enter:queue(0)",
                                  absent_markers=("NEXT 1",)))
                # fmt: on
                state.post2_release.set()
                wait_text(page, "reply-draft-during-send")
                reply_visible_at = time.monotonic()
                latency = (reply_visible_at - started) * 1000
                measurements["queued_reply_visible_after_release_ms"] = round(
                    latency, 3
                )
                require(latency <= 2500, f"reply latency {latency:.3f}ms")
                wait_text(page, "ACTIVE TURN", present=False)
                # The 30-row viewport is the physical-slot proof above. The
                # settled transcript contains two full turns plus a tool block;
                # widen only this final evidence frame so an older causal row
                # cannot be mistaken for a missing projection after clipping.
                resize_terminal(page, 99, 42)
                wait_text(page, "evidence_probe")
                visible = screen_text(page)
                first_user_row, _ = unique_screen_line(
                    visible, request_label, "YOU"
                )
                first_tool_row, _ = unique_screen_line(visible, "✓", "evidence_probe")
                first_keeper_row, _ = unique_screen_line(visible, request_label, KEEPER)
                second_user_row, second_user_line = unique_screen_line(
                    visible, queued_request_label, "YOU"
                )
                second_keeper_row, _ = unique_screen_line(
                    visible, queued_request_label, KEEPER
                )
                require(
                    first_user_row
                    < first_tool_row
                    < first_keeper_row
                    < second_user_row
                    < second_keeper_row,
                    "final rows are not grouped USER then TOOL then ASSISTANT by request",
                )
                require(
                    queued_clock in second_user_line,
                    "settled queued USER lost its original submitted_at",
                )
                require("Enter:send" in visible, "settled footer does not allow send")
                measurements["final_causal_row_order_zero_based"] = [
                    first_user_row,
                    first_tool_row,
                    first_keeper_row,
                    second_user_row,
                    second_keeper_row,
                ]
                # fmt: off
                shots.append(capture(page, output, prefix + "07-chat-causal-turns-settled.png",
                                  SUCCESS_MESSAGE, f"reply-{SUCCESS_MESSAGE}", request_label,
                                  "✓", "evidence_probe",
                                  "draft-during-send", "reply-draft-during-send",
                                  queued_request_label, "Enter:send",
                                  expected_dimensions=(99, 42)))
                # fmt: on
    # fmt: off
    return {"name": "responsive_causal_queue", "measurements": measurements,
            "screenshots": shots, "http": final_http(state, 2, 0)}
    # fmt: on


def recovery_scenario(
    browser: Browser,
    output: Path,
    prefix: str,
    executable: Path,
) -> dict[str, Any]:
    state = Fixture("recovery")
    shots: list[dict[str, Any]] = []
    measurements: dict[str, float | int] = {}
    with fixture_server(state) as api_port:
        with tempfile.TemporaryDirectory(
            prefix="masc-tui-keeper-chat-recovery-"
        ) as raw:
            base = Path(raw)
            prepare_base(base)
            state.workspace_base_path = str(base)
            recovery = base / ".masc/tui-keeper-chat-recovery.json"
            with ttyd_session(browser, base, api_port, executable) as (page, _started):
                open_message(page)
                type_text(page, "recover-v3")
                press(page, "Enter")
                await_event(state.post_seen, "recovery POST")
                request = request_identity(state, "recover-v3")
                request_label = compact_request_label(request)
                wait_text(page, "outcome unverified:")
                visible = screen_text(page)
                require(
                    "partial-must-not-be-promoted" not in visible,
                    "partial reply was promoted",
                )
                require(recovery.exists(), "recovery file is missing")
                recovery_bytes = recovery.read_bytes()
                recovery_json = json.loads(recovery_bytes)
                expected_recovery = {
                    "schema": "masc.tui_keeper_chat_recovery.v3",
                    "phase": "accepted",
                    "request_id": request["request_id"],
                    "keeper_name": KEEPER,
                    "message": "recover-v3",
                }
                require(
                    recovery_json == expected_recovery, "recovery identity mismatch"
                )
                require(
                    stat.S_IMODE(recovery.stat().st_mode) == 0o600,
                    "recovery mode is not 0600",
                )
                recovery_hash = digest_bytes(recovery_bytes)
                type_text(page, "blocked-resend")
                press(page, "Enter")
                page.wait_for_timeout(350)
                require(
                    state.summary()["chat_stream_post_count"] == 1,
                    "unverified Enter sent a second POST",
                )
                # fmt: off
                shots.append(capture(page, output, prefix + "08-chat-outcome-unverified.png",
                                  "outcome unverified:", request_label, "> blocked-resend",
                                  "Ctrl-R:resume exact request  Enter:blocked"))
                # fmt: on
                navigations: list[Frame] = []
                page.on("framenavigated", lambda frame: navigations.append(frame))
                require(
                    not state.get1_seen.is_set(),
                    "manual reconciliation GET arrived before Ctrl-R",
                )
                started = time.monotonic()
                press(page, "Control+R")
                await_event(state.get1_seen, "manual operation GET")
                get_latency = (time.monotonic() - started) * 1000
                wait_text(page, f"(reconciling exact operation {request_label}")
                ui_latency = (time.monotonic() - started) * 1000
                measurements.update(
                    {
                        "ctrl_r_to_get_ms": round(get_latency, 3),
                        "ctrl_r_to_reconciling_ui_ms": round(ui_latency, 3),
                        "ctrl_r_navigation_count": len(navigations),
                    }
                )
                require(get_latency <= 500, f"Ctrl-R GET latency {get_latency:.3f}ms")
                require(ui_latency <= 500, f"Ctrl-R UI latency {ui_latency:.3f}ms")
                require(navigations == [], "Ctrl-R navigated the browser page")
                press(page, "Control+R")
                press(page, "Enter")
                page.wait_for_timeout(350)
                interim = state.summary()
                require(
                    interim["chat_stream_post_count"] == 1
                    and interim["chat_operation_get_count"] == 1,
                    "held reconciliation did not remain POST1/GET1",
                )
            require(
                recovery.exists() and digest_file(recovery) == recovery_hash,
                "recovery changed across process exit",
            )
            state.get1_release.set()
            await_event(state.get1_done, "GET1 cleanup")
            with ttyd_session(browser, base, api_port, executable) as (
                page,
                session_started,
            ):
                await_event(state.get2_seen, "startup operation GET")
                assert state.get2_received_monotonic is not None
                startup_latency = (
                    state.get2_received_monotonic - session_started
                ) * 1000
                measurements["restart_to_auto_get_ms"] = round(startup_latency, 3)
                require(
                    startup_latency <= 5000,
                    f"startup GET latency {startup_latency:.3f}ms",
                )
                open_message(page)
                wait_text(
                    page,
                    "Recovered an accepted request; reconciling the exact durable operation",
                )
                wait_text(page, f"(reconciling exact operation {request_label}")
                # fmt: off
                shots.append(capture(page, output, prefix + "09-chat-restarted-reconciling.png",
                                  "Recovered an accepted request; reconciling the exact durable operation",
                                  f"(reconciling exact operation {request_label}",
                                  "reconciling exact operation  Enter:blocked"))
                # fmt: on
                started = time.monotonic()
                state.get2_release.set()
                wait_text(page, "Operation settled successfully (turn:v3)")
                latency = (time.monotonic() - started) * 1000
                measurements["recovery_visible_after_release_ms"] = round(latency, 3)
                require(latency <= 2500, f"recovery latency {latency:.3f}ms")
                wait_text(page, "outcome unverified:", present=False)
                wait_text(page, "(reconciling exact operation", present=False)
                deadline = time.monotonic() + 5
                while recovery.exists() and time.monotonic() < deadline:
                    time.sleep(0.05)
                require(not recovery.exists(), "terminal recovery retained fence")
                require("Enter:send" in screen_text(page), "settled footer blocks send")
                # fmt: off
                shots.append(capture(page, output, prefix + "10-chat-reconciled.png",
                                  "Operation settled successfully (turn:v3)",
                                  "canonical reply is unavailable", "transport", "Enter:send"))
                # fmt: on
    summary = final_http(state, 1, 2)
    expected_path = f"/api/v1/keepers/{KEEPER}/chat/operations/{request['request_id']}"
    paths = [
        r["path"] for r in summary["records"] if r["operation_ordinal"] is not None
    ]
    require(paths == [expected_path, expected_path], f"operation paths: {paths}")
    # fmt: off
    return {
        "name": "accepted_eof_exact_recovery_across_restart",
        "uncertainty_fixture": "accepted strict SSE ending before terminal event",
        "measurements": measurements, "recovery_sha256_before_restart": recovery_hash,
        "screenshots": shots, "http": summary,
    }
    # fmt: on


def replayable_scenario(
    browser: Browser,
    output: Path,
    prefix: str,
    executable: Path,
) -> dict[str, Any]:
    state = Fixture("success")
    shots: list[dict[str, Any]] = []
    request = {
        "request_id": "tui-0198f0de-1234-7abc-8def-0123456789ab",
        "name": KEEPER,
        "message": "replayable-v3",
    }
    with fixture_server(state) as api_port:
        with tempfile.TemporaryDirectory(prefix="masc-tui-keeper-chat-replay-") as raw:
            base = Path(raw)
            prepare_base(base)
            state.workspace_base_path = str(base)
            recovery = write_recovery(base, phase="replayable", request=request)
            with ttyd_session(browser, base, api_port, executable) as (page, started):
                await_event(state.post_seen, "authorized replay POST")
                observed = request_identity(state, request["message"])
                require(observed == request, "authorized replay changed exact identity")
                post_record = next(
                    record
                    for record in state.summary()["records"]
                    if record["method"] == "POST"
                )
                post_latency = (post_record["received_monotonic"] - started) * 1000
                open_message(page)
                request_label = compact_request_label(request)
                wait_text(page, "Recovered a replayable request")
                wait_text(page, f"(replaying exact request {request_label}")
                wait_text(page, "prior outcome unverified:")
                phase = json.loads(recovery.read_text(encoding="utf-8"))["phase"]
                require(phase == "dispatching", f"replay claim phase: {phase}")
                # fmt: off
                shots.append(capture(page, output, prefix + "11-chat-replayable-exact-replay.png",
                                     "Recovered a replayable request",
                                     f"(replaying exact request {request_label}",
                                     "prior outcome unverified:",
                                     "replaying exact request  Enter:blocked"))
                # fmt: on
                state.post_release.set()
                wait_text(page, "reply-v3")
                wait_until(lambda: not recovery.exists(), "replay fence cleanup")
    # fmt: off
    return {
        "name": "durable_replayable_exact_id_replay",
        "measurements": {"startup_to_replay_post_ms": round(post_latency, 3)},
        "screenshots": shots, "http": final_http(state, 1, 0),
    }
    # fmt: on


def cross_process_fail_closed_scenario(
    browser: Browser,
    output: Path,
    prefix: str,
    executable: Path,
) -> dict[str, Any]:
    state = Fixture("rejection")
    shots: list[dict[str, Any]] = []
    measurements: dict[str, float | int] = {}
    request = {
        "request_id": "tui-0198f0df-5678-7abc-9def-0123456789ab",
        "name": KEEPER,
        "message": "race-v3",
    }
    with fixture_server(state) as api_port:
        with tempfile.TemporaryDirectory(prefix="masc-tui-keeper-chat-race-") as raw:
            base = Path(raw)
            prepare_base(base)
            state.workspace_base_path = str(base)
            recovery = write_recovery(base, phase="prepared", request=request)
            dispatch_lock = Path(str(recovery) + ".dispatch.lock")
            with held_file_lock(dispatch_lock) as release_lock:
                with ttyd_session(browser, base, api_port, executable) as (
                    observer,
                    observer_started,
                ):
                    open_message(observer)
                    wait_text(
                        observer,
                        "Recovered a prepared request; claiming its first serialized dispatch",
                    )
                    wait_text(observer, "prepared recovery blocked")
                    wait_text(observer, "Ctrl-R:retry prepared fence  Enter:blocked")
                    summary_during = state.summary()
                    posts_during = summary_during["chat_stream_post_count"]
                    require(posts_during == 0, "locked observer issued a POST")
                    measurements.update(
                        {
                            "prepared_observer_start_to_blocked_ui_ms": round(
                                (time.monotonic() - observer_started) * 1000,
                                3,
                            ),
                            "post_count_while_external_lock_active": posts_during,
                        }
                    )
                    # fmt: off
                    shots.append(capture(observer, output, prefix + "12-chat-stale-prepared-blocked.png",
                                         "Recovered a prepared request; claiming its first serialized dispatch",
                                         "prepared recovery blocked",
                                         "Ctrl-R:retry prepared fence  Enter:blocked"))
                    # fmt: on
                    release_lock()
                    with ttyd_session(browser, base, api_port, executable) as (
                        owner,
                        _,
                    ):
                        await_event(state.post_seen, "owner first serialized POST")
                        observed = request_identity(state, request["message"])
                        require(
                            observed == request,
                            "owner dispatcher changed exact identity",
                        )
                        phase = json.loads(recovery.read_text(encoding="utf-8"))[
                            "phase"
                        ]
                        require(
                            phase == "dispatching", f"owner dispatch phase: {phase}"
                        )
                        require(
                            state.summary()["chat_stream_post_count"] == 1,
                            "owner did not remain the only POST",
                        )
                        released = time.monotonic()
                        state.post_release.set()
                        wait_until(
                            lambda: any(
                                record["method"] == "POST"
                                and record["response_status"] == 403
                                and record["response_handler_completed"]
                                for record in state.summary()["records"]
                            ),
                            "definitive rejection response",
                        )
                        wait_until(
                            lambda: not recovery.exists(), "rejected fence cleanup"
                        )
                        measurements["rejection_release_to_fence_removed_ms"] = round(
                            (time.monotonic() - released) * 1000, 3
                        )
                        owner.wait_for_timeout(500)
                        measurements[
                            "fence_absent_after_500ms_observation"
                        ] = not recovery.exists()
                        require(
                            measurements["fence_absent_after_500ms_observation"],
                            "rejected fence reappeared during stability observation",
                        )
                    resumed = time.monotonic()
                    press(observer, "Control+R")
                    wait_text(observer, "Enter:send")
                    wait_text(observer, "prepared recovery blocked", present=False)
                    measurements["stale_ctrl_r_to_send_enabled_ms"] = round(
                        (time.monotonic() - resumed) * 1000, 3
                    )
                    observer.wait_for_timeout(350)
                    require(
                        state.summary()["chat_stream_post_count"] == 1,
                        "stale Ctrl-R recreated and dispatched the removed fence",
                    )
                    measurements["post_count_after_350ms_stability_observation"] = 1
                    # fmt: off
                    shots.append(capture(observer, output, prefix + "13-chat-stale-fence-not-recreated.png",
                                         "Recovered a prepared request",
                                         "Enter:send"))
                    # fmt: on
    summary = state.summary()
    require(summary["chat_stream_post_count"] == 1, "race final POST count")
    require(summary["chat_operation_get_count"] == 0, "race final GET count")
    require(summary["other_post_count"] == 0, "race emitted other POST")
    require(summary["unexpected_chat_route_count"] == 0, "race used wrong route")
    require(summary["errors"] == [], f"race fixture errors: {summary['errors']}")
    require(
        all(record["response_handler_completed"] for record in summary["records"]),
        "race left an HTTP response unsettled",
    )
    # fmt: off
    return {
        "name": "two_tui_stale_prepared_not_recreated",
        "measurements": measurements, "screenshots": shots, "http": summary,
    }
    # fmt: on


def steer_scenario(
    browser: Browser,
    output: Path,
    prefix: str,
    executable: Path,
) -> dict[str, Any]:
    state = Fixture("steer")
    shots: list[dict[str, Any]] = []
    measurements: dict[str, Any] = {}
    with fixture_server(state) as api_port:
        with tempfile.TemporaryDirectory(prefix="masc-tui-keeper-chat-steer-") as raw:
            base = Path(raw)
            prepare_base(base)
            state.workspace_base_path = str(base)
            with ttyd_session(browser, base, api_port, executable) as (page, _started):
                open_message(page)
                show_full_metadata(page)
                type_text(page, "original-course")
                state.note_submission("original-course", time.time())
                press(page, "Enter")
                await_event(state.post_seen, "steer original POST")
                original = request_identity(state, "original-course")
                original_label = compact_request_label(original)
                wait_text(page, "ACTIVE TURN")
                wait_text(page, original_label)

                type_text(page, "ordinary-next")
                state.note_submission("ordinary-next", time.time())
                press(page, "Enter")
                wait_text(page, "NEXT 1")
                type_text(page, "/steer corrected-course")
                state.note_submission("corrected-course", time.time())
                steer_started = time.monotonic()
                press(page, "Enter")
                wait_text(page, "STEER 1")
                wait_text(page, "NEXT 2")
                await_event(state.interrupt_seen, "steer exact interrupt POST")
                steer_visible_at = time.monotonic()
                page.wait_for_timeout(350)
                stable_summary = state.summary()
                require(
                    stable_summary["chat_stream_post_count"] == 1
                    and len(stable_summary["requests"]) == 1,
                    "STEER dispatched a replacement before the parent terminal",
                )
                queued_text = screen_text(page)
                steer_row, _ = unique_screen_line(queued_text, "STEER 1")
                steer_body_row, _ = unique_screen_line(queued_text, "corrected-course")
                next_row, _ = unique_screen_line(queued_text, "NEXT 2")
                next_body_row, _ = unique_screen_line(queued_text, "ordinary-next")
                require(
                    steer_body_row == steer_row + 1 and next_body_row == next_row + 1,
                    "STEER/NEXT lanes do not reserve USER-shaped slots",
                )
                require(
                    steer_row < next_row,
                    "STEER does not precede ordinary NEXT in the pending lane",
                )
                measurements.update(
                    {
                        "steer_enter_to_visible_and_interrupt_ms": round(
                            (steer_visible_at - steer_started) * 1000,
                            3,
                        ),
                        "steer_pending_row_zero_based": steer_row,
                        "ordinary_next_pending_row_zero_based": next_row,
                        "post_count_after_interrupt_stability_observation": 1,
                    }
                )
                # fmt: off
                shots.append(capture(page, output, prefix + "14-chat-steer-distinct.png",
                                     "ACTIVE TURN",
                                     "STEER 1", "corrected-course",
                                     "NEXT 2", "ordinary-next", "Enter:queue(2)"))
                # fmt: on

                release_started = time.monotonic()
                state.post_release.set()
                wait_until(
                    lambda: len(state.summary()["requests"]) == 2,
                    "STEER did not dispatch after the interrupted turn settled",
                )
                corrected = request_identity(state, "corrected-course")
                corrected_label = compact_request_label(corrected)
                wait_text(page, "STEER 1", present=False)
                wait_text(page, corrected_label)
                active_text = screen_text(page)
                _, _ = unique_screen_line(active_text, corrected_label, "YOU")
                next_row, _ = unique_screen_line(active_text, "NEXT 1")
                next_body_row, _ = unique_screen_line(active_text, "ordinary-next")
                require(
                    next_body_row == next_row + 1,
                    "remaining NEXT lane lost its USER-shaped slot",
                )
                measurements["interrupt_release_to_steer_active_ms"] = round(
                    (time.monotonic() - release_started) * 1000,
                    3,
                )
                # fmt: off
                shots.append(capture(page, output, prefix + "15-chat-steer-active-before-next.png",
                                     "ACTIVE TURN", corrected_label,
                                     "corrected-course", "NEXT 1", "ordinary-next",
                                     absent_markers=("STEER 1",)))
                # fmt: on

                state.post2_release.set()
                wait_until(
                    lambda: len(state.summary()["requests"]) == 3,
                    "ordinary NEXT did not dispatch after STEER",
                )
                ordinary = request_identity(state, "ordinary-next")
                ordinary_label = compact_request_label(ordinary)
                wait_text(page, "reply-ordinary-next")
                wait_text(page, "ACTIVE TURN", present=False)
                wait_text(page, "Enter:send")
                messages = [
                    request["message"] for request in state.summary()["requests"]
                ]
                require(
                    messages
                    == ["original-course", "corrected-course", "ordinary-next"],
                    f"steer dispatch order is not causal: {messages!r}",
                )
                # fmt: off
                shots.append(capture(page, output, prefix + "16-chat-steer-order-settled.png",
                                     original_label, "reply-original-course",
                                     corrected_label, "reply-corrected-course",
                                     ordinary_label, "reply-ordinary-next", "Enter:send",
                                     absent_markers=("STEER 1", "NEXT 1")))
                # fmt: on
    # fmt: off
    return {
        "name": "steer_interrupt_precedes_ordinary_next",
        "measurements": measurements,
        "dispatch_messages": ["original-course", "corrected-course", "ordinary-next"],
        "screenshots": shots,
        "http": final_http(state, 3, 0, interrupts=1),
    }
    # fmt: on


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected-head", required=True)
    parser.add_argument("--target-pr", required=True, type=int)
    args = parser.parse_args()
    script_path = Path(__file__).resolve()
    script_hash = digest_file(script_path)
    output = Path(tempfile.mkdtemp(prefix="masc-tui-keeper-chat-capture-"))
    source_temp = tempfile.TemporaryDirectory(prefix=".source-", dir=output)
    source_dir = Path(source_temp.name)
    build_temp = tempfile.TemporaryDirectory(prefix=".dune-build-", dir=output)
    build_dir = Path(build_temp.name)
    executable = build_dir / "default/bin/masc_tui.exe"
    # fmt: off
    evidence: dict[str, Any] = {
        "schema": "masc.tui_keeper_chat_capture.v3", "target_pr": args.target_pr,
        "output_dir": str(output), "started_at": utc_now(), "scenarios": [],
    }
    # fmt: on
    code = 0
    try:
        require(
            re.fullmatch(r"[0-9a-f]{40}", args.expected_head) is not None,
            "--expected-head must be a full lowercase SHA",
        )
        require(args.target_pr > 0, "--target-pr must be positive")
        head = run_text("git", "rev-parse", "HEAD")
        dirty = run_text("git", "status", "--porcelain=v1").splitlines()
        require(head == args.expected_head, f"HEAD mismatch: {head}")
        require(dirty == [], f"dirty checkout: {dirty}")
        require(BUILD_WRAPPER.is_file(), f"missing build wrapper: {BUILD_WRAPPER}")
        require(TTYD.is_file(), f"missing ttyd: {TTYD}")

        archive_path = output / ".source.tar"
        with archive_path.open("xb") as archive_handle:
            archive_result = subprocess.run(
                ["git", "archive", "--format=tar", head],
                cwd=WORKTREE,
                stdout=archive_handle,
            )
        require(archive_result.returncode == 0, "git archive failed")
        archive_hash = digest_file(archive_path)
        with tarfile.open(archive_path, mode="r") as archive:
            archive.extractall(path=source_dir, filter="data")
        archive_path.unlink()
        snapshot_wrapper = source_dir / "scripts/dune-local.sh"
        require(snapshot_wrapper.is_file(), "source snapshot is incomplete")

        require(not any(build_dir.iterdir()), "fresh build directory is not empty")
        build_environment = safe_env(BUILD_ENV_KEYS)
        build_args = ["build", "--build-dir", str(build_dir), "bin/masc_tui.exe"]
        build_started = utc_now()
        build_started_monotonic = time.monotonic()
        build = subprocess.run(
            [str(snapshot_wrapper), *build_args],
            cwd=source_dir,
            capture_output=True,
            env=build_environment,
        )
        # fmt: off
        evidence["build"] = {
            "command": ["scripts/dune-local.sh", *build_args],
            "started_at": build_started, "finished_at": utc_now(),
            "duration_ms": round((time.monotonic() - build_started_monotonic) * 1000, 3),
            "returncode": build.returncode, "stdout_sha256": digest_bytes(build.stdout),
            "stderr_sha256": digest_bytes(build.stderr),
            "stdout_utf8": build.stdout.decode("utf-8"),
            "stderr_utf8": build.stderr.decode("utf-8"),
            "inherited_environment_keys": sorted(build_environment),
            "fresh_build_dir": str(build_dir),
            "source_snapshot": {
                "kind": "git_archive", "commit": head, "tar_sha256": archive_hash,
            },
        }
        # fmt: on
        require(build.returncode == 0, f"focused build failed: {build.returncode}")
        require(
            executable.is_file() and not executable.is_symlink(),
            f"missing/non-regular rebuilt executable: {executable}",
        )
        require(
            run_text("git", "rev-parse", "HEAD") == head, "HEAD changed during build"
        )
        require(
            run_text("git", "status", "--porcelain=v1") == "", "build dirtied checkout"
        )
        require(
            digest_file(script_path) == script_hash,
            "capture script changed during build",
        )
        executable_hash = digest_file(executable)
        executable_bytes = executable.stat().st_size
        prefix = ""
        # fmt: off
        evidence["source"] = {
            "head": head,
            "branch": run_text("git", "branch", "--show-current"),
            "disposition": "exact-head-candidate",
            "executable_sha256": executable_hash,
            "executable_bytes": executable_bytes,
            "script_sha256": script_hash,
            "ttyd_version": run_text(str(TTYD), "--version"),
            "playwright_version": package_version("playwright"),
            "child_environment_keys": sorted(set(safe_env(SAFE_ENV_KEYS)) | {
                "MASC_BASE_PATH", "MASC_HOST", "MASC_TUI_SYNC",
                "NO_PROXY", "TERM", "no_proxy",
            }),
        }
        # fmt: on

        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(headless=True)
            try:
                evidence["source"]["chromium_version"] = browser.version
                evidence["scenarios"].append(
                    success_scenario(browser, output, prefix, executable)
                )
                evidence["scenarios"].append(
                    steer_scenario(browser, output, prefix, executable)
                )
            finally:
                browser.close()

        # fmt: off
        names = [scenario["name"] for scenario in evidence["scenarios"]]
        require(names == ["responsive_causal_queue",
                          "steer_interrupt_precedes_ordinary_next"],
                f"incomplete scenarios: {names}")
        screenshots = [shot for scenario in evidence["scenarios"] for shot in scenario["screenshots"]]
        # fmt: on
        require(len(screenshots) == 10, f"screenshot count: {len(screenshots)}")
        screenshot_paths = sorted(output.glob("*.png"))
        require(
            [path.name for path in screenshot_paths]
            == sorted(shot["file"] for shot in screenshots),
            "on-disk screenshot set differs from scenario records",
        )
        screenshot_records = {shot["file"]: shot for shot in screenshots}
        for path in screenshot_paths:
            record = screenshot_records[path.name]
            require(path.stat().st_size == record["bytes"], f"size drift: {path.name}")
            require(digest_file(path) == record["sha256"], f"hash drift: {path.name}")
        require(
            run_text("git", "rev-parse", "HEAD") == head, "HEAD changed during capture"
        )
        require(
            run_text("git", "status", "--porcelain=v1") == "",
            "capture dirtied checkout",
        )
        require(
            digest_file(executable) == executable_hash,
            "executable changed during capture",
        )
        require(
            digest_file(script_path) == script_hash,
            "capture script changed during execution",
        )
        # fmt: off
        evidence["verified"] = {
            "exact_head": True, "clean_before_and_after": True, "focused_build": True,
            "both_causal_scenarios": True, "ten_screenshots": True,
            "causal_queue_measured": True, "steer_interrupt_measured": True,
            "raw_dom_and_http_bodies": True,
            "binary_unchanged_during_capture": True, "script_unchanged": True,
            "immutable_git_archive_source": True, "screenshots_rehashed": True,
        }
        # fmt: on
        evidence["status"] = "passed"
    except Exception as error:  # noqa: BLE001 - always persist structured failure
        code = 1
        evidence["status"] = "failed"
        evidence["failure"] = {
            "type": type(error).__name__,
            "detail": str(error),
        }
        evidence["partial_screenshots"] = [
            {
                "file": path.name,
                "bytes": path.stat().st_size,
                "sha256": digest_file(path),
            }
            for path in sorted(output.glob("*.png"))
        ]
    finally:
        build_temp.cleanup()
        source_temp.cleanup()
    evidence["finished_at"] = utc_now()
    evidence_path = output / "evidence.json"
    with evidence_path.open("x", encoding="utf-8") as handle:
        json.dump(evidence, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    print(json.dumps(evidence, ensure_ascii=False, indent=2))
    print(f"evidence_path={evidence_path}", file=sys.stderr)
    return code


if __name__ == "__main__":
    raise SystemExit(main())
