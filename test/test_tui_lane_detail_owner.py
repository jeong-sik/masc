"""Real HTTP/PTY proof that selected lane details keep the newest request."""
import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import zlib

import test_tui_keyboard_input as h


def run(binary, transition, old_fails):
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures[h.KEEPER_LANES_PATH] = h.keeper_lanes_response([])
    fixtures[h.STANDALONE_LANES_PATH] = h.standalone_lanes_response()
    row = h.verifier_lane_runs_response()[1]["runs"][0]
    fixtures[h.lane_runs_path("verifier_exact")] = (200, {
        "runs": [{**row, "run_id": "run-owner-a"}, {**row, "run_id": "run-owner-b"}],
        "has_more": False, "total": 2,
    })
    current = copy.deepcopy(h.verifier_lane_run_detail_response()[1])
    current["run"].update(run_id="run-owner-a", status="approved", elapsed_s=5.0)
    current["run"]["output"]["reason"] = "verified current proof"
    older = copy.deepcopy(current)
    older["run"].update(status="running", elapsed_s=None, output=None)
    older["run"]["payload_availability"]["output"] = None
    obsolete = (503, {"error": "obsolete-lane-detail-error"}) if old_fails else (200, older)
    old = h.GatedHttpResponse(obsolete, subsequent_response=(200, current), hold_seconds=20.0)
    path = "/api/v1/dashboard/exact-lane-runs/run-owner-a"
    fixtures[path] = old
    other = copy.deepcopy(current)
    other["run"]["run_id"] = "run-owner-b"
    fixtures["/api/v1/dashboard/exact-lane-runs/run-owner-b"] = (200, other)

    def interact(process, master, _slave, output, _base):
        try:
            h.palette_go(process, master, output, b"go lanes", b"Verifier")
            h.send_and_wait(process, master, output, b"/Verifier",
                           re.compile(rb"\x1b\[7m[^\x1b\n]*Verifier"))
            h.send_and_wait(process, master, output, b"\x1b", b"j/k:move")
            h.send_and_wait(process, master, output, b"\r", b"2 loaded / 2 retained")
            h.send_and_wait(process, master, output, b"\r", b"MASC Lane Run")
            assert h.wait_for_fixture_event(process, master, output, old.requested, timeout=5.0)
            if transition == "refresh":
                h.send_and_wait(process, master, output, b"R", b"APPROVED")
            else:
                h.send_and_wait(process, master, output, b"\x1b", b"2 loaded / 2 retained")
                if transition == "different run":
                    h.send_and_wait(process, master, output, b"j", b"run-owner-b")
                h.send_and_wait(process, master, output, b"\r", b"APPROVED")
            # No later current request may conceal the old response. Lane
            # detail is not polled automatically; only the overview is.
            old.release.set()
            assert h.wait_for_fixture_event(process, master, output, old.completed, timeout=5.0)
            h.drain_until_quiet(process, master, output)
            h.read_available(master, output)
            before = len(output)
            h.resize_and_wait(process, master, output, rows=42, columns=150,
                              needle=b"APPROVED", controls=(h.FULL_REDRAW,))
            redraw = output.find(h.FULL_REDRAW, before)
            assert redraw >= 0
            h.wait_for_output(process, master, output, h.FRAME_END, start=redraw, timeout=3.0)
            end = output.find(h.FRAME_END, redraw) + len(h.FRAME_END)
            start = output.rfind(h.FRAME_START, before, redraw)
            frame = bytes(output[redraw if start < 0 else start:end])
            screen = h.screen_text(frame)
            expected_id = b"run-owner-b" if transition == "different run" else b"run-owner-a"
            assert expected_id in screen and b"APPROVED" in screen, screen
            assert b"NO DECISION YET" not in screen and b"obsolete-lane-detail-error" not in screen, screen
            print("LANE_DETAIL_OWNER_PTY_EVIDENCE " + json.dumps({
                "transition": transition, "late_response": "error" if old_fails else "running",
                "exact_run_id": expected_id.decode(), "rows":42, "columns":150,
                "binary_sha256":hashlib.sha256(Path(binary).read_bytes()).hexdigest(),
                "encoding":"zlib+base64", "pty":base64.b64encode(zlib.compress(frame)).decode(),
            }), flush=True)
            if transition == "refresh" and not old_fails:
                wrong = copy.deepcopy(current)
                wrong["run"]["run_id"] = "wrong-response-id"
                fixtures[path] = (200, wrong)
                h.send_and_wait(process, master, output, b"R",
                               b"lane run detail response does not match the requested run")
                screen = h.screen_text(bytes(output))
                assert b"APPROVED" in screen and b"wrong-response-id" not in screen, screen
            os.write(master, b"q")
        finally:
            old.release.set()

    h.run_terminal_scenario(binary, description=f"lane detail {transition}: late {old_fails=}",
                            interact=interact, http_fixtures=fixtures)


if __name__ == "__main__":
    binary = os.path.abspath(sys.argv[1])
    for transition in ("refresh", "reopen", "different run"):
        for old_fails in (False, True):
            run(binary, transition, old_fails)
    print("Lane detail request ownership: PASS")
