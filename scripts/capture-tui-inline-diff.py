#!/usr/bin/env python3
"""Capture Keeper chat's compact-to-inline-diff transition without building.

Run this after building the current clean worktree yourself::

    python3 scripts/capture-tui-inline-diff.py \
      --expected-head "$(git rev-parse HEAD)" \
      --target-pr 12345 \
      --executable _build/default/bin/masc_tui.exe

The driver accepts only this worktree's commit-stamped _build executable.
It records that the checkout is clean at capture time; build-time cleanliness
remains an explicit external evidence boundary.
"""

from __future__ import annotations

import argparse
from collections import Counter
from dataclasses import dataclass, field
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import threading
import time
from typing import Any, cast

from playwright.sync_api import Browser, sync_playwright


WORKTREE = Path(__file__).resolve().parents[1]
REPOSITORY = "jeong-sik/masc"
SUPPORT_PATH = WORKTREE / "scripts/capture-tui-keeper-chat.py"
KEYBOARD_PATH = WORKTREE / "test/test_tui_keyboard_input.py"
KEEPER = "alpha"
EXECUTION_ID = "exec-inline-diff-42"
PROVIDER_CALL_ID = "provider-call-decoy-42"
HISTORY_GET = f"/api/v1/keepers/{KEEPER}/chat/history"
MEMORY_GET = f"/api/v1/keepers/{KEEPER}/memory-journal?limit=20"
CHANGES_GET = f"/api/v1/keepers/{KEEPER}/file-changes?window_hours=24"
MCP_POST = "/mcp"
MCP_OBSERVER_GET = "/mcp?sse_kind=observer"
MCP_SESSION_ID = "mcp-inline-diff-session"
FIXTURE_AT = time.time() - 60.0
OPERATOR_REQUEST = "Update lib/runtime_selection.ml and show me what changed."


def load_module(name: str, path: Path) -> Any:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load support: {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return cast(Any, module)


support = load_module("tui_capture_support", SUPPORT_PATH)
keyboard = load_module("tui_keyboard_support", KEYBOARD_PATH)


def require(condition: bool, detail: str) -> None:
    if not condition:
        raise AssertionError(detail)


require(
    Path(support.WORKTREE).resolve() == WORKTREE,
    "MASC_CAPTURE_WORKTREE must not redirect inline-diff evidence",
)


def history_payload() -> list[dict[str, object]]:
    operation = {"kind": "operation", "operation_id": "tui-inline-diff"}
    return [
        {
            "id": "operator-inline-diff",
            "role": "user",
            "content": OPERATOR_REQUEST,
            "ts": FIXTURE_AT - 1.0,
            "delivery_key": operation,
            "transcript_slot": {"kind": "accepted_user"},
        },
        {
            "id": "tool-inline-diff",
            "role": "tool",
            "content": json.dumps({"file_path": "lib/runtime_selection.ml"}),
            "ts": FIXTURE_AT,
            "delivery_key": operation,
            "transcript_slot": {
                "kind": "tool_call",
                "execution_id": EXECUTION_ID,
                "ordinal": 0,
            },
            "tool_call_id": PROVIDER_CALL_ID,
            "execution_id": EXECUTION_ID,
            "tool_call_name": "Edit",
        },
        {
            "id": "assistant-inline-diff",
            "role": "assistant",
            "content": "Updated the runtime selection without leaving the conversation.",
            "ts": FIXTURE_AT + 1.0,
            "delivery_key": operation,
            "transcript_slot": {"kind": "terminal_assistant"},
        },
    ]


def change(
    *,
    execution_id: str,
    before: str,
    after: str,
    old_start: int,
    new_start: int,
) -> dict[str, object]:
    old_count = len(before.splitlines())
    new_count = len(after.splitlines())
    return {
        "at": FIXTURE_AT,
        "keeper": KEEPER,
        "turn": 42,
        "task_id": "task-inline-diff",
        "execution_id": execution_id,
        "line_evidence": {
            "kind": "edit",
            "occurrence_count": 1,
            "occurrences": [
                {
                    "old_range": {
                        "start_line": old_start,
                        "end_line": old_start + old_count - 1,
                    },
                    "new_range": {
                        "start_line": new_start,
                        "end_line": new_start + new_count - 1,
                    },
                }
            ],
        },
        "location": {
            "kind": "repo",
            "repo_id": "masc",
            "path": "lib/runtime_selection.ml",
        },
        "change": {
            "kind": "edit",
            "before": before,
            "after": after,
            "replace_all": False,
        },
        "succeeded": True,
    }


def changes_payload() -> dict[str, object]:
    provider_call_decoy = change(
        execution_id=PROVIDER_CALL_ID,
        before="WRONG_PROVIDER_CALL_JOIN",
        after="WRONG_PROVIDER_CALL_RESULT",
        old_start=7,
        new_start=7,
    )
    matching = change(
        execution_id=EXECUTION_ID,
        before="let selected = fallback\nlet source = \x60Fallback",
        after=(
            "let selected = configured\n"
            "let source = \x60Configured\n"
            "let status = \x60Ready"
        ),
        old_start=42,
        new_start=42,
    )
    path_last_decoy = change(
        execution_id="exec-inline-diff-path-last-decoy",
        before="WRONG_PATH_LAST_JOIN",
        after="WRONG_PATH_LAST_RESULT",
        old_start=91,
        new_start=91,
    )
    return {
        "keeper": KEEPER,
        "window_hours": 24.0,
        "calls_in_window": 3,
        "changes": [provider_call_decoy, matching, path_last_decoy],
        "over_budget": 0,
        "malformed": 0,
    }


@dataclass
class ObservedFixture:
    response: Any
    lock: threading.Lock = field(default_factory=threading.Lock)
    calls: list[dict[str, object]] = field(default_factory=list)

    def __call__(self) -> Any:
        response = self.response
        if callable(response):
            response = cast(Any, response())
        if isinstance(response, keyboard.RawHttpResponse):
            status = response.status
            body = response.body
            content_type = response.content_type
        else:
            status, payload = response
            body = json.dumps(payload).encode()
            content_type = "application/json"
        observation = {
            "received_monotonic": time.monotonic(),
            "status": status,
            "body_bytes": len(body),
            "body_sha256": support.digest_bytes(body),
            "body_utf8": body.decode("utf-8"),
            "content_type": content_type,
        }
        with self.lock:
            self.calls.append(observation)
        return response

    def snapshot(self) -> list[dict[str, object]]:
        with self.lock:
            return [dict(call) for call in self.calls]


class ObservedHttpFixtures(dict[str, Any]):
    """Record every route lookup, including routes absent from the fixture map."""

    def __init__(self, values: dict[str, Any]) -> None:
        super().__init__(values)
        self.lock = threading.Lock()
        self.lookups: list[dict[str, object]] = []

    def get(self, key: str, default: Any = None) -> Any:
        with self.lock:
            self.lookups.append(
                {
                    "received_monotonic": time.monotonic(),
                    "path": key,
                    "registered": key in self,
                }
            )
        return super().get(key, default)

    def snapshot(self) -> list[dict[str, object]]:
        with self.lock:
            return [dict(lookup) for lookup in self.lookups]

    def response_snapshot(self) -> dict[str, list[dict[str, object]]]:
        return {
            path: fixture.snapshot()
            for path, fixture in self.items()
            if isinstance(fixture, ObservedFixture) and fixture.snapshot()
        }


def roster_payload() -> dict[str, object]:
    return {
        "count": 1,
        "total": 1,
        "truncated": False,
        "keepers": [
            {
                "runtime_class": "keeper",
                "name": KEEPER,
                "agent_name": f"keeper-{KEEPER}-agent",
                "meta": {
                    "name": KEEPER,
                    "trace_id": "trace-inline-diff",
                    "created_at": "2026-08-27T00:00:00Z",
                    "updated_at": "2026-08-27T00:00:00Z",
                    "sandbox_profile": "local",
                },
                "health": "healthy",
                "paused": False,
                "next_action": None,
                "phase": "running",
                "keepalive_running": True,
                "autoboot_enabled": True,
                "proactive_enabled": True,
                "runtime_id": "anthropic.claude-opus-5",
                "created_at": "2026-08-27T00:00:00Z",
                "updated_at": "2026-08-27T00:00:00Z",
            }
        ],
    }


def fixtures(
    base: Path,
) -> tuple[
    ObservedHttpFixtures,
    dict[str, ObservedFixture],
    list[tuple[str, bytes]],
]:
    history = ObservedFixture((200, history_payload()))
    memory = ObservedFixture(
        (
            200,
            {
                "keeper": KEEPER,
                "returned": 0,
                "undecodable_lines": 0,
                "entries": [],
            },
        )
    )
    changes = ObservedFixture((200, changes_payload()))
    initialize = ObservedFixture(
        keyboard.RawHttpResponse(
            200,
            json.dumps({"jsonrpc": "2.0", "id": 1, "result": {}}).encode(),
            content_type="application/json",
            headers=(("Mcp-Session-Id", MCP_SESSION_ID),),
        )
    )
    observer = ObservedFixture(
        keyboard.RawHttpResponse(200, b"", content_type="text/event-stream")
    )
    values = keyboard.overview_event_http_fixtures()
    values.update(
        {
            "/api/v1/gate/keepers?detailed=true": (200, roster_payload()),
            "/api/v1/keepers/tool-approvals": (200, {"pending": []}),
            "/api/v1/keepers/tool-approval-mode": (200, {"overrides": []}),
            "/api/v1/dashboard/scheduled-automation": (
                200,
                {
                    "status": "ok",
                    "schedule_store_read_error": None,
                    "request_count": 0,
                    "truncated": False,
                    "fsm": {"next_due_at_iso": None},
                    "requests": [],
                },
            ),
            HISTORY_GET: history,
            MEMORY_GET: memory,
            CHANGES_GET: changes,
            MCP_POST: initialize,
            MCP_OBSERVER_GET: observer,
        }
    )
    keyboard.with_workspace_identity(values, str(base))
    observed_values = {
        path: response
        if isinstance(response, ObservedFixture)
        else ObservedFixture(response)
        for path, response in values.items()
    }
    return (
        ObservedHttpFixtures(observed_values),
        {
            "history": history,
            "memory": memory,
            "changes": changes,
            "mcp_initialize": initialize,
            "mcp_observer": observer,
        },
        [],
    )


def wait_call_count(fixture: ObservedFixture, count: int, label: str) -> None:
    support.wait_until(lambda: len(fixture.snapshot()) >= count, label)
    require(len(fixture.snapshot()) == count, f"{label}: {len(fixture.snapshot())}")


def open_chat(page: Any) -> None:
    support.press(page, "2", "MASC Keepers")
    support.press(page, "Enter", "Identity")
    support.press(page, "c", f"Keepers ▸ {KEEPER} ▸ chat")


def run_scenario(
    browser: Browser,
    output: Path,
    executable: Path,
) -> dict[str, object]:
    with tempfile.TemporaryDirectory(prefix="masc-tui-inline-diff-") as raw:
        base = Path(raw)
        keyboard.seed_workspace(str(base), (KEEPER,))
        http_fixtures, observed, requests = fixtures(base)
        with keyboard.test_http_endpoint(http_fixtures, requests) as (
            api_port,
            start_endpoint,
            set_workspace_base_path,
        ):
            set_workspace_base_path(str(base))
            start_endpoint()
            with support.ttyd_session(browser, base, api_port, executable) as (
                page,
                _started,
            ):
                open_chat(page)
                support.wait_text(page, "Updated the runtime selection")
                support.wait_text(page, "✓ Edit")
                support.wait_text(page, OPERATOR_REQUEST)
                support.wait_text(page, "TURN · YOU")
                wait_call_count(observed["history"], 2, "history GET count")
                wait_call_count(observed["memory"], 2, "memory GET count")
                compact = support.screen_text(page)
                full_only = (
                    "masc:lib/runtime_selection.ml (+3 -2)",
                    "old L42-43 -> new L42-44",
                    "-let selected = fallback",
                    "+let selected = configured",
                    "WRONG_PROVIDER_CALL_JOIN",
                    "WRONG_PROVIDER_CALL_RESULT",
                    "WRONG_PATH_LAST_JOIN",
                    "WRONG_PATH_LAST_RESULT",
                    "tools:full",
                    "diffs 24h",
                )
                require(
                    observed["changes"].snapshot() == [],
                    "compact mode fetched file changes before Ctrl-D",
                )
                require(
                    all(
                        lookup["path"] != CHANGES_GET
                        for lookup in http_fixtures.snapshot()
                    ),
                    "compact mode looked up file changes before Ctrl-D",
                )
                require(
                    all(marker not in compact for marker in full_only),
                    "compact mode exposed full inline-diff content",
                )
                require(
                    "TURN · TOOLS" not in compact,
                    "direct tool row split away from its accepted user turn",
                )
                compact_shot = support.capture(
                    page,
                    output,
                    "01-chat-tool-compact.png",
                    "Keepers ▸ alpha ▸ chat",
                    "TURN · YOU",
                    OPERATOR_REQUEST,
                    "✓ Edit",
                    "Updated the runtime selection",
                )

                started = time.monotonic()
                support.press(page, "Control+D")
                support.wait_text(page, "tools:full")
                support.wait_text(page, "diffs 24h")
                support.wait_text(page, "old L42-43 -> new L42-44")
                support.wait_text(page, "-let selected = fallback")
                support.wait_text(page, "+let selected = configured")
                range_visible_ms = round((time.monotonic() - started) * 1000, 3)
                wait_call_count(observed["changes"], 1, "file-changes GET count")
                change_call = observed["changes"].snapshot()[0]
                change_lookups = [
                    lookup
                    for lookup in http_fixtures.snapshot()
                    if lookup["path"] == CHANGES_GET
                ]
                require(
                    len(change_lookups) == 1
                    and cast(float, change_lookups[0]["received_monotonic"]) >= started,
                    f"file changes route lookup did not follow Ctrl-D: {change_lookups}",
                )
                require(
                    cast(float, change_call["received_monotonic"]) >= started,
                    "file changes were requested before Ctrl-D",
                )
                full = support.screen_text(page)
                ordered = (
                    "TURN · YOU",
                    OPERATOR_REQUEST,
                    "✓ Edit",
                    "masc:lib/runtime_selection.ml (+3 -2)",
                    "old L42-43 -> new L42-44",
                    "-let selected = fallback",
                    "+let selected = configured",
                    "Updated the runtime selection",
                )
                positions = [full.find(marker) for marker in ordered]
                require(
                    all(position >= 0 for position in positions)
                    and positions == sorted(positions),
                    f"inline diff is missing or reordered: {positions}",
                )
                require(
                    "WRONG_PROVIDER_CALL_JOIN" not in full
                    and "WRONG_PROVIDER_CALL_RESULT" not in full
                    and "WRONG_PATH_LAST_JOIN" not in full
                    and "WRONG_PATH_LAST_RESULT" not in full,
                    "provider call id, file path, or list position authorized the join",
                )
                require(
                    "TURN · TOOLS" not in full,
                    "full tool row split away from its accepted user turn",
                )
                for failure in (
                    "fixture endpoint unavailable",
                    "data unreliable",
                    "decode failed",
                ):
                    require(
                        failure not in full, f"TUI reported fixture failure: {failure}"
                    )
                full_shot = support.capture(
                    page,
                    output,
                    "02-chat-inline-diff-full.png",
                    "tools:full",
                    "diffs 24h",
                    *ordered,
                )

        wait_call_count(observed["mcp_initialize"], 1, "MCP initialize count")
        wait_call_count(observed["mcp_observer"], 1, "MCP observer count")
        expected_counts = {
            "history": 2,
            "memory": 2,
            "changes": 1,
            "mcp_initialize": 1,
            "mcp_observer": 1,
        }
        final_counts = {
            name: len(fixture.snapshot()) for name, fixture in observed.items()
        }
        require(
            final_counts == expected_counts,
            f"final fixture call counts: {final_counts}",
        )
        post_paths = [request_path for request_path, _ in requests]
        require(post_paths == [MCP_POST], f"scenario emitted POSTs: {post_paths}")
        route_lookups = http_fixtures.snapshot()
        unregistered = [lookup for lookup in route_lookups if not lookup["registered"]]
        require(unregistered == [], f"unregistered HTTP routes: {unregistered}")
        response_observations = http_fixtures.response_snapshot()
        lookup_counts = Counter(cast(str, lookup["path"]) for lookup in route_lookups)
        response_counts = {
            path: len(calls) for path, calls in response_observations.items()
        }
        require(
            dict(lookup_counts) == response_counts,
            "route lookup/fixture resolution mismatch: "
            f"{dict(lookup_counts)} != {response_counts}",
        )
        failed_responses = [
            (path, call["status"])
            for path, calls in response_observations.items()
            for call in calls
            if not 200 <= cast(int, call["status"]) < 400
        ]
        require(
            failed_responses == [],
            f"fixture HTTP responses failed: {failed_responses}",
        )
        expected_paths = {
            "effective_base_path": str(base),
            "effective_masc_root": str(base / ".masc"),
        }
        for health_path in ("/health", "/health?full=1"):
            health_calls = response_observations.get(health_path, [])
            require(health_calls != [], f"TUI did not request {health_path}")
            for call in health_calls:
                health_body = cast(
                    dict[str, object], json.loads(cast(str, call["body_utf8"]))
                )
                paths = health_body.get("paths")
                require(
                    isinstance(paths, dict)
                    and all(
                        paths.get(key) == value for key, value in expected_paths.items()
                    ),
                    f"{health_path} workspace identity mismatch: {paths}",
                )
        mcp_body = cast(dict[str, object], json.loads(requests[0][1].decode("utf-8")))
        require(
            mcp_body.get("jsonrpc") == "2.0" and mcp_body.get("method") == "initialize",
            f"unexpected MCP request: {mcp_body}",
        )
        return {
            "name": "ctrl_d_exact_execution_inline_diff",
            "interaction": {
                "keys": ["2", "Enter", "c", "Ctrl-D"],
                "state_change": "compact tool row -> full recorded inline diff",
            },
            "measurements": {
                "ctrl_d_to_exact_range_ms": range_visible_ms,
                "file_changes_before_ctrl_d": 0,
                "file_changes_after_ctrl_d": final_counts["changes"],
                "canonical_execution_join": EXECUTION_ID,
                "provider_call_decoy_rejected": PROVIDER_CALL_ID,
                "path_last_decoy_rejected": "exec-inline-diff-path-last-decoy",
            },
            "screenshots": [compact_shot, full_shot],
            "http": {
                "observed_gets_and_mcp": {
                    name: fixture.snapshot() for name, fixture in observed.items()
                },
                "all_route_lookups": route_lookups,
                "fixture_resolution_outputs": response_observations,
                "request_method_and_wire_write_completion": (
                    "not observed at handler entry by imported test server; "
                    "completed POST bodies are recorded after respond()"
                ),
                "post_requests": [
                    {
                        "path": request_path,
                        "body_bytes": len(body),
                        "body_sha256": support.digest_bytes(body),
                        "body_utf8": body.decode("utf-8"),
                    }
                    for request_path, body in requests
                ],
            },
        }


def provided_executable_scope(executable: Path) -> dict[str, object]:
    build_root = (WORKTREE / "_build").resolve()
    require(
        executable.is_relative_to(build_root),
        f"provided executable is outside this worktree build: {executable}",
    )
    return {"inside_worktree_build_dir": True}


def pull_request_snapshot(number: int) -> dict[str, object]:
    snapshot = cast(
        dict[str, object],
        json.loads(
            support.run_text(
                "gh",
                "pr",
                "view",
                str(number),
                "--repo",
                REPOSITORY,
                "--json",
                "baseRefName,baseRefOid,headRefOid,isDraft,state,url",
            )
        ),
    )
    snapshot["checked_at"] = support.utc_now()
    require(
        snapshot.get("url") == f"https://github.com/{REPOSITORY}/pull/{number}",
        f"unexpected PR repository: {snapshot.get('url')}",
    )
    return snapshot


def require_current_main_ancestry(pull_request: dict[str, object], head: str) -> None:
    require(pull_request.get("baseRefName") == "main", "PR base is not main")
    require(pull_request.get("state") == "OPEN", "PR is not open")
    require(pull_request.get("isDraft") is True, "PR is not draft")
    base = pull_request.get("baseRefOid")
    require(
        isinstance(base, str) and re.fullmatch(r"[0-9a-f]{40}", base) is not None,
        f"invalid PR base SHA: {base}",
    )
    ancestry = subprocess.run(
        ["git", "merge-base", "--is-ancestor", cast(str, base), head],
        cwd=WORKTREE,
        capture_output=True,
        check=False,
    )
    require(
        ancestry.returncode in (0, 1),
        "cannot inspect PR base ancestry: "
        + ancestry.stderr.decode("utf-8", errors="replace"),
    )
    require(
        ancestry.returncode == 0,
        f"current PR base {base} is not an ancestor of HEAD {head}",
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected-head", required=True)
    parser.add_argument("--target-pr", required=True, type=int)
    parser.add_argument("--executable", required=True, type=Path)
    args = parser.parse_args()
    output = Path(tempfile.mkdtemp(prefix="masc-tui-inline-diff-capture-"))
    script_path = Path(__file__).resolve()
    script_hash = support.digest_file(script_path)
    evidence: dict[str, object] = {
        "schema": "masc.tui_inline_diff_capture.v1",
        "target_pr": args.target_pr,
        "output_dir": str(output),
        "started_at": support.utc_now(),
        "scenarios": [],
    }
    code = 0
    try:
        require(
            re.fullmatch(r"[0-9a-f]{40}", args.expected_head) is not None,
            "--expected-head must be a full lowercase SHA",
        )
        require(args.target_pr > 0, "--target-pr must be positive")
        head = support.run_text("git", "rev-parse", "HEAD")
        tree = support.run_text("git", "rev-parse", "HEAD^{tree}")
        dirty = support.run_text("git", "status", "--porcelain=v1").splitlines()
        require(head == args.expected_head, f"HEAD mismatch: {head}")
        require(dirty == [], f"dirty checkout: {dirty}")
        pull_request = pull_request_snapshot(args.target_pr)
        require(
            pull_request.get("headRefOid") == head,
            f"PR head mismatch: {pull_request.get('headRefOid')}",
        )
        require_current_main_ancestry(pull_request, head)
        evidence["pull_request"] = pull_request
        require(support.TTYD.is_file(), f"missing ttyd: {support.TTYD}")
        provided_executable = (
            args.executable
            if args.executable.is_absolute()
            else WORKTREE / args.executable
        )
        require(
            provided_executable.is_file() and not provided_executable.is_symlink(),
            f"missing/non-regular executable: {provided_executable}",
        )
        executable = provided_executable.resolve()
        executable_scope = provided_executable_scope(executable)
        executable_payload = executable.read_bytes()
        embedded_head_occurrences = executable_payload.count(head.encode())
        require(
            embedded_head_occurrences == 1,
            f"provided executable embeds HEAD {embedded_head_occurrences} times",
        )
        executable_hash = support.digest_bytes(executable_payload)
        evidence["source"] = {
            "head": head,
            "tree": tree,
            "branch": support.run_text("git", "branch", "--show-current"),
            "checkout_clean_at_capture": True,
            "executable_path": str(executable),
            "executable_sha256": executable_hash,
            "executable_bytes": len(executable_payload),
            "embedded_head_occurrences": embedded_head_occurrences,
            "provided_executable_scope": executable_scope,
            "build_time_cleanliness": "not independently observable",
            "script_sha256": script_hash,
            "ttyd_version": support.run_text(str(support.TTYD), "--version"),
            "playwright_version": support.package_version("playwright"),
            "terminal": {
                "term": "xterm-256color",
                "colorterm": None,
                "renderer": "ttyd-dom",
                "tui_sync": "off",
            },
            "http_evidence_boundary": (
                "fixture route lookup and response intent; request method at handler "
                "entry and socket write completion are not independently observed"
            ),
        }
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(headless=True)
            try:
                cast(dict[str, object], evidence["source"])["chromium_version"] = (
                    browser.version
                )
                scenario = run_scenario(browser, output, executable)
                cast(list[object], evidence["scenarios"]).append(scenario)
            finally:
                browser.close()

        screenshots = cast(list[dict[str, object]], scenario["screenshots"])
        screenshot_paths = sorted(output.glob("*.png"))
        require(len(screenshots) == 2, f"screenshot count: {len(screenshots)}")
        require(
            [image.name for image in screenshot_paths]
            == sorted(cast(str, shot["file"]) for shot in screenshots),
            "on-disk screenshot set differs from scenario records",
        )
        for image_path in screenshot_paths:
            record = next(
                shot for shot in screenshots if shot["file"] == image_path.name
            )
            require(
                image_path.stat().st_size == record["bytes"],
                f"size drift: {image_path.name}",
            )
            require(
                support.digest_file(image_path) == record["sha256"],
                f"hash drift: {image_path.name}",
            )
        require(support.run_text("git", "rev-parse", "HEAD") == head, "HEAD changed")
        require(
            support.run_text("git", "status", "--porcelain=v1") == "",
            "capture dirtied checkout",
        )
        require(support.digest_file(executable) == executable_hash, "binary changed")
        require(support.digest_file(script_path) == script_hash, "script changed")
        final_pull_request = pull_request_snapshot(args.target_pr)
        require(
            final_pull_request.get("headRefOid") == head,
            f"PR head changed during capture: {final_pull_request.get('headRefOid')}",
        )
        require(
            final_pull_request.get("baseRefOid") == pull_request.get("baseRefOid"),
            "PR base changed during capture",
        )
        require_current_main_ancestry(final_pull_request, head)
        evidence["pull_request_after_capture"] = final_pull_request
        evidence["verified"] = {
            "source_and_binary_head_match": True,
            "clean_before_and_after": True,
            "provided_binary_unchanged": True,
            "script_unchanged": True,
            "compact_and_full_screenshots": True,
            "real_ctrl_d_interaction": True,
            "canonical_execution_join_with_decoy": True,
            "terminal_visible_text_and_fixture_contract": True,
            "screenshots_rehashed": True,
        }
        evidence["status"] = "passed"
    except Exception as error:  # noqa: BLE001 - preserve structured failure
        code = 1
        evidence["status"] = "failed"
        evidence["failure"] = {
            "type": type(error).__name__,
            "detail": str(error),
        }
        evidence["partial_screenshots"] = [
            {
                "file": image_path.name,
                "bytes": image_path.stat().st_size,
                "sha256": support.digest_file(image_path),
            }
            for image_path in sorted(output.glob("*.png"))
        ]
    evidence["finished_at"] = support.utc_now()
    evidence_path = output / "evidence.json"
    with evidence_path.open("x", encoding="utf-8") as handle:
        json.dump(evidence, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    print(json.dumps(evidence, ensure_ascii=False, indent=2))
    print(f"evidence_path={evidence_path}", file=sys.stderr)
    return code


if __name__ == "__main__":
    raise SystemExit(main())
