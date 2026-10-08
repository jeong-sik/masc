"""Real HTTP/PTY proof that selected lane details keep the newest request."""
import base64
import copy
import hashlib
import json
import os
import re
import sys
import zlib
from pathlib import Path

import tui_keyboard_harness as _keyboard_harness
import tui_keyboard_keepers as _keyboard_keepers



# The longest ids the lanes reported on 2026-09-28: board attention's prefix
# and 32 hex digits, 54 cells. At the 100 columns this scenario runs at the
# run detail's heading has room for them whole.
RUN_A = "exact-board-attention-d3104cd8683ae948b6ee1721639adf20"
RUN_B = "exact-board-attention-836d84223072c444090b8adc50c29631"


def run(binary, transition, old_fails):
    fixtures = _keyboard_harness.keeper_runtime_http_fixtures()
    fixtures[_keyboard_keepers.KEEPER_LANES_PATH] = _keyboard_keepers.keeper_lanes_response([])
    fixtures[_keyboard_keepers.LANE_INVENTORY_PATH] = _keyboard_keepers.lane_inventory_response()
    row = _keyboard_keepers.verifier_lane_runs_response()[1]["runs"][0]
    fixtures[_keyboard_keepers.lane_runs_path("verifier_exact")] = (200, {
        # The list draws no run id, so the two rows are told apart by the
        # task each verified.
        "runs": [{**row, "run_id": RUN_A, "subject_id": "owner-a"},
                 {**row, "run_id": RUN_B, "subject_id": "owner-b"}],
        "has_more": False, "total": 2,
    })
    current = copy.deepcopy(_keyboard_keepers.verifier_lane_run_detail_response()[1])
    current["run"].update(run_id=RUN_A, status="approved", elapsed_s=5.0)
    current["run"]["output"]["reason"] = "verified current proof"
    older = copy.deepcopy(current)
    older["run"].update(status="running", elapsed_s=None, output=None)
    older["run"]["payload_availability"]["output"] = None
    obsolete = (503, {"error": "obsolete-lane-detail-error"}) if old_fails else (200, older)
    old = _keyboard_harness.GatedHttpResponse(obsolete, subsequent_response=(200, current), hold_seconds=20.0)
    path = "/api/v1/dashboard/exact-lane-runs/" + RUN_A
    fixtures[path] = old
    other = copy.deepcopy(current)
    other["run"]["run_id"] = RUN_B
    fixtures["/api/v1/dashboard/exact-lane-runs/" + RUN_B] = (200, other)

    def interact(process, master, _slave, output, _base):
        try:
            _keyboard_harness.palette_go(process, master, output, b"go lanes", b"Verifier")
            _keyboard_harness.send_and_wait(process, master, output, b"/Verifier",
                           re.compile(rb"\x1b\[7m[^\x1b\n]*Verifier"))
            _keyboard_harness.send_and_wait(process, master, output, b"\x1b", b"j/k:move")
            _keyboard_harness.send_and_wait(process, master, output, b"\r", b"2 loaded / 2 retained")
            opened = len(output)
            _keyboard_harness.send_and_wait(process, master, output, b"\r", b"MASC Lane Run")
            _keyboard_harness.wait_for_output(process, master, output, RUN_A.encode(),
                              start=opened, timeout=3.0)
            heading = next(line for line in _keyboard_harness.screen_text(bytes(output)).splitlines()
                           if b"MASC Lane Run" in line)
            assert RUN_A.encode() in heading, heading
            assert _keyboard_harness.wait_for_fixture_event(process, master, output, old.requested, timeout=5.0)
            if transition == "refresh":
                _keyboard_harness.send_and_wait(process, master, output, b"R", b"APPROVED")
            else:
                _keyboard_harness.send_and_wait(process, master, output, b"\x1b", b"2 loaded / 2 retained")
                if transition == "different run":
                    _keyboard_harness.send_and_wait(process, master, output, b"j",
                                    re.compile(rb"\x1b\[7m[^\x1b\n]*task owner-b"))
                _keyboard_harness.send_and_wait(process, master, output, b"\r", b"APPROVED")
            # No later current request may conceal the old response. Lane
            # detail is not polled automatically; only the overview is.
            old.release.set()
            assert _keyboard_harness.wait_for_fixture_event(process, master, output, old.completed, timeout=5.0)
            _keyboard_harness.drain_until_quiet(process, master, output)
            _keyboard_harness.read_available(master, output)
            before = len(output)
            _keyboard_harness.resize_and_wait(process, master, output, rows=42, columns=150,
                              needle=b"APPROVED", controls=(_keyboard_harness.FULL_REDRAW,))
            redraw = output.find(_keyboard_harness.FULL_REDRAW, before)
            assert redraw >= 0
            _keyboard_harness.wait_for_output(process, master, output, _keyboard_harness.FRAME_END, start=redraw, timeout=3.0)
            end = output.find(_keyboard_harness.FRAME_END, redraw) + len(_keyboard_harness.FRAME_END)
            start = output.rfind(_keyboard_harness.FRAME_START, before, redraw)
            frame = bytes(output[redraw if start < 0 else start:end])
            screen = _keyboard_harness.screen_text(frame)
            expected_id = (RUN_B if transition == "different run" else RUN_A).encode()
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
                _keyboard_harness.send_and_wait(process, master, output, b"R",
                               b"lane run detail response does not match the requested run")
                screen = _keyboard_harness.screen_text(bytes(output))
                assert b"APPROVED" in screen and b"wrong-response-id" not in screen, screen
            os.write(master, b"q")
        finally:
            old.release.set()

    _keyboard_harness.run_terminal_scenario(binary, description=f"lane detail {transition}: late {old_fails=}",
                            interact=interact, http_fixtures=fixtures)


if __name__ == "__main__":
    binary = os.path.abspath(sys.argv[1])
    for transition in ("refresh", "reopen", "different run"):
        for old_fails in (False, True):
            run(binary, transition, old_fails)
    print("Lane detail request ownership: PASS")
