from __future__ import annotations

from tui_keyboard_harness import palette_go
from tui_keyboard_harness import select_keeper_row

import hashlib
import json
import os
import subprocess
import time

from tui_keyboard_chat import (
    unwrapped,
)
from tui_keyboard_harness import (
    DASHBOARD_GOALS_PATH,
    FULL_REDRAW,
    PLANNING_PATH,
    RUNTIME_RESOLVED_PATH,
    HttpResponse,
    Interaction,
    overview_event_briefing,
    planning_goal,
    planning_snapshot,
    resize_and_wait,
    run_terminal_scenario,
    screen_text,
    send_and_wait,
    tab_until,
    wait_for_output,
)
from tui_keyboard_runtime import (
    runtime_resolved_response,
)


def duplicated_attention_briefing() -> HttpResponse:
    item = {
        "kind": "keeper_attention",
        "severity": "warning",
        "summary": "sangsu has external attention from discord",
        "target_type": "keeper",
        "target_id": "sangsu",
    }
    other = dict(item, summary="analyst needs operator attention")
    return (
        200,
        {
            "summary": {
                "workspace_health": "ok",
                "cluster": "cluster-a",
                "project": "project-a",
            },
            "generated_at": "2026-08-24T00:00:00Z",
            # The same row on both lists, the way the live briefing serves an
            # incident that is also queued for attention.
            "incidents": [item, other],
            "attention_queue": [item],
            "attention_items": [],
            "agent_briefs": [],
            "keeper_briefs": [],
            "keepers_listing": {"state": "listed"},
            "keepers_unread": [],
        },
    )


def unread_keeper_briefing() -> HttpResponse:
    return (
        200,
        {
            "summary": {
                "workspace_health": "ok",
                "cluster": "cluster-a",
                "project": "project-a",
            },
            "generated_at": "2026-09-23T00:00:00Z",
            "incidents": [],
            "attention_queue": [],
            "attention_items": [],
            "agent_briefs": [],
            "keeper_briefs": [],
            # The server listed this Keeper but could not build its row
            # (#38090). It has no brief, and the Overview still counts it.
            "keepers_listing": {"state": "listed"},
            "keepers_unread": [
                {
                    "name": "k-unread",
                    "reason": "row_raised",
                    "detail": "Failure(\"default runtime not initialized\")",
                }
            ],
        },
    )


def unread_keeper_counted_interaction() -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        wait_for_output(
            process,
            master_fd,
            output,
            b"1 Keeper states unreadable",
            start=0,
            timeout=10.0,
        )
        # The first screen preserves the count and the missing-state evidence.
        # Individual rows belong on Keepers.
        # The harness confirms the exit that this first press arms.
        os.write(master_fd, b"q")

    return interact


def unlisted_keepers_briefing() -> HttpResponse:
    # The server could not list the Keeper directory (#38120). There is no
    # brief and no unread row, and the briefing says why the fleet is empty.
    return (
        200,
        {
            "summary": {
                "workspace_health": "ok",
                "cluster": "cluster-a",
                "project": "project-a",
            },
            "generated_at": "2026-09-25T00:00:00Z",
            "incidents": [],
            "attention_queue": [],
            "attention_items": [],
            "agent_briefs": [],
            "keeper_briefs": [],
            "keepers_listing": {"state": "unreadable", "detail": "EACCES"},
            "keepers_unread": [],
        },
    )


def unlisted_keepers_named_interaction() -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        # The count cell names the failure instead of drawing "Keepers: 0".
        wait_for_output(
            process,
            master_fd,
            output,
            b"unlisted",
            start=0,
            timeout=10.0,
        )
        wait_for_output(
            process,
            master_fd,
            output,
            b"Keepers unlisted: EACCES",
            start=0,
            timeout=10.0,
        )
        # The harness confirms the exit that this first press arms.
        os.write(master_fd, b"q")

    return interact


def paused_and_stopped_briefing() -> HttpResponse:
    # One Keeper the operator paused (the flag, whatever the phase), one
    # paused by phase, one stopped, one with no phase and one running.
    return (
        200,
        {
            "summary": {
                "workspace_health": "ok",
                "cluster": "cluster-a",
                "project": "project-a",
            },
            "generated_at": "2026-09-23T00:00:00Z",
            "incidents": [],
            "attention_queue": [],
            "attention_items": [],
            "agent_briefs": [],
            "keeper_briefs": [
                {"name": "k-flagged", "phase": None, "paused": True},
                {"name": "k-halted", "phase": "paused", "paused": False},
                {"name": "k-stopped", "phase": "stopped", "paused": False},
                {"name": "k-unknown", "phase": None, "paused": False},
                {"name": "k-running", "phase": "running", "last_turn_ago_s": 30},
            ],
            "keepers_listing": {"state": "listed"},
            "keepers_unread": [],
        },
    )


def paused_apart_from_stopped_interaction() -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        # Home no longer derives a fleet state summary from briefing rows.
        wait_for_output(
            process, master_fd, output, b"Continue", start=0, timeout=10.0
        )
        frame = resize_and_wait(
            process, master_fd, output, rows=30, columns=120,
            needle=b"MASC Dashboard", controls=(FULL_REDRAW,),
        )
        if any(label in frame for label in (b" idle ", b" no work ", b"k-unknown")):
            raise AssertionError(f"Dashboard invented a Keeper state row: {frame!r}")
        # The harness confirms the exit that this first press arms.
        os.write(master_fd, b"q")

    return interact


def attention_drawn_once_interaction() -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        wait_for_output(process, master_fd, output, b"Continue", start=0, timeout=10.0)
        frame = resize_and_wait(
            process, master_fd, output, rows=30, columns=99, needle=b"Continue",
            controls=(FULL_REDRAW,), final_cursor=b"\x1b[?25l",
        )
        # Incident text is not an authoritative operator request. Neither
        # duplicated nor distinct briefing incidents enter Home's decisions.
        for label in (b"sangsu has external attention", b"analyst needs operator"):
            if label in frame:
                raise AssertionError(f"Home projected an incident as a decision: {frame!r}")

        os.write(master_fd, b"q")

    return interact


def dashboard_usage_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    wait_for_output(process, master_fd, output, b"MASC Dashboard", start=0, timeout=30.0)
    wait_for_output(process, master_fd, output, b"Continue", start=0, timeout=10.0)
    dashboard = unwrapped(screen_text(bytes(output)))
    if b"Work:" not in dashboard or b"Continue" not in dashboard:
        raise AssertionError(f"Dashboard entry missing: {dashboard!r}")
    if b"actual 3 (reported)" in dashboard or b"linked tasks 0/1 done" in dashboard:
        raise AssertionError(f"Dashboard duplicated Work detail: {dashboard!r}")
    print("DASHBOARD_PTY_SCREEN=" + json.dumps(dashboard.decode("utf-8", errors="replace")), flush=True)
    send_and_wait(process, master_fd, output, b"\t", b"Fixture Goal")
    send_and_wait(process, master_fd, output, b"\r", b"Actual: 3 (reported)")
    wait_for_output(process, master_fd, output, b"artifact:fixture-checks", start=0, timeout=5.0)
    send_and_wait(process, master_fd, output, b"\x1b", b"MASC Work")
    send_and_wait(process, master_fd, output, b"p", b"MASC Approvals")
    send_and_wait(process, master_fd, output, b"\x1b", b"MASC Work")
    send_and_wait(process, master_fd, output, b"t", b"MASC Work / Tasks")
    usage = tab_until(process, master_fd, output, b"MASC Usage")
    if b"MASC Usage" not in usage:
        raise AssertionError(f"Usage is not on the main ring: {usage!r}")
    wait_for_output(process, master_fd, output, b"Plan usage", start=0, timeout=10.0)
    send_and_wait(process, master_fd, output, b"v", b"UTC days reported")
    plain = unwrapped(screen_text(bytes(output)))
    for scope_prefix in (
        hashlib.md5(b"provider:fixture").hexdigest()[:8].encode(),
        hashlib.md5(b"provider:fixture-alt").hexdigest()[:8].encode(),
    ):
        if scope_prefix not in plain:
            raise AssertionError(f"Usage merged quota scope {scope_prefix!r}: {plain!r}")
    print("USAGE_PTY_SCREEN=" + json.dumps(plain.decode("utf-8", errors="replace")), flush=True)
    send_and_wait(process, master_fd, output, b"v", b"Keeper usage")
    send_and_wait(process, master_fd, output, b"p", b"MASC Usage / Telemetry")
    send_and_wait(process, master_fd, output, b"3", b"Gate Governance")
    send_and_wait(process, master_fd, output, b"p", b"MASC Usage")
    send_and_wait(process, master_fd, output, b"w", b"1 UTC days")
    send_and_wait(process, master_fd, output, b"w", b"7 UTC days")
    # Leave from diagnostics: Home's Usage shortcut must still open accounts.
    send_and_wait(process, master_fd, output, b"p", b"MASC Usage / Telemetry")
    system = tab_until(process, master_fd, output, b"MASC System")
    if b"MASC System" not in system:
        raise AssertionError(f"System is not on the main ring: {system!r}")
    send_and_wait(process, master_fd, output, b"A", b"MASC Activity")
    tab_until(process, master_fd, output, b"MASC Dashboard")
    send_and_wait(process, master_fd, output, b"m", b"7 UTC days")
    usage = screen_text(bytes(output))
    if b"MASC Usage / Telemetry" in usage:
        raise AssertionError(f"Home Usage shortcut resumed diagnostics: {usage!r}")
    send_and_wait(process, master_fd, output, b"p", b"MASC Usage / Telemetry")
    palette_go(process, master_fd, output, b"go Usage", b"7 UTC days")
    send_and_wait(process, master_fd, output, b"p", b"MASC Usage / Telemetry")
    palette_go(process, master_fd, output, b"go Keepers", b"MASC Keepers")
    select_keeper_row(process, master_fd, output, b"alpha")
    send_and_wait(process, master_fd, output, b"c", b"Esc:list")
    send_and_wait(process, master_fd, output, b"/cost", b"/cost")
    send_and_wait(process, master_fd, output, b"\r", b"7 UTC days")
    send_and_wait(process, master_fd, output, b"i", b"to alpha")
    send_and_wait(process, master_fd, output, b"/telemetry", b"/telemetry")
    send_and_wait(process, master_fd, output, b"\r", b"MASC Usage / Telemetry")
    tab_until(process, master_fd, output, b"MASC Usage")
    wait_for_output(
        process, master_fd, output, b"7 UTC days",
        start=output.rfind(b"MASC Usage"), timeout=10.0,
    )
    os.write(master_fd, b"q")


def run_dashboard_usage_regression(executable: str) -> None:
    now = time.time()
    scope = "provider:fixture"
    scope_id = hashlib.md5(scope.encode()).hexdigest()
    second_scope = "provider:fixture-alt"
    second_scope_id = hashlib.md5(second_scope.encode()).hexdigest()
    status, runtime = runtime_resolved_response()
    assert status == 200 and isinstance(runtime, dict)
    runtime["provider_usage_windows"] = [
        {
            "scope": scope,
            "scope_id": scope_id,
            "providers": [{"id": "fixture", "display_name": "fixture"}],
            "state": "reported",
            "windows": [
                {
                    "limit_id": None,
                    "window": {"kind": "five_hour"},
                    "role": "gates_model_calls",
                    "utilization": {"unit": "fraction", "value": 0.4},
                    "resets_at": None,
                    "observed_at": now,
                    "source": "fixture",
                }
            ],
        },
        {
            "scope": second_scope,
            "scope_id": second_scope_id,
            "providers": [{"id": "fixture-alt", "display_name": "fixture-alt"}],
            "state": "reported",
            "windows": [
                {
                    "limit_id": None,
                    "window": {"kind": "five_hour"},
                    "role": "gates_model_calls",
                    "utilization": {"unit": "fraction", "value": 0.8},
                    "resets_at": None,
                    "observed_at": now,
                    "source": "fixture",
                }
            ],
        }
    ]
    planning = planning_goal("goal-fixture", "Fixture Goal")
    planning["criterion_revision"] = "r1"
    planning["metric"] = "accepted checks"
    planning["target_value"] = "5"
    run_terminal_scenario(
        executable,
        description="Dashboard, Work, Usage and System navigation",
        interact=dashboard_usage_interaction,
        refresh=1.0,
        http_fixtures={
            "/api/v1/dashboard/briefing": (200, overview_event_briefing()),
            PLANNING_PATH: planning_snapshot([planning]),
            DASHBOARD_GOALS_PATH: (
                200,
                {
                    "generated_at": "2026-09-25T00:00:00Z",
                    "tree": [
                        {
                            "id": "goal-fixture",
                            "title": "Fixture Goal",
                            "phase": "executing",
                            "priority": 1,
                            "criterion_revision": "r1",
                            "metric": "accepted checks",
                            "target_value": "5",
                            "measurement": {
                                "state": "reported",
                                "record": {
                                    "goal_id": "goal-fixture",
                                    "criterion_revision": "r1",
                                    "observed_value": "3",
                                    "evidence": "artifact:fixture-checks",
                                    "actor": "fixture",
                                    "recorded_at": "2026-09-25T00:00:00Z",
                                },
                            },
                            "due_date": None,
                            "task_count": 1,
                            "task_done_count": 0,
                            "stagnation_seconds": None,
                            "tasks": [{"id": "task-fixture", "status": "todo"}],
                            "children": [],
                        }
                    ],
                },
            ),
            RUNTIME_RESOLVED_PATH: (200, runtime),
            "/api/v1/dashboard/provider-usage-history?days=14": (
                200,
                {
                    "days": 14,
                    "generated_at": now,
                    "sampling": "latest_provider_report_per_utc_day",
                    "unreadable_reports": 0, "reported_no_windows": [],
                    "points": [
                        {
                            "scope_id": scope_id,
                            "kind": "five_hour",
                            "limit_id": None,
                            "unit": "fraction",
                            "value": 0.4,
                            "observed_at": now,
                            "source": "fixture",
                            "resets_at": None,
                        },
                        {
                            "scope_id": second_scope_id,
                            "kind": "five_hour",
                            "limit_id": None,
                            "unit": "fraction",
                            "value": 0.8,
                            "observed_at": now,
                            "source": "fixture",
                            "resets_at": None,
                        }
                    ],
                },
            ),
            "/api/v1/dashboard/provider-usage-history?days=7": (
                200,
                {
                    "days": 7,
                    "generated_at": now,
                    "sampling": "latest_provider_report_per_utc_day",
                    "unreadable_reports": 0, "reported_no_windows": [],
                    "points": [],
                },
            ),
            "/api/v1/dashboard/keeper-costs?window=1440": (
                200,
                {"keepers": [], "window_minutes": 1440, "generated_at": now,
                 "cache": {"state": "fresh", "generated_at": now}},
            ),
        },
    )
