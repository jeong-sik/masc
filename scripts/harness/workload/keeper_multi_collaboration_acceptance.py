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
import tomllib
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
COMPOSITION_FIXTURE = (
    REPO_ROOT
    / "scripts"
    / "fixtures"
    / "keeper-multi-collaboration"
    / "tool-compositions.toml"
)
SCHEMA = "masc.keeper_multi_collaboration_evidence.v1"
EXPECTED_ROLES = {"coordinator", "builder-a", "builder-b", "reviewer", "researcher"}
TOOL_ALIASES = {"tool_write_file": {"tool_write_file", "Write"}}

KNOWN_ASSERTIONS = {
    "all_keepers_live",
    "role_identity_preserved",
    "goal_visible",
    "goal_assignment_visible",
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
    "persistence_tiers_dashboard_projection_observed",
}


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


def validate_persistence_browser_evidence(
    proof: Any,
    screenshot_path: pathlib.Path,
    expected_keepers: set[str],
) -> tuple[bool, str]:
    errors: list[str] = []
    if not isinstance(proof, dict):
        return False, "persistence browser proof is not an object"
    if proof.get("schema") != "masc.keeper_persistence_browser_evidence.v1":
        errors.append("schema mismatch")
    generated_at = proof.get("generated_at")
    if not isinstance(generated_at, str) or not generated_at:
        errors.append("generated_at is absent")
    else:
        try:
            dt.datetime.fromisoformat(generated_at.replace("Z", "+00:00"))
        except ValueError:
            errors.append("generated_at is invalid")
    if proof.get("interaction") != "manual_refresh":
        errors.append("manual refresh was not observed")
    if not expected_keepers:
        errors.append("expected Keeper fleet is absent")
    tiers = proof.get("tiers")
    if not isinstance(tiers, list) or len(tiers) != 4:
        errors.append("duration tiers must be an exact four-element list")
        tiers = []
    if all(isinstance(tier, dict) for tier in tiers):
        if [tier.get("id") for tier in tiers] != ["1h", "2h", "4h", "24h"]:
            errors.append("duration tier ids are not exact and ordered")
        previous_observed: set[str] | None = None
        previous_missing: set[str] | None = None
        for tier in tiers:
            status = tier.get("status")
            evidence_kind = tier.get("evidence_kind")
            observed_count = tier.get("observed_count")
            keeper_count = tier.get("keeper_count")
            missing_count = tier.get("missing_count")
            observed_names = tier.get("observed_keepers")
            missing_names = tier.get("missing_keepers")
            if status not in {"pass", "warn", "fail"}:
                errors.append(f"tier {tier.get('id')} status is invalid")
            if evidence_kind != "durable_turn_span":
                errors.append(f"tier {tier.get('id')} evidence kind is invalid")
            counts = (observed_count, keeper_count, missing_count)
            if not all(type(value) is int and value >= 0 for value in counts):
                errors.append(f"tier {tier.get('id')} counts are invalid")
                continue
            if not isinstance(observed_names, list) or not isinstance(missing_names, list):
                errors.append(f"tier {tier.get('id')} Keeper identities are absent")
                continue
            if not all(isinstance(name, str) and bool(name.strip()) for name in observed_names + missing_names):
                errors.append(f"tier {tier.get('id')} Keeper identities are invalid")
                continue
            observed = set(observed_names)
            missing = set(missing_names)
            if len(observed) != len(observed_names) or len(missing) != len(missing_names):
                errors.append(f"tier {tier.get('id')} Keeper identities contain duplicates")
            if observed & missing or observed | missing != expected_keepers:
                errors.append(f"tier {tier.get('id')} does not describe the exact run fleet")
            if len(observed) != observed_count or len(missing) != missing_count:
                errors.append(f"tier {tier.get('id')} counts do not match identities")
            if observed_count + missing_count != keeper_count or keeper_count != len(expected_keepers):
                errors.append(f"tier {tier.get('id')} Keeper total is inconsistent")
            derived_status = (
                "fail"
                if keeper_count == 0 or observed_count == 0
                else "pass"
                if observed_count == keeper_count
                else "warn"
            )
            if status != derived_status:
                errors.append(f"tier {tier.get('id')} status disagrees with counts")
            if previous_observed is not None and previous_missing is not None and (
                not observed <= previous_observed or not missing >= previous_missing
            ):
                errors.append(f"tier {tier.get('id')} violates duration monotonicity")
            previous_observed = observed
            previous_missing = missing
    elif tiers:
        errors.append("duration tiers contain non-object values")
    screenshot_digest = proof.get("screenshot_sha256")
    if proof.get("screenshot_file") != "keeper-persistence-proof.png":
        errors.append("screenshot filename is invalid")
    if not isinstance(screenshot_digest, str) or re.fullmatch(r"[0-9a-f]{64}", screenshot_digest) is None:
        errors.append("screenshot digest is invalid")
    elif not screenshot_path.is_file():
        errors.append("screenshot is absent")
    else:
        if sha256_file(screenshot_path) != screenshot_digest:
            errors.append("screenshot digest mismatch")
        if proof.get("screenshot_bytes") != screenshot_path.stat().st_size:
            errors.append("screenshot byte count mismatch")
    return not errors, "; ".join(errors) if errors else "exact refreshed persistence projection and screenshot verified"


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
            raise AcceptanceError(f"MCP transport failed: {error}") from error
        value = self._decode_response(body, request_id)
        if value.get("error") is not None:
            raise AcceptanceError(
                f"MCP {method} JSON-RPC error: {json.dumps(value['error'], ensure_ascii=False)}"
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
    if not isinstance(missions, list) or len(missions) != 19:
        raise AcceptanceError("mission catalog must contain exactly 19 missions")
    ids = [mission.get("id") for mission in missions]
    expected_ids = [f"RW{index:02d}" for index in range(1, 20)]
    if ids != expected_ids:
        raise AcceptanceError("mission ids must be ordered exactly RW01 through RW19")
    roles = catalog.get("roles")
    if not isinstance(roles, list) or set(roles) != EXPECTED_ROLES:
        raise AcceptanceError("catalog must define the exact five collaboration roles")
    if catalog.get("minimum_keeper_count") != len(roles):
        raise AcceptanceError("minimum_keeper_count must equal the five-role fleet")
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


def default_health_url(mcp_url: str) -> str:
    parsed = urllib.parse.urlsplit(mcp_url)
    return urllib.parse.urlunsplit(
        (parsed.scheme, parsed.netloc, "/health", "full=1", "")
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


def composition_catalog_status(masc_root: str) -> dict[str, Any]:
    """Compare the composition names this campaign's fixture requires against
    the catalog installed at the deployed runtime's config root.

    keeper_compose_* tools are a config-driven surface: Keeper_run_tools_setup
    reads <config_root>/tool-compositions.toml on every turn, so a missing or
    incomplete file makes every composition mission fail eight minutes in with
    a downstream browser timeout instead of failing here (masc#28975, run
    e0-r3-20260818). The runner and the runtime share a host by the
    --expected-base-path contract, so reading the file the server reads is a
    legitimate read-only preflight check."""
    with open(COMPOSITION_FIXTURE, "rb") as handle:
        fixture = tomllib.load(handle)
    required = sorted(
        entry["name"] for entry in fixture.get("compositions", [])
    )
    installed_path = pathlib.Path(masc_root) / "config" / "tool-compositions.toml"
    report: dict[str, Any] = {
        "required": required,
        "installed_path": str(installed_path),
        "fixture_path": str(COMPOSITION_FIXTURE),
    }
    if not installed_path.is_file():
        report["status"] = "missing_file"
        report["installed"] = []
        report["missing"] = required
        return report
    try:
        with open(installed_path, "rb") as handle:
            installed_catalog = tomllib.load(handle)
    except tomllib.TOMLDecodeError as error:
        report["status"] = "unparseable"
        report["error"] = str(error)
        return report
    installed = sorted(
        name
        for entry in installed_catalog.get("compositions", [])
        if isinstance(entry, dict)
        for name in [entry.get("name")]
        if isinstance(name, str)
    )
    missing = sorted(set(required) - set(installed))
    report["installed"] = installed
    report["missing"] = missing
    report["status"] = "ok" if not missing else "missing_names"
    return report


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
    compositions = composition_catalog_status(health_masc_root(health))
    result = {
        "status": (
            "passed" if not missing and compositions["status"] == "ok" else "failed"
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
        "composition_catalog": compositions,
    }
    if missing:
        raise AcceptanceError(f"deployed runtime is missing operator tools: {missing}")
    if compositions["status"] != "ok":
        raise AcceptanceError(
            "composition catalog is not installed for this campaign: "
            f"status={compositions['status']} missing={compositions.get('missing')} — "
            f"install {compositions['fixture_path']} at {compositions['installed_path']}"
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
        self.slug = safe_slug(run_id, 16)
        self.marker = f"keeper-collab-{self.slug}"
        self.runtime_id = runtime_id
        self.token_file = token_file
        self.browser_proof_script = browser_proof_script
        self.expected_base_path = expected_base_path
        self.secret = f"memory-{uuid.uuid4().hex[:12]}"
        self.goal_id = f"goal-{self.marker}"
        self.schedule_id = f"schedule-{self.marker}"
        self.roles = {
            "coordinator": f"rw-{self.slug}-coord",
            "builder-a": f"rw-{self.slug}-build-a",
            "builder-b": f"rw-{self.slug}-build-b",
            "reviewer": f"rw-{self.slug}-review",
            "researcher": f"rw-{self.slug}-research",
        }
        self.task_ids: dict[str, str] = {}
        self.task_create_receipts: dict[str, ToolObservation] = {}
        self.turns: dict[str, TurnObservation] = {}
        self.statuses: dict[str, Any] = {}
        self.observations: dict[str, ToolObservation] = {}
        self.tool_call_rows: dict[str, list[dict[str, Any]]] = {}
        self.browser_proof: dict[str, Any] = {}
        self.persistence_browser_proof: dict[str, Any] = {}

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
            }
            if self.runtime_id:
                arguments["runtime_id"] = self.runtime_id
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
        self.call(
            "goal-assign",
            "masc_goal_assign",
            {"goal_id": self.goal_id, "owner": self.roles["coordinator"]},
        )
        for role, keeper in self.roles.items():
            arguments: dict[str, Any] = {
                "name": keeper,
                "active_goal_ids": [self.goal_id],
            }
            if self.runtime_id:
                arguments["runtime_id"] = self.runtime_id
            self.call(f"keeper-goal-scope-{role}", "masc_keeper_up", arguments)

        task_specs = {
            "builder-a": "Build the first durable collaboration artifact",
            "builder-b": "Build the second durable collaboration artifact",
            "researcher": "Run Fusion and record an advisory collaboration result",
            "reviewer": "Review the shared Board thread and task evidence",
            "contention": "Resolve a single-owner concurrent claim",
            "fallback": "Continue useful work after losing a concurrent claim",
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
                "payload_kind": "masc.keeper_wake",
                "payload_schema_version": 1,
                "payload_body": {
                    "keeper_name": self.roles["coordinator"],
                    "title": f"Scheduled collaboration checkpoint {self.marker}",
                    "message": (
                        f"Scheduled source {self.marker}: inspect Goal {self.goal_id} and "
                        f"comment SCHEDULE_WAKE_OK on Board post {post_id}."
                    ),
                    "urgency": "normal",
                },
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
            }
        )
        completed = subprocess.run(
            ["node", str(self.browser_proof_script)],
            cwd=REPO_ROOT,
            env=environment,
            check=False,
            capture_output=True,
            text=True,
            timeout=120,
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
        self.persistence_browser_proof = read_measurement(
            "keeper-persistence-proof.json"
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
        down_deadline = time.monotonic() + 90.0
        while time.monotonic() < down_deadline:
            status = self.read_status("coordinator", "down-poll")
            if isinstance(status, dict) and not status.get("keepalive_running", False):
                break
            time.sleep(1.0)
        else:
            raise AcceptanceError("coordinator did not stop within 90 seconds")
        arguments: dict[str, Any] = {"name": self.roles["coordinator"]}
        if self.runtime_id:
            arguments["runtime_id"] = self.runtime_id
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
        history_text = json.dumps(histories, ensure_ascii=False)
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
        persistence_browser_screenshot = (
            self.writer.output_dir / "browser" / "keeper-persistence-proof.png"
        )
        persistence_projection_passed, persistence_projection_detail = (
            validate_persistence_browser_evidence(
                self.persistence_browser_proof,
                persistence_browser_screenshot,
                set(self.roles.values()),
            )
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
            "goal_visible": (self.goal_id.lower() in goal_text.lower(), self.goal_id),
            "goal_assignment_visible": (
                self.roles["coordinator"].lower() in goal_text.lower(),
                self.roles["coordinator"],
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
            "persistence_tiers_dashboard_projection_observed": (
                persistence_projection_passed,
                persistence_projection_detail,
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
        "effective_base_path": health_base_path(health),
        "effective_masc_root": health_masc_root(health),
        "preflight": preflight_result,
        "resources": {
            "keepers": run.roles,
            "goal_id": run.goal_id,
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
    persistence_proof_path = output_dir / "browser" / "keeper-persistence-proof.json"
    persistence_screenshot_path = output_dir / "browser" / "keeper-persistence-proof.png"
    try:
        persistence_proof = json.loads(
            persistence_proof_path.read_text(encoding="utf-8")
        )
    except (OSError, json.JSONDecodeError) as error:
        errors.append(f"persistence browser proof is unreadable: {error}")
    else:
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
        expected_keepers = set(keepers.values()) if exact_role_map else set()
        persistence_valid, persistence_detail = validate_persistence_browser_evidence(
            persistence_proof,
            persistence_screenshot_path,
            expected_keepers,
        )
        if not persistence_valid:
            errors.append(f"persistence browser proof is invalid: {persistence_detail}")
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
    parser.add_argument("--run-id")
    parser.add_argument("--output-dir")
    parser.add_argument("--timeout", type=float, default=150.0)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        catalog = load_catalog(pathlib.Path(args.catalog))
        if args.validate_catalog:
            print(
                json.dumps(
                    {
                        "status": "passed",
                        "catalog": str(pathlib.Path(args.catalog)),
                        "mission_count": len(catalog["missions"]),
                        "assertion_count": len(KNOWN_ASSERTIONS),
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
