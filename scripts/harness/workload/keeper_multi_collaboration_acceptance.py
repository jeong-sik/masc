#!/usr/bin/env python3
"""Real-world, multi-Keeper product acceptance runner.

This is deliberately not a build or unit-test runner.  It drives a deployed,
isolated MASC runtime through MCP and accepts the system only when multiple
Keepers leave correlated Goal, Task, Board, Comment, Schedule, Fusion, IDE,
Memory, and Context outcomes behind.

Mutation is fail-closed: ``--run`` requires both ``--allow-mutation`` and an
exact ``--expected-base-path`` match against ``/health?full=1``.  ``--preflight``
and ``--validate-catalog`` are read-only.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import dataclasses
import datetime as dt
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from typing import Any, Iterable


SCRIPT_PATH = pathlib.Path(__file__).resolve()
REPO_ROOT = SCRIPT_PATH.parents[3]
DEFAULT_CATALOG = (
    REPO_ROOT
    / "scripts"
    / "fixtures"
    / "keeper-multi-collaboration"
    / "missions.json"
)
SCHEMA = "masc.keeper_multi_collaboration_evidence.v1"
# Mission ids are identifiers, not positions: RW19 held the persistence tier
# projection and was removed with that feature, and past evidence files still
# name the surviving missions by these numbers. Listing them avoids a range
# that would silently demand renumbering every retirement.
EXPECTED_MISSION_IDS = (
    "RW01", "RW02", "RW03", "RW04", "RW05", "RW06", "RW07", "RW08",
    "RW09", "RW10", "RW11", "RW12", "RW13", "RW14", "RW15", "RW16",
    "RW17", "RW18", "RW20", "RW21", "RW22", "RW23", "RW26",
)

EXPECTED_ROLES = {"coordinator", "builder-a", "builder-b", "reviewer", "researcher"}
TOOL_ALIASES = {
    "tool_write_file": {"tool_write_file", "Write"},
    "tool_execute": {"tool_execute", "Execute"},
}

KNOWN_ASSERTIONS = {
    "all_keepers_live",
    "role_identity_preserved",
    "runtime_assignment_serving_observed",
    "goal_visible",
    "goal_shared_open_set_visible",
    "tasks_linked_to_goal",
    "parallel_wave_completed",
    "parallel_keeper_overlap_observed",
    "multiple_task_owners_visible",
    "board_thread_visible",
    "multi_author_comments_visible",
    "ide_annotation_observed",
    "task_evidence_submitted",
    "fusion_started",
    "peer_progress_during_fusion",
    "schedule_terminal_visible",
    "scheduled_wake_progress_visible",
    "invalid_tool_turn_settled",
    "same_keeper_recovered",
    "unaffected_peers_progressed",
    "restart_succeeded",
    "context_secret_recalled",
    "memory_write_observed",
    "no_illegal_direct_done",
    "contention_single_owner",
    "contention_loser_continued",
    "reviewer_progress_visible",
    "all_surfaces_observed",
    "correlation_marker_complete",
    "artifact_bundle_complete",
    "same_keeper_eleven_linked_turns",
    "composition_inline_observed",
    "composition_parallel_schedule_observed",
    "composition_sequential_dataflow_observed",
    "composition_async_observed",
    "composition_turn_context_observed",
    "composition_dashboard_browser_observed",
    "poc_execution_proof_observed",
    "poc_review_cites_execution",
    "debate_restatement_faithful",
    "debate_verdict_cites_rebuttal",
    "qa_coverage_execution_observed",
    "qa_coverage_passes_verification",
    "qa_coverage_review_matches_spec",
    "goal_verifier_refutation_observed",
    "goal_verifier_reentry_proven",
    "goal_verifier_dashboard_browser_observed",
    "claim_measurement_executed",
    "claim_verdict_cites_measurement",
}

# Goal verification is an autonomous durable drain, not one synchronous model
# request. A retryable provider failure is re-armed by the runtime's default
# 60-second maintenance pulse. The acceptance budget must therefore cover a
# full first request, that re-arm interval, and a full second request. Keep one
# additional pulse as scheduling/polling margin so a retry observed near the
# request boundary is not turned into a false-negative campaign result.
GOAL_VERIFIER_RETRY_INTERVAL_SEC = 60.0
BROWSER_PROOF_TIMEOUT_FLOOR_SEC = 600.0


# ── RW26: paper-claim reproduction ──────────────────────────────────
# The claim under measurement is Benford's law on the Fibonacci sequence —
# a mathematically proven statement, so the mission needs no external paper
# fixture and stays fully offline. The evaluator computes the expected count
# independently below; the keeper prompts carry only the rule, never the
# answer, exactly like the RW22 qa_cases discipline.
RW26_FIBONACCI_COUNT = 200


def rw26_fibonacci_leading_one_count(n: int) -> int:
    """Number of F(1)..F(n) (F(1)=F(2)=1) whose leading decimal digit is 1."""
    if n < 1:
        raise ValueError("n must be positive")
    count = 0
    a, b = 1, 1
    for _ in range(n):
        if str(a)[0] == "1":
            count += 1
        a, b = b, a + b
    return count


# Deliberately-wrong-input self-check (the RFC's bug-model for a mission
# whose fixture is a derivation rather than a file): the first ten
# Fibonacci numbers are 1,1,2,3,5,8,13,21,34,55 — exactly three lead with
# the digit 1. A drifted implementation fails at import, before any
# campaign run can quote it as an oracle.
if rw26_fibonacci_leading_one_count(10) != 3:
    raise AssertionError("rw26 oracle drifted: F(1..10) must contain 3 leading-1 values")


# An external process sweep on this machine SIGTERMs masc servers every
# 8-40 minutes (issue #31711); a supervised server restarts in well under a
# minute. A refused connection never reached the server, so replaying it is
# safe for mutations too; the -32002 "starting up" JSON-RPC error is the
# same boot window seen after the socket returns.
TRANSPORT_RETRY_INTERVAL_SEC = 10.0
TRANSPORT_RETRY_ATTEMPTS = 30

def goal_verifier_convergence_timeout(request_timeout: float) -> float:
    return (2.0 * request_timeout) + (2.0 * GOAL_VERIFIER_RETRY_INTERVAL_SEC)


def browser_proof_subprocess_timeout(request_timeout: float) -> float:
    # The Node proof's declared Keeper-ready window is 240 seconds. It then
    # verifies three independent dashboard surfaces and owns the failure-state
    # screenshot/console capture. The parent must never terminate it before
    # that inner contract can settle and emit its diagnostic artifacts.
    return max(BROWSER_PROOF_TIMEOUT_FLOOR_SEC, 2.0 * request_timeout)


class AcceptanceError(RuntimeError):
    pass


@dataclasses.dataclass(frozen=True)
class ToolObservation:
    tool: str
    arguments: dict[str, Any]
    response: dict[str, Any]
    text: str
    data: Any


@dataclasses.dataclass
class TurnObservation:
    role: str
    keeper: str
    label: str
    status: str
    started_at: str
    finished_at: str
    started_epoch_seconds: float
    finished_epoch_seconds: float
    duration_seconds: float
    operation_id: str | None
    operation_state: str | None
    operation_started_at: float | None
    operation_completed_at: float | None
    text: str
    error: str | None
    response: dict[str, Any] | None


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def safe_slug(value: str, limit: int = 24) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
    if not slug:
        raise AcceptanceError("run id does not contain a usable slug")
    return slug[:limit].rstrip("-")


def campaign_identity_slug(value: str, limit: int = 16) -> str:
    """Keep a readable prefix without discarding the full run identity."""
    digest = hashlib.sha256(value.encode("utf-8")).hexdigest()[:8]
    prefix_limit = limit - len(digest) - 1
    if prefix_limit < 1:
        raise AcceptanceError("campaign slug limit is too small for identity hash")
    return f"{safe_slug(value, prefix_limit)}-{digest}"


def json_bytes(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True) + "\n").encode()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def source_sha() -> str:
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=REPO_ROOT, text=True
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def keeper_is_live(data: Any) -> bool:
    """A keeper can receive missions when its keepalive loop runs and the
    registry reports a running fiber. These are the fields
    ``masc_keeper_status`` actually emits (``runtime.phase`` /
    ``runtime.fiber_health`` from the keeper registry FSM). The previous
    predicate demanded ``agent.exists``, but ``parse_agent_status`` never
    emits an ``exists`` key and keepers on this build never materialize an
    agents-dir identity file, so no fleet could ever pass bootstrap."""
    if not isinstance(data, dict):
        return False
    runtime = data.get("runtime")
    if not isinstance(runtime, dict):
        return False
    return (
        bool(data.get("keepalive_running"))
        and runtime.get("phase") == "running"
        and runtime.get("fiber_health") == "alive"
    )


def parse_json_maybe(text: str) -> Any:
    try:
        value = json.loads(text)
    except (json.JSONDecodeError, TypeError):
        return text
    if isinstance(value, dict) and value.get("result") is not None:
        return value["result"]
    return value


def parse_json_exact(text: str) -> Any:
    """Decode the tool's exact JSON envelope without unwrapping its result field."""
    try:
        return json.loads(text)
    except (json.JSONDecodeError, TypeError):
        return text


def text_contains(value: Any, needle: str) -> bool:
    return needle.lower() in json.dumps(value, ensure_ascii=False).lower()


def extract_identity(text: str, prefixes: Iterable[str]) -> str:
    prefix_pattern = "|".join(re.escape(prefix) for prefix in prefixes)
    pattern = rf"\b(?:{prefix_pattern})[a-zA-Z0-9_-]+\b"
    match = re.search(pattern, text)
    if not match:
        raise AcceptanceError(
            f"could not extract identity with prefixes {list(prefixes)!r} from tool result"
        )
    return match.group(0)


class EvidenceWriter:
    def __init__(self, output_dir: pathlib.Path) -> None:
        self.output_dir = output_dir
        self._lock = threading.Lock()
        self._counter = 0
        for child in ("raw", "turns", "observations", "keeper-status"):
            (output_dir / child).mkdir(parents=True, exist_ok=False)

    def write_json(self, relative: str, value: Any) -> pathlib.Path:
        path = self.output_dir / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(json_bytes(value))
        return path

    def record_tool(self, label: str, observation: ToolObservation) -> pathlib.Path:
        with self._lock:
            self._counter += 1
            counter = self._counter
        safe_label = safe_slug(label, 48)
        return self.write_json(
            f"raw/{counter:03d}-{safe_label}.json",
            {
                "tool": observation.tool,
                "arguments": observation.arguments,
                "response": observation.response,
                "text": observation.text,
                "data": observation.data,
            },
        )


class McpClient:
    def __init__(self, endpoint: str, token: str, timeout: float) -> None:
        self.endpoint = endpoint
        self.token = token
        self.timeout = timeout
        self.session_id: str | None = None
        self.protocol_version = "2025-11-25"
        self._request_id = 0

    def _next_id(self) -> int:
        self._request_id += 1
        return self._request_id

    def _decode_response(self, body: bytes, request_id: int) -> dict[str, Any]:
        raw = body.decode("utf-8", errors="replace")
        stripped = raw.strip()
        if stripped.startswith("{"):
            value = json.loads(stripped)
            if not isinstance(value, dict):
                raise AcceptanceError("MCP response is not a JSON object")
            return value
        candidates: list[dict[str, Any]] = []
        for line in raw.splitlines():
            if not line.startswith("data:"):
                continue
            payload = line[5:].strip()
            if not payload or payload == "[DONE]":
                continue
            try:
                value = json.loads(payload)
            except json.JSONDecodeError:
                continue
            if isinstance(value, dict):
                candidates.append(value)
        for value in reversed(candidates):
            if value.get("id") == request_id:
                return value
        raise AcceptanceError("MCP SSE response had no matching JSON-RPC payload")

    def request(
        self,
        method: str,
        params: dict[str, Any],
        *,
        _retry_on_stale_session: bool = True,
        _transport_retries: int = TRANSPORT_RETRY_ATTEMPTS,
    ) -> dict[str, Any]:
        request_id = self._next_id()
        payload = json.dumps(
            {
                "jsonrpc": "2.0",
                "id": request_id,
                "method": method,
                "params": params,
            },
            ensure_ascii=False,
        ).encode()
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        }
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        if self.session_id:
            headers["Mcp-Session-Id"] = self.session_id
            headers["Mcp-Protocol-Version"] = self.protocol_version
        request = urllib.request.Request(
            self.endpoint, data=payload, headers=headers, method="POST"
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                body = response.read()
                session_id = response.headers.get("Mcp-Session-Id")
                if session_id:
                    self.session_id = session_id
                protocol_version = response.headers.get("Mcp-Protocol-Version")
                if protocol_version:
                    self.protocol_version = protocol_version
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace")
            if (
                _retry_on_stale_session
                and error.code == 404
                and self.session_id is not None
                and method != "initialize"
            ):
                # RFC-0100 Q3: the server answers a POST that echoes a
                # session id it has no state for with 404 so the client
                # re-handshakes — and it reaps sessions whose grace period
                # (MASC_SESSION_SSE_GRACE_PERIOD_SEC, default 300s) elapses
                # without activity. This runner's primary session sits idle
                # while per-turn sub-clients drive keeper turns, so a long
                # mission phase crosses that window (run
                # e0-collab-20260818-1157 died exactly this way). The 404
                # is raised by the session check before dispatch, so the
                # rejected request never executed and one replay on a fresh
                # session is safe for mutations too.
                self.session_id = None
                self.initialize()
                return self.request(
                    method, params, _retry_on_stale_session=False
                )
            raise AcceptanceError(f"MCP HTTP {error.code}: {detail[:1000]}") from error
        except urllib.error.URLError as error:
            refused = isinstance(getattr(error, "reason", None), ConnectionRefusedError)
            if refused and _transport_retries > 0:
                time.sleep(TRANSPORT_RETRY_INTERVAL_SEC)
                return self.request(
                    method,
                    params,
                    _retry_on_stale_session=_retry_on_stale_session,
                    _transport_retries=_transport_retries - 1,
                )
            raise AcceptanceError(f"MCP transport failed: {error}") from error
        value = self._decode_response(body, request_id)
        if value.get("error") is not None:
            error_value = value["error"]
            starting_up = (
                isinstance(error_value, dict) and error_value.get("code") == -32002
            )
            if starting_up and _transport_retries > 0:
                time.sleep(TRANSPORT_RETRY_INTERVAL_SEC)
                return self.request(
                    method,
                    params,
                    _retry_on_stale_session=_retry_on_stale_session,
                    _transport_retries=_transport_retries - 1,
                )
            raise AcceptanceError(
                f"MCP {method} JSON-RPC error: {json.dumps(error_value, ensure_ascii=False)}"
            )
        return value

    def initialize(self) -> None:
        self.request(
            "initialize",
            {
                "protocolVersion": self.protocol_version,
                "clientInfo": {
                    "name": "keeper-multi-collaboration-acceptance",
                    "version": "1.0",
                },
                "capabilities": {},
            },
        )
        if not self.session_id:
            raise AcceptanceError("MCP initialize did not return Mcp-Session-Id")

    def list_tools(self) -> set[str]:
        names: set[str] = set()
        cursor: str | None = None
        while True:
            params: dict[str, Any] = {}
            if cursor:
                params["cursor"] = cursor
            response = self.request("tools/list", params)
            result = response.get("result") or {}
            for tool in result.get("tools") or []:
                name = tool.get("name")
                if isinstance(name, str):
                    names.add(name)
            cursor = result.get("nextCursor")
            if not cursor:
                return names

    def call_tool(
        self,
        name: str,
        arguments: dict[str, Any],
        *,
        allow_tool_error: bool = False,
    ) -> ToolObservation:
        response = self.request(
            "tools/call", {"name": name, "arguments": arguments}
        )
        result = response.get("result") or {}
        texts = [
            item.get("text", "")
            for item in result.get("content") or []
            if item.get("type") == "text"
        ]
        text = "\n".join(value for value in texts if value)
        data = result.get("structuredContent")
        if data is None:
            data = parse_json_maybe(text)
        if result.get("isError") is True and not allow_tool_error:
            raise AcceptanceError(f"tool {name} returned isError=true: {text[:1200]}")
        return ToolObservation(name, arguments, response, text, data)


def load_catalog(path: pathlib.Path) -> dict[str, Any]:
    try:
        catalog = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise AcceptanceError(f"could not read mission catalog {path}: {error}") from error
    if catalog.get("schema") != "masc.keeper_multi_collaboration_missions.v1":
        raise AcceptanceError("mission catalog schema mismatch")
    missions = catalog.get("missions")
    if not isinstance(missions, list) or len(missions) != 23:
        raise AcceptanceError("mission catalog must contain exactly 23 missions")
    ids = [mission.get("id") for mission in missions]
    if ids != list(EXPECTED_MISSION_IDS):
        raise AcceptanceError(
            "mission ids must be exactly " + ", ".join(EXPECTED_MISSION_IDS)
        )
    roles = catalog.get("roles")
    if not isinstance(roles, list) or set(roles) != EXPECTED_ROLES:
        raise AcceptanceError("catalog must define the exact five collaboration roles")
    if catalog.get("minimum_keeper_count") != len(roles):
        raise AcceptanceError("minimum_keeper_count must equal the five-role fleet")
    required_skill_identities = catalog.get("keeper_required_skill_identities")
    if not isinstance(required_skill_identities, list) or not required_skill_identities:
        raise AcceptanceError("catalog must declare keeper_required_skill_identities")
    required_identity_keys: list[tuple[str, str, str]] = []
    for index, identity in enumerate(required_skill_identities):
        required_identity_keys.append(
            canonical_skill_identity_key(
                identity,
                context=f"keeper_required_skill_identities[{index}]",
            )
        )
    if len(set(required_identity_keys)) != len(required_identity_keys):
        raise AcceptanceError(
            "keeper_required_skill_identities must not contain duplicates"
        )
    approaches = catalog.get("execution_approaches")
    if (
        catalog.get("approaches_apply_to_each_mission") is not True
        or not isinstance(approaches, list)
        or [approach.get("id") for approach in approaches] != ["A", "B", "C"]
    ):
        raise AcceptanceError(
            "catalog must apply the exact A/B/C execution approaches to every mission"
        )
    for approach in approaches:
        for field in ("name", "method"):
            if not isinstance(approach.get(field), str) or not approach[field].strip():
                raise AcceptanceError(f"approach {approach.get('id')} is missing {field}")
        evidence = approach.get("required_evidence")
        if not isinstance(evidence, list) or not evidence or not all(
            isinstance(item, str) and item.strip() for item in evidence
        ):
            raise AcceptanceError(
                f"approach {approach.get('id')} has invalid required_evidence"
            )
    for mission in missions:
        actors = mission.get("actors")
        if not isinstance(actors, list) or not actors or not set(actors) <= EXPECTED_ROLES:
            raise AcceptanceError(f"{mission.get('id')} contains invalid actors")
        for field in ("phase", "name", "user_story"):
            if not isinstance(mission.get(field), str) or not mission[field].strip():
                raise AcceptanceError(f"{mission.get('id')} is missing {field}")
        for field in ("capabilities", "assertions", "evidence"):
            if not isinstance(mission.get(field), list) or not mission[field]:
                raise AcceptanceError(f"{mission.get('id')} is missing {field}")
    assertions = {
        assertion
        for mission in missions
        for assertion in mission.get("assertions") or []
    }
    unknown = assertions - KNOWN_ASSERTIONS
    missing = KNOWN_ASSERTIONS - assertions
    if unknown:
        raise AcceptanceError(f"catalog contains unknown assertions: {sorted(unknown)}")
    if missing:
        raise AcceptanceError(f"catalog does not route assertions: {sorted(missing)}")
    if catalog.get("acceptance_authority") != "real_world_product_outcomes":
        raise AcceptanceError("real-world product outcomes must remain the acceptance authority")
    return catalog


def parse_runtime_by_role(raw: str | None) -> dict[str, str]:
    if raw is None or not raw.strip():
        return {}
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as error:
        raise AcceptanceError(
            f"--runtime-by-role-json is not valid JSON: {error}"
        ) from error
    if not isinstance(value, dict):
        raise AcceptanceError("--runtime-by-role-json must be an object")
    keys = set(value)
    if keys != EXPECTED_ROLES:
        raise AcceptanceError(
            "--runtime-by-role-json must name the exact five roles: "
            f"missing={sorted(EXPECTED_ROLES - keys)} extra={sorted(keys - EXPECTED_ROLES)}"
        )
    invalid = sorted(
        role
        for role, runtime_id in value.items()
        if not isinstance(runtime_id, str) or not runtime_id.strip()
    )
    if invalid:
        raise AcceptanceError(
            f"--runtime-by-role-json has blank/non-string runtime ids: {invalid}"
        )
    return {role: value[role].strip() for role in sorted(EXPECTED_ROLES)}


def validate_runtime_strategy(
    *,
    runtime_id: str | None,
    runtime_by_role: dict[str, str],
    require_heterogeneous: bool,
) -> None:
    if runtime_id and runtime_by_role:
        raise AcceptanceError(
            "--runtime-id and --runtime-by-role-json are mutually exclusive"
        )
    if require_heterogeneous:
        distinct = set(runtime_by_role.values())
        if (
            len(runtime_by_role) != len(EXPECTED_ROLES)
            or len(distinct) != len(EXPECTED_ROLES)
        ):
            raise AcceptanceError(
                "--require-heterogeneous-runtimes needs five distinct runtime ids, "
                f"one per role; observed={len(distinct)}"
            )


def runtime_strategy_receipt(
    *,
    runtime_id: str | None,
    runtime_by_role: dict[str, str],
    require_heterogeneous: bool,
    roles: set[str] = EXPECTED_ROLES,
) -> dict[str, Any]:
    resolved = {
        role: runtime_by_role.get(role, runtime_id) for role in sorted(roles)
    }
    if any(value is None for value in resolved.values()):
        raise AcceptanceError(
            "an exact runtime selection is required before a mutable run"
        )
    exact = {role: str(value) for role, value in resolved.items()}
    distinct_count = len(set(exact.values()))
    return {
        "runtime_strategy": (
            "heterogeneous_required"
            if require_heterogeneous
            else "role_map"
            if runtime_by_role
            else "shared_runtime"
        ),
        "runtime_by_role": exact,
        "distinct_runtime_count": distinct_count,
    }


def collect_runtime_serving_evidence(
    *,
    base_path: pathlib.Path,
    keepers_by_role: dict[str, str],
    expected_runtime_by_role: dict[str, str],
    manifest_line_cursors_by_keeper: dict[str, dict[str, int]],
) -> dict[str, Any]:
    """Read durable runtime receipts and prove each configured role actually served.

    A configured runtime ID is not execution evidence.  Only a terminal
    ``receipt_appended`` row for the requested runtime, with a completed
    no-fallback outcome, proves that role reached the provider and returned.
    """
    role_evidence: dict[str, Any] = {}
    parse_errors: list[str] = []
    observed_runtime_ids: set[str] = set()

    for role in sorted(keepers_by_role):
        keeper = keepers_by_role[role]
        expected_runtime = expected_runtime_by_role[role]
        manifest_root = (
            base_path / ".masc" / "keepers" / keeper / "runtime-manifests"
        )
        exact_receipts: list[dict[str, Any]] = []
        fallback_receipts: list[dict[str, Any]] = []
        current_run_row_count = 0
        manifest_files = sorted(manifest_root.glob("*.jsonl"))
        if keeper not in manifest_line_cursors_by_keeper:
            parse_errors.append(f"{keeper}:missing campaign manifest cursor")
        keeper_cursors = manifest_line_cursors_by_keeper.get(keeper, {})
        for manifest_path in manifest_files:
            relative_path = str(manifest_path.relative_to(base_path))
            baseline_line_count = keeper_cursors.get(relative_path, 0)
            observed_line_count = 0
            with manifest_path.open(encoding="utf-8") as handle:
                for line_number, raw_line in enumerate(handle, 1):
                    observed_line_count = line_number
                    if line_number <= baseline_line_count:
                        continue
                    stripped = raw_line.strip()
                    if not stripped:
                        continue
                    try:
                        row = json.loads(stripped)
                    except json.JSONDecodeError as error:
                        parse_errors.append(
                            f"{relative_path}:{line_number}:{error.msg}"
                        )
                        continue
                    if not isinstance(row, dict) or row.get("event") != "receipt_appended":
                        continue
                    current_run_row_count += 1
                    decision = row.get("decision")
                    if not isinstance(decision, dict):
                        parse_errors.append(
                            f"{relative_path}:{line_number}:missing decision object"
                        )
                        continue
                    schema_errors: list[str] = []
                    if row.get("schema_version") != 1:
                        schema_errors.append("schema_version must be 1")
                    if row.get("keeper_name") != keeper:
                        schema_errors.append("keeper_name mismatch")
                    if not isinstance(row.get("trace_id"), str) or not row.get(
                        "trace_id"
                    ):
                        schema_errors.append("trace_id must be non-empty")
                    keeper_turn_id = row.get("keeper_turn_id")
                    if (
                        not isinstance(keeper_turn_id, int)
                        or isinstance(keeper_turn_id, bool)
                        or keeper_turn_id < 1
                    ):
                        schema_errors.append("keeper_turn_id must be a positive int")
                    if row.get("runtime_id") != decision.get("runtime_id"):
                        schema_errors.append(
                            "top-level runtime_id does not match decision"
                        )
                    if schema_errors:
                        parse_errors.append(
                            f"{relative_path}:{line_number}:"
                            + "; ".join(schema_errors)
                        )
                        continue
                    receipt = {
                        "path": relative_path,
                        "line": line_number,
                        "ts": row.get("ts"),
                        "trace_id": row.get("trace_id"),
                        "keeper_turn_id": row.get("keeper_turn_id"),
                        "runtime_id": decision.get("runtime_id"),
                        "runtime_attempt_count": decision.get("runtime_attempt_count"),
                        "runtime_fallback_applied": decision.get(
                            "runtime_fallback_applied"
                        ),
                        "runtime_outcome": decision.get("runtime_outcome"),
                        "outcome": decision.get("outcome"),
                        "status": row.get("status"),
                    }
                    is_exact_success = (
                        row.get("status") == "ok"
                        and decision.get("outcome") == "ok"
                        and decision.get("runtime_outcome") == "completed"
                        and decision.get("runtime_id") == expected_runtime
                        and decision.get("runtime_fallback_applied") is False
                    )
                    if is_exact_success:
                        exact_receipts.append(receipt)
                        observed_runtime_ids.add(expected_runtime)
                    elif (
                        decision.get("runtime_fallback_applied") is True
                        or decision.get("runtime_id") != expected_runtime
                    ):
                        fallback_receipts.append(receipt)
            if observed_line_count < baseline_line_count:
                parse_errors.append(
                    f"{relative_path}:manifest shortened after campaign cursor "
                    f"({observed_line_count} < {baseline_line_count})"
                )

        role_evidence[role] = {
            "keeper": keeper,
            "expected_runtime_id": expected_runtime,
            "manifest_file_count": len(manifest_files),
            "baseline_manifest_line_count": sum(keeper_cursors.values()),
            "current_run_receipt_row_count": current_run_row_count,
            "exact_success_count": len(exact_receipts),
            "fallback_receipt_count": len(fallback_receipts),
            "exact_success_receipts": exact_receipts,
            "fallback_receipts": fallback_receipts,
            "served": bool(exact_receipts),
        }

    all_roles_served = all(
        evidence["served"] for evidence in role_evidence.values()
    )
    return {
        "schema": "masc.keeper_runtime_serving_evidence.v1",
        "status": "passed" if all_roles_served and not parse_errors else "failed",
        "all_roles_served": all_roles_served,
        "role_count": len(role_evidence),
        "served_role_count": sum(
            evidence["served"] for evidence in role_evidence.values()
        ),
        "distinct_served_runtime_count": len(observed_runtime_ids),
        "observed_runtime_ids": sorted(observed_runtime_ids),
        "parse_errors": parse_errors,
        "roles": role_evidence,
    }


def capture_runtime_manifest_line_cursors(
    *, base_path: pathlib.Path, keepers_by_role: dict[str, str]
) -> dict[str, dict[str, int]]:
    """Snapshot manifest append positions before the campaign mutates Keepers."""
    cursors: dict[str, dict[str, int]] = {}
    for keeper in sorted(set(keepers_by_role.values())):
        manifest_root = (
            base_path / ".masc" / "keepers" / keeper / "runtime-manifests"
        )
        keeper_cursors: dict[str, int] = {}
        for manifest_path in sorted(manifest_root.glob("*.jsonl")):
            relative_path = str(manifest_path.relative_to(base_path))
            with manifest_path.open(encoding="utf-8") as handle:
                keeper_cursors[relative_path] = sum(1 for _ in handle)
        cursors[keeper] = keeper_cursors
    return cursors


def default_health_url(mcp_url: str) -> str:
    parsed = urllib.parse.urlsplit(mcp_url)
    return urllib.parse.urlunsplit(
        (parsed.scheme, parsed.netloc, "/health", "full=1", "")
    )


def default_skills_url(mcp_url: str) -> str:
    parsed = urllib.parse.urlsplit(mcp_url)
    return urllib.parse.urlunsplit(
        (parsed.scheme, parsed.netloc, "/api/v1/skills", "", "")
    )


def read_health(url: str, token: str, timeout: float) -> dict[str, Any]:
    headers = {"Accept": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, headers=headers, method="GET")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            value = json.loads(response.read().decode("utf-8"))
    except (urllib.error.URLError, json.JSONDecodeError) as error:
        raise AcceptanceError(f"health read failed: {error}") from error
    if not isinstance(value, dict):
        raise AcceptanceError("health response is not a JSON object")
    return value


def health_base_path(health: dict[str, Any]) -> str:
    paths = health.get("paths") or {}
    value = paths.get("effective_base_path")
    return value if isinstance(value, str) else ""


def health_masc_root(health: dict[str, Any]) -> str:
    paths = health.get("paths") or {}
    value = paths.get("effective_masc_root")
    return value if isinstance(value, str) else ""


def health_binary_commit(health: dict[str, Any]) -> str:
    build = health.get("build") or {}
    value = build.get("binary_commit")
    return value.strip() if isinstance(value, str) else ""


def read_skills(url: str, token: str, timeout: float) -> dict[str, Any]:
    headers = {"Accept": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, headers=headers, method="GET")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            value = json.loads(response.read().decode("utf-8"))
    except (urllib.error.URLError, json.JSONDecodeError) as error:
        raise AcceptanceError(f"skills snapshot read failed: {error}") from error
    if not isinstance(value, dict):
        raise AcceptanceError("skills snapshot response is not a JSON object")
    return value


def canonical_skill_identity_key(value: Any, *, context: str) -> tuple[str, str, str]:
    if not isinstance(value, dict):
        raise AcceptanceError(f"{context} must be an object")
    expected_fields = {"source_id", "package_id", "name"}
    if set(value) != expected_fields:
        raise AcceptanceError(
            f"{context} must contain exactly {sorted(expected_fields)}"
        )
    fields = tuple(value[field] for field in ("source_id", "package_id", "name"))
    if not all(isinstance(field, str) and field for field in fields):
        raise AcceptanceError(f"{context} fields must be non-empty strings")
    return fields


def canonical_skill_reference_key(
    value: Any, *, context: str
) -> tuple[str, str, str, str]:
    if not isinstance(value, dict):
        raise AcceptanceError(f"{context} must be an object")
    if set(value) != {"identity", "content_revision"}:
        raise AcceptanceError(
            f"{context} must contain exactly identity and content_revision"
        )
    identity_key = canonical_skill_identity_key(
        value.get("identity"), context=f"{context}.identity"
    )
    content_revision = value.get("content_revision")
    if not isinstance(content_revision, str) or not content_revision:
        raise AcceptanceError(f"{context}.content_revision must be a non-empty string")
    return (*identity_key, content_revision)


def skill_identity_json(key: tuple[str, str, str]) -> dict[str, str]:
    source_id, package_id, name = key
    return {
        "source_id": source_id,
        "package_id": package_id,
        "name": name,
    }


def skill_reference_json(key: tuple[str, str, str, str]) -> dict[str, Any]:
    source_id, package_id, name, content_revision = key
    return {
        "identity": skill_identity_json((source_id, package_id, name)),
        "content_revision": content_revision,
    }


def composition_surface_status(
    *,
    skills: dict[str, Any],
    required_skill_identities: Iterable[dict[str, Any]],
    skills_url: str,
) -> dict[str, Any]:
    """Resolve campaign identities once, then compare exact SkillReferences.

    The mission catalog owns the stable identities that this campaign needs.
    The published snapshot pins each identity to its content revision. Surface
    availability is then decided only by the canonical four-field reference;
    tool names and name prefixes are display data, not acceptance authority.
    """
    required_identity_keys = sorted(
        canonical_skill_identity_key(
            identity, context=f"required_skill_identities[{index}]"
        )
        for index, identity in enumerate(required_skill_identities)
    )
    snapshot = skills.get("snapshot")
    snapshot_rows = snapshot.get("skills") if isinstance(snapshot, dict) else None
    published_rows = snapshot_rows if isinstance(snapshot_rows, list) else []
    published_by_identity: dict[tuple[str, str, str], tuple[str, str, str, str]] = {}
    ambiguous_published_identities: set[tuple[str, str, str]] = set()
    invalid_published_references: list[str] = []
    for index, row in enumerate(published_rows):
        if not isinstance(row, dict):
            invalid_published_references.append(
                f"snapshot.skills[{index}] is not an object"
            )
            continue
        reference = {
            "identity": row.get("identity"),
            "content_revision": row.get("content_revision"),
        }
        try:
            reference_key = canonical_skill_reference_key(
                reference, context=f"snapshot.skills[{index}]"
            )
        except AcceptanceError as error:
            invalid_published_references.append(str(error))
            continue
        identity_key = reference_key[:3]
        if identity_key in ambiguous_published_identities:
            continue
        previous = published_by_identity.get(identity_key)
        if previous is not None and previous != reference_key:
            invalid_published_references.append(
                "snapshot publishes more than one revision for "
                + json.dumps(skill_identity_json(identity_key), sort_keys=True)
            )
            published_by_identity.pop(identity_key)
            ambiguous_published_identities.add(identity_key)
            continue
        published_by_identity[identity_key] = reference_key

    required_reference_keys = {
        published_by_identity[identity]
        for identity in required_identity_keys
        if identity in published_by_identity
    }
    unresolved_identity_keys = sorted(
        set(required_identity_keys) - set(published_by_identity)
    )
    surfaces = skills.get("surfaces")
    surface_rows = surfaces if isinstance(surfaces, list) else []
    installed_reference_keys: set[tuple[str, str, str, str]] = set()
    unavailable_by_reference: dict[tuple[str, str, str, str], dict[str, Any]] = {}
    invalid_surface_references: list[str] = []
    for index, row in enumerate(surface_rows):
        if not isinstance(row, dict):
            invalid_surface_references.append(f"surfaces[{index}] is not an object")
            continue
        try:
            reference_key = canonical_skill_reference_key(
                row.get("reference"), context=f"surfaces[{index}].reference"
            )
        except AcceptanceError as error:
            invalid_surface_references.append(str(error))
            continue
        if row.get("kind") == "composition":
            installed_reference_keys.add(reference_key)
        elif row.get("kind") == "unavailable":
            unavailable_by_reference[reference_key] = {
                "reference": skill_reference_json(reference_key),
                "error": row.get("error"),
            }

    required_unavailable_keys = sorted(
        required_reference_keys & set(unavailable_by_reference)
    )
    missing_reference_keys = sorted(required_reference_keys - installed_reference_keys)
    snapshot_state = skills.get("state")
    if snapshot_state != "ready":
        status = "snapshot_not_ready"
    elif unresolved_identity_keys:
        status = "required_identity_not_published"
    elif required_unavailable_keys:
        status = "surface_unavailable"
    elif missing_reference_keys:
        status = "missing_surfaces"
    else:
        status = "ok"
    return {
        "status": status,
        "skills_url": skills_url,
        "snapshot_state": snapshot_state,
        "required_skill_identities": [
            skill_identity_json(key) for key in required_identity_keys
        ],
        "required_skill_references": [
            skill_reference_json(key) for key in sorted(required_reference_keys)
        ],
        "installed_skill_references": [
            skill_reference_json(key) for key in sorted(installed_reference_keys)
        ],
        "missing_skill_references": [
            skill_reference_json(key) for key in missing_reference_keys
        ],
        "unresolved_required_skill_identities": [
            skill_identity_json(key) for key in unresolved_identity_keys
        ],
        "unavailable_surfaces": [
            unavailable_by_reference[key] for key in sorted(unavailable_by_reference)
        ],
        "required_unavailable_surfaces": [
            unavailable_by_reference[key] for key in required_unavailable_keys
        ],
        "invalid_published_references": invalid_published_references,
        "invalid_surface_references": invalid_surface_references,
    }


def preflight(
    *,
    catalog: dict[str, Any],
    mcp_url: str,
    health_url: str,
    token: str,
    timeout: float,
    expected_base_path: str | None,
    expected_source_sha: str | None,
) -> tuple[McpClient, dict[str, Any], dict[str, Any]]:
    health = read_health(health_url, token, timeout)
    effective_base_path = health_base_path(health)
    if expected_base_path is not None and effective_base_path != expected_base_path:
        raise AcceptanceError(
            "health base-path mismatch: "
            f"expected={expected_base_path!r} actual={effective_base_path!r}"
        )
    binary_commit = health_binary_commit(health)
    runner_commit = source_sha()
    if expected_source_sha is not None:
        if binary_commit != expected_source_sha:
            raise AcceptanceError(
                "health binary-commit mismatch: "
                f"expected={expected_source_sha!r} actual={binary_commit!r}"
            )
        if runner_commit != expected_source_sha:
            raise AcceptanceError(
                "runner checkout mismatch: "
                f"expected={expected_source_sha!r} actual={runner_commit!r}"
            )
    client = McpClient(mcp_url, token, timeout)
    client.initialize()
    available = client.list_tools()
    required = set(catalog["operator_required_tools"])
    missing = sorted(required - available)
    skills_url = default_skills_url(mcp_url)
    skills = read_skills(skills_url, token, timeout)
    composition_surfaces = composition_surface_status(
        skills=skills,
        required_skill_identities=catalog["keeper_required_skill_identities"],
        skills_url=skills_url,
    )
    result = {
        "status": (
            "passed"
            if not missing and composition_surfaces["status"] == "ok"
            else "failed"
        ),
        "checked_at": utc_now(),
        "mcp_url": mcp_url,
        "health_url": health_url,
        "effective_base_path": effective_base_path,
        "effective_masc_root": health_masc_root(health),
        "runtime_binary_commit": binary_commit,
        "runner_source_sha": runner_commit,
        "operator_required_tool_count": len(required),
        "available_tool_count": len(available),
        "missing_operator_tools": missing,
        "keeper_required_tools": catalog["keeper_required_tools"],
        "composition_surfaces": composition_surfaces,
    }
    if missing:
        raise AcceptanceError(f"deployed runtime is missing operator tools: {missing}")
    if composition_surfaces["status"] != "ok":
        raise AcceptanceError(
            "composition surfaces are not ready for this campaign: "
            f"status={composition_surfaces['status']} "
            f"missing={composition_surfaces.get('missing_skill_references')} "
            "required_unavailable="
            f"{composition_surfaces.get('required_unavailable_surfaces')} "
            "unresolved="
            f"{composition_surfaces.get('unresolved_required_skill_identities')} — "
            f"inspect {composition_surfaces['skills_url']}"
        )
    return client, health, result


class MissionRun:
    def __init__(
        self,
        *,
        catalog: dict[str, Any],
        client: McpClient,
        writer: EvidenceWriter,
        endpoint: str,
        token: str,
        timeout: float,
        run_id: str,
        runtime_id: str | None,
        runtime_by_role: dict[str, str],
        require_heterogeneous_runtimes: bool,
        token_file: pathlib.Path,
        browser_proof_script: pathlib.Path,
        expected_base_path: str,
    ) -> None:
        self.catalog = catalog
        self.client = client
        self.writer = writer
        self.endpoint = endpoint
        self.token = token
        self.timeout = timeout
        self.run_id = run_id
        self.slug = campaign_identity_slug(run_id, 16)
        self.marker = f"keeper-collab-{self.slug}"
        # RW20/RW21 tokens. Deterministic per run so evaluators match them
        # exactly; the debate tokens are handed only to their originator's
        # prompt, so a responder can produce them only by reading the Board.
        self.poc_output_token = f"POC_OUTPUT={self.marker}-executed"
        self.debate_claim_token = f"{self.marker}-position-A"
        self.debate_rebuttal_token = f"{self.marker}-counter-B"
        # RW22 tokens. The declared scope is a fixed set of cases; the
        # tester never receives them, so the only way its report can name
        # all three is to have actually run the artifact.
        # Each case is a distinct transform over its own input, and every
        # result is emitted as "<case>=<value>". The prefix keeps a short
        # result (the length case is a two-digit number) from matching by
        # accident anywhere on the Board.
        # RW26: the evaluator's independent expectation. The keeper prompts
        # state only the rule (first N Fibonacci numbers, count the ones whose
        # decimal form starts with 1); this exact integer never appears in any
        # prompt, so a matching Board claim can only come from a real run.
        self.claim_fib_count = RW26_FIBONACCI_COUNT
        self.claim_expected = rw26_fibonacci_leading_one_count(self.claim_fib_count)
        qa_inputs = tuple(f"{self.marker}-case-{index}" for index in (1, 2, 3))
        self.qa_cases = (
            ("upper", qa_inputs[0], f"upper={qa_inputs[0].upper()}"),
            ("length", qa_inputs[1], f"length={len(qa_inputs[1])}"),
            ("reverse", qa_inputs[2], f"reverse={qa_inputs[2][::-1]}"),
        )
        self.runtime_id = runtime_id
        self.runtime_by_role = runtime_by_role
        self.require_heterogeneous_runtimes = require_heterogeneous_runtimes
        self.token_file = token_file
        self.browser_proof_script = browser_proof_script
        self.expected_base_path = expected_base_path
        self.secret = f"memory-{uuid.uuid4().hex[:12]}"
        self.goal_id = f"goal-{self.marker}"
        self.verifier_goal_id = f"goal-{self.marker}-verifier"
        self.verifier_artifact = f"artifacts/{self.marker}-goal-proof.txt"
        self.verifier_success_token = f"GOAL_PROOF_PASS={self.marker}"
        self.schedule_id = f"schedule-{self.marker}"
        self.roles = {
            "coordinator": f"rw-{self.slug}-coord",
            "builder-a": f"rw-{self.slug}-build-a",
            "builder-b": f"rw-{self.slug}-build-b",
            "reviewer": f"rw-{self.slug}-review",
            "researcher": f"rw-{self.slug}-research",
        }
        self.runtime_manifest_line_cursors = capture_runtime_manifest_line_cursors(
            base_path=pathlib.Path(self.expected_base_path),
            keepers_by_role=self.roles,
        )
        self.task_ids: dict[str, str] = {}
        self.verifier_task_id = ""
        self.task_create_receipts: dict[str, ToolObservation] = {}
        self.turns: dict[str, TurnObservation] = {}
        self.statuses: dict[str, Any] = {}
        self.observations: dict[str, ToolObservation] = {}
        self.tool_call_rows: dict[str, list[dict[str, Any]]] = {}
        self.browser_proof: dict[str, Any] = {}
        self.goal_verifier_browser_proof: dict[str, Any] = {}
        self.goal_verifier_evidence: dict[str, Any] = {}
        self.runtime_serving_evidence: dict[str, Any] = {}

    def runtime_for_role(self, role: str) -> str | None:
        return self.runtime_by_role.get(role, self.runtime_id)

    def call(self, label: str, tool: str, arguments: dict[str, Any]) -> ToolObservation:
        observation = self.client.call_tool(tool, arguments)
        self.writer.record_tool(label, observation)
        return observation

    def new_client(self) -> McpClient:
        client = McpClient(self.endpoint, self.token, self.timeout)
        client.initialize()
        return client

    def dashboard_get(self, path: str) -> dict[str, Any]:
        parsed = urllib.parse.urlparse(self.endpoint)
        url = urllib.parse.urlunparse(
            (parsed.scheme, parsed.netloc, path, "", "", "")
        )
        headers = {"Accept": "application/json"}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        request = urllib.request.Request(url, headers=headers, method="GET")
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                value = json.loads(response.read().decode("utf-8"))
        except (urllib.error.HTTPError, urllib.error.URLError, json.JSONDecodeError) as error:
            raise AcceptanceError(f"Dashboard GET {path} failed: {error}") from error
        if not isinstance(value, dict):
            raise AcceptanceError(f"Dashboard GET {path} returned a non-object payload")
        return value

    def find_goal(self, value: Any, goal_id: str) -> dict[str, Any] | None:
        if isinstance(value, dict):
            if value.get("id") == goal_id or value.get("goal_id") == goal_id:
                if "phase" in value and "verification" in value:
                    return value
            for nested in value.values():
                found = self.find_goal(nested, goal_id)
                if found is not None:
                    return found
        elif isinstance(value, list):
            for nested in value:
                found = self.find_goal(nested, goal_id)
                if found is not None:
                    return found
        return None

    def read_goal(self, goal_id: str, label: str) -> dict[str, Any]:
        observation = self.call(label, "masc_goal_list", {})
        goal = self.find_goal(observation.data, goal_id)
        if goal is None:
            raise AcceptanceError(f"goal list did not contain {goal_id}")
        return goal

    def wait_for_goal_state(
        self,
        *,
        phase: str,
        completion_state: str | None = None,
        timeout: float | None = None,
    ) -> dict[str, Any]:
        if timeout is None:
            timeout = goal_verifier_convergence_timeout(self.timeout)
        deadline = time.monotonic() + timeout
        attempt = 0
        last: dict[str, Any] | None = None
        while time.monotonic() < deadline:
            attempt += 1
            last = self.read_goal(
                self.verifier_goal_id,
                f"goal-verifier-poll-{phase}-{attempt}",
            )
            verification = last.get("verification")
            completion = (
                verification.get("completion")
                if isinstance(verification, dict)
                else None
            )
            if (
                last.get("phase") == phase
                and (
                    completion_state is None
                    or (
                        isinstance(completion, dict)
                        and completion.get("state") == completion_state
                    )
                )
            ):
                return last
            time.sleep(2.0)
        raise AcceptanceError(
            "Goal verifier state did not converge: "
            f"expected phase={phase} "
            f"completion={completion_state}, last={json.dumps(last, ensure_ascii=False)}"
        )

    def wait_for_verifier_task_verdict(
        self, to_status: str, timeout: float = 300.0
    ) -> dict[str, Any]:
        deadline = time.monotonic() + timeout
        attempt = 0
        last: Any = None
        while time.monotonic() < deadline:
            attempt += 1
            history = self.call(
                f"goal-verifier-task-history-{to_status}-{attempt}",
                "masc_task_history",
                {"task_id": self.verifier_task_id, "limit": 100},
            )
            last = history.data
            entries = last if isinstance(last, list) else []
            for entry in entries:
                if (
                    isinstance(entry, dict)
                    and entry.get("type") == "task_completion_verdict"
                    and entry.get("to_status") == to_status
                    and entry.get("verification_id")
                ):
                    return entry
            time.sleep(2.0)
        raise AcceptanceError(
            f"verifier Task has no completion verdict to {to_status}: "
            f"last={json.dumps(last, ensure_ascii=False)}"
        )

    def role_instructions(self, role: str) -> str:
        shared = (
            f"Real-world acceptance mission {self.marker}. "
            "실제 MASC 도구와 durable state만 사용하세요. 결과를 말로 주장하지 말고 "
            "Task, Board comment, IDE annotation, Memory 중 요청된 surface에 남기세요. "
            "다른 Keeper의 playground 파일을 직접 읽지 마세요. 도구 하나가 실패해도 "
            "보안/중복효과 위험이 아닌 한 다음 안전한 작업을 계속하세요."
        )
        role_text = {
            "coordinator": "Goal과 Board 협업을 조율하고 각 Keeper의 결과를 합치세요.",
            "builder-a": "Task를 claim하고 파일, IDE annotation, evidence를 남기세요.",
            "builder-b": "Task를 claim하고 실패 뒤 복구 및 동시 claim 규칙을 지키세요.",
            "reviewer": "Board thread와 Task 상태를 읽고 독립적인 검토 comment를 남기세요.",
            "researcher": "Fusion을 비동기로 시작하고 기다리는 동안 독립 Task를 진행하세요.",
        }[role]
        return f"{shared}\n역할: {role}. {role_text}"

    def create_fleet(self) -> None:
        for role, keeper in self.roles.items():
            arguments: dict[str, Any] = {
                "name": keeper,
                "instructions": self.role_instructions(role),
                "mention_targets": [keeper, role],
                "proactive_enabled": False,
                "autoboot_enabled": True,
                # masc_keeper_up refuses a keeper with no sandbox_profile
                # ("sandbox_profile is required (allowed: local, docker,
                # microvm, remote_ssh)"). The campaign runs against an isolated
                # base path and writes only inside its own playground, so the
                # local profile is the one that matches what the missions do;
                # it is also what MASC_EXEC_ALLOW_LOCAL_PLAYGROUND=1 admits on
                # the campaign server. Without this the fleet never boots and
                # the run aborts on the first keeper.
                "sandbox_profile": "local",
            }
            runtime_id = self.runtime_for_role(role)
            if runtime_id:
                arguments["runtime_id"] = runtime_id
            self.call(f"keeper-up-{role}", "masc_keeper_up", arguments)

    def wait_for_fleet(self, timeout: float = 90.0) -> None:
        deadline = time.monotonic() + timeout
        pending = set(self.roles)
        while pending and time.monotonic() < deadline:
            for role in list(pending):
                try:
                    status = self.call(
                        f"keeper-status-bootstrap-{role}",
                        "masc_keeper_status",
                        {
                            "name": self.roles[role],
                            "fast": True,
                            "include_context": False,
                            "include_metrics_overview": False,
                            "include_history_tail": False,
                        },
                    )
                except AcceptanceError:
                    continue
                data = status.data
                if keeper_is_live(data):
                    self.statuses[role] = data
                    pending.remove(role)
            if pending:
                time.sleep(1.0)
        if pending:
            raise AcceptanceError(f"keepers did not become live: {sorted(pending)}")

    def setup_product_state(self) -> str:
        self.call(
            "goal-upsert",
            "masc_goal_upsert",
            {
                "id": self.goal_id,
                "title": f"Multi-Keeper real-world mission {self.marker}",
                "metric": "correlated product outcomes",
                "target_value": f"{len(self.catalog['missions'])}/{len(self.catalog['missions'])} missions",
                "priority": 1,
            },
        )
        task_specs = {
            "builder-a": "Build the first durable collaboration artifact",
            "builder-b": "Build the second durable collaboration artifact",
            "researcher": "Run Fusion and record an advisory collaboration result",
            "reviewer": "Review the shared Board thread and task evidence",
            "contention": "Resolve a single-owner concurrent claim",
            "fallback": "Continue useful work after losing a concurrent claim",
            "qa-implement": "Implement the declared coverage cases",
            "qa-test": "Run every declared case and report the outputs",
        }
        for key, title in task_specs.items():
            observation = self.call(
                f"task-create-{key}",
                "masc_add_task",
                {
                    "title": f"[{self.marker}] {title}",
                    "description": (
                        f"Mission {self.marker}. Produce a durable product result, "
                        "comment on the shared Board thread, and preserve exact task identity."
                    ),
                    "priority": 1 if key == "contention" else 2,
                    "goal_id": self.goal_id,
                },
            )
            self.task_ids[key] = extract_identity(observation.text, ["task-"])
            # The server's creation receipt echoes the persisted task with its
            # goal_id — the durable evidence of goal linkage. The Quest Board
            # text projection consumed at observation time does not render
            # goal links at all, so judging linkage from it fails every run
            # even though the linkage is real (masc#28976, run
            # e0-r4-20260818).
            self.task_create_receipts[key] = observation

        mentions = " ".join(f"@{keeper}" for keeper in self.roles.values())
        board = self.call(
            "board-kickoff",
            "masc_board_post",
            {
                "title": f"[{self.marker}] collaboration mission",
                "body": (
                    f"mission={self.marker} goal={self.goal_id}\n"
                    f"Five Keeper handoff thread. {mentions}"
                ),
                "author": "keeper-collaboration-harness",
                "visibility": "internal",
                "post_kind": "automation",
                "meta": {"mission_id": self.marker, "goal_id": self.goal_id},
            },
        )
        post_id = extract_identity(board.text, ["p-"])

        due_at = time.time() + 25.0
        self.call(
            "schedule-create",
            "masc_schedule_create",
            {
                "schedule_id": self.schedule_id,
                "due_at_unix": due_at,
                "keeper_name": self.roles["coordinator"],
                "title": f"Scheduled collaboration checkpoint {self.marker}",
                "message": (
                    f"Scheduled source {self.marker}: inspect Goal {self.goal_id} and "
                    f"comment SCHEDULE_WAKE_OK on Board post {post_id}."
                ),
                "urgency": "normal",
                "source": "operator_request",
                "requested_by_id": "keeper-collaboration-harness",
                "scheduled_by_id": "keeper-collaboration-harness",
            },
        )
        return post_id

    def run_turn(self, role: str, label: str, prompt: str) -> TurnObservation:
        started_at = utc_now()
        submitted_epoch_seconds = time.time()
        start = time.monotonic()
        response: dict[str, Any] | None = None
        text = ""
        error: str | None = None
        status = "passed"
        operation_id: str | None = None
        operation_state: str | None = None
        operation_started_at: float | None = None
        operation_completed_at: float | None = None
        try:
            client = self.new_client()
            submission = client.call_tool(
                "masc_keeper_msg",
                {"name": self.roles[role], "message": prompt},
            )
            self.writer.record_tool(f"turn-submit-{label}", submission)
            if not isinstance(submission.data, dict):
                raise AcceptanceError(
                    f"masc_keeper_msg did not return structured operation data: {submission.text[:500]}"
                )
            raw_operation_id = submission.data.get("operation_id")
            if not isinstance(raw_operation_id, str) or not raw_operation_id:
                raise AcceptanceError("masc_keeper_msg did not return operation_id")
            operation_id = raw_operation_id
            target = {"kind": "keeper", "name": self.roles[role]}
            deadline = time.monotonic() + self.timeout
            last_recorded_state: str | None = None
            while time.monotonic() < deadline:
                terminal = client.call_tool(
                    "masc_keeper_delegate_status",
                    {"target": target, "operation_id": operation_id},
                )
                if not isinstance(terminal.data, dict):
                    raise AcceptanceError(
                        "masc_keeper_delegate_status did not return structured operation data"
                    )
                raw_state = terminal.data.get("state")
                operation_state = raw_state if isinstance(raw_state, str) else None
                if operation_state != last_recorded_state:
                    self.writer.record_tool(
                        f"turn-state-{label}-{operation_state or 'unknown'}", terminal
                    )
                    last_recorded_state = operation_state
                raw_started_at = terminal.data.get("started_at")
                if isinstance(raw_started_at, (int, float)):
                    operation_started_at = float(raw_started_at)
                raw_completed_at = terminal.data.get("completed_at")
                if isinstance(raw_completed_at, (int, float)):
                    operation_completed_at = float(raw_completed_at)
                if operation_state in {"Succeeded", "Failed", "Cancelled"}:
                    response = terminal.response
                    text = terminal.text
                    if operation_state != "Succeeded":
                        status = "failed"
                        failure_detail = terminal.data.get("failure_detail")
                        error = (
                            str(failure_detail)
                            if failure_detail is not None
                            else f"operation settled as {operation_state}"
                        )
                    break
                time.sleep(1.0)
            else:
                raise AcceptanceError(
                    f"Keeper operation {operation_id} did not settle within {self.timeout}s"
                )
        except Exception as exception:  # Evidence must survive a failed turn.
            status = "failed"
            error = str(exception)
        finished_epoch_seconds = operation_completed_at or time.time()
        started_epoch_seconds = operation_started_at or submitted_epoch_seconds
        turn = TurnObservation(
            role=role,
            keeper=self.roles[role],
            label=label,
            status=status,
            started_at=started_at,
            finished_at=utc_now(),
            started_epoch_seconds=started_epoch_seconds,
            finished_epoch_seconds=finished_epoch_seconds,
            duration_seconds=round(time.monotonic() - start, 3),
            operation_id=operation_id,
            operation_state=operation_state,
            operation_started_at=operation_started_at,
            operation_completed_at=operation_completed_at,
            text=text,
            error=error,
            response=response,
        )
        self.turns[label] = turn
        self.writer.write_json(f"turns/{label}.json", dataclasses.asdict(turn))
        return turn

    def run_parallel_wave(self, post_id: str) -> None:
        composition_instruction = (
            "먼저 keeper_compose_mission-snapshot을 정확히 한 번 호출하고 그 typed 결과를 확인하세요. "
        )
        prompts = {
            "coordinator": (
                composition_instruction
                + f"Mission {self.marker}. Board post {post_id}, Goal {self.goal_id}, Schedule "
                f"{self.schedule_id}를 각각 실제 도구로 읽으세요. mission marker를 가진 별도 Board "
                "coordination summary post도 하나 생성하세요. "
                f"keeper_memory_write로 continuity secret {self.secret}를 durable memory에 기록한 뒤, "
                f"post {post_id}에 COORDINATOR_READY와 secret을 포함한 comment를 남기세요. "
                "다른 Keeper 작업을 기다리며 polling하지 마세요."
            ),
            "builder-a": (
                composition_instruction
                + f"Mission {self.marker}. exact Task {self.task_ids['builder-a']}를 claim하세요. "
                f"Write(tool_write_file)로 playground의 artifacts/{self.marker}-builder-a.md에 "
                "구체적인 구현 결과를 실제로 쓰고, "
                f"keeper_ide_annotate로 그 파일 1행을 Task {self.task_ids['builder-a']}와 Goal "
                f"{self.goal_id}에 연결하세요. keeper_task_done으로 artifact evidence를 제출한 뒤 "
                f"Board post {post_id}에 BUILDER_A_DONE comment를 남기세요."
            ),
            "builder-b": (
                composition_instruction
                + f"Mission {self.marker}. exact Task {self.task_ids['builder-b']}를 claim하세요. "
                f"Write(tool_write_file)로 playground의 artifacts/{self.marker}-builder-b.md에 "
                "구체적인 구현 결과를 실제로 쓰고, "
                f"keeper_ide_annotate로 그 파일 1행을 Task {self.task_ids['builder-b']}와 Goal "
                f"{self.goal_id}에 연결하세요. keeper_task_done으로 artifact evidence를 제출한 뒤 "
                f"Board post {post_id}에 BUILDER_B_DONE comment를 남기세요."
            ),
            "reviewer": (
                composition_instruction
                + f"Mission {self.marker}. Board post {post_id}와 Goal {self.goal_id}, active Tasks를 읽고 "
                f"post {post_id}에 REVIEWER_OBSERVED라는 독립 review comment를 남기세요. "
                "다른 Keeper playground 파일은 직접 읽지 마세요."
            ),
            "researcher": (
                composition_instruction
                + "keeper_compose_background-snapshot을 정확히 한 번 제출하고 request_id를 보존하세요. "
                + f"Mission {self.marker}. masc_fusion으로 'How should five resident agents preserve "
                "progress when one work source fails?'를 비동기로 시작하세요. Fusion을 기다리거나 polling하지 말고 "
                f"즉시 exact Task {self.task_ids['researcher']}를 claim하고, Board post {post_id}에 "
                "FUSION_STARTED와 run_id를 comment한 뒤 Task evidence를 제출하세요. 마지막으로 보존한 "
                "request_id로 keeper_composition_status를 호출하세요. status가 queued 또는 running이면 "
                "동일한 request_id만 사용해 터미널 상태가 될 때까지 상태를 다시 확인하고, "
                "done이 되면 즉시 중단하세요. 외부 composition을 다시 제출하지 마세요."
            ),
        }
        with concurrent.futures.ThreadPoolExecutor(max_workers=5) as executor:
            futures = {
                executor.submit(self.run_turn, role, f"parallel-{role}", prompt): role
                for role, prompt in prompts.items()
            }
            for future in concurrent.futures.as_completed(futures):
                future.result()

    def run_continuity_chain(self, post_id: str) -> None:
        for step in range(1, 10):
            previous = "COORDINATOR_READY" if step == 1 else f"CONTINUITY_STEP_{step - 1}"
            self.run_turn(
                "coordinator",
                f"continuity-{step}",
                (
                    f"Mission {self.marker}, continuity step {step}. "
                    "keeper_compose_mission-snapshot을 정확히 한 번 호출하세요. "
                    f"Board post {post_id}에서 {previous}를 확인한 다음 CONTINUITY_STEP_{step} "
                    "comment를 남기세요. 최초 turn의 continuity secret은 다시 쓰거나 추측하지 마세요."
                ),
            )

    def capture_browser_proof(self) -> None:
        browser_dir = self.writer.output_dir / "browser"
        environment = os.environ.copy()
        environment.update(
            {
                "MASC_COMPOSITION_DASHBOARD_URL": default_health_url(
                    self.endpoint
                ).removesuffix("/health?full=1"),
                "MASC_COMPOSITION_DASHBOARD_TOKEN_FILE": str(self.token_file),
                "MASC_COMPOSITION_KEEPER_NAME": self.roles["coordinator"],
                "MASC_COMPOSITION_EXPECTED_BASE_PATH": self.expected_base_path,
                "MASC_COMPOSITION_BROWSER_ARTIFACT_DIR": str(browser_dir),
                "MASC_GOAL_VERIFICATION_GOAL_ID": self.verifier_goal_id,
                "MASC_GOAL_VERIFICATION_RUN_ID": str(
                    self.goal_verifier_evidence.get("proven_run_id", "")
                ),
            }
        )
        completed = subprocess.run(
            ["node", str(self.browser_proof_script)],
            cwd=REPO_ROOT,
            env=environment,
            check=False,
            capture_output=True,
            text=True,
            timeout=browser_proof_subprocess_timeout(self.timeout),
        )
        if completed.returncode != 0:
            raise AcceptanceError(
                "composition browser proof failed: "
                + (completed.stderr.strip() or completed.stdout.strip())
            )

        def read_measurement(filename: str) -> dict[str, Any]:
            measurement_path = browser_dir / filename
            try:
                measurement = json.loads(measurement_path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as error:
                raise AcceptanceError(
                    f"invalid browser proof measurement {filename}: {error}"
                ) from error
            if not isinstance(measurement, dict):
                raise AcceptanceError(
                    f"browser proof measurement {filename} must be an object"
                )
            return measurement

        self.browser_proof = read_measurement("keeper-composition-inspector.json")
        self.goal_verifier_browser_proof = read_measurement(
            "goal-verification-run-proof.json"
        )

    def run_contention(self, post_id: str) -> None:
        prompts = {
            "builder-a": (
                f"Mission {self.marker}. exact Task {self.task_ids['contention']}를 지금 claim하세요. "
                f"claim 성공이면 Board post {post_id}에 CONTENTION_OWNER comment와 evidence만 남기고 "
                "이 turn을 종료하세요. 이미 다른 Keeper가 소유했다면 재시도/override하지 말고 exact "
                f"fallback Task {self.task_ids['fallback']}를 claim한 뒤 Board post {post_id}에 "
                "CONTENDER_A_CONTINUED comment와 fallback evidence를 남기세요."
            ),
            "builder-b": (
                f"Mission {self.marker}. exact Task {self.task_ids['contention']}를 지금 claim하세요. "
                f"claim 성공이면 Board post {post_id}에 CONTENTION_OWNER comment와 evidence만 남기고 "
                "이 turn을 종료하세요. 이미 다른 Keeper가 소유했다면 재시도/override하지 말고 exact "
                f"fallback Task {self.task_ids['fallback']}를 claim한 뒤 Board post {post_id}에 "
                "CONTENDER_B_CONTINUED comment와 fallback evidence를 남기세요."
            ),
        }
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
            futures = [
                executor.submit(self.run_turn, role, f"contention-{role}", prompt)
                for role, prompt in prompts.items()
            ]
            for future in concurrent.futures.as_completed(futures):
                future.result()

    def run_failure_recovery(self, post_id: str) -> None:
        self.run_turn(
            "builder-b",
            "invalid-tool",
            (
                f"Mission {self.marker}. deterministic rejection을 검증합니다. keeper_ide_annotate를 "
                "file_path='invalid-proof.md', line_start=0, content='must reject'로 정확히 한 번 호출하세요. "
                "거부 결과를 숨기거나 무한 재시도하지 말고 turn을 종료하세요."
            ),
        )
        self.run_turn(
            "builder-b",
            "recovery-after-invalid",
            (
                f"새 source입니다. 이전 도구 거부와 무관하게 정상 작업을 계속하세요. valid file "
                f"artifacts/{self.marker}-recovered.md를 Write(tool_write_file)로 만들고 "
                "line_start=1로 IDE annotation한 뒤 "
                f"Board post {post_id}에 POISON_RECOVERED comment를 남기세요."
            ),
        )

    def run_poc_delivery(self, post_id: str) -> None:
        # RW20: the completion claim must be an execution log, not a file's
        # existence. The requester posts the requirement, the builder writes
        # AND runs the artifact so the expected output token lands in a
        # durable Execute tool row, and the reviewer quotes that token back.
        # The reviewer's prompt does not carry the token wording as a fait
        # accompli claim — but the token itself is deterministic so the
        # evaluator can match it exactly without semantic classification.
        output_token = self.poc_output_token
        self.run_turn(
            "researcher",
            "poc-request",
            (
                f"Mission {self.marker}. composition 도구는 호출하지 마세요. "
                f"Board post {post_id}에 POC_REQUEST={self.marker}-poc comment를 남기세요. "
                f"요구 내용: 실행하면 정확히 '{output_token}' 한 줄을 출력하는 스크립트."
            ),
        )
        self.run_turn(
            "builder-a",
            "poc-implement",
            (
                f"Mission {self.marker}. composition 도구는 호출하지 마세요. "
                f"Write(tool_write_file)로 playground의 artifacts/{self.marker}-poc.sh에 "
                f"정확히 '{output_token}' 한 줄을 출력하는 셸 스크립트를 쓰세요. "
                "그 다음 Execute(tool_execute)로 그 스크립트를 실제로 실행해 출력을 확인하고, "
                f"Board post {post_id}에 실행에서 얻은 출력 그대로 POC_EXECUTED=<출력의 = 뒤 값> "
                "comment를 남기세요. 실행 없이 완료를 주장하지 마세요."
            ),
        )
        self.run_turn(
            "reviewer",
            "poc-review",
            (
                f"Mission {self.marker}. composition 도구는 호출하지 마세요. "
                f"Board post {post_id}에서 POC_REQUEST와 POC_EXECUTED comment를 읽고, "
                "실행 출력이 요구와 일치하는지 확인한 뒤 POC_REVIEW_CONFIRMS=<POC_EXECUTED의 값 그대로> "
                "comment를 남기세요. 값을 새로 만들지 말고 board에서 읽은 값만 인용하세요."
            ),
        )

    def run_claim_reproduction(self, post_id: str) -> None:
        # RW26: a person states a published quantitative claim; the system
        # must come back with a run the person can read. The builder writes
        # AND executes the measurement so the count lands in a durable
        # Execute row; the reviewer judges only from what the Board carries.
        # Nobody's prompt contains the expected integer — the evaluator
        # computes it independently (rw26_fibonacci_leading_one_count).
        n = self.claim_fib_count
        self.run_turn(
            "researcher",
            "claim-state",
            (
                f"Mission {self.marker}. composition 도구는 호출하지 마세요. "
                f"Board post {post_id}에 CLAIM_STATED={self.marker}-benford comment를 남기세요. "
                "주장 내용: 피보나치 수열은 Benford 법칙을 따른다 — "
                f"F(1)=1, F(2)=1로 시작하는 처음 {n}개의 피보나치 수 가운데 십진 표기의 "
                "선두 숫자가 1인 수의 개수는 Benford 예측(약 30.1%)에 부합한다. "
                "이 주장을 실측으로 검증해 달라고 요구하세요."
            ),
        )
        self.run_turn(
            "builder-a",
            "claim-measure",
            (
                f"Mission {self.marker}. composition 도구는 호출하지 마세요. "
                f"Write(tool_write_file)로 playground의 artifacts/{self.marker}-claim.py에 "
                f"F(1)=1, F(2)=1로 시작하는 처음 {n}개의 피보나치 수 중 십진 선두 숫자가 1인 "
                "수의 개수를 정확한 정수 연산으로 세어 'LEADING_ONE_COUNT=<개수>' 한 줄을 "
                "출력하는 스크립트를 쓰세요. 그 다음 Execute(tool_execute)로 그 스크립트를 "
                "실제로 실행해 출력을 얻고, Board post "
                f"{post_id}에 실행 출력에서 읽은 값 그대로 CLAIM_MEASURED=<개수> comment를 "
                "남기세요. 실행 없이 값을 추정하거나 완료를 주장하지 마세요."
            ),
        )
        self.run_turn(
            "reviewer",
            "claim-verdict",
            (
                f"Mission {self.marker}. composition 도구는 호출하지 마세요. "
                f"Board post {post_id}에서 CLAIM_STATED와 CLAIM_MEASURED comment를 읽으세요. "
                f"측정 개수가 전체 {n}개의 약 30.1%에 부합하는지 한 문장으로 판정한 뒤 "
                "CLAIM_VERDICT_CITES=<읽은 CLAIM_MEASURED의 = 뒤 값 그대로> comment를 "
                "남기세요. 값을 새로 계산하거나 추측하지 말고 board에서 읽은 값만 인용하세요."
            ),
        )

    def run_debate(self, post_id: str) -> None:
        # RW21: the restatement and citation tokens are deliberately absent
        # from the responder prompts — the only way to produce them is to
        # read the opposing comment on the Board, which is what the mission
        # verifies (the same mechanism context_secret_recalled uses).
        claim_token = self.debate_claim_token
        rebuttal_token = self.debate_rebuttal_token
        self.run_turn(
            "builder-a",
            "debate-claim",
            (
                f"Mission {self.marker}. composition 도구는 호출하지 마세요. "
                f"Board post {post_id}에 DEBATE_CLAIM={claim_token} comment를 남기고, "
                "같은 comment에 '실패한 source는 즉시 재시도해야 한다'는 입장을 한 문장으로 쓰세요."
            ),
        )
        self.run_turn(
            "builder-b",
            "debate-rebut",
            (
                f"Mission {self.marker}. composition 도구는 호출하지 마세요. "
                f"Board post {post_id}에서 DEBATE_CLAIM comment를 찾아 읽으세요. "
                "하나의 comment 안에 먼저 DEBATE_RESTATE=<읽은 DEBATE_CLAIM의 = 뒤 값 그대로>로 "
                f"상대 주장을 재진술한 뒤, DEBATE_REBUTTAL={rebuttal_token}과 함께 "
                "그 입장에 반대하는 구체적 근거 한 문장을 쓰세요. 재진술 값을 추측하지 마세요."
            ),
        )
        self.run_turn(
            "reviewer",
            "debate-verdict",
            (
                f"Mission {self.marker}. composition 도구는 호출하지 마세요. "
                f"Board post {post_id}에서 DEBATE_CLAIM과 DEBATE_REBUTTAL comment를 모두 읽고, "
                "어느 쪽이 더 설득력 있는지 한 문장으로 판정한 뒤 "
                "DEBATE_VERDICT_CITES=<읽은 DEBATE_REBUTTAL의 = 뒤 값 그대로> comment를 남기세요. "
                "인용 값을 추측하지 마세요."
            ),
        )

    def run_qa_coverage(self, post_id: str) -> None:
        # RW22: coverage is a claim about a declared set, so the mission fixes
        # the set first and then requires every member of it to appear in a
        # real execution.
        #
        # Two things keep this from degenerating into the very anti-pattern it
        # exists to catch. The cases carry different behaviours rather than
        # echoing a token, so covering all three means three distinct
        # transforms actually ran — a script that prints constants covers
        # nothing. And the work enters the typed verification flow: each side
        # claims its own Task on the shared Goal and submits evidence through
        # keeper_task_done, so "done" is a submission for verification rather
        # than a self-declaration.
        #
        # Neither builder nor tester receives the expected outputs. The builder
        # is told the transform rule, the tester is told nothing but the path,
        # and the evaluator computes the expected values independently.
        rules = "; ".join(
            f"{name}: 입력 '{source}' 을 "
            + {
                "upper": "전부 대문자로 바꿔",
                "length": "그 길이(문자 수)를",
                "reverse": "문자 순서를 뒤집어",
            }[name]
            + " 계산해 '<케이스이름>=<결과>' 한 줄로 출력"
            for name, source, _ in self.qa_cases
        )
        self.run_turn(
            "researcher",
            "qa-spec",
            (
                f"Mission {self.marker}. composition 도구는 호출하지 마세요. "
                f"Board post {post_id}에 QA_SCOPE={rules} comment를 남기세요. "
                "이 세 케이스가 이번 검증의 전체 대상 범위입니다."
            ),
        )
        self.run_turn(
            "builder-a",
            "qa-implement",
            (
                f"Mission {self.marker}. composition 도구는 호출하지 마세요. "
                f"exact Task {self.task_ids['qa-implement']}를 claim하세요. "
                f"Board post {post_id}의 QA_SCOPE를 읽고, Write(tool_write_file)로 "
                f"playground의 artifacts/{self.marker}-qa.sh에 셸 스크립트를 쓰세요. "
                "스크립트는 세 케이스를 각각 수행해 '<케이스이름>=<결과>' 형태로 "
                "한 줄씩 출력해야 합니다. 값을 상수로 박지 말고 입력에서 실제로 변환하세요. "
                f"작성 후 keeper_task_done으로 그 파일을 evidence로 제출하고 "
                f"Board post {post_id}에 QA_IMPLEMENTED={self.marker}-qa.sh comment를 남기세요."
            ),
        )
        self.run_turn(
            "builder-b",
            "qa-test",
            (
                f"Mission {self.marker}. composition 도구는 호출하지 마세요. "
                f"exact Task {self.task_ids['qa-test']}를 claim하세요. "
                f"Execute(tool_execute)로 playground의 artifacts/{self.marker}-qa.sh를 "
                "실제로 실행하고 출력된 줄을 그대로 모으세요. "
                f"keeper_task_done으로 실행 결과를 evidence로 제출한 뒤 "
                f"Board post {post_id}에 QA_COVERAGE_RAN=<출력된 값들을 쉼표로 이어서> "
                "comment를 남기세요. 실행하지 않은 값을 적지 마세요."
            ),
        )
        self.run_turn(
            "reviewer",
            "qa-review",
            (
                f"Mission {self.marker}. composition 도구는 호출하지 마세요. "
                f"Board post {post_id}에서 QA_SCOPE와 QA_COVERAGE_RAN을 읽고 "
                "선언된 케이스 수와 실행이 낸 값의 수를 대조하세요. "
                "전부 덮었으면 QA_COVERAGE_VERDICT=COMPLETE:<실행이 낸 값들 그대로>, "
                "빠졌으면 QA_COVERAGE_VERDICT=MISSING:<빠진 케이스 이름> comment를 남기세요. "
                "Board에서 읽은 값만 쓰고 새로 만들지 마세요."
            ),
        )

    def run_goal_verifier_refute_reenter_prove(self) -> None:
        self.call(
            "goal-verifier-upsert",
            "masc_goal_upsert",
            {
                "id": self.verifier_goal_id,
                "title": f"Artifact-gated Goal verifier mission {self.marker}",
                "metric": (
                    f"producer artifact {self.verifier_artifact} contains the exact "
                    f"token {self.verifier_success_token}"
                ),
                "target_value": self.verifier_success_token,
                "priority": 1,
            },
        )
        self.wait_for_goal_state(
            phase="executing",
            completion_state="idle",
        )
        verifier_task = self.call(
            "goal-verifier-task-create",
            "masc_add_task",
            {
                "title": f"[{self.marker}] Produce exact Goal proof artifact",
                "description": (
                    f"Write {self.verifier_artifact} so its exact content is "
                    f"{self.verifier_success_token}; submit that artifact as "
                    "verification evidence."
                ),
                "priority": 1,
                "goal_id": self.verifier_goal_id,
            },
        )
        self.verifier_task_id = extract_identity(verifier_task.text, ["task-"])
        failure_token = f"GOAL_PROOF_FAIL={self.marker}"
        self.run_turn(
            "coordinator",
            "goal-verifier-refute-artifact",
            self._goal_verifier_refute_prompt(failure_token),
        )
        rejected_task_verdict = self.wait_for_verifier_task_verdict("in_progress")
        self.writer.write_json(
            "observations/goal-verifier-task-refuted.json",
            rejected_task_verdict,
        )
        self.call(
            "goal-verifier-request-refute",
            "masc_goal_transition",
            {"goal_id": self.verifier_goal_id, "action": "request_complete"},
        )
        refuted = self.wait_for_goal_state(
            phase="executing",
            completion_state="proof_refuted",
        )
        refuted_verdict = (
            refuted.get("verification", {})
            .get("completion", {})
            .get("verdict", {})
        )
        refuted_run_id = refuted_verdict.get("verification_run_id")
        if not isinstance(refuted_run_id, str) or not refuted_run_id.strip():
            raise AcceptanceError("refuted Goal verdict has no verification_run_id")
        self.writer.write_json("observations/goal-verifier-refuted.json", refuted)

        self.run_turn(
            "coordinator",
            "goal-verifier-proven-artifact",
            self._goal_verifier_proven_prompt(),
        )
        approved_task_verdict = self.wait_for_verifier_task_verdict("done")
        self.writer.write_json(
            "observations/goal-verifier-task-proven.json",
            approved_task_verdict,
        )
        self.call(
            "goal-verifier-request-prove",
            "masc_goal_transition",
            {"goal_id": self.verifier_goal_id, "action": "request_complete"},
        )
        proven = self.wait_for_goal_state(
            phase="completed",
            completion_state="proof_proven",
        )
        proven_verdict = (
            proven.get("verification", {})
            .get("completion", {})
            .get("verdict", {})
        )
        proven_run_id = proven_verdict.get("verification_run_id")
        if not isinstance(proven_run_id, str) or not proven_run_id.strip():
            raise AcceptanceError("proven Goal verdict has no verification_run_id")
        if proven_run_id == refuted_run_id:
            raise AcceptanceError("refutation and proof reused one verification run ID")
        self.writer.write_json("observations/goal-verifier-proven.json", proven)

        runs_payload = self.dashboard_get(
            "/api/v1/dashboard/goal-verification-runs"
        )
        runs = runs_payload.get("runs")
        if not isinstance(runs, list):
            raise AcceptanceError("Goal verification runs route has no runs array")
        proof_runs = [
            run
            for run in runs
            if isinstance(run, dict)
            and run.get("goal_id") == self.verifier_goal_id
            and run.get("review_kind") == "proof"
        ]
        by_id = {
            run.get("run_id"): run
            for run in proof_runs
            if isinstance(run.get("run_id"), str)
        }
        for expected_run_id in (refuted_run_id, proven_run_id):
            run = by_id.get(expected_run_id)
            if not isinstance(run, dict) or run.get("status") != "committed":
                raise AcceptanceError(
                    f"Goal proof run {expected_run_id} is not durably committed"
                )
            tools = run.get("tools")
            if not isinstance(tools, list) or not any(
                isinstance(tool, dict)
                and tool.get("tool_name") == "verification_read_file"
                for tool in tools
            ):
                raise AcceptanceError(
                    f"Goal proof run {expected_run_id} has no artifact read"
                )
        self.goal_verifier_evidence = {
            "goal_id": self.verifier_goal_id,
            "artifact": self.verifier_artifact,
            "task_id": self.verifier_task_id,
            "task_refuted_verdict": rejected_task_verdict,
            "task_proven_verdict": approved_task_verdict,
            "refuted_run_id": refuted_run_id,
            "proven_run_id": proven_run_id,
            "refuted_goal": refuted,
            "proven_goal": proven,
            "runs": proof_runs,
        }
        self.writer.write_json(
            "observations/goal-verification-runs.json",
            {"payload": runs_payload, "evidence": self.goal_verifier_evidence},
        )

    def _goal_verifier_refute_prompt(self, failure_token: str) -> str:
        return (
            f"Mission {self.marker}. composition 도구는 호출하지 마세요. "
            f"exact Task {self.verifier_task_id}를 claim하세요. "
            f"tool_write_file을 path='{self.verifier_artifact}', "
            f"content='{failure_token}', mode='overwrite'로 호출하세요. "
            "path에 'playground/' 접두사나 절대 경로를 붙이지 마세요. "
            f"keeper_task_done은 task_id='{self.verifier_task_id}', "
            f"evidence_refs=['artifact:{self.verifier_artifact}']로 제출하세요. "
            "실패 내용이어도 완료를 가장하지 말고 실제 파일을 그대로 제출하세요."
        )

    def _goal_verifier_proven_prompt(self) -> str:
        return (
            f"Mission {self.marker}. composition 도구는 호출하지 마세요. "
            f"반려 뒤 in_progress인 exact Task {self.verifier_task_id}만 계속 처리하세요. "
            "keeper_task_release, masc_add_task, keeper_task_claim을 호출하지 말고 "
            "Task를 release하거나 대체 Task를 만들거나 claim하지 마세요. "
            f"tool_write_file을 path='{self.verifier_artifact}', "
            f"content='{self.verifier_success_token}', mode='overwrite'로 호출하세요. "
            "path에 'playground/' 접두사나 절대 경로를 붙이지 마세요. "
            f"tool_read_file도 path='{self.verifier_artifact}'로 호출해 exact content를 확인하세요. "
            f"keeper_task_done은 task_id='{self.verifier_task_id}', "
            f"evidence_refs=['artifact:{self.verifier_artifact}']로 다시 제출하세요."
        )

    def restart_and_recall(self, post_id: str) -> None:
        self.writer.write_json(
            "keeper-status/coordinator-before-restart.json",
            self.read_status("coordinator", "before-restart"),
        )
        self.call(
            "keeper-down-coordinator",
            "masc_keeper_down",
            {"name": self.roles["coordinator"], "remove_meta": False, "remove_session": False},
        )
        # keepalive_running answers whether the fiber is up. It does not
        # answer whether the shutdown operation reached a phase that admits a
        # restart: the operation can still sit in Finalizing_tasks or
        # Cleanup_ready, and masc_keeper_up is then refused with
        # "shutdown operation is not an operator-supersedable blocked
        # operation" (#29181). shutdown_admission_fence is the predicate the
        # server's admission preflight consults, so wait on that.
        #
        # Only False admits. None means the status carried no operation
        # record — either none exists yet or the read failed — and treating
        # that as "no fence" is the same misread this replaces.
        down_deadline = time.monotonic() + 90.0
        while time.monotonic() < down_deadline:
            status = self.read_status("coordinator", "down-poll")
            if isinstance(status, dict) and not status.get("keepalive_running", False):
                runtime_surface = status.get("runtime")
                fence = (
                    runtime_surface.get("shutdown_admission_fence")
                    if isinstance(runtime_surface, dict)
                    else None
                )
                if fence is False:
                    break
            time.sleep(1.0)
        else:
            raise AcceptanceError(
                "coordinator shutdown did not clear the admission fence within "
                "90 seconds"
            )
        # Same required field as create_fleet: masc_keeper_up refuses a keeper
        # with no sandbox_profile. Restating it here rather than reusing the
        # create path keeps the restart a restart; the two call sites differ in
        # everything else (no instructions, no mention targets).
        arguments: dict[str, Any] = {
            "name": self.roles["coordinator"],
            "sandbox_profile": "local",
        }
        runtime_id = self.runtime_for_role("coordinator")
        if runtime_id:
            arguments["runtime_id"] = runtime_id
        self.call("keeper-restart-coordinator", "masc_keeper_up", arguments)
        deadline = time.monotonic() + 90.0
        while time.monotonic() < deadline:
            status = self.read_status("coordinator", "restart-poll")
            if isinstance(status, dict) and status.get("keepalive_running"):
                break
            time.sleep(1.0)
        else:
            raise AcceptanceError("coordinator did not restart within 90 seconds")
        self.run_turn(
            "coordinator",
            "context-after-restart",
            (
                f"Mission {self.marker}. 이전 prompt에 있던 continuity secret을 이번 prompt에서 다시 "
                f"제공하지 않았습니다. checkpoint/history/memory에서 회수해 Board post {post_id}에 "
                "MEMORY_RECALLED=<secret> comment를 남기세요. 추측하지 마세요."
            ),
        )
        self.writer.write_json(
            "keeper-status/coordinator-after-restart.json",
            self.read_status("coordinator", "after-restart"),
        )

    def read_status(self, role: str, label: str) -> Any:
        observation = self.call(
            f"keeper-status-{label}-{role}",
            "masc_keeper_status",
            {
                "name": self.roles[role],
                "fast": False,
                "include_context": True,
                "include_metrics_overview": True,
                "include_history_tail": True,
                "tail_messages": 20,
                "tail_turns": 20,
            },
        )
        self.statuses[role] = observation.data
        return observation.data

    def wait_for_async_sources(self) -> None:
        # masc_fusion_status is a keeper-internal tool (RFC-0266 §7 Phase 3
        # keeper-scoped isolation; see masc#28963/#28960): the operator MCP
        # session this runner authenticates as can never observe a researcher
        # keeper's fusion runs through it, so gating on it here would spin the
        # full deadline on every run. Fusion progress is observed instead via
        # the researcher's own durable tool-call event (masc_agent_timeline),
        # checked in evaluate_assertions.
        deadline = time.monotonic() + 180.0
        while time.monotonic() < deadline:
            schedule = self.call(
                "schedule-poll", "masc_schedule_get", {"schedule_id": self.schedule_id}
            )
            self.observations["schedule"] = schedule
            schedule_terminal = any(
                text_contains(schedule.data, state)
                for state in ("succeeded", "failed", "cancelled", "expired")
            )
            if schedule_terminal:
                data = self.read_status("coordinator", "after-schedule")
                self.writer.write_json(
                    "keeper-status/coordinator-after-schedule.json", data
                )
                return
            time.sleep(3.0)

    def collect_product_observations(self, post_id: str) -> None:
        for role in self.roles:
            data = self.read_status(role, "final")
            self.writer.write_json(f"keeper-status/{role}.json", data)
            timeline = self.call(
                f"observe-timeline-{role}",
                "masc_agent_timeline",
                {
                    "agent_name": self.roles[role],
                    "since_hours": 1.0,
                    "limit": 200,
                    "include_tasks": True,
                    "include_board": True,
                    "include_tool_calls": True,
                },
            )
            self.observations[f"timeline-{role}"] = timeline
            self.writer.write_json(
                f"observations/timeline-{role}.json",
                {
                    "tool": "masc_agent_timeline",
                    "text": timeline.text,
                    "data": timeline.data,
                },
            )
            encoded_keeper = urllib.parse.quote(self.roles[role], safe="")
            # 500, not 200: the durable inspector is now the assertion
            # evidence stream, and r4 roles already reached 139 rows in a
            # single campaign — headroom keeps a longer mission ladder from
            # clipping the early turns the assertions need.
            tool_calls = self.dashboard_get(
                f"/api/v1/keepers/{encoded_keeper}/tool-calls?limit=500"
            )
            entries = tool_calls.get("entries")
            if not isinstance(entries, list) or not all(
                isinstance(entry, dict) for entry in entries
            ):
                raise AcceptanceError(
                    f"tool-call inspector returned malformed rows for {role}"
                )
            self.tool_call_rows[role] = entries
            self.writer.write_json(
                f"observations/tool-calls-{role}.json", tool_calls
            )
        runtime_receipt = runtime_strategy_receipt(
            runtime_id=self.runtime_id,
            runtime_by_role=self.runtime_by_role,
            require_heterogeneous=self.require_heterogeneous_runtimes,
            roles=set(self.roles),
        )
        self.runtime_serving_evidence = collect_runtime_serving_evidence(
            base_path=pathlib.Path(self.expected_base_path),
            keepers_by_role=self.roles,
            expected_runtime_by_role=runtime_receipt["runtime_by_role"],
            manifest_line_cursors_by_keeper=self.runtime_manifest_line_cursors,
        )
        self.writer.write_json(
            "observations/runtime-serving-by-role.json",
            self.runtime_serving_evidence,
        )
        calls = {
            "goals": ("masc_goal_list", {}),
            "tasks": ("masc_tasks", {"include_done": True, "include_cancelled": True}),
            "board-search": (
                "masc_board_search",
                {"query": self.marker, "limit": 50, "compact": False},
            ),
            "board-post": (
                "masc_board_post_get",
                {"post_id": post_id, "comment_offset": 0, "comment_limit": 100},
            ),
            "schedule": ("masc_schedule_get", {"schedule_id": self.schedule_id}),
        }
        for label, (tool, arguments) in calls.items():
            observation = self.call(f"observe-{label}", tool, arguments)
            self.observations[label] = observation
            self.writer.write_json(
                f"observations/{label}.json",
                {"tool": tool, "text": observation.text, "data": observation.data},
            )
        for key, task_id in self.task_ids.items():
            observation = self.call(
                f"observe-task-history-{key}",
                "masc_task_history",
                {"task_id": task_id, "limit": 100},
            )
            self.observations[f"task-history-{key}"] = observation
            self.writer.write_json(
                f"observations/task-history-{key}.json",
                {"tool": "masc_task_history", "text": observation.text, "data": observation.data},
            )

    def _completion_verdict(self, key: str) -> tuple[bool, str]:
        """Whether this task's own history shows it passed verification.

        Submitting is not completing. keeper_task_done issues
        submit_for_verification, and the completion authority then approves or
        rejects — live records show 41 approvals against 35 rejections, so the
        verdict is a real judgement rather than a rubber stamp. A mission that
        only checked the submission tool call would pass on rejected work.

        The detail distinguishes rejected from still-unjudged, because those
        need different follow-up.
        """
        observation = self.observations.get(f"task-history-{key}")
        entries = getattr(observation, "data", None)
        verdicts = [
            entry
            for entry in (entries if isinstance(entries, list) else [])
            if isinstance(entry, dict)
            and entry.get("type") == "task_completion_verdict"
        ]
        for entry in verdicts:
            if (
                entry.get("from_status") == "awaiting_verification"
                and entry.get("to_status") == "done"
                and entry.get("verification_id")
            ):
                return True, f"{key}=approved({entry['verification_id']})"
        if verdicts:
            last = verdicts[-1]
            return (
                False,
                f"{key}={last.get('from_status')}->{last.get('to_status')}",
            )
        return False, f"{key}=no_verdict"

    def _status_text(self, role: str) -> str:
        return json.dumps(self.statuses.get(role), ensure_ascii=False).lower()

    def _tool_events(self, role: str, tool_name: str) -> list[dict[str, Any]]:
        # Judged from the durable tool-call inspector rows, not from
        # masc_agent_timeline: the timeline is a lossy window that dropped
        # early-turn events (masc_fusion, keeper_memory_write) even under its
        # limit, flipping real successes to FAIL in run e0-r4-20260818
        # (masc#28976). Rows nested inside a composition run are excluded —
        # a composition node executing masc_board_stats is not the keeper
        # calling it. Normalized to the {"detail": {...}} event shape the
        # assertion sites consume, ordered by timestamp so
        # rejected-then-recovered sequences stay judgeable.
        accepted_names = TOOL_ALIASES.get(tool_name, {tool_name})
        rows = self.tool_call_rows.get(role) or []
        return [
            {
                "detail": {
                    "tool_name": row.get("tool"),
                    "success": row.get("success"),
                },
                "ts": row.get("ts"),
            }
            for row in sorted(rows, key=lambda row: float(row.get("ts") or 0.0))
            if row.get("tool") in accepted_names
            and not row.get("composition_tool")
        ]

    def _successful_tool(self, role: str, tool_name: str) -> bool:
        return any(
            event["detail"].get("success") is True
            for event in self._tool_events(role, tool_name)
        )

    def evaluate_assertions(self, post_id: str) -> dict[str, dict[str, Any]]:
        goals = self.observations["goals"].data
        tasks = self.observations["tasks"].data
        board = self.observations["board-post"].data
        schedule = self.observations["schedule"].data
        histories = {
            key: self.observations[f"task-history-{key}"].data for key in self.task_ids
        }
        board_text = json.dumps(board, ensure_ascii=False)
        task_text = json.dumps(tasks, ensure_ascii=False)
        goal_text = json.dumps(goals, ensure_ascii=False)
        goal_rows = goals.get("goals", []) if isinstance(goals, dict) else []
        shared_goal = next(
            (
                row
                for row in goal_rows
                if isinstance(row, dict) and row.get("id") == self.goal_id
            ),
            None,
        )
        history_text = json.dumps(histories, ensure_ascii=False)
        qa_verdicts = [
            self._completion_verdict(key) for key in ("qa-implement", "qa-test")
        ]
        goal_verifier_refuted = self.goal_verifier_evidence.get("refuted_goal")
        goal_verifier_proven = self.goal_verifier_evidence.get("proven_goal")
        goal_verifier_refuted_run = self.goal_verifier_evidence.get(
            "refuted_run_id"
        )
        goal_verifier_proven_run = self.goal_verifier_evidence.get(
            "proven_run_id"
        )
        goal_verifier_runs = self.goal_verifier_evidence.get("runs")
        goal_verifier_runs_by_id = {
            run.get("run_id"): run
            for run in (
                goal_verifier_runs if isinstance(goal_verifier_runs, list) else []
            )
            if isinstance(run, dict) and isinstance(run.get("run_id"), str)
        }
        parallel_turns = [
            turn for label, turn in self.turns.items() if label.startswith("parallel-")
        ]
        coordinator_turns = [
            turn for turn in self.turns.values() if turn.role == "coordinator"
        ]
        required_inline_turn_labels = {
            *(f"parallel-{role}" for role in self.roles),
            *(f"continuity-{step}" for step in range(1, 10)),
        }
        required_coordinator_turn_labels = {
            "parallel-coordinator",
            *(f"continuity-{step}" for step in range(1, 10)),
            "context-after-restart",
        }

        def rows_for_turn(role: str, turn: TurnObservation) -> list[dict[str, Any]]:
            return [
                row
                for row in self.tool_call_rows.get(role, [])
                if isinstance(row.get("ts"), (int, float))
                and turn.started_epoch_seconds <= float(row["ts"])
                <= turn.finished_epoch_seconds
                and is_submitted_turn_row(row)
            ]

        def is_submitted_turn_row(row: dict[str, Any]) -> bool:
            # The mission prompt reaches a keeper only through a submitted
            # turn. Its autonomous cycle receives "Continue." and calls the
            # same tools with the same trace_id, so before rows carried
            # turn_kind (masc#28977) the only available boundary was the
            # submission's wall clock — and a keeper that started an
            # autonomous turn while the harness was submitting had its own
            # compose runs land outside every window, counted as an
            # exactly-once violation it never committed. Rows without the
            # field fail closed: no run is attributable, and the assertion
            # says so rather than passing on an empty universe.
            return row.get("turn_kind") == "direct"

        def autonomous_composition_runs(composition_tool: str) -> set[tuple[str, str]]:
            runs: set[tuple[str, str]] = set()
            for role, rows in self.tool_call_rows.items():
                for row in rows:
                    if row.get("composition_tool") != composition_tool:
                        continue
                    if is_submitted_turn_row(row):
                        continue
                    run_id = row.get("composition_run_id")
                    if isinstance(run_id, str) and run_id:
                        runs.add((role, run_id))
            return runs

        def successful_windowed_tool(role: str, label: str, tool_name: str) -> bool:
            # A durable, non-composition tool row of the given name that
            # succeeded inside the labeled turn's wall-clock window.
            turn = self.turns.get(label)
            if turn is None:
                return False
            accepted_names = TOOL_ALIASES.get(tool_name, {tool_name})
            return any(
                row.get("tool") in accepted_names
                and row.get("success") is True
                and not row.get("composition_tool")
                for row in rows_for_turn(role, turn)
            )

        def windowed_execute_output_contains(
            role: str, label: str, needle: str
        ) -> bool:
            turn = self.turns.get(label)
            if turn is None:
                return False
            return any(
                row.get("tool") in TOOL_ALIASES["tool_execute"]
                and row.get("success") is True
                and not row.get("composition_tool")
                and isinstance(row.get("output"), str)
                and needle in row["output"]
                for row in rows_for_turn(role, turn)
            )

        def composition_runs(
            composition_tool: str,
        ) -> dict[tuple[str, str], list[dict[str, Any]]]:
            runs: dict[tuple[str, str], list[dict[str, Any]]] = {}
            for role, rows in self.tool_call_rows.items():
                for row in rows:
                    if row.get("composition_tool") != composition_tool:
                        continue
                    if not is_submitted_turn_row(row):
                        continue
                    run_id = row.get("composition_run_id")
                    if isinstance(run_id, str) and run_id:
                        runs.setdefault((role, run_id), []).append(row)
            return runs

        def has_nested_settlement_evidence(row: dict[str, Any]) -> bool:
            execution_id = row.get("execution_id")
            tool_use_id = row.get("tool_use_id")
            result_bytes = row.get("result_bytes")
            truncated_to = row.get("truncated_to")
            output = row.get("output")
            return (
                isinstance(execution_id, str)
                and bool(execution_id.strip())
                and isinstance(tool_use_id, str)
                and bool(tool_use_id.strip())
                and isinstance(result_bytes, int)
                and not isinstance(result_bytes, bool)
                and result_bytes >= 0
                and truncated_to is None
                and isinstance(output, str)
                and result_bytes == len(output.encode("utf-8"))
            )

        def has_unique_nested_identities(
            rows: list[dict[str, Any]], expected_count: int
        ) -> bool:
            return (
                len({row.get("execution_id") for row in rows}) == expected_count
                and len({row.get("tool_use_id") for row in rows}) == expected_count
            )

        inline_runs = composition_runs("keeper_compose_mission-snapshot")
        async_runs = composition_runs("keeper_compose_background-snapshot")
        autonomous_inline_runs = autonomous_composition_runs(
            "keeper_compose_mission-snapshot"
        )
        composition_rows = [row for rows in inline_runs.values() for row in rows]
        inline_turn_runs: dict[str, tuple[str, list[dict[str, Any]]]] = {}
        inline_turn_errors: list[str] = []
        attributed_inline_run_keys: set[tuple[str, str]] = set()
        for label in sorted(required_inline_turn_labels):
            role = label.removeprefix("parallel-") if label.startswith("parallel-") else "coordinator"
            turn = self.turns.get(label)
            if turn is None:
                inline_turn_errors.append(f"{label}:missing_turn")
                continue
            turn_rows = [
                row
                for row in rows_for_turn(role, turn)
                if row.get("composition_tool") == "keeper_compose_mission-snapshot"
            ]
            run_ids = {
                row.get("composition_run_id")
                for row in turn_rows
                if isinstance(row.get("composition_run_id"), str)
                and row.get("composition_run_id")
            }
            if len(run_ids) != 1:
                inline_turn_errors.append(f"{label}:runs={sorted(run_ids)}")
                continue
            run_id = next(iter(run_ids))
            run_rows = [row for row in turn_rows if row.get("composition_run_id") == run_id]
            outer_rows = [
                row
                for row in rows_for_turn(role, turn)
                if row.get("tool") == "keeper_compose_mission-snapshot"
            ]
            parent_ids = {row.get("parent_tool_use_id") for row in run_rows}
            node_ids = {row.get("composition_node_id") for row in run_rows}
            if (
                len(run_rows) != 4
                or len(outer_rows) != 1
                or node_ids != {"clock", "board", "board-peer", "memory"}
                or len(parent_ids) != 1
                or next(iter(parent_ids)) != outer_rows[0].get("tool_use_id")
                or not all(row.get("disposition") == "completed" for row in run_rows)
                or not all(has_nested_settlement_evidence(row) for row in run_rows)
                or not has_unique_nested_identities(run_rows, 4)
            ):
                inline_turn_errors.append(f"{label}:invalid_rows={len(run_rows)}")
                continue
            inline_turn_runs[label] = (run_id, run_rows)
            attributed_inline_run_keys.add((role, run_id))
        unattributed_inline_runs = set(inline_runs) - attributed_inline_run_keys
        inline_run_ids_globally_unique = (
            len({run_id for run_id, _ in inline_turn_runs.values()})
            == len(required_inline_turn_labels)
        )
        inline_action_rows = [
            row for _, rows in inline_turn_runs.values() for row in rows
        ]
        accepted_inline_row_identities = {
            (
                label.removeprefix("parallel-")
                if label.startswith("parallel-")
                else "coordinator",
                run_id,
                row.get("execution_id"),
                row.get("tool_use_id"),
            )
            for label, (run_id, rows) in inline_turn_runs.items()
            for row in rows
        }
        full_inline_action_rows = [
            row for rows in inline_runs.values() for row in rows
        ]
        full_inline_row_identities = {
            (role, run_id, row.get("execution_id"), row.get("tool_use_id"))
            for (role, run_id), rows in inline_runs.items()
            for row in rows
        }
        inline_row_universe_exact = (
            len(inline_action_rows) == 56
            and len(full_inline_action_rows) == 56
            and len(accepted_inline_row_identities) == 56
            and full_inline_row_identities == accepted_inline_row_identities
        )
        inline_action_identities_globally_unique = (
            len(inline_action_rows) == 56
            and len({row.get("execution_id") for row in inline_action_rows}) == 56
            and len({row.get("tool_use_id") for row in inline_action_rows}) == 56
        )

        researcher_turn = self.turns.get("parallel-researcher")
        researcher_rows = (
            rows_for_turn("researcher", researcher_turn)
            if researcher_turn is not None
            else []
        )
        async_submit_rows = [
            row
            for row in researcher_rows
            if row.get("tool") == "keeper_compose_background-snapshot"
        ]
        async_status_rows = [
            row for row in researcher_rows if row.get("tool") == "keeper_composition_status"
        ]
        async_request_id: str | None = None
        async_outer_terminal = False
        if len(async_submit_rows) == 1 and async_status_rows:
            submission_output = parse_json_maybe(async_submit_rows[0].get("output", ""))
            candidate_request_id = (
                submission_output.get("request_id")
                if isinstance(submission_output, dict)
                else None
            )
            if isinstance(candidate_request_id, str) and candidate_request_id:
                async_request_id = candidate_request_id
                ordered_status_rows = sorted(
                    async_status_rows, key=lambda row: float(row.get("ts", 0.0))
                )
                status_evidence = [
                    (row.get("input"), parse_json_exact(row.get("output", "")))
                    for row in ordered_status_rows
                ]
                final_output = status_evidence[-1][1]
                async_outer_terminal = (
                    all(
                        isinstance(status_input, dict)
                        and status_input.get("request_id") == async_request_id
                        and isinstance(status_output, dict)
                        and status_output.get("request_id") == async_request_id
                        and status_output.get("status") in {"queued", "running", "done"}
                        for status_input, status_output in status_evidence
                    )
                    and all(
                        status_output.get("status") in {"queued", "running"}
                        for _, status_output in status_evidence[:-1]
                    )
                    and final_output.get("status") == "done"
                    and final_output.get("ok") is True
                )
        async_action_rows = [row for rows in async_runs.values() for row in rows]
        all_nested_action_rows = inline_action_rows + async_action_rows
        all_composition_run_ids = {
            run_id for _, run_id in set(inline_runs) | set(async_runs)
        }
        # Uniqueness is judged as uniqueness, not as a fixed count: pinning
        # these to 14/15/58 made one duplicate compose call (already rejected
        # by composition_inline_observed's exactly-once contract) cascade into
        # three unrelated structure assertions in run e0-r4-20260818
        # (masc#28976). Each failure mode stays owned by exactly one check.
        composition_run_ids_globally_unique = (
            len(inline_runs) > 0
            and len(async_runs) > 0
            and len(all_composition_run_ids) == len(inline_runs) + len(async_runs)
        )
        all_nested_action_identities_globally_unique = (
            len(all_nested_action_rows) > 0
            and len({row.get("execution_id") for row in all_nested_action_rows})
            == len(all_nested_action_rows)
            and len({row.get("tool_use_id") for row in all_nested_action_rows})
            == len(all_nested_action_rows)
        )

        coordinator_runtime_turn_ids: dict[str, int] = {}
        coordinator_turn_evidence_errors: list[str] = []
        for label in sorted(required_coordinator_turn_labels):
            turn = self.turns.get(label)
            if turn is None:
                coordinator_turn_evidence_errors.append(f"{label}:missing_turn")
                continue
            keeper_turn_ids = {
                row.get("keeper_turn_id")
                for row in rows_for_turn("coordinator", turn)
                if isinstance(row.get("keeper_turn_id"), int)
            }
            if len(keeper_turn_ids) != 1:
                coordinator_turn_evidence_errors.append(
                    f"{label}:keeper_turn_ids={sorted(keeper_turn_ids)}"
                )
                continue
            coordinator_runtime_turn_ids[label] = next(iter(keeper_turn_ids))
        required_inline_rows = [rows for _, rows in inline_turn_runs.values()]
        # Structure is judged over every attributed run; the 14-turn
        # exactly-once count contract is composition_inline_observed's job
        # alone (see the uniqueness comment above).
        parallel_schedule_observed = len(required_inline_rows) > 0 and all(
            all(
                any(
                    row.get("composition_node_id") == node
                    and row.get("batch_index") == 0
                    and row.get("batch_size") == 3
                    and row.get("execution_mode") == "concurrent"
                    for row in rows
                )
                for node in ("clock", "board", "board-peer")
            )
            for rows in required_inline_rows
        )
        sequential_dataflow_observed = len(required_inline_rows) > 0 and all(
            any(
                isinstance(row.get("input"), dict)
                and row["input"].get("query") == clock_output.get("now_iso")
                and row.get("batch_index") == 1
                and row.get("batch_size") == 1
                and row.get("execution_mode") == "serial"
                and row.get("disposition") == "completed"
                for row in rows
                if row.get("composition_node_id") == "memory"
            )
            for rows in required_inline_rows
            for clock_output in [
                parse_json_maybe(
                    next(
                        row.get("output", "")
                        for row in rows
                        if row.get("composition_node_id") == "clock"
                    )
                )
            ]
            if isinstance(clock_output, dict)
        )
        typed_context_observed = bool(composition_rows) and all(
            isinstance(row.get("composition_run_id"), str)
            and bool(row.get("composition_run_id"))
            and isinstance(row.get("composition_node_id"), str)
            and row.get("composition_execution") == "inline"
            and isinstance(row.get("parent_tool_use_id"), str)
            and row.get("disposition") in {"completed", "deferred", "failed"}
            for row in composition_rows
        )
        browser_screenshot = (
            self.writer.output_dir / "browser" / "keeper-composition-inspector.png"
        )
        parallel_events = sorted(
            [
                (turn.started_epoch_seconds, 1)
                for turn in parallel_turns
            ]
            + [
                (turn.finished_epoch_seconds, -1)
                for turn in parallel_turns
            ],
            key=lambda event: (event[0], event[1]),
        )
        concurrent_turns = 0
        max_concurrent_turns = 0
        for _, delta in parallel_events:
            concurrent_turns += delta
            max_concurrent_turns = max(max_concurrent_turns, concurrent_turns)
        owner_hits = [
            role
            for role in ("builder-a", "builder-b")
            if text_contains(histories["contention"], self.roles[role])
        ]
        loser_role = (
            ({"builder-a", "builder-b"} - set(owner_hits)).pop()
            if len(owner_hits) == 1
            else None
        )
        loser_marker = (
            "CONTENDER_A_CONTINUED"
            if loser_role == "builder-a"
            else "CONTENDER_B_CONTINUED"
        )
        distinct_owner_hits = {
            keeper
            for keeper in self.roles.values()
            if keeper.lower() in history_text.lower()
        }
        comment_author_hits = {
            role
            for role, keeper in self.roles.items()
            if keeper.lower() in board_text.lower()
        }
        observed_surfaces = {
            "Schedule": text_contains(schedule, self.schedule_id)
            and self._successful_tool("coordinator", "masc_schedule_get"),
            "Task": text_contains(tasks, self.marker)
            and any(
                self._successful_tool(role, "keeper_task_claim")
                for role in self.roles
            ),
            "Board": text_contains(board, self.marker)
            and self._successful_tool("coordinator", "masc_board_post"),
            "Goal": text_contains(goals, self.goal_id)
            and self._successful_tool("coordinator", "masc_goal_list"),
            "IDE": any(
                self._successful_tool(role, "keeper_ide_annotate")
                for role in ("builder-a", "builder-b")
            ),
            "Comment": len(comment_author_hits) >= 3,
            # masc_fusion_status is keeper-internal (RFC-0266 §7 Phase 3); the
            # operator session cannot poll it (masc#28963/#28960), so Fusion
            # progress is observed only through the researcher keeper's own
            # durable masc_fusion tool-call event.
            "Fusion": self._successful_tool("researcher", "masc_fusion"),
            "Memory": self._successful_tool("coordinator", "keeper_memory_write"),
            "Context": self.secret.lower() in board_text.lower(),
        }
        task_status_words = ("awaiting_verification", "done", "in_progress", "claimed")
        recalled_pattern = re.compile(
            rf"MEMORY_RECALLED.{{0,240}}{re.escape(self.secret)}|"
            rf"{re.escape(self.secret)}.{{0,240}}MEMORY_RECALLED",
            re.IGNORECASE | re.DOTALL,
        )
        invalid_turn = self.turns.get("invalid-tool")
        builder_b_ide_events = self._tool_events("builder-b", "keeper_ide_annotate")
        failed_ide_positions = [
            index
            for index, event in enumerate(builder_b_ide_events)
            if event["detail"].get("success") is False
        ]
        successful_ide_positions = [
            index
            for index, event in enumerate(builder_b_ide_events)
            if event["detail"].get("success") is True
        ]
        failed_then_recovered = bool(failed_ide_positions) and any(
            success > min(failed_ide_positions) for success in successful_ide_positions
        )
        artifact_files = [
            path
            for path in self.writer.output_dir.rglob("*.json")
            if path.name not in {"bundle.json", "assertions.json"}
        ]
        expected_runtime_ids = {
            runtime_id
            for role in self.roles
            for runtime_id in [self.runtime_for_role(role)]
            if isinstance(runtime_id, str) and runtime_id
        }
        runtime_serving_passed = (
            self.runtime_serving_evidence.get("status") == "passed"
            and self.runtime_serving_evidence.get("served_role_count")
            == len(self.roles)
            and self.runtime_serving_evidence.get("distinct_served_runtime_count")
            == len(expected_runtime_ids)
        )
        checks: dict[str, tuple[bool, str]] = {
            "all_keepers_live": (
                len(self.statuses) == len(self.roles)
                and all(
                    keeper_is_live(self.statuses.get(role)) for role in self.roles
                ),
                f"observed live keepalive status for {len(self.statuses)}/{len(self.roles)} roles",
            ),
            "role_identity_preserved": (
                all(self.roles[role].lower() in self._status_text(role) for role in self.roles),
                "each final status contains its exact Keeper identity",
            ),
            "runtime_assignment_serving_observed": (
                runtime_serving_passed,
                (
                    "durable no-fallback runtime receipts served "
                    f"{self.runtime_serving_evidence.get('served_role_count', 0)}/"
                    f"{len(self.roles)} roles across "
                    f"{self.runtime_serving_evidence.get('distinct_served_runtime_count', 0)}/"
                    f"{len(expected_runtime_ids)} configured runtimes"
                ),
            ),
            "goal_visible": (self.goal_id.lower() in goal_text.lower(), self.goal_id),
            "goal_shared_open_set_visible": (
                isinstance(shared_goal, dict) and "owner" not in shared_goal,
                "shared Goal is present and the removed owner field is absent",
            ),
            "tasks_linked_to_goal": (
                # Goal linkage is judged from the creation receipts (the
                # server echoes the persisted task, goal_id included); the
                # Quest Board text projection never renders goal links, so
                # searching it for the goal id fails even when linkage is
                # real (masc#28976). The projection still proves the tasks
                # are alive on the board at observation time.
                all(task_id.lower() in task_text.lower() for task_id in self.task_ids.values())
                and len(self.task_create_receipts) == len(self.task_ids)
                and all(
                    isinstance(receipt.data, dict)
                    and receipt.data.get("ok") is True
                    and receipt.data.get("goal_id") == self.goal_id
                    for receipt in self.task_create_receipts.values()
                ),
                f"{len(self.task_ids)} task ids on the board; "
                f"{len(self.task_create_receipts)} creation receipts carry goal_id",
            ),
            "parallel_wave_completed": (
                len(parallel_turns) == 5 and all(turn.status == "passed" for turn in parallel_turns),
                f"{sum(turn.status == 'passed' for turn in parallel_turns)}/5 turn calls settled successfully",
            ),
            "parallel_keeper_overlap_observed": (
                max_concurrent_turns >= 3,
                f"maximum simultaneous Keeper requests={max_concurrent_turns}",
            ),
            "multiple_task_owners_visible": (
                len(distinct_owner_hits) >= 2,
                f"task histories contain {sorted(distinct_owner_hits)}",
            ),
            "board_thread_visible": (
                post_id.lower() in board_text.lower() and self.marker.lower() in board_text.lower(),
                post_id,
            ),
            "multi_author_comments_visible": (
                len(comment_author_hits) >= 3,
                f"comment authors/identities: {sorted(comment_author_hits)}",
            ),
            "ide_annotation_observed": (
                all(
                    self._successful_tool(role, "keeper_ide_annotate")
                    and self._successful_tool(role, "tool_write_file")
                    for role in ("builder-a", "builder-b")
                ),
                "both builders wrote files and linked IDE annotations",
            ),
            "task_evidence_submitted": (
                "submit_for_verification" in history_text.lower()
                or "awaiting_verification" in task_text.lower(),
                "task history or current task state",
            ),
            "fusion_started": (
                # keeper-side evidence only; masc_fusion_status is
                # keeper-internal and unreachable from the operator session
                # (masc#28963/#28960).
                self._successful_tool("researcher", "masc_fusion"),
                "researcher durable tool event",
            ),
            "peer_progress_during_fusion": (
                text_contains(board, "BUILDER_A_DONE") and text_contains(board, "BUILDER_B_DONE"),
                "builder completion markers coexist with Fusion registry",
            ),
            "schedule_terminal_visible": (
                text_contains(schedule, self.schedule_id)
                and any(text_contains(schedule, state) for state in ("succeeded", "failed", "cancelled", "expired")),
                "schedule identity plus durable terminal state",
            ),
            "scheduled_wake_progress_visible": (
                text_contains(board, "SCHEDULE_WAKE_OK")
                or text_contains(self.statuses["coordinator"], "Scheduled collaboration checkpoint"),
                "scheduled wake marker in Board or coordinator history",
            ),
            "invalid_tool_turn_settled": (
                invalid_turn is not None
                and invalid_turn.status in {"passed", "tool_error"}
                and bool(failed_ide_positions),
                f"turn terminal status={invalid_turn.status if invalid_turn else 'missing'}; rejected IDE calls={len(failed_ide_positions)}",
            ),
            "same_keeper_recovered": (
                self.turns.get("recovery-after-invalid") is not None
                and self.turns["recovery-after-invalid"].status == "passed"
                and failed_then_recovered
                and text_contains(board, "POISON_RECOVERED"),
                "builder-b has a rejected IDE event followed by a successful IDE event and product evidence",
            ),
            "unaffected_peers_progressed": (
                sum(
                    text_contains(board, marker)
                    for marker in ("COORDINATOR_READY", "REVIEWER_OBSERVED", "BUILDER_A_DONE")
                )
                >= 2,
                "independent peer markers survived",
            ),
            "restart_succeeded": (
                isinstance(self.statuses.get("coordinator"), dict)
                and bool(self.statuses["coordinator"].get("keepalive_running")),
                "coordinator keepalive active after down/up",
            ),
            "context_secret_recalled": (
                recalled_pattern.search(board_text) is not None,
                "secret was not repeated in the post-restart prompt",
            ),
            "memory_write_observed": (
                self._successful_tool("coordinator", "keeper_memory_write"),
                "coordinator durable successful tool event",
            ),
            "no_illegal_direct_done": (
                all(
                    not self._tool_events(role, "masc_task_update")
                    for role in self.roles
                )
                and ("submit_for_verification" in history_text.lower()
                     or "awaiting_verification" in task_text.lower())
                and any(word in task_text.lower() for word in task_status_words),
                "no direct operator task update; evidence entered typed verification flow",
            ),
            "contention_single_owner": (
                len(owner_hits) == 1,
                f"contention history owner identities={owner_hits}",
            ),
            "contention_loser_continued": (
                loser_role is not None
                and text_contains(histories["fallback"], self.roles[loser_role])
                and text_contains(board, loser_marker),
                f"loser={loser_role!r} owns fallback and left its exact continuation marker",
            ),
            "reviewer_progress_visible": (
                text_contains(board, "REVIEWER_OBSERVED")
                and self.roles["reviewer"].lower() in board_text.lower(),
                "reviewer Board outcome",
            ),
            "all_surfaces_observed": (
                all(observed_surfaces.values()),
                json.dumps(observed_surfaces, ensure_ascii=False, sort_keys=True),
            ),
            "correlation_marker_complete": (
                all(
                    text_contains(value, self.marker)
                    for value in (goals, tasks, board, schedule)
                )
                and self._successful_tool("researcher", "masc_fusion"),
                "marker in Goal/Task/Board/Schedule and researcher's durable Fusion tool event",
            ),
            "artifact_bundle_complete": (
                len(artifact_files) >= 20
                and (self.writer.output_dir / "health.json").is_file()
                and (self.writer.output_dir / "preflight.json").is_file(),
                f"{len(artifact_files)} JSON evidence artifacts before bundle emission",
            ),
            "same_keeper_eleven_linked_turns": (
                set(coordinator_runtime_turn_ids) == required_coordinator_turn_labels
                and len(set(coordinator_runtime_turn_ids.values())) == 11
                and len({turn.operation_id for turn in coordinator_turns}) == 11
                and all(turn.status == "passed" for turn in coordinator_turns)
                and all(text_contains(board, f"CONTINUITY_STEP_{step}") for step in range(1, 10))
                and text_contains(board, f"MEMORY_RECALLED={self.secret}"),
                "eleven distinct runtime keeper_turn_id values join the requested operations, "
                f"errors={coordinator_turn_evidence_errors}",
            ),
            "composition_inline_observed": (
                set(inline_turn_runs) == required_inline_turn_labels
                and not inline_turn_errors
                and not unattributed_inline_runs
                and inline_run_ids_globally_unique
                and inline_row_universe_exact
                and inline_action_identities_globally_unique,
                f"exact completed inline runs={len(inline_turn_runs)}/14 "
                f"errors={inline_turn_errors} unattributed={sorted(unattributed_inline_runs)} "
                f"autonomous={sorted(autonomous_inline_runs)}",
            ),
            "composition_parallel_schedule_observed": (
                parallel_schedule_observed,
                "clock/board/board-peer share exact concurrent batch 0 of size 3",
            ),
            "composition_sequential_dataflow_observed": (
                sequential_dataflow_observed,
                "memory node receives typed clock output in serial batch 1",
            ),
            "composition_async_observed": (
                len(async_runs) == 1
                and async_outer_terminal
                and all(
                    role == "researcher"
                    and len(rows) == 2
                    and {row.get("composition_node_id") for row in rows}
                    == {"clock", "board"}
                    and all(
                        row.get("composition_execution") == "async"
                        and row.get("disposition") == "completed"
                        and has_nested_settlement_evidence(row)
                        for row in rows
                    )
                    and all(
                        row.get("parent_tool_use_id")
                        == async_submit_rows[0].get("tool_use_id")
                        for row in rows
                    )
                    and has_unique_nested_identities(rows, 2)
                    for (role, _), rows in async_runs.items()
                )
                and composition_run_ids_globally_unique
                and all_nested_action_identities_globally_unique,
                f"async runs={len(async_runs)} request_id={async_request_id} "
                f"submit_rows={len(async_submit_rows)} status_rows={len(async_status_rows)} terminal={async_outer_terminal}",
            ),
            "composition_turn_context_observed": (
                typed_context_observed,
                f"typed composition rows={len(composition_rows)}",
            ),
            "composition_dashboard_browser_observed": (
                self.browser_proof.get("schema")
                == "masc.keeper_composition_browser_evidence.v1"
                and self.browser_proof.get("keeper") == self.roles["coordinator"]
                and self.browser_proof.get("nodes")
                == ["board", "board-peer", "clock", "memory"]
                and self.browser_proof.get("execution") == "inline"
                and self.browser_proof.get("dispositions")
                == ["completed", "completed", "completed", "completed"]
                and self.browser_proof.get("input_visible") is True
                and self.browser_proof.get("output_visible") is True
                and isinstance(self.browser_proof.get("screenshot_sha256"), str)
                and len(self.browser_proof["screenshot_sha256"]) == 64
                and browser_screenshot.is_file()
                and sha256_file(browser_screenshot)
                == self.browser_proof["screenshot_sha256"],
                "actual dashboard inspector renders one complete typed run with expanded input/output",
            ),
            "poc_execution_proof_observed": (
                successful_windowed_tool("builder-a", "poc-implement", "tool_write_file")
                and windowed_execute_output_contains(
                    "builder-a", "poc-implement", self.poc_output_token
                )
                and text_contains(board, f"POC_EXECUTED={self.marker}-executed"),
                "builder-a wrote the artifact, a durable Execute row carries the "
                "expected output token, and the Board claim quotes that execution",
            ),
            "poc_review_cites_execution": (
                text_contains(board, f"POC_REVIEW_CONFIRMS={self.marker}-executed")
                and successful_windowed_tool(
                    "reviewer", "poc-review", "masc_board_comment"
                ),
                "reviewer's own comment quotes the executed output token read "
                "from the Board",
            ),
            "claim_measurement_executed": (
                successful_windowed_tool(
                    "builder-a", "claim-measure", "tool_write_file"
                )
                and windowed_execute_output_contains(
                    "builder-a",
                    "claim-measure",
                    f"LEADING_ONE_COUNT={self.claim_expected}",
                )
                and text_contains(
                    board, f"CLAIM_MEASURED={self.claim_expected}"
                ),
                "builder-a wrote the measurement, a durable Execute row "
                f"carries LEADING_ONE_COUNT={self.claim_expected} (the "
                "evaluator's independent Fibonacci/Benford count over "
                f"{self.claim_fib_count} terms — never present in any "
                "prompt), and the Board claim quotes that execution",
            ),
            "claim_verdict_cites_measurement": (
                text_contains(
                    board, f"CLAIM_VERDICT_CITES={self.claim_expected}"
                )
                and successful_windowed_tool(
                    "reviewer", "claim-verdict", "masc_board_comment"
                ),
                "reviewer's own comment quotes the measured count read from "
                "the Board, matching the evaluator's independent expectation",
            ),
            "debate_restatement_faithful": (
                text_contains(
                    board, f"DEBATE_RESTATE={self.debate_claim_token}"
                )
                and successful_windowed_tool(
                    "builder-b", "debate-rebut", "masc_board_comment"
                )
                and text_contains(
                    board, f"DEBATE_REBUTTAL={self.debate_rebuttal_token}"
                ),
                "builder-b restated the exact claim token (absent from its "
                "prompt, readable only on the Board) before rebutting",
            ),
            "qa_coverage_execution_observed": (
                successful_windowed_tool(
                    "builder-a", "qa-implement", "tool_write_file"
                )
                and all(
                    windowed_execute_output_contains(
                        "builder-b", "qa-test", expected
                    )
                    for _, _, expected in self.qa_cases
                ),
                "every declared case produced its transformed result in "
                "builder-b's durable Execute output, not only in a claim: ran="
                + ",".join(
                    name
                    for name, _, expected in self.qa_cases
                    if windowed_execute_output_contains(
                        "builder-b", "qa-test", expected
                    )
                )
                + " declared="
                + ",".join(name for name, _, _ in self.qa_cases),
            ),
            "qa_coverage_passes_verification": (
                all(
                    successful_windowed_tool(role, label, tool)
                    for role, label in (
                        ("builder-a", "qa-implement"),
                        ("builder-b", "qa-test"),
                    )
                    for tool in ("keeper_task_claim", "keeper_task_done")
                )
                and all(passed for passed, _ in qa_verdicts),
                "implementer and tester each claimed their own Task on the "
                "shared Goal, submitted evidence through keeper_task_done, and "
                "an independent completion authority carried both from "
                "awaiting_verification to done: "
                + " ".join(detail for _, detail in qa_verdicts),
            ),
            "qa_coverage_review_matches_spec": (
                text_contains(board, "QA_COVERAGE_VERDICT=COMPLETE:")
                and all(
                    text_contains(board, expected)
                    for _, _, expected in self.qa_cases
                )
                and successful_windowed_tool(
                    "reviewer", "qa-review", "masc_board_comment"
                ),
                "reviewer compared the declared scope against the run and "
                "reported COMPLETE quoting every transformed result read from "
                "the Board",
            ),
            "debate_verdict_cites_rebuttal": (
                text_contains(
                    board, f"DEBATE_VERDICT_CITES={self.debate_rebuttal_token}"
                )
                and successful_windowed_tool(
                    "reviewer", "debate-verdict", "masc_board_comment"
                ),
                "reviewer's verdict quotes the rebuttal token (absent from its "
                "prompt, readable only on the Board)",
            ),
            "goal_verifier_refutation_observed": (
                isinstance(goal_verifier_refuted, dict)
                and goal_verifier_refuted.get("phase") == "executing"
                and isinstance(goal_verifier_refuted_run, str)
                and text_contains(goal_verifier_refuted, "proof_refuted")
                and text_contains(
                    goal_verifier_runs_by_id.get(goal_verifier_refuted_run),
                    self.verifier_artifact,
                ),
                f"goal={self.verifier_goal_id} refuted_run={goal_verifier_refuted_run}",
            ),
            "goal_verifier_reentry_proven": (
                isinstance(goal_verifier_proven, dict)
                and goal_verifier_proven.get("phase") == "completed"
                and isinstance(goal_verifier_proven_run, str)
                and goal_verifier_proven_run != goal_verifier_refuted_run
                and text_contains(goal_verifier_proven, "proof_proven")
                and text_contains(goal_verifier_proven, self.verifier_success_token)
                and text_contains(
                    goal_verifier_runs_by_id.get(goal_verifier_proven_run),
                    self.verifier_artifact,
                ),
                f"goal={self.verifier_goal_id} proven_run={goal_verifier_proven_run}",
            ),
            "goal_verifier_dashboard_browser_observed": (
                self.goal_verifier_browser_proof.get("schema")
                == "masc.goal_verification_browser_evidence.v1"
                and self.goal_verifier_browser_proof.get("goal_id")
                == self.verifier_goal_id
                and self.goal_verifier_browser_proof.get("run_id")
                == goal_verifier_proven_run
                and self.goal_verifier_browser_proof.get("status") == "committed"
                and self.goal_verifier_browser_proof.get("review_kind") == "proof"
                and self.goal_verifier_browser_proof.get("artifact_tool_visible")
                is True
                and isinstance(
                    self.goal_verifier_browser_proof.get("screenshot_sha256"),
                    str,
                )
                and len(self.goal_verifier_browser_proof["screenshot_sha256"])
                == 64
                and (
                    self.writer.output_dir
                    / "browser"
                    / "goal-verification-run-proof.png"
                ).is_file()
                and sha256_file(
                    self.writer.output_dir
                    / "browser"
                    / "goal-verification-run-proof.png"
                )
                == self.goal_verifier_browser_proof["screenshot_sha256"],
                "real-backend browser expanded the exact proven Goal run and "
                "rendered verification_read_file evidence",
            ),
        }
        malformed = [
            name
            for name, value in checks.items()
            if not isinstance(value, tuple) or len(value) != 2
        ]
        if malformed:
            raise AcceptanceError(f"assertion definitions are malformed: {malformed}")
        return {
            name: {"passed": passed, "detail": detail}
            for name, (passed, detail) in checks.items()
        }

    def run(self) -> tuple[str, dict[str, dict[str, Any]]]:
        self.create_fleet()
        self.wait_for_fleet()
        post_id = self.setup_product_state()
        self.run_parallel_wave(post_id)
        self.run_contention(post_id)
        self.run_failure_recovery(post_id)
        self.run_poc_delivery(post_id)
        self.run_claim_reproduction(post_id)
        self.run_debate(post_id)
        self.run_qa_coverage(post_id)
        self.run_goal_verifier_refute_reenter_prove()
        self.run_continuity_chain(post_id)
        self.restart_and_recall(post_id)
        self.wait_for_async_sources()
        self.collect_product_observations(post_id)
        self.capture_browser_proof()
        return post_id, self.evaluate_assertions(post_id)


def bundle_markdown(bundle: dict[str, Any]) -> str:
    lines = [
        "# Keeper Multi-Collaboration Real-World Acceptance",
        "",
        f"- Run ID: `{bundle['run_id']}`",
        f"- Mission marker: `{bundle['mission_marker']}`",
        f"- Source SHA: `{bundle['source_sha']}`",
        f"- Effective base path: `{bundle['effective_base_path']}`",
        f"- Status: **{bundle['status']}** ({bundle['passed_count']}/{bundle['scenario_count']})",
        f"- Bundle ID: `{bundle['bundle_id']}`",
        "- Approach A: **not executed by this runner** (hermetic CI remains separate)",
        "- Approach B: **"
        + next(
            row["status"]
            for row in bundle["approach_results"]
            if row["id"] == "B"
        )
        + "** (this isolated real-world run)",
        "- Approach C: **not executed by this runner** (duration canary remains separate)",
        "",
        "| ID | Real-world mission | Status | Failed assertions |",
        "|---|---|---|---|",
    ]
    for mission in bundle["missions"]:
        failed = [
            assertion["name"]
            for assertion in mission["assertions"]
            if not assertion["passed"]
        ]
        lines.append(
            f"| {mission['id']} | {mission['name']} | {mission['status']} | "
            f"{', '.join(failed) if failed else '-'} |"
        )
    lines.extend(
        [
            "",
            "A pass is product-state evidence from an isolated deployed runtime. CI build or unit-test status is not substituted for these missions.",
            "",
        ]
    )
    return "\n".join(lines)


def build_bundle(
    *,
    catalog: dict[str, Any],
    run: MissionRun,
    assertions: dict[str, dict[str, Any]],
    preflight_result: dict[str, Any],
    health: dict[str, Any],
    output_dir: pathlib.Path,
    post_id: str,
) -> dict[str, Any]:
    missing_pre_bundle_evidence: list[str] = []
    for mission in catalog["missions"]:
        for pattern in mission["evidence"]:
            if pattern in {"bundle.json", "bundle.md"}:
                continue
            if not any(path.is_file() for path in output_dir.glob(pattern)):
                missing_pre_bundle_evidence.append(f"{mission['id']}:{pattern}")
    if missing_pre_bundle_evidence:
        assertions["artifact_bundle_complete"] = {
            "passed": False,
            "detail": "missing evidence: " + ", ".join(missing_pre_bundle_evidence),
        }
    missions = []
    for mission in catalog["missions"]:
        routed = [
            {"name": name, **assertions[name]} for name in mission["assertions"]
        ]
        passed = all(row["passed"] for row in routed)
        approach_results = [
            {
                "id": approach["id"],
                "name": approach["name"],
                "status": (
                    ("passed" if passed else "failed")
                    if approach["id"] == "B"
                    else "not_executed_by_this_runner"
                ),
                "required_evidence": approach["required_evidence"],
            }
            for approach in catalog["execution_approaches"]
        ]
        missions.append(
            {
                "id": mission["id"],
                "name": mission["name"],
                "phase": mission["phase"],
                "actors": mission["actors"],
                "capabilities": mission["capabilities"],
                "user_story": mission["user_story"],
                "status": "passed" if passed else "failed",
                "assertions": routed,
                "evidence": mission["evidence"],
                "approaches": approach_results,
            }
        )
    passed_count = sum(mission["status"] == "passed" for mission in missions)
    seed = {
        "source_sha": health_binary_commit(health),
        "runner_source_sha": source_sha(),
        "run_id": run.run_id,
        "marker": run.marker,
        "missions": [(row["id"], row["status"]) for row in missions],
    }
    bundle_id = sha256_bytes(json_bytes(seed))
    artifact_manifest = [
        {
            "path": str(path.relative_to(output_dir)),
            "sha256": sha256_file(path),
            "bytes": path.stat().st_size,
        }
        for path in sorted(output_dir.rglob("*"))
        if path.is_file() and path.name not in {"bundle.json", "bundle.md"}
    ]
    return {
        "schema": SCHEMA,
        "acceptance_authority": catalog["acceptance_authority"],
        "generated_at": utc_now(),
        "run_id": run.run_id,
        "mission_marker": run.marker,
        "source_sha": health_binary_commit(health),
        "runner_source_sha": source_sha(),
        "bundle_id": bundle_id,
        "status": "passed" if passed_count == len(missions) else "failed",
        "scenario_count": len(missions),
        "passed_count": passed_count,
        "approach_results": [
            {
                "id": approach["id"],
                "name": approach["name"],
                "status": (
                    (
                        "passed"
                        if passed_count == len(missions)
                        else "failed"
                    )
                    if approach["id"] == "B"
                    else "not_executed_by_this_runner"
                ),
                "method": approach["method"],
                "required_evidence": approach["required_evidence"],
            }
            for approach in catalog["execution_approaches"]
        ],
        "effective_base_path": health_base_path(health),
        "effective_masc_root": health_masc_root(health),
        "preflight": preflight_result,
        "resources": {
            "keepers": run.roles,
            **runtime_strategy_receipt(
                runtime_id=run.runtime_id,
                runtime_by_role=run.runtime_by_role,
                require_heterogeneous=run.require_heterogeneous_runtimes,
                roles=set(run.roles),
            ),
            "goal_id": run.goal_id,
            "goal_verifier_goal_id": run.verifier_goal_id,
            "goal_verifier_task_id": run.verifier_task_id,
            "task_ids": run.task_ids,
            "board_post_id": post_id,
            "schedule_id": run.schedule_id,
        },
        "missions": missions,
        "artifacts": artifact_manifest,
        "artifact_root": str(output_dir),
    }


def verify_bundle(
    *,
    catalog: dict[str, Any],
    output_dir: pathlib.Path,
    expected_base_path: str | None,
    expected_source_sha: str | None,
) -> dict[str, Any]:
    bundle_path = output_dir / "bundle.json"
    if not bundle_path.is_file():
        raise AcceptanceError(f"missing real-world bundle: {bundle_path}")
    try:
        bundle = json.loads(bundle_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise AcceptanceError(f"invalid bundle JSON: {error}") from error
    errors: list[str] = []
    if bundle.get("schema") != SCHEMA:
        errors.append("schema mismatch")
    if bundle.get("acceptance_authority") != "real_world_product_outcomes":
        errors.append("acceptance authority mismatch")
    expected_ids = [mission["id"] for mission in catalog["missions"]]
    missions = bundle.get("missions") or []
    actual_ids = [mission.get("id") for mission in missions]
    if actual_ids != expected_ids:
        errors.append(f"mission ids mismatch: {actual_ids!r}")
    if bundle.get("scenario_count") != len(expected_ids):
        errors.append("scenario count mismatch")
    expected_approach_ids = ["A", "B", "C"]
    approach_results = bundle.get("approach_results")
    if (
        not isinstance(approach_results, list)
        or [row.get("id") for row in approach_results] != expected_approach_ids
        or [row.get("status") for row in approach_results]
        != ["not_executed_by_this_runner", "passed", "not_executed_by_this_runner"]
    ):
        errors.append("bundle A/B/C approach results are missing or conflated")
    for mission in missions:
        approaches = mission.get("approaches")
        if (
            not isinstance(approaches, list)
            or [row.get("id") for row in approaches] != expected_approach_ids
            or [row.get("status") for row in approaches]
            != [
                "not_executed_by_this_runner",
                mission.get("status"),
                "not_executed_by_this_runner",
            ]
        ):
            errors.append(
                f"mission {mission.get('id')} A/B/C results are missing or conflated"
            )
    passed_count = sum(mission.get("status") == "passed" for mission in missions)
    if bundle.get("passed_count") != passed_count:
        errors.append("passed count mismatch")
    if passed_count != len(expected_ids) or bundle.get("status") != "passed":
        errors.append(
            f"real-world status is not complete: {passed_count}/{len(expected_ids)}"
        )
    if expected_source_sha:
        if bundle.get("source_sha") != expected_source_sha:
            errors.append("bundle runtime binary SHA does not match expected source SHA")
        if bundle.get("runner_source_sha") != expected_source_sha:
            errors.append("bundle runner SHA does not match expected source SHA")
    if expected_base_path and bundle.get("effective_base_path") != expected_base_path:
        errors.append("bundle effective base path mismatch")
    resources = bundle.get("resources")
    runtime_by_role = (
        resources.get("runtime_by_role") if isinstance(resources, dict) else None
    )
    runtime_strategy = (
        resources.get("runtime_strategy") if isinstance(resources, dict) else None
    )
    valid_runtime_map = (
        isinstance(runtime_by_role, dict)
        and set(runtime_by_role) == EXPECTED_ROLES
        and all(
            isinstance(runtime_id, str) and bool(runtime_id.strip())
            for runtime_id in runtime_by_role.values()
        )
    )
    distinct_runtime_count = (
        len(set(runtime_by_role.values())) if valid_runtime_map else 0
    )
    if not valid_runtime_map:
        errors.append("bundle runtime map does not name all five roles")
    if isinstance(resources, dict) and resources.get("distinct_runtime_count") != distinct_runtime_count:
        errors.append("bundle distinct runtime count mismatch")
    if runtime_strategy not in {
        "shared_runtime",
        "role_map",
        "heterogeneous_required",
    }:
        errors.append(f"unknown runtime strategy: {runtime_strategy!r}")
    if runtime_strategy == "heterogeneous_required" and distinct_runtime_count != len(
        EXPECTED_ROLES
    ):
        errors.append(
            "heterogeneous runtime strategy does not contain five distinct runtimes"
        )
    if runtime_strategy == "shared_runtime" and distinct_runtime_count != 1:
        errors.append("shared runtime strategy does not contain one runtime id")
    artifacts = bundle.get("artifacts") or []
    if len(artifacts) < 20:
        errors.append("artifact manifest is unexpectedly small")
    manifest_paths: list[str] = []
    for artifact in artifacts:
        relative = artifact.get("path")
        if not isinstance(relative, str) or relative.startswith("/") or ".." in pathlib.PurePosixPath(relative).parts:
            errors.append(f"unsafe artifact path: {relative!r}")
            continue
        manifest_paths.append(relative)
        path = output_dir / relative
        if not path.is_file():
            errors.append(f"missing artifact: {relative}")
            continue
        if sha256_file(path) != artifact.get("sha256"):
            errors.append(f"artifact digest mismatch: {relative}")
        if path.stat().st_size != artifact.get("bytes"):
            errors.append(f"artifact size mismatch: {relative}")
    if len(manifest_paths) != len(set(manifest_paths)):
        errors.append("artifact manifest contains duplicate paths")
    actual_artifacts = {
        str(path.relative_to(output_dir))
        for path in output_dir.rglob("*")
        if path.is_file() and path.name not in {"bundle.json", "bundle.md"}
    }
    if set(manifest_paths) != actual_artifacts:
        errors.append("artifact manifest does not exactly cover evidence files")
    for mission in catalog["missions"]:
        for pattern in mission["evidence"]:
            pure_pattern = pathlib.PurePosixPath(pattern)
            if pure_pattern.is_absolute() or ".." in pure_pattern.parts:
                errors.append(f"unsafe catalog evidence pattern: {pattern!r}")
                continue
            if not any(path.is_file() for path in output_dir.glob(pattern)):
                errors.append(
                    f"missing catalog evidence for {mission['id']}: {pattern}"
                )
    # The role-map assertion used to sit inside the persistence proof's else
    # branch, so a missing proof file skipped it silently. It is about the
    # bundle's own resources and runs on its own now.
    resources = bundle.get("resources")
    keepers = resources.get("keepers") if isinstance(resources, dict) else None
    exact_role_map = (
        isinstance(keepers, dict)
        and set(keepers) == EXPECTED_ROLES
        and all(
            isinstance(value, str) and bool(value.strip())
            for value in keepers.values()
        )
        and len(set(keepers.values())) == len(EXPECTED_ROLES)
    )
    if not exact_role_map:
        errors.append("bundle resources do not name five distinct exact role Keepers")
    goal_proof_path = output_dir / "browser" / "goal-verification-run-proof.json"
    goal_screenshot_path = output_dir / "browser" / "goal-verification-run-proof.png"
    proven_goal_path = output_dir / "observations" / "goal-verifier-proven.json"
    try:
        goal_proof = json.loads(goal_proof_path.read_text(encoding="utf-8"))
        proven_goal = json.loads(proven_goal_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        errors.append(f"Goal verifier browser/ledger proof is unreadable: {error}")
    else:
        resources = bundle.get("resources")
        expected_goal_id = (
            resources.get("goal_verifier_goal_id")
            if isinstance(resources, dict)
            else None
        )
        verification = (
            proven_goal.get("verification")
            if isinstance(proven_goal, dict)
            else None
        )
        completion = (
            verification.get("completion")
            if isinstance(verification, dict)
            else None
        )
        verdict = (
            completion.get("verdict") if isinstance(completion, dict) else None
        )
        expected_run_id = (
            verdict.get("verification_run_id")
            if isinstance(verdict, dict)
            else None
        )
        if (
            goal_proof.get("schema")
            != "masc.goal_verification_browser_evidence.v1"
            or not isinstance(expected_goal_id, str)
            or goal_proof.get("goal_id") != expected_goal_id
            or not isinstance(expected_run_id, str)
            or goal_proof.get("run_id") != expected_run_id
            or goal_proof.get("status") != "committed"
            or goal_proof.get("review_kind") != "proof"
            or goal_proof.get("artifact_tool_visible") is not True
            or not goal_screenshot_path.is_file()
            or goal_proof.get("screenshot_sha256")
            != sha256_file(goal_screenshot_path)
        ):
            errors.append("Goal verifier browser proof does not match ledger run identity")
    seed = {
        "source_sha": bundle.get("source_sha"),
        "runner_source_sha": bundle.get("runner_source_sha"),
        "run_id": bundle.get("run_id"),
        "marker": bundle.get("mission_marker"),
        "missions": [(row.get("id"), row.get("status")) for row in missions],
    }
    if bundle.get("bundle_id") != sha256_bytes(json_bytes(seed)):
        errors.append("bundle id does not match its identity/status seed")
    if errors:
        raise AcceptanceError("; ".join(errors))
    return {
        "status": "passed",
        "bundle_id": bundle.get("bundle_id"),
        "source_sha": bundle.get("source_sha"),
        "mission_count": len(expected_ids),
        "artifact_count": len(artifacts),
        "effective_base_path": bundle.get("effective_base_path"),
    }


def read_token(args: argparse.Namespace) -> str:
    if args.token_file:
        return pathlib.Path(args.token_file).read_text(encoding="utf-8").strip()
    return os.environ.get("MCP_TOKEN", "").strip()


def prepare_output_dir(path: pathlib.Path) -> None:
    if path.exists():
        if not path.is_dir():
            raise AcceptanceError(f"output path exists and is not a directory: {path}")
        if any(path.iterdir()):
            raise AcceptanceError(f"output directory must be empty: {path}")
    else:
        path.mkdir(parents=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--validate-catalog", action="store_true")
    mode.add_argument("--verify", action="store_true")
    mode.add_argument("--preflight", action="store_true")
    mode.add_argument("--run", action="store_true")
    parser.add_argument("--catalog", default=str(DEFAULT_CATALOG))
    parser.add_argument("--mcp-url", default=os.environ.get("MCP_URL", "http://127.0.0.1:8935/mcp"))
    parser.add_argument("--health-url")
    parser.add_argument("--token-file")
    parser.add_argument("--browser-proof-script")
    parser.add_argument("--expected-base-path")
    parser.add_argument("--expected-source-sha")
    parser.add_argument("--allow-mutation", action="store_true")
    parser.add_argument("--runtime-id")
    parser.add_argument("--runtime-by-role-json")
    parser.add_argument("--require-heterogeneous-runtimes", action="store_true")
    parser.add_argument("--run-id")
    parser.add_argument("--output-dir")
    parser.add_argument("--timeout", type=float, default=150.0)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        catalog = load_catalog(pathlib.Path(args.catalog))
        runtime_by_role = parse_runtime_by_role(args.runtime_by_role_json)
        validate_runtime_strategy(
            runtime_id=args.runtime_id,
            runtime_by_role=runtime_by_role,
            require_heterogeneous=args.require_heterogeneous_runtimes,
        )
        if args.validate_catalog:
            print(
                json.dumps(
                    {
                        "status": "passed",
                        "catalog": str(pathlib.Path(args.catalog)),
                        "mission_count": len(catalog["missions"]),
                        "assertion_count": len(KNOWN_ASSERTIONS),
                        "approach_ids": [
                            approach["id"]
                            for approach in catalog["execution_approaches"]
                        ],
                        "acceptance_authority": catalog["acceptance_authority"],
                    },
                    ensure_ascii=False,
                    indent=2,
                )
            )
            return 0

        if args.verify:
            if not args.output_dir:
                raise AcceptanceError("--verify requires --output-dir")
            if not args.expected_base_path:
                raise AcceptanceError("--verify requires exact --expected-base-path")
            if not args.expected_source_sha:
                raise AcceptanceError("--verify requires exact --expected-source-sha")
            result = verify_bundle(
                catalog=catalog,
                output_dir=pathlib.Path(args.output_dir).resolve(),
                expected_base_path=args.expected_base_path,
                expected_source_sha=args.expected_source_sha,
            )
            print(json.dumps(result, ensure_ascii=False, indent=2))
            return 0

        token = read_token(args)
        health_url = args.health_url or default_health_url(args.mcp_url)
        client, health, preflight_result = preflight(
            catalog=catalog,
            mcp_url=args.mcp_url,
            health_url=health_url,
            token=token,
            timeout=args.timeout,
            expected_base_path=args.expected_base_path,
            expected_source_sha=args.expected_source_sha,
        )
        if args.preflight:
            print(json.dumps(preflight_result, ensure_ascii=False, indent=2))
            return 0

        if not args.allow_mutation:
            raise AcceptanceError("--run requires explicit --allow-mutation")
        runtime_receipt = runtime_strategy_receipt(
            runtime_id=args.runtime_id,
            runtime_by_role=runtime_by_role,
            require_heterogeneous=args.require_heterogeneous_runtimes,
        )
        if not args.expected_base_path:
            raise AcceptanceError("--run requires exact --expected-base-path")
        if not args.expected_source_sha:
            raise AcceptanceError("--run requires exact --expected-source-sha")
        if not args.output_dir:
            raise AcceptanceError("--run requires --output-dir")
        if not args.token_file:
            raise AcceptanceError("--run requires --token-file")
        if not args.browser_proof_script:
            raise AcceptanceError("--run requires --browser-proof-script")
        output_dir = pathlib.Path(args.output_dir).resolve()
        prepare_output_dir(output_dir)
        writer = EvidenceWriter(output_dir)
        writer.write_json("health.json", health)
        writer.write_json("preflight.json", preflight_result)
        run_id = args.run_id or dt.datetime.now(dt.timezone.utc).strftime(
            "rw-%Y%m%d-%H%M%S"
        )
        mission_run = MissionRun(
            catalog=catalog,
            client=client,
            writer=writer,
            endpoint=args.mcp_url,
            token=token,
            timeout=args.timeout,
            run_id=run_id,
            runtime_id=args.runtime_id,
            runtime_by_role=runtime_by_role,
            require_heterogeneous_runtimes=args.require_heterogeneous_runtimes,
            token_file=pathlib.Path(args.token_file).resolve(),
            browser_proof_script=pathlib.Path(args.browser_proof_script).resolve(),
            expected_base_path=args.expected_base_path,
        )
        try:
            post_id, assertions = mission_run.run()
        except Exception as error:
            writer.write_json(
                "fatal.json",
                {
                    "schema": SCHEMA,
                    "status": "failed",
                    "failed_at": utc_now(),
                    "run_id": run_id,
                    "mission_marker": mission_run.marker,
                    "source_sha": health_binary_commit(health),
                    "runner_source_sha": source_sha(),
                    "effective_base_path": health_base_path(health),
                    "error": str(error),
                    "completed_turns": {
                        label: dataclasses.asdict(turn)
                        for label, turn in mission_run.turns.items()
                    },
                    "resources": {
                        "keepers": mission_run.roles,
                        **runtime_receipt,
                        "goal_id": mission_run.goal_id,
                        "task_ids": mission_run.task_ids,
                        "schedule_id": mission_run.schedule_id,
                    },
                },
            )
            raise AcceptanceError(
                f"real-world mission aborted; inspect {output_dir / 'fatal.json'}: {error}"
            ) from error
        writer.write_json("assertions.json", assertions)
        bundle = build_bundle(
            catalog=catalog,
            run=mission_run,
            assertions=assertions,
            preflight_result=preflight_result,
            health=health,
            output_dir=output_dir,
            post_id=post_id,
        )
        writer.write_json("bundle.json", bundle)
        (output_dir / "bundle.md").write_text(
            bundle_markdown(bundle), encoding="utf-8"
        )
        verify_bundle(
            catalog=catalog,
            output_dir=output_dir,
            expected_base_path=args.expected_base_path,
            expected_source_sha=args.expected_source_sha,
        )
        print(json.dumps(bundle, ensure_ascii=False, indent=2))
        return 0 if bundle["status"] == "passed" else 1
    except AcceptanceError as error:
        print(f"keeper-multi-collaboration-acceptance: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
