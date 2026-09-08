"""Actual HTTP/PTY proof of Tools polling and superseded read ownership."""
import base64
import hashlib
import json
import os
from pathlib import Path
import sys
import threading
import time
import zlib

import test_tui_keyboard_input as h


def inventory(marker):
    return 200, {
        "tool_inventory": {"count": 0, "tools": []},
        "effective_keeper_surface": {
            "status": "available", "keeper_name": "alpha",
            "runtime_id": "fixture.tools", "official_client_kind": "agent_core",
            "tool_delivery": {"status": "delivered"}, "native_posture": None,
            "skill_snapshot_revision": "c" * 64,
            "instruction_skills": [], "composition_skills": [], "skill_profiles": [],
            "skill_discovery_bytes": 0, "skill_eager_body_bytes": 0, "skills_left_out": [],
            "count": 1, "tools": [{"name": marker, "origin": {"kind": "descriptor"}}],
            "tool_surface_sha256": None,
        },
        "skill_activations": {"status": "no_session", "keeper_name": "alpha"},
    }


def evidence(binary, phase, process, master, output, marker, observations):
    h.read_available(master, output)
    before = len(output)
    h.resize_and_wait(process, master, output, rows=30, columns=120,
                      needle=marker, controls=(h.FULL_REDRAW,))
    redraw = output.find(h.FULL_REDRAW, before)
    assert redraw >= 0
    h.wait_for_output(process, master, output, h.FRAME_END, start=redraw, timeout=3.0)
    end = output.find(h.FRAME_END, redraw) + len(h.FRAME_END)
    start = output.rfind(h.FRAME_START, before, redraw)
    frame = bytes(output[redraw if start < 0 else start:end])
    print("TOOLS_POLL_CONTINUITY_PTY_EVIDENCE " + json.dumps({
        "phase": phase, "refresh_s": 2.0, "response_delay_s": 3.0,
        "binary_sha256": hashlib.sha256(Path(binary).read_bytes()).hexdigest(),
        "rows": 30, "columns": 120, "encoding": "zlib+base64",
        "pty": base64.b64encode(zlib.compress(frame)).decode(),
        "observations": observations,
    }), flush=True)


def delayed_reads(binary):
    fixtures = h.skills_usage_clarity_http_fixtures()
    catalog = fixtures["/api/v1/skills"]
    lock = threading.Lock()
    started = []
    async_finished = []
    origin = time.monotonic()

    def tools():
        with lock:
            started.append(time.monotonic() - origin)
            ordinal = len(started)
        time.sleep(3.0)
        return inventory(f"keeper_poll_result_{ordinal}")

    def skills():
        time.sleep(3.0)
        return catalog

    def async_read():
        time.sleep(3.0)
        with lock:
            async_finished.append(time.monotonic() - origin)
        return 503, {"error": "delayed async source failure"}

    fixtures["/api/v1/dashboard/tools?keeper=alpha"] = tools
    fixtures["/api/v1/skills"] = skills
    fixtures["/api/v1/async-requests"] = async_read

    def interact(process, master, _slave, output, _base):
        h.tab_until(process, master, output, b"MASC Config")
        h.send_and_wait(process, master, output, b"t", b"MASC Tools")
        h.wait_for_output(process, master, output, b"keeper_poll_result_1", start=0, timeout=10.0)
        # Inventory must be visible while the independently owned async read
        # is still pending. Its late error must be applied, not starved by ticks.
        h.send_and_wait(process, master, output, b"p", b"Async broker")
        h.wait_for_output(process, master, output, "Async broker — 읽기 실패:".encode(), start=0, timeout=10.0)
        for _ in range(4):
            h.send_and_wait(process, master, output, b"p", b"MASC Tools")
        h.wait_for_output(process, master, output, b"keeper_poll_result_2", start=0, timeout=10.0)
        with lock:
            observations = {"inventory_started_s": list(started),
                            "async_response_ready_s": list(async_finished)}
        assert len(started) >= 2 and async_finished
        assert started[1] >= async_finished[0], observations
        evidence(binary, "slow independent reads settle and polling resumes", process,
                 master, output, b"keeper_poll_result_2", observations)
        os.write(master, b"q")

    h.run_terminal_scenario(binary, description="Tools slow automatic polling",
                            refresh=2.0, interact=interact, http_fixtures=fixtures)


def superseded_catalog(binary):
    fixtures = h.skills_usage_clarity_http_fixtures()
    catalog = fixtures["/api/v1/skills"]
    old = h.GatedHttpResponse((503, {"error": "obsolete catalog"}), hold_seconds=30.0)
    new_started = threading.Event()
    new_ready = threading.Event()
    lock = threading.Lock()
    counts = {"inventory": 0, "catalog": 0}
    at_new_completion = []

    def tools():
        with lock:
            counts["inventory"] += 1
            ordinal = counts["inventory"]
        return inventory(f"keeper_owner_result_{ordinal}")

    def skills():
        with lock:
            counts["catalog"] += 1
            ordinal = counts["catalog"]
        if ordinal == 1:
            return old()
        if ordinal == 2:
            new_started.set()
            time.sleep(3.0)
            with lock:
                at_new_completion.append(dict(counts))
            new_ready.set()
        return catalog

    fixtures["/api/v1/dashboard/tools?keeper=alpha"] = tools
    fixtures["/api/v1/skills"] = skills

    def interact(process, master, _slave, output, _base):
        try:
            h.tab_until(process, master, output, b"MASC Config")
            h.send_and_wait(process, master, output, b"t", b"keeper_owner_result_1")
            assert h.wait_for_fixture_event(process, master, output, old.requested, timeout=5.0)
            h.send_and_wait(process, master, output, b"r", b"keeper_owner_result_2")
            assert h.wait_for_fixture_event(process, master, output, new_started, timeout=5.0)
            old.release.set()
            assert h.wait_for_fixture_event(process, master, output, new_ready, timeout=10.0)
            # A 2s tick occurs while the 3s catalog read is pending. An old
            # completion must not clear the new catalog's ownership and admit
            # another poll before that current read finishes.
            assert at_new_completion == [{"inventory": 2, "catalog": 2}], at_new_completion
            h.wait_for_output(process, master, output, b"keeper_owner_result_3", start=0, timeout=10.0)
            evidence(binary, "old catalog cannot clear new pending owner", process,
                     master, output, b"keeper_owner_result_3", at_new_completion)
            os.write(master, b"q")
        finally:
            old.release.set()

    h.run_terminal_scenario(binary, description="Tools superseded catalog ownership",
                            refresh=2.0, interact=interact, http_fixtures=fixtures)


if __name__ == "__main__":
    binary = os.path.abspath(sys.argv[1])
    delayed_reads(binary)
    superseded_catalog(binary)
    print("Tools automatic polling and superseded owner: PASS")
