from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import subprocess
import threading
import time
from pathlib import Path

from tui_keyboard_harness import (
    DASHBOARD_GOALS_PATH,
    empty_goals_fixture,
    CSI_RE,
    FRAME_END,
    FRAME_START,
    FULL_REDRAW,
    HeadersHttpResponse,
    HttpFixtures,
    HttpRequests,
    HttpResponse,
    Interaction,
    RawHttpResponse,
    StreamingHttpResponse,
    drain_until_quiet,
    overview_event_briefing,
    overview_event_http_fixtures,
    read_available,
    resize_and_wait,
    run_terminal_scenario,
    screen_text,
    send_and_wait,
    tab_until,
    wait_for_fixture_state,
    wait_for_output,
)

# The hook's per-call observation names the keeper turn (total_turns + 1)
# the session-numbered call below belongs to; without it the row would name
# the turn with no number. The session ordinal (7) and the keeper turn (42)
# differ, so a
# needle can tell which of the two numbers a row drew.
OBSERVER_TOOL_CALLED_FRAME = (
    b"id: 1\n"
    b"event: message\n"
    b'data: {"type":"keeper_turn_observation","name":"alpha","turn":7,'
    b'"total_turns":41,"ts_unix":1787505641.0}\n\n'
    b"id: 2\n"
    b"event: message\n"
    b'data: {"type":"agent_core:tool_called","event_type":"tool_called",'
    b'"event_id":"evt-1","ts_unix":1787505641.28,"correlation_id":"trace-1",'
    b'"run_id":"wr-1","parent_event_id":null,"agent_name":"alpha",'
    b'"task_id":"task-1","tool_name":"read_file","payload":{"agent_name":"alpha",'
    b'"tool_name":"read_file","tool_use_id":"tu-1","turn":7}}\n\n'
)


def observer_http_fixtures() -> HttpFixtures:
    """The MCP session handshake and a two-frame observer stream."""

    return {
        # The feed opens only after a refresh reaches the server, and the
        # connection reading counts the overview, board, planning, and
        # approval loads - so one of those must answer.
        "/api/v1/dashboard/briefing": (200, overview_event_briefing()),
        "/api/v1/board?sort_by=hot": (200, {"posts": []}),
        "/mcp": RawHttpResponse(
            200,
            json.dumps({"jsonrpc": "2.0", "id": 1, "result": {}}).encode(),
            content_type="application/json",
            headers=(("Mcp-Session-Id", "mcp_fixture_session"),),
        ),
        "/mcp?sse_kind=observer": RawHttpResponse(
            200,
            OBSERVER_TOOL_CALLED_FRAME,
            content_type="text/event-stream",
        ),
    }


def run_http_badge_refresh_regression(executable: str) -> None:
    fixtures = overview_event_http_fixtures()
    briefing = fixtures["/api/v1/dashboard/briefing"]
    if not isinstance(briefing, tuple):
        raise AssertionError("briefing fixture must be a response tuple")
    completed = 0
    slow_next = threading.Event()
    slow_started = threading.Event()
    release_slow = threading.Event()
    fail_next = threading.Event()

    def answer_briefing() -> HttpResponse:
        nonlocal completed
        if slow_next.is_set():
            slow_started.set()
            release_slow.wait(timeout=4.0)
        else:
            time.sleep(0.08)
        completed += 1
        if fail_next.is_set():
            return (503, {"error": "refresh refused"})
        return briefing

    fixtures["/api/v1/dashboard/briefing"] = answer_briefing
    # The badge reports a full failure only when every requested surface fails.
    # A failed briefing beside successful Board/Planning reads is "partial".
    for path, response in tuple(fixtures.items()):
        if path in ("/health?full=1", "/api/v1/dashboard/briefing"):
            continue
        if isinstance(response, tuple):
            fixtures[path] = lambda response=response: (
                (503, {"error": "refresh refused"}) if fail_next.is_set() else response
            )

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        # The badge colours its status, so the raw PTY bytes split HTTP from [connected].
        connected = re.compile(rb"HTTP (?:\x1b\[[0-9;]*m)*\[connected\]")
        wait_for_output(
            process, master_fd, output, connected, start=0, timeout=3.0
        )
        first_completed = completed
        prompt_start = len(output)
        if not wait_for_fixture_state(
            process, master_fd, output,
            lambda: completed >= first_completed + 2,
            timeout=4.0,
        ):
            raise AssertionError("two prompt HTTP refreshes did not complete")
        # Let the terminal drain the second answer before arming the slow one.
        time.sleep(0.12)
        read_available(master_fd, output)
        slow_next.set()
        if b"refreshing..." in output[prompt_start:]:
            raise AssertionError("a prompt refresh flashed the warning badge")

        if not wait_for_fixture_state(
            process, master_fd, output, slow_started.is_set, timeout=2.0
        ):
            raise AssertionError("the slow refresh did not start")
        slow_start = len(output)
        wait_for_output(
            process, master_fd, output,
            re.compile(rb"HTTP (?:\x1b\[[0-9;]*m)*\[refreshing\.\.\.\]"),
            start=slow_start, timeout=2.0,
        )
        connected_start = len(output)
        release_slow.set()
        wait_for_output(
            process, master_fd, output, connected,
            start=connected_start, timeout=2.0,
        )
        fail_next.set()
        failure_start = len(output)
        wait_for_output(
            process, master_fd, output,
            re.compile(rb"HTTP (?:\x1b\[[0-9;]*m)*\[refresh failed\]"),
            start=failure_start, timeout=2.0,
        )
        os.write(master_fd, b"q")

    try:
        # The shared injection workspace pushes the badge out of this header.
        run_terminal_scenario(
            executable, description="HTTP badge refresh timing",
            interact=interact, refresh=0.5, terminal_cols=140,
            workspace="badge-fixture", http_fixtures=fixtures,
        )
    finally:
        release_slow.set()


def run_observer_reconnect_regression(executable: str) -> None:
    releases = [threading.Event() for _ in range(8)]
    seen: list[dict[str, str]] = []
    requests: HttpRequests = []

    def frame(event_id: int, call: str) -> bytes:
        value = {
            "type": "keeper_tool_call", "name": "alpha", "tool_name": "keeper_skill",
            "ts_unix": 100.0, "turn": 7, "tool_use_id": call,
            "tool_args": {"skill": "input-" + call},
            "tool_result": {"receipt": "output-" + call},
        }
        return f"id: {event_id}\ndata: ".encode() + json.dumps(value).encode() + b"\n\n"

    def respond(headers: dict[str, str]) -> StreamingHttpResponse:
        index = len(seen)
        seen.append(headers)
        handshake = [
            (("x-masc-sse-instance-id", "epoch-a"), ("x-masc-sse-replay", "fresh")),
            (("x-masc-sse-instance-id", "epoch-a"), ("x-masc-sse-replay", "resumed")),
            (("x-masc-sse-instance-id", "epoch-a"), ("x-masc-sse-replay", "resumed")),
            (("x-masc-sse-instance-id", "epoch-b"), ("x-masc-sse-replay", "reset-instance-changed")),
            (("x-masc-sse-instance-id", "epoch-c"),),  # malformed: no replay contract
            (("x-masc-sse-instance-id", "epoch-c"), ("x-masc-sse-replay", "fresh")),
            (),  # peer no longer implements scoped replay
            (),
        ][min(index, 7)]

        def chunks():
            if index == 0:
                yield frame(41, "before-disconnect")
                releases[0].wait(timeout=20)
                yield b"id: 42\n"  # an ID-only partial frame was never delivered
            elif index == 1:
                yield frame(41, "before-disconnect") + frame(42, "during-disconnect")
                releases[1].wait(timeout=20)
            elif index == 2:
                return  # same epoch EOF with zero new events must retain session/cursor
            elif index == 3:
                yield frame(1, "after-restart")
                releases[3].wait(timeout=20)
            elif index in (4, 6):
                # No data: an old peer may suppress all events under our old
                # high numeric cursor. The client must close after headers.
                releases[index].wait(timeout=20)
            elif index == 5:
                yield frame(1, "after-malformed")
                releases[5].wait(timeout=20)
            else:
                yield frame(1, "unsupported-live-only")
                releases[7].wait(timeout=20)

        return StreamingHttpResponse(chunks, headers=handshake)

    fixtures = observer_http_fixtures()
    fixtures["/mcp?sse_kind=observer"] = HeadersHttpResponse(respond)

    def interact(process, master_fd, _slave_fd, output, _base_path):
        try:
            resize_and_wait(process, master_fd, output, rows=38, columns=150, needle=b"MASC Dashboard")
            tab_until(process, master_fd, output, b"MASC System")
            send_and_wait(process, master_fd, output, b"A", b"MASC Activity")
            wait_for_output(process, master_fd, output, b"feed: live 1", start=0, timeout=10)
            send_and_wait(process, master_fd, output, b"f", b"scope actions")
            send_and_wait(process, master_fd, output, b"\r", b"Tool use ID: before-disconnect")
            releases[0].set()
            wait_for_output(process, master_fd, output, b"Retained feed events: 2", start=0, timeout=10)
            drain_until_quiet(process, master_fd, output)
            plain = screen_text(bytes(output))
            for needle in (b"Tool use ID: before-disconnect", b"output-before-disconnect",
                           b"resumed; no event expired while disconnected"):
                if needle not in plain:
                    raise AssertionError(f"Replayed call retargeted selection or lost replay coverage: {plain!r}")
            releases[1].set()
            wait_for_output(process, master_fd, output, b"Retained feed events: 3", start=0, timeout=10)
            wait_for_output(process, master_fd, output, b"disconnected history not recovered", start=0, timeout=10)
            releases[3].set()
            wait_for_output(process, master_fd, output, b"Retained feed events: 4", start=0, timeout=10)
            releases[5].set()
            wait_for_output(process, master_fd, output, b"Retained feed events: 5", start=0, timeout=10)
            drain_until_quiet(process, master_fd, output)
            plain = screen_text(bytes(output))
            if b"Replay unavailable (live only)" not in plain or b"before-disconnect" not in plain:
                raise AssertionError(f"Unsupported peer claimed replay or changed pinned evidence: {plain!r}")
            expected = [(None, None), ("epoch-a", "41"), ("epoch-a", "42"),
                        ("epoch-a", "42"), ("epoch-b", "1"), (None, None),
                        ("epoch-c", "1"), (None, None)]
            actual = [(h.get("x-masc-sse-instance-id"), h.get("last-event-id")) for h in seen]
            if actual != expected:
                raise AssertionError(f"HTTP cursor/epoch sequence differs: {actual!r}")
            if len([path for path, _ in requests if path == "/mcp"]) != 1:
                raise AssertionError("Transient zero-event close replaced the MCP session")
            if any(h.get("mcp-session-id") != "mcp_fixture_session" for h in seen):
                raise AssertionError("Reconnect did not retain the initialized MCP session")
            send_and_wait(process, master_fd, output, b"\x1b", b"MASC Activity")
            detail = send_and_wait(process, master_fd, output, b"g\r", b"Tool use ID: unsupported-live-only")
            if b"output-unsupported-live-only" not in screen_text(bytes(output)):
                raise AssertionError(f"Live-only call did not expose its I/O: {detail!r}")
            captured = bytes(output)
            end = captured.rfind(FRAME_END) + len(FRAME_END)
            redraw = captured.rfind(FULL_REDRAW, 0, end)
            start = captured.rfind(FRAME_START, 0, redraw)
            if end < len(FRAME_END) or start < 0:
                raise AssertionError("Reconnect evidence has no completed redraw frame")
            print("OBSERVER_RECONNECT_EVIDENCE " + json.dumps({
                "fixture": "actual HTTP disconnect/restart/capability negotiation with canonical Keeper I/O",
                "requests": actual, "retained_unique_events": 5,
                "binary_sha256": hashlib.sha256(Path(executable).read_bytes()).hexdigest(),
                "pre_open_history_tested": False, "replay_completeness_proven": False,
                "rows": 38, "columns": 150, "encoding": "base64",
                "pty": base64.b64encode(captured[start:end]).decode(),
            }), flush=True)
            os.write(master_fd, b"q")
        finally:
            for release in releases:
                release.set()

    run_terminal_scenario(executable, description="Observer reconnect preserves scoped exact-call I/O",
                          interact=interact, refresh=0.5, http_fixtures=fixtures,
                          http_requests=requests)


def run_acting_call_evidence_regression(executable: str) -> None:
    release_next = threading.Event()
    keep_open = threading.Event()
    binary_sha256 = hashlib.sha256(Path(executable).read_bytes()).hexdigest()

    def emit_frame(phase: str, output: bytearray) -> None:
        captured = bytes(output)
        end = captured.rfind(FRAME_END)
        if end < 0:
            raise AssertionError("Acting evidence has no completed terminal frame")
        end += len(FRAME_END)
        redraw = captured.rfind(FULL_REDRAW, 0, end)
        start = captured.rfind(FRAME_START, 0, redraw) if redraw >= 0 else -1
        if start < 0:
            raise AssertionError("Acting evidence has no complete redraw origin")
        # A full redraw replaces every row; only its frame and later complete
        # deltas are needed to reproduce this exact screen. Session history
        # made the second evidence record exceed Dune's output allowance.
        current_frame = captured[start:end]
        print("ACTING_PTY_EVIDENCE " + json.dumps({
            "phase": phase, "fixture": "synthetic exact-event inspector",
            "binary_sha256": binary_sha256, "rows": 35, "columns": 140,
            "encoding": "base64", "pty": base64.b64encode(current_frame).decode(),
        }), flush=True)

    def frame(value):
        return b"event: message\ndata: " + json.dumps(value).encode() + b"\n\n"

    keeper = {
        "type": "keeper_tool_call", "name": "alpha", "tool_name": "keeper_skill",
        "ts_unix": 100.0, "turn": 7, "tool_use_id": "skill-call-exact",
        "planned_index": 3, "batch_index": 1, "batch_size": 2, "execution_mode": "concurrent",
        "tool_args": {"skill": "research-plan-exact"},
        "tool_result": {"receipt_sha256": "receipt-exact", "status": "served"},
        "tool_args_preview": "safe-input-preview-exact",
        "tool_output_preview": "safe-output-preview-exact\n\n\x1b[2Jforged-preview-text",
    }
    core = {
        "type": "agent_core:tool_completed", "event_type": "tool_completed",
        "agent_name": "runtime-lane-exact", "tool_name": "masc_fusion", "ts_unix": 101.0,
        "event_id": "event-exact", "run_id": "run-exact", "caused_by": "cause-exact",
        "parent_event_id": "parent-exact", "correlation_id": "trace-exact",
        "payload": {"turn": 7, "tool_use_id": "call-exact", "execution_id": "exec-exact"},
    }
    late = dict(core, event_id="new-event-must-not-replace", tool_name="other_tool")
    late["payload"] = {"turn": 8, "tool_use_id": "new-call-must-not-replace"}

    def chunks():
        yield frame(keeper) + frame(core)
        if release_next.wait(timeout=15):
            yield frame(late)
            keep_open.wait(timeout=15)

    fixtures = observer_http_fixtures()
    fixtures["/mcp?sse_kind=observer"] = StreamingHttpResponse(chunks)

    def interact(process, master_fd, _slave_fd, output, _base_path):
        try:
            resize_and_wait(process, master_fd, output, rows=35, columns=140, needle=b"MASC Dashboard")
            tab_until(process, master_fd, output, b"MASC System")
            send_and_wait(process, master_fd, output, b"A", b"MASC Activity")
            wait_for_output(process, master_fd, output, b"feed: live 2", start=0, timeout=10)
            # A folded turn is never silently opened as one of its calls.
            aggregate_start = len(output)
            os.write(master_fd, b"\r")
            drain_until_quiet(process, master_fd, output)
            if b"ACTING EVENT EVIDENCE" in output[aggregate_start:]:
                raise AssertionError("Aggregated turn opened as an exact call")
            send_and_wait(process, master_fd, output, b"f", b"scope actions")
            io_head = send_and_wait(process, master_fd, output, b"j\r", b"Tool use ID: skill-call-exact")
            for scheduling in (b"Execution mode: concurrent", b"Planned index (zero-based): 3",
                               b"Batch index (zero-based) / size: 1 / 2"):
                if scheduling not in io_head:
                    raise AssertionError(f"Keeper scheduling evidence missing: {scheduling!r}")
            # Narrow the viewport so the I/O requires scrolling even when
            # scheduling metadata is present above it.
            resize_and_wait(process, master_fd, output, rows=22, columns=140,
                            needle=b"ACTING EVENT EVIDENCE")
            io_tail = send_and_wait(process, master_fd, output, b"\x1b[6~", b"safe-output-preview-exact")
            for needle in (b"skill-call-exact", b"research-plan-exact", b"receipt-exact", b"producer-redacted"):
                if needle not in io_head + io_tail:
                    raise AssertionError(f"Selected Keeper event lost I/O evidence {needle!r}: {bytes(output)!r}")
            visible_io = screen_text(bytes(output))
            if b"\x1b[2Jforged-preview-text" in io_head + io_tail:
                raise AssertionError("Tool output preview emitted a terminal clear command")
            for needle in (b"safe-output-preview-exact", b"[2Jforged-preview-text"):
                if needle not in visible_io:
                    raise AssertionError(f"Terminal-safe multiline preview lost text {needle!r}: {visible_io!r}")
            resize_and_wait(process, master_fd, output, rows=35, columns=140,
                            needle=b"safe-output-preview-exact")
            emit_frame("redacted-io", output)
            send_and_wait(process, master_fd, output, b"\x1b", b"MASC Activity")
            detail = send_and_wait(process, master_fd, output, b"k\r", b"Execution ID: exec-exact")
            for needle in (b"Event ID: event-exact", b"Run ID: run-exact", b"Parent event ID: parent-exact", b"Caused by: cause-exact", b"Correlation ID: trace-exact"):
                if needle not in CSI_RE.sub(b"", detail):
                    raise AssertionError(f"Selected runtime event lost exact reference {needle!r}: {detail!r}")
            start = len(output)
            release_next.set()
            wait_for_output(process, master_fd, output, b"Retained feed events: 3", start=start, timeout=8)
            drain_until_quiet(process, master_fd, output)
            pinned = bytes(output[start:])
            plain = screen_text(bytes(output))
            if b"Execution ID: exec-exact" not in plain or b"new-call-must-not-replace" in plain:
                raise AssertionError(f"New SSE event retargeted the open detail: {pinned!r}")
            emit_frame("pinned-exact-event", output)
            send_and_wait(process, master_fd, output, b"\x1b", b"MASC Activity")
            # The newly arrived event is independently selectable after closing.
            latest = send_and_wait(process, master_fd, output, b"g\r", b"new-call-must-not-replace")
            if b"Execution ID: not carried" not in screen_text(bytes(output)):
                raise AssertionError(f"Absent execution identity inherited the previous call: {latest!r}")
            keep_open.set()
            os.write(master_fd, b"q")
        finally:
            release_next.set()
            keep_open.set()

    run_terminal_scenario(executable, description="Acting exact event evidence stays pinned across SSE",
                          interact=interact, http_fixtures=fixtures)


def observer_feed_interaction(requests: HttpRequests) -> Interaction:
    """The TUI opens an MCP session after its first refresh reaches the
    server, subscribes to the observer feed with that session, and counts
    the frames it receives on the Overview row."""

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        # The fixture closes the stream right after its two frames, so the
        # row the test can rely on is the closed one. What this scenario is
        # about is the MCP session and the subscription under it, so it waits
        # for the row to exist and not for the number on it: the count and
        # where it sits are read by test_tui_feed_row_counts_events.py, which
        # names masc_tui_render.ml and is selected by a change to the row.
        # Spelling the number here made a wording change to the row a change
        # to this file, and editing this file puts the whole walk inside the
        # gate's twelve-minute step alongside every other suite the change
        # selects. The row is on Activity's status line.
        read_available(master_fd, output)
        activity_start = len(output)
        tab_until(process, master_fd, output, b"MASC System")
        send_and_wait(process, master_fd, output, b"A", b"MASC Activity")
        wait_for_output(
            process, master_fd, output, b"feed: closed", start=0, timeout=10.0
        )
        initialize = [body for path, body in requests if path == "/mcp"]
        if len(initialize) != 1:
            raise AssertionError(
                f"expected one MCP initialize, saw {len(initialize)}: {requests!r}"
            )
        payload = json.loads(initialize[0])
        if payload.get("method") != "initialize":
            raise AssertionError(f"MCP POST was not an initialize: {payload!r}")
        # The call frame the fixture streamed is a row on the Acting surface;
        # the observation is held but hidden. The default view folds the call
        # into a turn chunk: the running turn names its in-flight call under
        # the keeper's number.
        # The walk is already on Activity; another Tab would leave it.
        wait_for_output(
            process,
            master_fd,
            output,
            "(1 row \u00b7 2 events held)".encode(),
            start=activity_start,
            timeout=10.0,
        )
        acting = bytes(output[activity_start:])
        for needle, what in (
            ("(1 row \u00b7 2 events held)".encode(), "the shown rows and held events"),
            (b"alpha", "the keeper that acted"),
            (b"turn 42", "the keeper turn"),
            (b"read_file", "the in-flight tool"),
        ):
            if needle not in acting:
                raise AssertionError(f"Acting did not draw {what}: {acting!r}")
        # The count belongs to the open reading, not to the Logs tab it
        # follows: a dot stands between the strip and the count.
        if "Logs  \u00b7  (1 row \u00b7 2 events held)".encode() not in CSI_RE.sub(b"", acting):
            raise AssertionError(
                f"Activity's count sat against the Logs tab: {CSI_RE.sub(b'', acting)!r}"
            )
        # One f lands on the flat actions log, where the call is its own row
        # and carries the task. The title counts the same here; the scope row
        # under the feed says which log is open.
        flat = send_and_wait(
            process, master_fd, output, b"f", b"scope actions"
        )
        for needle, what in (
            ("\u25b6 call".encode(), "the call glyph and label"),
            (b"read_file", "the tool"),
            (b"task-1", "the task"),
        ):
            if needle not in flat:
                raise AssertionError(f"Actions did not draw {what}: {flat!r}")
        # The frame's turn is the agent session's ordinal, not a keeper turn,
        # so the flat row leaves it to the event evidence.
        if b"turn 7" in flat:
            raise AssertionError(f"Actions drew the session ordinal as a turn: {flat!r}")
        os.write(master_fd, b"q")

    return interact


def run_http_conditional_read_regression(executable: str) -> None:
    """A dashboard read sends the tag of the answer it kept, and a 304 answers
    with that answer. The briefing is the first read of every full pass and
    the goal tree the last one on the Overview, so a slow goal tree keeps one
    pass out across several ticks; the briefing's tag must still go out on
    the pass after it."""
    fixtures = overview_event_http_fixtures()
    briefing = fixtures["/api/v1/dashboard/briefing"]
    if not isinstance(briefing, tuple):
        raise AssertionError("briefing fixture must be a response tuple")
    _status, briefing_payload = briefing
    briefing_body = json.dumps(briefing_payload).encode()
    briefing_tag = 'W/"briefing-fixture"'
    reads = {"untagged": 0, "tagged": 0}
    slow_goals = threading.Event()
    slow_goals_done = threading.Event()

    def answer_briefing(headers: dict[str, str]) -> RawHttpResponse:
        if headers.get("if-none-match") == briefing_tag:
            reads["tagged"] += 1
            return RawHttpResponse(
                304, b"", content_type="application/json",
                headers=(("ETag", briefing_tag),),
            )
        reads["untagged"] += 1
        return RawHttpResponse(
            200, briefing_body, content_type="application/json",
            headers=(("ETag", briefing_tag),),
        )

    def answer_goals() -> HttpResponse:
        if slow_goals.is_set() and not slow_goals_done.is_set():
            # Longer than three refresh ticks at refresh=0.5.
            time.sleep(1.6)
            slow_goals_done.set()
        return empty_goals_fixture()

    fixtures["/api/v1/dashboard/briefing"] = HeadersHttpResponse(answer_briefing)
    fixtures[DASHBOARD_GOALS_PATH] = answer_goals

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        connected = re.compile(rb"HTTP (?:\x1b\[[0-9;]*m)*\[connected\]")
        wait_for_output(
            process, master_fd, output, connected, start=0, timeout=3.0
        )
        if not wait_for_fixture_state(
            process, master_fd, output,
            lambda: reads["tagged"] >= 2,
            timeout=4.0,
        ):
            raise AssertionError(
                f"the briefing's tag did not go out on two reads: {reads!r}"
            )
        answered_start = len(output)
        wait_for_output(
            process, master_fd, output, connected,
            start=answered_start, timeout=2.0,
        )
        if b"HTTP 304" in output:
            raise AssertionError("a 304 reached the screen as a refusal")
        slow_goals.set()
        if not wait_for_fixture_state(
            process, master_fd, output, slow_goals_done.is_set, timeout=4.0
        ):
            raise AssertionError("the slow goal tree read did not finish")
        reads_after_slow = reads["tagged"] + reads["untagged"]
        if not wait_for_fixture_state(
            process, master_fd, output,
            lambda: reads["tagged"] + reads["untagged"] >= reads_after_slow + 2,
            timeout=4.0,
        ):
            raise AssertionError(
                f"the briefing was not read again after the slow pass: {reads!r}"
            )
        if reads["untagged"] != 1:
            raise AssertionError(
                "only the first briefing read may go out without the tag; "
                f"reads were {reads!r}"
            )
        os.write(master_fd, b"q")

    try:
        run_terminal_scenario(
            executable, description="HTTP conditional read",
            interact=interact, refresh=0.5, terminal_cols=140,
            workspace="conditional-read-fixture", http_fixtures=fixtures,
        )
    finally:
        slow_goals_done.set()
