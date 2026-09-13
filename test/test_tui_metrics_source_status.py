"""Actual HTTP responses drive Metrics' per-source availability and counts."""
from __future__ import annotations

import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import select
import sys
import time
import zlib

import test_tui_keyboard_input as h


def run(executable: str) -> None:
    fixtures = h.blocked_gate_detail_http_fixtures()
    gate_path = "/api/v1/dashboard/gate"
    held_path = "/api/v1/keepers/tool-approvals"
    modes_path = "/api/v1/keepers/tool-approval-mode"
    gate = copy.deepcopy(fixtures[gate_path][1])
    gate["approval_rules"] = [{
        "id": "rule-source-proof", "keeper_name": "alpha", "tool_name": "Execute",
        "request_fingerprint": "b" * 64, "created_at": 1787557500.0,
    }]
    held = {"pending": [{
        "keeper": "alpha", "tool_call_id": "held-source-proof", "tool": "keeper_skill",
        "args": "{}", "question": "Source fixture only", "because": None,
        "asked_at": 1787557500.0, "timeout_sec": 300.0,
    }]}
    modes = {"overrides": [{"keeper": "alpha", "mode": "yolo"}]}
    zero_gate = {**gate, "approval_queue": [], "approval_rules": []}
    no_queue = {**gate, "approval_queue": None,
                "approval_queue_state": {"state": "unavailable", "operator_detail": "queue-store-offline"}}
    no_rules = {**gate, "approval_rules": None,
                "approval_rules_state": {"state": "unavailable", "error": "rule-store-offline"}}
    phase = "initial"
    requests: list[tuple[str, str]] = []
    sources = ("gate", "held", "modes")

    def response(source: str):
        requested_phase = phase
        requests.append((requested_phase, source))
        if requested_phase == "initial" or (requested_phase == "stale" and source != "held"):
            return 503, {"error": source + "-source-offline"}
        if requested_phase == "rules-unavailable" and source == "held":
            return 503, {"error": "held-source-offline"}
        if source == "gate":
            return 200, {"zero": zero_gate, "queue-unavailable": no_queue,
                         "rules-unavailable": no_rules}.get(requested_phase, gate)
        if source == "held":
            return 200, {"pending": []} if requested_phase == "zero" else held
        return 200, {"overrides": []} if requested_phase == "zero" else modes

    fixtures[gate_path] = lambda: response("gate")
    fixtures[held_path] = lambda: response("held")
    fixtures[modes_path] = lambda: response("modes")

    def interact(process, master, _slave, output, _base_path):
        nonlocal phase

        def await_screen(*required: str, absent: tuple[str, ...] = ()) -> bytes:
            deadline = time.monotonic() + 5.0
            while time.monotonic() < deadline:
                h.read_available(master, output)
                end = output.rfind(h.FRAME_END)
                screen = h.screen_text(bytes(output[:end + len(h.FRAME_END)])) if end >= 0 else b""
                if all(label.encode() in screen for label in required) and all(
                    label.encode() not in screen for label in absent
                ):
                    return screen
                if process.poll() is not None:
                    break
                select.select([master], [], [], 0.05)
            raise AssertionError(f"Metrics phase {phase}: required={required!r} absent={absent!r} requests={requests!r}: {screen!r}")

        # A phase's screen can already hold what it requires before that phase
        # has been asked for: "YOLO Keepers: 1" is the queue-unavailable reading
        # as well as the rules-unavailable one. Moving on at that point retags
        # the request still on its way, and the final ownership check then
        # finds the phase without it. Each phase waits for its own three.
        def await_requests(expected: str) -> None:
            deadline = time.monotonic() + 5.0
            missing = list(sources)
            while time.monotonic() < deadline:
                h.read_available(master, output)
                missing = [source for source in sources if (expected, source) not in requests]
                if not missing:
                    return
                if process.poll() is not None:
                    break
                select.select([master], [], [], 0.05)
            raise AssertionError(f"Metrics phase {expected}: no request for {missing!r}: requests={requests!r}")

        def refresh(next_phase: str) -> None:
            nonlocal phase
            phase = next_phase
            os.write(master, b"r")
            await_requests(next_phase)

        def evidence() -> None:
            captured = bytes(output)
            end = captured.rfind(h.FRAME_END) + len(h.FRAME_END)
            redraw = captured.rfind(h.FULL_REDRAW, 0, end)
            start = captured.rfind(h.FRAME_START, 0, redraw)
            if min(start, redraw) < 0:
                raise AssertionError("Metrics evidence has no complete redraw origin")
            print("METRICS_SOURCE_PTY_EVIDENCE " + json.dumps({
                "phase": phase, "rows": 30, "columns": 100,
                "binary_sha256": hashlib.sha256(Path(executable).read_bytes()).hexdigest(),
                "encoding": "zlib+base64",
                "pty": base64.b64encode(zlib.compress(captured[start:end])).decode(),
            }), flush=True)

        h.palette_go(process, master, output, b"go metrics", b"MASC Metrics")
        h.send_and_wait(process, master, output, b"3", b"Gate Governance")
        await_requests("initial")
        await_screen("Gate unavailable", "Tool holds unavailable", "YOLO Keepers: unavailable",
                     "Pending Gate Calls: unavailable", "Standing Rules: unavailable",
                     absent=("no active pending", "Pending Gate Calls: 0", "Tool holds 0"))
        refresh("ready")
        await_screen("Gate 1", "Tool holds 1", "Pending Gate Calls: 1",
                     "Held Tool Approvals: 1", "Standing Rules: 1", "YOLO Keepers: 1")
        refresh("stale")
        await_screen("Gate stale", "Tool holds 1", "Pending Gate Calls: stale: previous reading",
                     "Standing Rules: stale: previous reading", "YOLO Keepers: stale: previous reading",
                     "partial coverage", "keeper_skill", absent=("no active pending",))
        evidence()
        refresh("queue-unavailable")
        await_screen("Gate unavailable", "Tool holds 1", "queue-store-offline",
                     "Standing Rules: 1", "YOLO Keepers: 1", "partial coverage",
                     absent=("no active pending", "Pending Gate Calls: 0"))
        refresh("rules-unavailable")
        await_screen("Gate 1", "Tool holds stale", "rule-store-offline",
                     "Pending Gate Calls: 1", "YOLO Keepers: 1", "partial coverage",
                     absent=("no active pending", "Standing Rules: 0"))
        refresh("zero")
        await_screen("Gate 0", "Tool holds 0", "Pending Gate Calls: 0",
                     "Held Tool Approvals: 0", "Standing Rules: 0", "YOLO Keepers: 0",
                     "no active pending gate operations or held approval requests",
                     absent=("previous reading", "partial coverage", "keeper_skill"))
        evidence()
        for expected in ("initial", "ready", "stale", "queue-unavailable", "rules-unavailable", "zero"):
            for source in sources:
                if (expected, source) not in requests:
                    raise AssertionError(f"No real HTTP response for {expected}/{source}")
        os.write(master, b"q")

    h.run_terminal_scenario(executable, description="Metrics source availability remains distinct from zero",
                            interact=interact, http_fixtures=fixtures)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("TUI Metrics source status: PASS")
