#!/usr/bin/env python3
"""Submit one natural Keeper message and retain its typed operation receipt.

This producer deliberately does not select or name a Skill.  It sends the
message file unchanged through ``masc_keeper_msg`` exactly once, then observes
the returned operation through ``masc_keeper_delegate_status``.  The operation
surface does not expose a Skill invocation identity, so the receipt preserves
the exact turn reference needed by a later ledger join instead of guessing one.
"""

from __future__ import annotations

import argparse
from collections.abc import Callable
from datetime import datetime, timezone
from hashlib import sha256
import json
import math
from pathlib import Path
import re
import stat
import subprocess
import sys
import time
from typing import Any, Protocol, cast
import uuid
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit, urlunsplit
from urllib.request import Request

import proof_http


GIT_COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
GIT_TREE_RE = re.compile(r"^[0-9a-f]{40}$")
OPERATION_ID_RE = re.compile(r"^[A-Za-z0-9_.-]{1,128}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
OPERATION_SCHEMA = "masc.keeper_chat_operation.v1"
RECEIPT_SCHEMA = "masc.natural-keeper-skill-proof-producer/v1"
# Where a tool call's trace sits in the result: CallToolResult is a closed
# shape, so the server hangs its own fields off _meta under this vendor key.
CALL_META_KEY = "com.github.yousleepwhen.masc/call"
TERMINAL_STATES = frozenset({"Succeeded", "Failed", "Cancelled"})
NONTERMINAL_STATES = frozenset({"Queued", "Running"})


class ProducerError(RuntimeError):
    pass


class ToolTransport(Protocol):
    caller_agent_id: str | None

    def call_tool(self, name: str, arguments: dict[str, Any]) -> dict[str, Any]: ...


def require(condition: bool, detail: str) -> None:
    if not condition:
        raise ProducerError(detail)


def utc_now() -> str:
    return (
        datetime.now(timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def digest_bytes(value: bytes) -> str:
    return sha256(value).hexdigest()


def canonical_json_digest(value: Any) -> str:
    payload = json.dumps(
        value, ensure_ascii=False, separators=(",", ":"), sort_keys=True
    ).encode()
    return digest_bytes(payload)


def direct_message_input(message: str) -> dict[str, Any]:
    return {
        "schema": "masc.keeper_chat_operation.input.v1",
        "message": message,
        "user_blocks": [],
        "turn_instructions": None,
        "surface_context": None,
        "attachments": [],
    }


def parse_turn_ref(value: str) -> tuple[str, int]:
    trace_id, separator, turn_text = value.rpartition("#")
    require(separator == "#" and trace_id != "", "turn_ref is not canonical")
    require(
        turn_text.isascii() and turn_text.isdecimal(),
        "turn_ref absolute turn is not canonical",
    )
    absolute_turn = int(turn_text)
    require(
        absolute_turn >= 0 and str(absolute_turn) == turn_text,
        "turn_ref absolute turn is not canonical",
    )
    return trace_id, absolute_turn


def validate_turn_ref(value: str) -> None:
    parse_turn_ref(value)


def validate_runtime_instance_id(value: str) -> None:
    try:
        parsed = uuid.UUID(value)
    except ValueError as error:
        raise ProducerError("runtime instance id is not a UUID") from error
    require(
        parsed.version == 7 and str(parsed) == value,
        "runtime instance id is not canonical UUIDv7",
    )


def validate_direct_message_source(
    value: Any, *, keeper: str, submitted_by: str
) -> None:
    expected_thread = f"keeper:{keeper}"
    expected = {
        "schema": "masc.keeper_chat_operation.source.v1",
        "submitted_by": submitted_by,
        "thread_id": expected_thread,
        "continuation_channel": {
            "kind": "dashboard",
            "thread_id": expected_thread,
        },
        "surface": {"kind": "agent"},
        "channel": "agent",
        "channel_user_id": "",
        "channel_user_name": "",
        "channel_workspace_id": "",
        "conversation_id": None,
        "external_message_id": None,
        "workspace_id": None,
        "extra_mentions": [],
        "user_row_origin": "needs_append",
    }
    require(
        value == expected, "operation source differs from exact direct-message source"
    )


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        require(key not in result, f"JSON object repeats field {key}")
        result[key] = value
    return result


def decode_json(payload: bytes, context: str) -> dict[str, Any]:
    try:
        value = json.loads(payload, object_pairs_hook=reject_duplicate_keys)
    except ProducerError as error:
        raise ProducerError(f"{context}: {error}") from error
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ProducerError(f"{context} is not valid JSON: {error}") from error
    require(isinstance(value, dict), f"{context} is not a JSON object")
    return value


def exact_fields(value: Any, expected: set[str], context: str) -> dict[str, Any]:
    require(isinstance(value, dict), f"{context} is not an object")
    actual = set(value)
    require(
        actual == expected,
        f"{context} fields differ: expected={sorted(expected)} actual={sorted(actual)}",
    )
    return value


def required_string(value: dict[str, Any], field: str, context: str) -> str:
    result = value.get(field)
    require(isinstance(result, str) and result != "", f"{context}.{field} is empty")
    return cast(str, result)


def required_sha256(value: dict[str, Any], field: str, context: str) -> str:
    result = required_string(value, field, context)
    require(
        SHA256_RE.fullmatch(result) is not None, f"{context}.{field} is not SHA-256"
    )
    return result


def required_number(value: dict[str, Any], field: str, context: str) -> float:
    result = value.get(field)
    require(
        isinstance(result, (int, float))
        and not isinstance(result, bool)
        and math.isfinite(result)
        and result >= 0,
        f"{context}.{field} is not a nonnegative number",
    )
    return float(cast(int | float, result))


def canonical_base_url(value: str) -> str:
    parsed = urlsplit(value)
    require(parsed.scheme in ("http", "https"), "base URL must use http or https")
    require(parsed.netloc != "", "base URL must have a host")
    require(
        parsed.username is None and parsed.password is None,
        "base URL must not contain credentials",
    )
    require(parsed.path in ("", "/"), "base URL must identify the server root")
    require(
        parsed.query == "" and parsed.fragment == "",
        "base URL must not have a query or fragment",
    )
    return urlunsplit((parsed.scheme, parsed.netloc, "", "", ""))


def source_snapshot(repo: Path) -> dict[str, Any]:
    def git(*arguments: str) -> str:
        try:
            return subprocess.check_output(
                ["git", *arguments], cwd=repo, text=True, stderr=subprocess.PIPE
            ).strip()
        except (OSError, subprocess.CalledProcessError) as error:
            raise ProducerError(
                f"cannot inspect source checkout {repo}: {error}"
            ) from error

    head = git("rev-parse", "HEAD")
    tree = git("rev-parse", "HEAD^{tree}")
    tracked_changes = git(
        "status", "--porcelain=v1", "--untracked-files=no"
    ).splitlines()
    require(GIT_COMMIT_RE.fullmatch(head) is not None, "source HEAD is not a commit")
    require(GIT_TREE_RE.fullmatch(tree) is not None, "source tree is not a git tree")
    require(not tracked_changes, "source checkout has tracked changes")
    return {"head": head, "tree": tree, "tracked_changes": tracked_changes}


def validate_expected_source(source: dict[str, Any], expected_sha: str) -> None:
    require(
        GIT_COMMIT_RE.fullmatch(expected_sha) is not None,
        "expected source SHA is not a commit",
    )
    require(source.get("head") == expected_sha, "source HEAD differs from expected SHA")


def read_secret(path: Path) -> str:
    require(not path.is_symlink(), "token file must not be a symlink")
    try:
        mode = path.stat().st_mode
        require(stat.S_ISREG(mode), "token file must be regular")
        raw = path.read_text(encoding="utf-8")
        token = raw.strip()
    except OSError as error:
        raise ProducerError(f"cannot read token file: {error}") from error
    require(token != "", "token file is empty")
    require("\r" not in token and "\n" not in token, "token file has multiple lines")
    return token


def read_message(path: Path) -> tuple[str, bytes]:
    require(not path.is_symlink(), "message file must not be a symlink")
    try:
        mode = path.stat().st_mode
        require(stat.S_ISREG(mode), "message file must be regular")
        raw = path.read_bytes()
        message = raw.decode("utf-8")
    except (OSError, UnicodeDecodeError) as error:
        raise ProducerError(f"cannot read UTF-8 message file: {error}") from error
    require(message.strip() != "", "message file is blank")
    return message, raw


def auth_headers(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def read_health(base_url: str, token: str, timeout: float) -> dict[str, Any]:
    request = Request(
        f"{base_url}/health?full=1",
        headers={"Accept": "application/json", **auth_headers(token)},
    )
    try:
        with proof_http.open_no_redirect(request, timeout=timeout) as response:
            return decode_json(response.read(), "full health response")
    except (HTTPError, URLError, OSError) as error:
        raise ProducerError(f"cannot read full health response: {error}") from error


def validate_health(
    health: dict[str, Any], *, source: dict[str, Any], expected_base_path: str
) -> dict[str, str]:
    require(health.get("health_detail") == "full", "health response is not full")
    build = health.get("build")
    require(isinstance(build, dict), "health.build is not an object")
    paths = health.get("paths")
    require(isinstance(paths, dict), "health.paths is not an object")
    build = cast(dict[str, Any], build)
    paths = cast(dict[str, Any], paths)
    binary_commit = required_string(build, "binary_commit", "health.build")
    source_fingerprint = required_sha256(build, "source_fingerprint", "health.build")
    executable_sha256 = required_sha256(build, "executable_sha256", "health.build")
    executable_provenance_path = required_string(
        build, "executable_provenance_path", "health.build"
    )
    require(
        Path(executable_provenance_path).is_absolute(),
        "health.build.executable_provenance_path is not absolute",
    )
    executable_provenance_sha256 = required_sha256(
        build, "executable_provenance_sha256", "health.build"
    )
    require(binary_commit == source["head"], "server binary differs from source HEAD")
    require(
        build.get("binary_commit_source") == "embedded",
        "server binary commit is not embedded",
    )
    effective_base_path = required_string(paths, "effective_base_path", "health.paths")
    require(
        effective_base_path == expected_base_path,
        "server effective base path differs from requested base path",
    )
    runtime_instance_id = required_string(build, "runtime_instance_id", "health.build")
    validate_runtime_instance_id(runtime_instance_id)
    return {
        "binary_commit": binary_commit,
        "source_fingerprint": source_fingerprint,
        "executable_sha256": executable_sha256,
        "executable_provenance_path": executable_provenance_path,
        "executable_provenance_sha256": executable_provenance_sha256,
        "runtime_instance_id": runtime_instance_id,
        "started_at": required_string(build, "started_at", "health.build"),
        "effective_base_path": effective_base_path,
        "effective_masc_root": required_string(
            paths, "effective_masc_root", "health.paths"
        ),
    }


def require_same_server(before: dict[str, str], after: dict[str, str]) -> None:
    require(after == before, "server identity changed during natural Keeper production")


class McpClient:
    def __init__(
        self, endpoint: str, token: str, timeout: float, protocol_version: str
    ) -> None:
        self.endpoint = endpoint
        self._token = token
        self.timeout = timeout
        self.protocol_version = protocol_version
        self.session_id: str | None = None
        self.caller_agent_id: str | None = None
        self._next_request_id = 1

    def _decode_response(self, body: bytes, request_id: int) -> dict[str, Any]:
        stripped = body.strip()
        if stripped.startswith(b"{"):
            response = decode_json(stripped, "MCP response")
            require(response.get("id") == request_id, "MCP response id differs")
            return response
        matches: list[dict[str, Any]] = []
        for line in body.splitlines():
            if not line.startswith(b"data:"):
                continue
            payload = line[5:].strip()
            if payload in (b"", b"[DONE]"):
                continue
            value = decode_json(payload, "MCP SSE data")
            if value.get("id") == request_id:
                matches.append(value)
        require(len(matches) == 1, "MCP SSE response lacks one exact response id")
        return matches[0]

    def request(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        request_id = self._next_request_id
        self._next_request_id += 1
        payload = json.dumps(
            {
                "jsonrpc": "2.0",
                "id": request_id,
                "method": method,
                "params": params,
            },
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode()
        headers = {
            "Accept": "application/json, text/event-stream",
            "Content-Type": "application/json",
            **auth_headers(self._token),
        }
        if self.session_id is not None:
            headers["Mcp-Session-Id"] = self.session_id
            headers["Mcp-Protocol-Version"] = self.protocol_version
        request = Request(self.endpoint, data=payload, headers=headers, method="POST")
        try:
            with proof_http.open_no_redirect(request, timeout=self.timeout) as response:
                body = response.read()
                session_id = response.headers.get("Mcp-Session-Id")
                if session_id is not None:
                    self.session_id = session_id
        except (HTTPError, URLError, OSError) as error:
            # No retry is performed here.  A tools/call transport ambiguity
            # cannot authorize a second producer mutation.
            raise ProducerError(
                f"MCP transport failed for {method}: {error}"
            ) from error
        value = self._decode_response(body, request_id)
        require(value.get("jsonrpc") == "2.0", "MCP response is not JSON-RPC 2.0")
        require(
            set(value) in ({"jsonrpc", "id", "result"}, {"jsonrpc", "id", "error"}),
            "MCP response envelope fields differ",
        )
        require(value.get("error") is None, f"MCP {method} returned JSON-RPC error")
        return value

    def notify(self, method: str, params: dict[str, Any]) -> None:
        session_id = self.session_id
        require(session_id is not None, "MCP notification has no session id")
        session_id = cast(str, session_id)
        payload = json.dumps(
            {"jsonrpc": "2.0", "method": method, "params": params},
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode()
        request = Request(
            self.endpoint,
            data=payload,
            headers={
                "Accept": "application/json, text/event-stream",
                "Content-Type": "application/json",
                "Mcp-Session-Id": session_id,
                "Mcp-Protocol-Version": self.protocol_version,
                **auth_headers(self._token),
            },
            method="POST",
        )
        try:
            with proof_http.open_no_redirect(request, timeout=self.timeout) as response:
                response.read()
        except (HTTPError, URLError, OSError) as error:
            raise ProducerError(
                f"MCP transport failed for {method}: {error}"
            ) from error

    def initialize(self) -> None:
        self.request(
            "initialize",
            {
                "protocolVersion": self.protocol_version,
                "clientInfo": {
                    "name": "natural-keeper-skill-proof-producer",
                    "version": "1",
                },
                "capabilities": {},
            },
        )
        require(self.session_id is not None, "MCP initialize returned no session id")
        self.notify("notifications/initialized", {})

    def call_tool(self, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
        response = self.request("tools/call", {"name": name, "arguments": arguments})
        result = response.get("result")
        require(isinstance(result, dict), f"tool {name} result is not an object")
        result = cast(dict[str, Any], result)
        require(result.get("isError") is not True, f"tool {name} returned isError")
        meta = result.get("_meta")
        require(isinstance(meta, dict), f"tool {name} _meta is not an object")
        meta = cast(dict[str, Any], meta)
        # The call's trace lives under this server's own _meta key:
        # CallToolResult defines no member for it.
        call_meta = meta.get(CALL_META_KEY)
        require(
            isinstance(call_meta, dict),
            f"tool {name} _meta has no {CALL_META_KEY} entry",
        )
        call_meta = cast(dict[str, Any], call_meta)
        observed_agent_id = call_meta.get("agent_id")
        require(
            isinstance(observed_agent_id, str) and observed_agent_id != "",
            f"tool {name} call meta agent_id is empty",
        )
        require(
            self.caller_agent_id in (None, observed_agent_id),
            f"tool {name} caller agent identity changed",
        )
        self.caller_agent_id = observed_agent_id
        structured = result.get("structuredContent")
        if structured is not None:
            require(
                isinstance(structured, dict),
                f"tool {name} structuredContent is not an object",
            )
            return cast(dict[str, Any], structured)
        content = result.get("content")
        require(isinstance(content, list), f"tool {name} content is not an array")
        texts = [
            item.get("text")
            for item in cast(list[Any], content)
            if isinstance(item, dict) and item.get("type") == "text"
        ]
        require(
            len(texts) == 1 and isinstance(texts[0], str),
            f"tool {name} has no exact JSON text",
        )
        return decode_json(cast(str, texts[0]).encode(), f"tool {name} text")


def validate_keeper_status(
    status: dict[str, Any], *, keeper: str, runtime_id: str
) -> None:
    require(status.get("name") == keeper, "Keeper status names another Keeper")
    model = status.get("model_observability")
    require(isinstance(model, dict), "Keeper status lacks model_observability")
    model = cast(dict[str, Any], model)
    require(
        model.get("runtime_id") == runtime_id,
        "Keeper declarative runtime differs from requested runtime",
    )


def validate_acceptance(value: dict[str, Any]) -> str:
    fields = exact_fields(
        value,
        {"operation_id", "state", "queued_count", "existing"},
        "masc_keeper_msg result",
    )
    operation_id = required_string(fields, "operation_id", "masc_keeper_msg result")
    require(
        OPERATION_ID_RE.fullmatch(operation_id) is not None,
        "masc_keeper_msg returned an invalid operation id",
    )
    require(fields.get("state") == "queued", "new operation was not accepted as queued")
    queued_count = fields.get("queued_count")
    require(
        isinstance(queued_count, int)
        and not isinstance(queued_count, bool)
        and queued_count >= 0,
        "masc_keeper_msg queued_count is invalid",
    )
    require(fields.get("existing") is False, "new natural message reused an operation")
    return operation_id


def validate_operation(value: dict[str, Any], operation_id: str) -> str:
    require(value.get("schema") == OPERATION_SCHEMA, "operation schema is unsupported")
    require(value.get("operation_id") == operation_id, "operation identity changed")
    state = value.get("state")
    require(
        isinstance(state, str) and state in NONTERMINAL_STATES.union(TERMINAL_STATES),
        "operation state is unknown",
    )
    state = cast(str, state)
    base = {
        "schema",
        "operation_id",
        "sequence",
        "created_at",
        "execution_digest",
        "source",
        "input",
        "state",
    }
    extras = {
        "Queued": set(),
        "Running": {"started_at"},
        "Succeeded": {"completed_at", "outcome_ref"},
        "Failed": {
            "completed_at",
            "failure_kind",
            "failure_detail",
            "outcome_ref",
        },
        "Cancelled": {"completed_at"},
    }[state]
    exact_fields(value, base | extras, "Keeper chat operation")
    sequence = required_string(value, "sequence", "Keeper chat operation")
    require(
        sequence.isascii() and sequence.isdecimal(),
        "operation sequence is not a nonnegative int64",
    )
    digest = required_string(value, "execution_digest", "Keeper chat operation")
    require(
        SHA256_RE.fullmatch(digest) is not None, "operation execution digest is invalid"
    )
    required_number(value, "created_at", "Keeper chat operation")
    require(isinstance(value.get("source"), dict), "operation source is not an object")
    if state in NONTERMINAL_STATES:
        require(
            isinstance(value.get("input"), dict), "nonterminal operation lost input"
        )
    else:
        require(value.get("input") is None, "terminal operation retained input")
        required_number(value, "completed_at", "Keeper chat operation")
    if state == "Running":
        required_number(value, "started_at", "Keeper chat operation")
    if state == "Succeeded":
        required_string(value, "outcome_ref", "Keeper chat operation")
    if state == "Failed":
        required_string(value, "failure_kind", "Keeper chat operation")
        required_string(value, "failure_detail", "Keeper chat operation")
        outcome_ref = value.get("outcome_ref")
        require(
            outcome_ref is None or (isinstance(outcome_ref, str) and outcome_ref != ""),
            "failed operation outcome_ref is invalid",
        )
    return state


def validate_producer_operation(
    value: dict[str, Any],
    *,
    operation_id: str,
    keeper: str,
    submitted_by: str,
    message: str,
) -> str:
    state = validate_operation(value, operation_id)
    validate_direct_message_source(
        value.get("source"), keeper=keeper, submitted_by=submitted_by
    )
    expected_input = direct_message_input(message)
    require(
        value.get("execution_digest") == canonical_json_digest(expected_input),
        "operation execution digest differs from exact direct-message input",
    )
    if state in NONTERMINAL_STATES:
        require(
            value.get("input") == expected_input,
            "nonterminal operation input differs from exact direct-message input",
        )
    if state == "Succeeded":
        validate_turn_ref(
            required_string(value, "outcome_ref", "Keeper chat operation")
        )
    return state


def run_producer(
    *,
    transport: ToolTransport,
    keeper: str,
    runtime_id: str,
    message: str,
    message_raw: bytes,
    source_before: dict[str, Any],
    source_snapshot_fn: Callable[[], dict[str, Any]],
    observation_timeout: float,
    poll_interval: float,
    monotonic: Callable[[], float] = time.monotonic,
    sleep: Callable[[float], None] = time.sleep,
) -> dict[str, Any]:
    require(
        math.isfinite(observation_timeout) and observation_timeout > 0,
        "observation timeout must be positive and finite",
    )
    require(
        math.isfinite(poll_interval) and poll_interval > 0,
        "poll interval must be positive and finite",
    )
    require(keeper.strip() != "", "Keeper name must not be blank")
    require(runtime_id.strip() != "", "runtime id must not be blank")
    require(message.strip() != "", "natural message must not be blank")
    status = transport.call_tool(
        "masc_keeper_status",
        {
            "name": keeper,
            "fast": True,
            "include_context": False,
            "include_metrics_overview": False,
            "include_history_tail": False,
        },
    )
    validate_keeper_status(status, keeper=keeper, runtime_id=runtime_id)
    submitted_by = transport.caller_agent_id
    require(
        isinstance(submitted_by, str) and submitted_by != "",
        "MCP tool metadata did not identify the submitting agent",
    )
    submitted_by = cast(str, submitted_by)

    # This is the sole producer mutation.  In particular, no transport error
    # path calls it again; the caller receives an incomplete run instead.
    acceptance = transport.call_tool(
        "masc_keeper_msg", {"name": keeper, "message": message}
    )
    operation_id = validate_acceptance(acceptance)
    deadline = monotonic() + observation_timeout
    observations = 0
    while True:
        operation = transport.call_tool(
            "masc_keeper_delegate_status",
            {
                "target": {"kind": "keeper", "name": keeper},
                "operation_id": operation_id,
            },
        )
        observations += 1
        state = validate_producer_operation(
            operation,
            operation_id=operation_id,
            keeper=keeper,
            submitted_by=submitted_by,
            message=message,
        )
        if state in TERMINAL_STATES:
            break
        now = monotonic()
        require(now < deadline, "observation boundary reached before terminal state")
        sleep(min(poll_interval, deadline - now))

    source_after = source_snapshot_fn()
    require(source_after == source_before, "source checkout changed during production")
    require(state == "Succeeded", f"Keeper operation terminated as {state}")
    turn_ref = required_string(operation, "outcome_ref", "Keeper chat operation")
    return {
        "schema": RECEIPT_SCHEMA,
        "captured_at": utc_now(),
        "source": {
            "head": source_before["head"],
            "tree": source_before["tree"],
            "tracked_checkout_clean": True,
        },
        "keeper": keeper,
        "submitted_by": submitted_by,
        "keeper_admission": "exact_existing",
        "keeper_declarative_runtime_id": runtime_id,
        "actual_invocation_runtime_id": None,
        "operation": {
            "operation_id": operation_id,
            "acceptance": acceptance,
            "state": state,
            "turn_ref": turn_ref,
            "status_observations": observations,
            "typed_terminal_record": operation,
            "expected_operation_input_digest": canonical_json_digest(
                direct_message_input(message)
            ),
        },
        "message": {"bytes": len(message_raw), "sha256": digest_bytes(message_raw)},
        "skill_tool_use_id": None,
        "ledger_lookup": {
            "keeper": keeper,
            "turn_ref": turn_ref,
            "skill_tool_use_id": None,
        },
        "unresolved_identity": {
            "kind": "operation_surface_does_not_expose_skill_or_runtime_identity",
            "operation_schema": OPERATION_SCHEMA,
        },
        "producer_calls": {"masc_keeper_msg": 1},
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--expected-base-path", required=True)
    parser.add_argument("--source-repo", type=Path, required=True)
    parser.add_argument("--expected-source-sha", required=True)
    parser.add_argument("--token-file", type=Path, required=True)
    parser.add_argument("--keeper", required=True)
    parser.add_argument("--runtime-id", required=True)
    parser.add_argument("--message-file", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--mcp-protocol-version", required=True)
    parser.add_argument("--request-timeout-seconds", type=float, required=True)
    parser.add_argument("--observation-timeout-seconds", type=float, required=True)
    parser.add_argument("--poll-interval-seconds", type=float, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        base_url = canonical_base_url(args.base_url)
        require(
            args.mcp_protocol_version.strip() != "", "MCP protocol version is blank"
        )
        require(
            math.isfinite(args.request_timeout_seconds)
            and args.request_timeout_seconds > 0,
            "request timeout must be positive and finite",
        )
        source_repo = args.source_repo.resolve(strict=True)
        expected_base_path = str(Path(args.expected_base_path).resolve(strict=True))
        token = read_secret(args.token_file)
        message, message_raw = read_message(args.message_file)
        args.out.mkdir(parents=True, exist_ok=False)
        incomplete = args.out / "INCOMPLETE"
        incomplete.write_text(
            "natural Keeper Skill proof is incomplete\n", encoding="utf-8"
        )
        source_before = source_snapshot(source_repo)
        validate_expected_source(source_before, args.expected_source_sha)
        health = read_health(base_url, token, args.request_timeout_seconds)
        health_identity = validate_health(
            health, source=source_before, expected_base_path=expected_base_path
        )
        client = McpClient(
            f"{base_url}/mcp",
            token,
            args.request_timeout_seconds,
            args.mcp_protocol_version,
        )
        client.initialize()
        receipt = run_producer(
            transport=client,
            keeper=args.keeper,
            runtime_id=args.runtime_id,
            message=message,
            message_raw=message_raw,
            source_before=source_before,
            source_snapshot_fn=lambda: source_snapshot(source_repo),
            observation_timeout=args.observation_timeout_seconds,
            poll_interval=args.poll_interval_seconds,
        )
        health_after = read_health(base_url, token, args.request_timeout_seconds)
        require_same_server(
            health_identity,
            validate_health(
                health_after,
                source=source_before,
                expected_base_path=expected_base_path,
            ),
        )
        receipt["server"] = health_identity
        raw = (
            json.dumps(receipt, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
        ).encode()
        (args.out / "receipt.json").write_bytes(raw)
        incomplete.unlink()
        print(
            json.dumps(
                {
                    "status": "passed",
                    "receipt": str(args.out / "receipt.json"),
                    "sha256": digest_bytes(raw),
                    "operation_id": receipt["operation"]["operation_id"],
                    "producer_calls": receipt["producer_calls"],
                },
                sort_keys=True,
            )
        )
        return 0
    except (ProducerError, FileExistsError, FileNotFoundError) as error:
        print(f"natural-keeper-skill-proof-producer: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
