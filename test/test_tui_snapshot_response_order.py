"""Actual TUI reads preserve explicit-refresh order and slow poll progress."""
from __future__ import annotations

import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import sys
import threading
import time
import zlib

import test_tui_keyboard_input as h


PATHS = {
    "gate": "/api/v1/dashboard/gate",
    "held": "/api/v1/keepers/tool-approvals",
    "schedules": h.SCHEDULES_PATH,
}


def fixtures_and_reading(source: str, count: int):
    fixtures = h.schedule_detail_http_fixtures()
    gate = copy.deepcopy(h.blocked_gate_detail_http_fixtures()[PATHS["gate"]][1])
    gate_row = gate["approval_queue"][0]
    schedule = copy.deepcopy(fixtures[PATHS["schedules"]][1])
    schedule_row = schedule["requests"][0]
    held_row = {
        "keeper": "alpha", "tool_call_id": "held-current", "tool": "Execute",
        "args": "{}", "question": "Isolated fixture", "because": None,
        "asked_at": 1787557500.0, "timeout_sec": 300.0,
    }
    gate["approval_queue"] = []
    schedule["requests"] = []
    schedule["request_count"] = 0
    fixtures[PATHS["gate"]] = (200, gate)
    fixtures[PATHS["held"]] = (200, {"pending": []})
    fixtures[PATHS["schedules"]] = (200, schedule)
    fixtures["/api/v1/keepers/tool-approval-mode"] = (200, {"overrides": []})
    reading = copy.deepcopy(fixtures[PATHS[source]][1])
    if source == "gate":
        reading["approval_queue"] = [{**gate_row, "id": f"gate-current-{i}"} for i in range(count)]
    elif source == "held":
        reading["pending"] = [{**held_row, "tool_call_id": f"held-current-{i}"} for i in range(count)]
    else:
        reading["request_count"] = count
        reading["requests"] = [{**schedule_row, "schedule_id": f"schedule-current-{i}"} for i in range(count)]
    return fixtures, (200, reading)


def label(source: str, count: int) -> bytes:
    name = {"gate": "Pending Gate Calls", "held": "Held Tool Approvals", "schedules": "Requests"}[source]
    return f"{name}: {count}".encode()


def open_source(source, process, master, output):
    if source == "schedules":
        h.palette_go(process, master, output, b"go schedules", label(source, 0))
    else:
        h.palette_go(process, master, output, b"go metrics", b"MASC Metrics")
        h.send_and_wait(process, master, output, b"3", label(source, 0))


def capture(binary_sha, source, scenario, process, master, output):
    h.read_available(master, output)
    before = len(output)
    h.resize_and_wait(process, master, output, rows=30, columns=110,
                      needle=label(source, 2), controls=(h.FULL_REDRAW,))
    redraw = output.find(h.FULL_REDRAW, before)
    assert redraw >= 0
    h.wait_for_output(process, master, output, h.FRAME_END, start=redraw, timeout=3.0)
    end = output.find(h.FRAME_END, redraw) + len(h.FRAME_END)
    start = output.rfind(h.FRAME_START, before, redraw)
    assert start >= 0
    frame = bytes(output[start:end])
    screen = h.screen_text(frame)
    assert label(source, 2) in screen and label(source, 0) not in screen, screen
    assert b"obsolete-source-error" not in screen, screen
    print("SNAPSHOT_READ_PTY_EVIDENCE " + json.dumps({
        "source": source, "scenario": scenario, "rows": 30, "columns": 110,
        "binary_sha256": binary_sha, "encoding": "zlib+base64",
        "pty": base64.b64encode(zlib.compress(frame)).decode(),
    }), flush=True)


def explicit_refresh(binary, binary_sha, source, old_fails):
    fixtures, current = fixtures_and_reading(source, 2)
    path = PATHS[source]
    obsolete = (503, {"error": "obsolete-source-error"}) if old_fails else fixtures[path]
    old = h.GatedHttpResponse(obsolete, subsequent_response=current, hold_seconds=10.0)
    next_read = h.GatedHttpResponse(current, subsequent_response=current, hold_seconds=10.0)

    def interact(process, master, _slave, output, _base):
        try:
            open_source(source, process, master, output)
            fixtures[path] = old
            os.write(master, b"r")
            assert h.wait_for_fixture_event(process, master, output, old.requested, timeout=5.0)
            h.send_and_wait(process, master, output, b"r", label(source, 2))
            # Hold the next read so a later current reply cannot conceal an
            # obsolete success/error after it has been delivered by HTTP.
            fixtures[path] = next_read
            old.release.set()
            assert h.wait_for_fixture_event(process, master, output, old.completed, timeout=5.0)
            h.drain_until_quiet(process, master, output)
            screen = h.screen_text(bytes(output))
            assert label(source, 2) in screen and label(source, 0) not in screen, screen
            assert b"obsolete-source-error" not in screen, screen
            os.write(master, b"r")
            assert h.wait_for_fixture_event(process, master, output, next_read.requested, timeout=5.0)
            capture(binary_sha, source, "late error" if old_fails else "late success",
                    process, master, output)
            next_read.release.set()
            os.write(master, b"q")
        finally:
            old.release.set()
            next_read.release.set()

    h.run_terminal_scenario(binary, description=f"{source}: explicit refresh rejects late {'error' if old_fails else 'success'}",
                            interact=interact, http_fixtures=fixtures)


def slow_poll(binary, binary_sha, source):
    fixtures, current = fixtures_and_reading(source, 2)
    path = PATHS[source]
    slow = h.GatedHttpResponse(current, subsequent_response=current, hold_seconds=10.0)
    watching_ticks = threading.Event()
    two_ticks = threading.Event()
    resumed = threading.Event()
    tick_count = 0
    tick_lock = threading.Lock()
    began = time.monotonic()
    events = []

    def trace(event):
        events.append({"event": event, "elapsed_s": time.monotonic() - began,
                       "calls": slow.calls, "completed": slow.completed.is_set(),
                       "released": slow.release.is_set()})

    # Every full refresh probes compact server identity before loading the
    # surface. Fleet health (/health?full=1) is view-specific and is never
    # requested by Schedules, so it cannot witness that screen's timer.
    health = fixtures.get("/health", (200, {}))

    def health_read():
        nonlocal tick_count
        if watching_ticks.is_set():
            with tick_lock:
                tick_count += 1
                trace(f"health tick {tick_count}")
                if tick_count >= 2:
                    two_ticks.set()
        return health

    def source_read():
        trace("source entered")
        result = slow()
        trace(f"source returned HTTP {result[0]}")
        if slow.calls > 1:
            resumed.set()
        return result

    fixtures["/health"] = health_read

    def interact(process, master, _slave, output, _base):
        try:
            open_source(source, process, master, output)
            # Opening Schedules can draw its cached zero rows while the
            # explicit arrival read is still pending. Settle a distinct
            # explicit reading before replacing the endpoint: otherwise its
            # obsolete/owning arrival requests can be counted as timer polls.
            _, primed = fixtures_and_reading(source, 1)
            fixtures[path] = primed
            h.send_and_wait(process, master, output, b"r", label(source, 1))
            fixtures[path] = source_read
            # No key starts this read: it comes from the actual TUI timer.
            assert h.wait_for_fixture_event(process, master, output, slow.requested, timeout=5.0)
            trace("watching timer ticks")
            watching_ticks.set()
            assert h.wait_for_fixture_event(process, master, output, two_ticks, timeout=5.0)
            trace("checking pending read")
            assert not slow.completed.is_set(), f"{source} fixture expired before the pending-read assertion"
            assert slow.calls == 1, f"automatic polls replaced the pending {source} read: {slow.calls}"
            start = len(output)
            slow.release.set()
            h.wait_for_output(process, master, output, label(source, 2), start=start, timeout=5.0)
            assert h.wait_for_fixture_event(process, master, output, resumed, timeout=5.0)
            capture(binary_sha, source, "slow poll publishes and polling resumes",
                    process, master, output)
            os.write(master, b"q")
        finally:
            trace("scenario cleanup")
            print("SNAPSHOT_POLL_TIMELINE " + json.dumps({
                "source": source, "binary_sha256": binary_sha,
                "refresh_s": 0.2, "fixture_hold_s": slow.hold_seconds,
                "events": events,
            }), flush=True)
            slow.release.set()

    h.run_terminal_scenario(binary, description=f"{source}: automatic polling preserves a slow read",
                            refresh=0.2, interact=interact, http_fixtures=fixtures)


if __name__ == "__main__":
    binary = os.path.abspath(sys.argv[1])
    binary_sha = hashlib.sha256(Path(binary).read_bytes()).hexdigest()
    for source in PATHS:
        for old_fails in (False, True):
            explicit_refresh(binary, binary_sha, source, old_fails)
        slow_poll(binary, binary_sha, source)
    print("Gate, held approvals, and Schedules snapshot response ownership: PASS")
