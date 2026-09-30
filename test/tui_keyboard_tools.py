from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import subprocess
import threading
from pathlib import Path

from tui_keyboard_harness import (
    CSI_RE,
    FRAME_END,
    FRAME_START,
    FULL_REDRAW,
    GatedHttpResponse,
    HttpFixtures,
    HttpResponse,
    Interaction,
    drain_until_quiet,
    keeper_runtime_http_fixtures,
    read_available,
    resize_and_wait,
    run_terminal_scenario,
    screen_rows,
    screen_text,
    send_and_wait,
    tab_until,
    wait_for_fixture_event,
    wait_for_output,
)


def skills_usage_clarity_http_fixtures(
    *, ledgers_loaded: int = 19, unavailable: tuple[str, ...] = (), observed: bool = True
) -> HttpFixtures:
    fixtures = keeper_runtime_http_fixtures()
    fixtures["/api/v1/dashboard/tools?keeper=alpha"] = (
        200,
        {
            "tool_inventory": {"tools": [], "count": 0},
            "effective_keeper_surface": None,
            "skill_activations": None,
        },
    )
    fixtures["/api/v1/async-requests"] = (200, {"requests": []})
    fixtures["/api/v1/skills"] = (
        200,
        {
            "schema": "masc.skill-snapshot/v1",
            "state": "ready",
            "usage_coverage": {
                "ledgers_loaded": ledgers_loaded,
                "unavailable": list(unavailable),
            },
            "snapshot": {
                "snapshot_revision": "snapshot-rev1",
                "catalog_revision": "catalog-rev1",
                "config": {"kind": "unreadable"},
                "sources": [],
                "skills": [],
                "effective_skills": [],
                "shadows": [],
                "rejections": [],
            },
            "surfaces": [
                {
                    "reference": {
                        "identity": {
                            "source_id": "workspace",
                            "package_id": "pkg",
                            "name": "work-intake",
                        },
                        "content_revision": "rev1",
                    },
                    "kind": "instruction",
                    "usage": ([
                        {
                            "keeper": "alpha",
                            "invocations": 12,
                            "deliveries": 12,
                            "actions": 9,
                            "last_used_at": "2026-08-28T03:04:05Z",
                        }
                    ] if observed else []),
                    "profile": {"flow": None, "plan": {}, "context": {}},
                },
                {
                    "reference": {
                        "identity": {"source_id": "workspace", "package_id": "pkg", "name": "unobserved-skill"},
                        "content_revision": "rev2",
                    },
                    "kind": "composition",
                    "usage": [],
                    "profile": {"flow": None, "plan": {}, "context": {}},
                },
            ],
        },
    )
    return fixtures


def skills_usage_clarity_interaction(
    *, ledgers_loaded: int = 19, unavailable: tuple[str, ...] = (), observed: bool = True
) -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=160,
            needle=b"MASC Dashboard",
        )
        # Tools hangs off Config under [t] now, so the walk goes to the
        # parent stop and hops from there.
        tab_until(process, master_fd, output, b"MASC System")
        send_and_wait(process, master_fd, output, b"t", b"MASC System / Tools")
        usage = send_and_wait(
            process,
            master_fd,
            output,
            b"p" * 3,
            f"{1 if observed else 0} of 2 catalog Skills observed".encode(),
        )
        rendered = CSI_RE.sub(b"", usage)
        expected = [
            f"{1 if observed else 0} of 2 catalog Skills observed".encode(),
            f"{1 if observed else 2} without retained invocation".encode(),
            b"Scope: exact Skill revisions in current Keeper sessions",
            f"Activation ledgers loaded: {ledgers_loaded}; unavailable: {len(unavailable)}".encode(),
        ]
        expected.extend(f"Unavailable: {reason}".encode() for reason in unavailable)
        if observed:
            expected.extend((b"work-intake", b"alpha"))
        for needle in expected:
            if needle not in rendered:
                raise AssertionError(f"Skill usage did not show {needle!r}: {usage!r}")
        # One keeper, one row, counts in their own columns (#37830). The time is
        # the terminal's zone, so only the date's shape is pinned.
        if observed and not re.search(rb"alpha\s+12\s+12\s+9\s+\d{4}-", rendered):
            raise AssertionError(
                f"the keeper's counts are not in their own columns: {usage!r}"
            )
        if b"never invoked" in rendered:
            raise AssertionError(f"Unknown historical usage was called never invoked: {usage!r}")
        if not observed and re.search(rb"alpha\s+12\s+12\s+9", rendered):
            raise AssertionError(f"Unobserved usage inherited a previous count: {usage!r}")
        os.write(master_fd, b"q")

    return interact


def run_skill_usage_coverage_regression(executable: str) -> None:
    for description, loaded, unavailable, observed in (
        ("loaded current sessions do not prove lifetime non-use", 19, (), True),
        ("partial ledger coverage preserves known usage", 1, ("bravo: metadata unavailable",), True),
        ("unavailable inventory is not global zero usage", 0, ("keeper catalog: unavailable",), False),
    ):
        run_terminal_scenario(
            executable,
            description=f"Skill usage coverage: {description}",
            interact=skills_usage_clarity_interaction(
                ledgers_loaded=loaded, unavailable=unavailable, observed=observed
            ),
            http_fixtures=skills_usage_clarity_http_fixtures(
                ledgers_loaded=loaded, unavailable=unavailable, observed=observed
            ),
        )


def run_skill_catalog_error_regression(executable: str) -> None:
    for initial_error in (True, False):
        fixtures = skills_usage_clarity_http_fixtures()
        good = fixtures["/api/v1/skills"]
        if not isinstance(good, tuple):
            raise AssertionError("Skill catalog fixture must be a JSON response")
        bad_payload = dict(good[1])
        del bad_payload["usage_coverage"]
        fail_reads = threading.Event()
        if initial_error:
            fail_reads.set()
        failure = (
            (503, {"error": "fixture catalog unavailable"})
            if initial_error else (200, bad_payload)
        )
        fixtures["/api/v1/skills"] = lambda: failure if fail_reads.is_set() else good

        def interact(process, master_fd, _slave_fd, output, _base_path):
            resize_and_wait(process, master_fd, output, rows=30, columns=160, needle=b"MASC Dashboard")
            tab_until(process, master_fd, output, b"MASC System")
            send_and_wait(process, master_fd, output, b"t", b"MASC System / Tools")
            frame = send_and_wait(
                process, master_fd, output, b"p" * 3,
                b"skills catalog load failed:" if initial_error else b"1 of 2 catalog Skills observed",
            )
            if not initial_error:
                fail_reads.set()
                frame = send_and_wait(process, master_fd, output, b"r", b"Previous catalog reading retained")
            drain_until_quiet(process, master_fd, output)
            completed = bytes(output[:output.rfind(FRAME_END) + len(FRAME_END)])
            rendered = screen_text(completed)
            causes = (
                (b"HTTP 503", b"fixture catalog unavailable")
                if initial_error else (b"usage_coverage",)
            )
            if rendered.count(b"skills catalog load failed:") != 1 or not all(
                cause in rendered for cause in causes
            ):
                raise AssertionError(f"Catalog failure was hidden or duplicated: {frame!r}")
            if b"Skill catalog read failed:" in rendered or b"refresh failed" in rendered:
                raise AssertionError(f"Catalog failure was described more than once: {frame!r}")
            # The source is named once on the whole screen, not only once in
            # front of "load failed:": a cause that still carries its own
            # "skills catalog" prefix names the source twice.
            if rendered.lower().count(b"skills catalog") != 1:
                raise AssertionError(f"Catalog failure named its source twice: {frame!r}")
            if initial_error:
                if b"unavailable (no catalog reading)" not in rendered:
                    raise AssertionError(f"First failed reading still looked like loading: {frame!r}")
            elif not re.search(rb"alpha\s+12\s+12\s+9\s+\d{4}-", rendered):
                raise AssertionError(f"Refresh failure lost the previous known counts: {frame!r}")
            os.write(master_fd, b"q")

        run_terminal_scenario(
            executable,
            description=f"Skill catalog error: {'initial' if initial_error else 'refresh'}",
            interact=interact, http_fixtures=fixtures,
        )


def run_tools_request_identity_regression(executable: str) -> None:
    fixtures = skills_usage_clarity_http_fixtures()

    def inventory(keeper: str, tool: str) -> HttpResponse:
        return 200, {
            "tool_inventory": {"count": 0, "tools": []},
            "effective_keeper_surface": {
                "status": "available", "keeper_name": keeper,
                "runtime_id": "fixture.tools", "official_client_kind": "agent_core",
                "tool_delivery": {"status": "delivered"}, "native_posture": None,
                "skill_snapshot_revision": "c" * 64,
                "instruction_skills": [], "composition_skills": [], "skill_profiles": [],
                "skill_discovery_bytes": 0, "skill_eager_body_bytes": 0, "skills_left_out": [],
                "unavailable_skill_names": [],
                "count": 1, "tools": [{"name": tool, "origin": {"kind": "descriptor"}}],
                "tool_surface_sha256": None,
            },
            "skill_activations": {"status": "no_session", "keeper_name": keeper},
        }

    alpha_late = GatedHttpResponse(inventory("alpha", "keeper_alpha_late"), hold_seconds=30.0)
    beta_refresh_error = GatedHttpResponse(
        (503, {"error": "obsolete beta refresh failure"}),
        subsequent_response=inventory("beta", "keeper_beta_newest"), hold_seconds=30.0,
    )
    fixtures["/api/v1/dashboard/tools?keeper=alpha"] = alpha_late
    fixtures["/api/v1/dashboard/tools?keeper=beta"] = inventory("beta", "keeper_beta_current")
    async_calls = 0
    async_lock = threading.Lock()
    settled = {n: threading.Event() for n in range(1, 5)}

    def async_read() -> HttpResponse:
        nonlocal async_calls
        # launch_tools_load enqueues Tools_loaded before this sequential GET.
        # This is a response-settlement barrier, not an arbitrary sleep.
        with async_lock:
            async_calls += 1
            event = settled.get(async_calls)
        if event is not None:
            event.set()
        return 200, {
            "schema": "masc.async-request-observation/v1", "status": "ready",
            "summary": {"active": 0, "runtime_owned": 0, "ownership_unknown": 0, "record_errors": 0},
            "requests": [], "record_errors": [], "startup_recovery": None,
        }

    fixtures["/api/v1/async-requests"] = async_read

    def interact(process, master_fd, _slave_fd, output, _base_path):
        def await_event(event: threading.Event, description: str) -> None:
            if not wait_for_fixture_event(process, master_fd, output, event, timeout=10.0):
                raise AssertionError(description)

        def assert_current(expected: bytes, *, columns: int) -> None:
            # The main loop handles resize, drains async_messages, then calls
            # Render_schedule.take/present_frame. Require that completed full
            # redraw, not merely an earlier frame containing the same label.
            read_available(master_fd, output)
            before_resize = len(output)
            resize_and_wait(process, master_fd, output, rows=30, columns=columns,
                            needle=expected, controls=(FULL_REDRAW,))
            redraw = output.find(FULL_REDRAW, before_resize)
            wait_for_output(process, master_fd, output, FRAME_END, start=redraw, timeout=3.0)
            screen = screen_text(bytes(output))
            for stale in (b"keeper_alpha_late", b"obsolete beta refresh failure"):
                if stale in screen:
                    raise AssertionError(f"stale Tools response replaced the current view: {screen!r}")

        try:
            resize_and_wait(process, master_fd, output, rows=30, columns=120, needle=b"MASC Dashboard")
            tab_until(process, master_fd, output, b"MASC System")
            os.write(master_fd, b"t")
            await_event(alpha_late.requested, "alpha Tools request did not start")
            send_and_wait(process, master_fd, output, b"]", b"keeper_beta_current")
            await_event(settled[1], "beta Tools response did not settle")
            with async_lock:
                if async_calls != 1:
                    raise AssertionError("held alpha request settled before its fixture response")
            alpha_late.release.set()
            await_event(settled[2], "late alpha response did not settle")
            assert_current(b"keeper_beta_current", columns=119)

            fixtures["/api/v1/dashboard/tools?keeper=beta"] = beta_refresh_error
            os.write(master_fd, b"r")
            await_event(beta_refresh_error.requested, "older beta refresh did not start")
            send_and_wait(process, master_fd, output, b"r", b"keeper_beta_newest")
            await_event(settled[3], "newer beta refresh did not settle")
            with async_lock:
                if async_calls != 3:
                    raise AssertionError("held beta error settled before its fixture response")
            beta_refresh_error.release.set()
            await_event(settled[4], "obsolete same-keeper error did not settle")
            assert_current(b"keeper_beta_newest", columns=120)
            captured = bytes(output)
            end = captured.rfind(FRAME_END) + len(FRAME_END)
            redraw = captured.rfind(FULL_REDRAW, 0, end)
            start = captured.rfind(FRAME_START, 0, redraw)
            if min(start, redraw) < 0:
                raise AssertionError("Tools request identity evidence has no completed redraw")
            print("TOOLS_REQUEST_IDENTITY_PTY_EVIDENCE " + json.dumps({
                "fixture": "A slow / B fast / A late; older same-Keeper error after newer success",
                "settled_tool_responses": async_calls, "rows": 30, "columns": 120,
                "binary_sha256": hashlib.sha256(Path(executable).read_bytes()).hexdigest(),
                "encoding": "base64", "pty": base64.b64encode(captured[start:end]).decode(),
            }), flush=True)
            os.write(master_fd, b"q")
        finally:
            alpha_late.release.set()
            beta_refresh_error.release.set()

    run_terminal_scenario(executable, description="Tools responses retain requested Keeper and generation",
                          interact=interact, http_fixtures=fixtures)


def run_tools_purpose_regression(executable: str) -> None:
    fixtures = skills_usage_clarity_http_fixtures()
    # Alpha has an empty current ledger; the workspace aggregate retains
    # another Keeper's usage. The two panes must keep those scopes distinct.
    skills = fixtures["/api/v1/skills"]
    assert isinstance(skills, tuple)
    skills[1]["surfaces"][0]["usage"][0]["keeper"] = "bravo"
    suppressed = threading.Event()
    ledger_contents = {
        "workspace_key": "1" * 64, "session_id": "trace-alpha",
        "activations": [], "transition_rejections": [],
    }
    ledger_revision = hashlib.sha256(
        json.dumps(ledger_contents, separators=(",", ":")).encode()
    ).hexdigest()
    effective = {
        "status": "available", "keeper_name": "alpha", "runtime_id": "fixture.tools",
        "official_client_kind": "agent_core", "tool_delivery": {"status": "delivered"},
        "native_posture": None, "skill_snapshot_revision": "c" * 64,
        "instruction_skills": [], "composition_skills": [], "skill_profiles": [],
        "skill_discovery_bytes": 0, "skill_eager_body_bytes": 0, "skills_left_out": [],
        "unavailable_skill_names": [],
        "count": 1, "tools": [{"name": "keeper_status", "origin": {"kind": "descriptor"}}],
        "tool_surface_sha256": None,
    }
    inventory = {
        "count": 1,
        "tools": [{
            "name": "masc_board_post", "description": "Registered fixture tool",
            "registered_schema": True, "direct_call_allowed": False,
            "doc_refs": [], "prompt_hints": [], "surfaces": [],
        }],
    }
    fixtures["/api/v1/dashboard/tools?keeper=alpha"] = lambda: (200, {
        "tool_inventory": inventory,
        "effective_keeper_surface": ({**effective, "tools": [], "count": 0,
            "tool_delivery": {"status": "suppressed", "reason": "runtime_tools_unsupported"}}
            if suppressed.is_set() else effective),
        "skill_activations": {
            "status": "available", "keeper_name": "alpha",
            "ledger": {"schema": "masc.skill-activations/v5", **ledger_contents, "revision": ledger_revision},
        },
    })
    async_payload = {
        "schema": "masc.async-request-observation/v1", "status": "ready",
        "summary": {"active": 1, "runtime_owned": 0, "ownership_unknown": 1, "record_errors": 0},
        "requests": [{"request_id": "request-unowned", "keeper_name": "alpha", "status": "queued",
                      "elapsed_sec": 2, "worker_ownership": "disk_only_ownership_unknown"}],
        "record_errors": [], "startup_recovery": None,
    }
    fixtures["/api/v1/async-requests"] = lambda: (200, async_payload)

    def interact(process, master_fd, _slave_fd, output, _base_path):
        resize_and_wait(process, master_fd, output, rows=30, columns=120, needle=b"MASC Dashboard")
        tab_until(process, master_fd, output, b"MASC System")
        send_and_wait(process, master_fd, output, b"t", b"keeper_status")

        def require(*labels: str) -> None:
            screen = screen_text(bytes(output))
            for label in labels:
                if label.encode() not in screen:
                    raise AssertionError(f"Tools pane omitted {label!r}: {screen!r}")

        require("선택 Keeper의 도구·Skill 노출 범위", "ORIGIN=도구 출처", "Runtime 도구 전달: 지원")
        if b"masc_board_post" in screen_text(bytes(output)):
            raise AssertionError("Catalog-only tool appeared on selected Keeper surface")
        send_and_wait(process, master_fd, output, b"p", b"request-unowned")
        require("워크스페이스의 비동기 요청·복구 상태", "소유 확인 안 됨", "ownership-unknown=1")
        # Broken API data must not be presented as a healthy empty broker.
        for broken in ("unknown", None, -1):
            async_payload["summary"]["active"] = broken
            send_and_wait(process, master_fd, output, b"r", "읽기 실패:".encode())
            require("active")
            if b"active=0" in screen_text(bytes(output)) or b"request-unowned" in screen_text(bytes(output)):
                raise AssertionError("Malformed counter retained a healthy summary or stale request")
            async_payload["summary"]["active"] = 1
            send_and_wait(process, master_fd, output, b"r", b"request-unowned")
        del async_payload["summary"]["runtime_owned"]
        send_and_wait(process, master_fd, output, b"r", "읽기 실패:".encode())
        require("runtime_owned")
        async_payload["summary"]["runtime_owned"] = 0
        async_payload["startup_recovery"] = {"lost": 0}
        send_and_wait(process, master_fd, output, b"r", b"finalized")
        require("읽기 실패:")
        if b"finalized=0" in screen_text(bytes(output)):
            raise AssertionError("Missing recovery counter became zero")
        captured = bytes(output)
        end = captured.rfind(FRAME_END) + len(FRAME_END)
        redraw = captured.rfind(FULL_REDRAW, 0, end)
        start = captured.rfind(FRAME_START, 0, redraw)
        if min(start, redraw) < 0:
            raise AssertionError("Async error evidence has no completed redraw")
        print("ASYNC_OBSERVATION_PTY_EVIDENCE " + json.dumps({
            "fixture": "incomplete recovery report must fail visibly", "rows": 30, "columns": 120,
            "binary_sha256": hashlib.sha256(Path(executable).read_bytes()).hexdigest(),
            "encoding": "base64", "pty": base64.b64encode(captured[start:end]).decode(),
        }), flush=True)
        async_payload["startup_recovery"] = None
        async_payload["requests"][0]["worker_ownership"] = "new_unknown_owner"
        send_and_wait(process, master_fd, output, b"r", b"unknown worker ownership")
        require("읽기 실패:")
        async_payload["requests"][0]["worker_ownership"] = "disk_only_ownership_unknown"
        send_and_wait(process, master_fd, output, b"r", b"request-unowned")
        saved_requests = async_payload["requests"]
        async_payload["requests"] = []
        async_payload["summary"].update(active=0, ownership_unknown=0)
        send_and_wait(process, master_fd, output, b"r", b"active=0")
        if "읽기 실패:".encode() in screen_text(bytes(output)):
            raise AssertionError("Valid empty broker was rejected")
        async_payload["requests"] = saved_requests
        async_payload["summary"].update(active=1, ownership_unknown=1)
        send_and_wait(process, master_fd, output, b"r", b"request-unowned")
        send_and_wait(process, master_fd, output, b"p", b"Skill Use")
        require("현재 세션에 보존된 Skill 증거", "호출·전달·이후 행동은 별도 증거", "0 receipts",
                "instruction triggered 0 · delivered 0 · handed off 0 · actions 0")
        # One keeper, one row, counts in their own columns. Joined onto one
        # line, six keepers ran past the pane and the last of them could not
        # be read at all.
        send_and_wait(process, master_fd, output, b"p", b"TRIGGERED")
        require("현재 Keeper 세션들에서 읽힌 Skill revision별 사용 집계",
                "TRIGGERED/DELIVERED/ACTIONS=호출/전달/이후 행동",
                "1 of 2 catalog Skills observed", "Activation ledgers loaded: 19; unavailable: 0")
        usage_rows = screen_rows(bytes(output))
        bravo = [text for text in usage_rows.values() if b"bravo" in text]
        if not any(re.search(rb"bravo\s+12\s+12\s+9\s+\d{4}-", text) for text in bravo):
            raise AssertionError(
                f"the keeper's counts are not in their own columns: {bravo!r}"
            )
        if any(b"12/12/9" in text for text in usage_rows.values()):
            raise AssertionError("the joined per-keeper reading is back")
        send_and_wait(process, master_fd, output, b"p", b"masc_board_post")
        require("MASC 전체 등록 도구 목록", "DIRECT=직접 호출 허용", "surfaces=none은 노출 경로 없음")
        send_and_wait(process, master_fd, output, b"p", b"keeper_status")
        # The footer is the frame's last row, so wait for the frame to finish
        # rather than for its title: the key is read from that row below.
        resize_and_wait(process, master_fd, output, rows=30, columns=90, needle=b"MASC System / Tools",
                        final_cursor=b"\x1b[?25l")
        # The strip names the panes; the key that walks them is the footer's
        # "p:section" (#35638). The strip used to say it again as "p:다음 탭".
        require("호출 범위", "비동기 작업", "Skill 기록", "사용 집계", "전체 도구", "p:section",
                "사용 증거: Skill 기록", "Tool 호출별 입출력: Acting")
        if "p:다음 탭".encode() in screen_text(bytes(output)):
            raise AssertionError("Tools pane strip spelled the footer's p key a second time")
        suppressed.set()
        send_and_wait(process, master_fd, output, b"r", "Runtime 도구 전달: 미지원으로 제외".encode())
        require("Runtime 도구 전달: 미지원으로 제외", "0 tools")
        if b"keeper_status" in screen_text(bytes(output)):
            raise AssertionError("Suppressed surface retained a previously callable tool")
        captured = bytes(output)
        end = captured.rfind(FRAME_END)
        if end < 0:
            raise AssertionError("Tools evidence has no completed terminal frame")
        end += len(FRAME_END)
        redraw = captured.rfind(FULL_REDRAW, 0, end)
        start = captured.rfind(FRAME_START, 0, redraw) if redraw >= 0 else -1
        if start < 0:
            raise AssertionError("Tools evidence has no complete redraw origin")
        print("TOOLS_PURPOSE_PTY_EVIDENCE " + json.dumps({
            "fixture": "isolated tool purpose and scope", "rows": 30, "columns": 90,
            "binary_sha256": hashlib.sha256(Path(executable).read_bytes()).hexdigest(),
            "encoding": "base64", "pty": base64.b64encode(captured[start:end]).decode(),
        }), flush=True)
        os.write(master_fd, b"q")

    run_terminal_scenario(executable, description="Tools purposes distinguish visibility, receipts and usage",
                          interact=interact, http_fixtures=fixtures)
