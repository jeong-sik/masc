"""Responsive Dashboard journeys, from current-head fixture PTY frames."""
import base64
import hashlib
import json
import os
import sys

import test_tui_keyboard_input as h
import test_tui_keyboard_overview_pty as opening

SOURCE_MODULES = (
    "bin/masc_tui_dashboard.ml",
    "bin/masc_tui_dashboard.mli",
    "bin/masc_tui_render.ml",
    "bin/masc_tui_types.ml",
    "bin/masc_tui.ml",
    "bin/masc_tui_keys.ml",
)


def populated_fixtures():
    fixtures = h.keeper_runtime_http_fixtures()
    _, briefing = h.paused_and_stopped_briefing()
    briefing["incidents"] = [
        {"kind": "keeper_runtime_blocker", "severity": "bad",
         "summary": "alpha: provider unavailable · 점검 필요",
         "target_type": "keeper", "target_id": "alpha"},
        {"kind": "keeper_attention", "severity": "warning",
         "summary": "beta: a published report needs an operator decision",
         "target_type": "keeper", "target_id": "beta"},
    ]
    fixtures["/api/v1/dashboard/briefing"] = (200, briefing)
    goal = h.planning_goal("goal-studio", "팀 대시보드 · measured operator journeys")
    goal.update({"metric": "verified journeys", "target_value": "5",
                 "task_count": 3, "task_done_count": 2,
                 "measurement": {"state": "not_recorded"},
                 "stagnation_seconds": None,
                 "tasks": [{"id": "task-studio-1"}, {"id": "task-studio-2"},
                           {"id": "task-studio-3"}], "children": []})
    fixtures[h.DASHBOARD_GOALS_PATH] = (200, {"tree": [goal]})
    fixtures[h.PLANNING_PATH] = h.planning_snapshot([goal])
    return fixtures


def capture(process, fd, output, *, name, rows, columns, needle):
    # Always change geometry: reapplying the same size need not emit 2J.
    h.resize_and_wait(
        process, fd, output, rows=rows + 1, columns=columns + 1,
        needle=needle, controls=(h.FULL_REDRAW,), final_cursor=b"\x1b[?25l",
    )
    frame = h.resize_and_wait(
        process, fd, output, rows=rows, columns=columns,
        needle=needle, controls=(h.FULL_REDRAW,), final_cursor=b"\x1b[?25l",
    )
    screen = h.screen_text(frame)
    print("STUDIO_CAPTURE=" + json.dumps({
        "name": name, "rows": rows, "columns": columns,
        "provenance": "CI fixture PTY",
        "frame_b64": base64.b64encode(frame).decode(),
        "screen": screen.decode(errors="replace"),
    }), flush=True)
    return screen


def navigation(executable, *, no_color=False):
    fixtures = populated_fixtures()
    _, briefing = fixtures["/api/v1/dashboard/briefing"]
    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b"provider unavailable", start=0, timeout=10)
        # Wait for the measured Goal source too: a heading can precede it.
        h.wait_for_output(process, fd, output, "팀 대시보드".encode(), start=0, timeout=10)
        frame = capture(process, fd, output, name="wide-no-color" if no_color else "wide",
                        rows=42, columns=140, needle=b"verified journeys")
        for value in (b"Needs you", b"Work", b"Goals", b"Keepers", b"Usage",
                      b"actual not recorded", b"linked tasks 2/3 done"):
            if value not in frame:
                raise AssertionError(f"wide Dashboard omitted {value!r}: {frame!r}")
        if "┌".encode() not in frame:
            raise AssertionError("wide Dashboard did not compose bordered cards")

        # j moves to Work; the focus marker remains visible after a resize.
        h.send_and_wait(process, fd, output, b"j", "› Work".encode())
        compact = capture(process, fd, output, name="compact-work",
                          rows=24, columns=80, needle="› Work".encode())
        for value in (b"Needs you", b"Work", b"Goals", b"Keepers", b"Usage", b"Current Done states"):
            if value not in compact:
                raise AssertionError(f"compact Dashboard lost {value!r}: {compact!r}")
        briefing["incidents"].append({
            "kind": "keeper_attention", "severity": "info",
            "summary": "refresh-generation-2", "target_type": "keeper", "target_id": "beta",
        })
        h.send_and_wait(process, fd, output, b"r", b"3 attention items")
        refreshed = capture(process, fd, output, name="refreshed-work", rows=24, columns=80,
                            needle="› Work".encode())
        if "› Work".encode() not in refreshed:
            raise AssertionError("refresh changed the selected Dashboard destination")
        h.send_and_wait(process, fd, output, b"\r", b"MASC Work")
        # Work's existing first Esc leaves task focus; its next Esc returns.
        start = len(output)
        os.write(fd, b"\x1b")
        h.wait_for_output(process, fd, output, h.FRAME_END, start=start, timeout=5)
        if b"MASC Work" not in h.screen_text(bytes(output)):
            raise AssertionError("first Esc did not retain Work after clearing task focus")
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Dashboard")
        h.send_and_wait(process, fd, output, b"j", "› Goals".encode())
        h.send_and_wait(process, fd, output, b"\r", b"MASC Work")
        h.wait_for_output(process, fd, output, "팀 대시보드".encode(), start=0, timeout=5)
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Dashboard")
        h.send_and_wait(process, fd, output, b"\x1b[B", "› Keepers".encode())
        h.send_and_wait(process, fd, output, b"\r", b"MASC Keepers")
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Dashboard")
        h.send_and_wait(process, fd, output, b"j", "› Usage".encode())
        h.send_and_wait(process, fd, output, b"\r", b"MASC Usage")
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Dashboard")
        tiny = capture(process, fd, output, name="short-usage", rows=18, columns=80,
                       needle="› Usage".encode())
        if "› Usage".encode() not in tiny:
            raise AssertionError("short Dashboard hid its selected destination")
        # Previous wraps from Attention to Usage and next back to Attention.
        h.send_and_wait(process, fd, output, b"j", "› Needs you".encode())
        h.send_and_wait(process, fd, output, b"k", "› Usage".encode())
        h.send_and_wait(process, fd, output, b"\x1b[B", "› Needs you".encode())
        capture(process, fd, output, name="compact-attention", rows=24, columns=80,
                needle=b"provider unavailable")
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable, description="Dashboard studio navigation" + (" NO_COLOR" if no_color else ""),
        interact=interact, http_fixtures=fixtures,
        terminal_cols=140, terminal_rows=42,
        extra_env={"NO_COLOR": "1"} if no_color else {},
    )


def failed_source(executable):
    fixtures = populated_fixtures()
    fixtures[h.DASHBOARD_GOALS_PATH] = (503, {"error": "studio-goals-unavailable"})
    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b"Goals", start=0, timeout=10)
        h.wait_for_output(process, fd, output, b"Goals \xc2\xb7 unavailable", start=0, timeout=10)
        frame = capture(process, fd, output, name="failed-goals", rows=42, columns=140,
                        needle=b"Goals \xc2\xb7 unavailable")
        if b"Goals \xc2\xb7 0 active" in frame:
            raise AssertionError("failed Goals read was presented as zero")
        if b"provider unavailable" not in frame:
            raise AssertionError("a failed Goal source erased independent attention")
        os.write(fd, b"q")
    h.run_terminal_scenario(executable, description="Dashboard studio partial failure",
                           interact=interact, http_fixtures=fixtures,
                           terminal_cols=140, terminal_rows=42)


if __name__ == "__main__":
    executable = os.path.abspath(sys.argv[1])
    print("STUDIO_BINARY_SHA256=" + hashlib.sha256(open(executable, "rb").read()).hexdigest())
    navigation(executable)
    navigation(executable, no_color=True)
    failed_source(executable)
    opening.first_use_frames(executable)
    opening.unreadable_keeper_listing_has_no_first_use_guide(executable)
    print("tui dashboard studio PTY: PASS")
