"""Agenda page reading remains independent of its actionable selection."""
import copy
import json
import os
import sys
import threading

import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui_render_approvals.ml", "bin/masc_tui_render_approvals.mli",
    "bin/masc_tui_approvals_model.ml", "bin/masc_tui_approvals_model.mli",
    "bin/masc_tui.ml", "bin/masc_tui_render.ml", "bin/masc_tui_types.ml",
)


def run(executable):
    fixtures = h.schedule_detail_http_fixtures()
    template = fixtures[h.SCHEDULES_PATH][1]
    changed = threading.Event()
    refreshed = threading.Event()
    painted = threading.Event()

    def schedules():
        snapshot = copy.deepcopy(template)
        count = 40 if changed.is_set() else 20
        original = snapshot["requests"][0]
        snapshot["requests"] = []
        for index in range(count):
            row = copy.deepcopy(original)
            row.update(schedule_id=f"agenda-schedule-{index}",
                       schedule_instance_id=f"agenda-instance-{index}",
                       status="scheduled", payload_summary=f"AGENDA_SCHEDULE_{index:02d}",
                       due_at_iso=f"2026-08-25T10:{index:02d}:00Z",
                       last_wake=None)
            snapshot["requests"].append(row)
        snapshot["request_count"] = count
        if changed.is_set():
            refreshed.set()
        painted.set()
        return 200, snapshot

    fixtures[h.SCHEDULES_PATH] = schedules
    fixtures["/api/v1/keepers/tool-approvals"] = (200, {"pending": [{
        "keeper": "alpha", "tool_call_id": "agenda-held-call", "tool": "AgendaHeld",
        "args": "{}", "question": "Review the selected Agenda call?", "because": None,
        "asked_at": 1787766400.0, "timeout_sec": 300.0,
    }]})

    def interact(process, fd, _slave, output, _base):
        def require(*needles):
            h.drain_until_quiet(process, fd, output)
            screen = h.screen_text(bytes(output))
            for needle in needles:
                if needle not in screen:
                    raise AssertionError(f"Agenda lost {needle!r}: {screen!r}")
            return screen

        h.wait_for_output(process, fd, output, b"AGENDA_SCHEDULE_00", start=0, timeout=10)
        h.send_and_wait(process, fd, output, b";", b"MASC Agenda")
        require(b"Coming up", b"AGENDA_SCHEDULE_00")
        # Enter on a schedule is a no-op and need not emit a new frame.
        os.write(fd, b"\r")
        require(b"MASC Agenda", b"AGENDA_SCHEDULE_00")
        h.send_and_wait(process, fd, output, b"\x1b[6~", b"AGENDA_SCHEDULE_19")
        require(b"AGENDA_SCHEDULE_19")
        h.send_and_wait(process, fd, output, b"g", b"AGENDA_SCHEDULE_00")
        h.send_and_wait(process, fd, output, b"j", b"alpha is holding AgendaHeld")
        require(b"alpha is holding AgendaHeld")
        # An independently read page must stay put through repainting and Enter
        # must never act on the retained target outside that page.
        h.send_and_wait(process, fd, output, b"\x1b[H", b"AGENDA_SCHEDULE_00")
        painted.clear()
        if not h.wait_for_fixture_event(process, fd, output, painted, timeout=10):
            raise AssertionError("Agenda did not refresh while reading its first page")
        require(b"Coming up", b"AGENDA_SCHEDULE_00")
        os.write(fd, b"\r")
        require(b"MASC Agenda", b"AGENDA_SCHEDULE_00")
        h.send_and_wait(process, fd, output, b"k", b"alpha is holding AgendaHeld")
        # Insert schedules above the same selected call. Following a target
        # follows its identity's new row without changing what Enter opens.
        refresh_start = len(output)
        changed.set()
        if not h.wait_for_fixture_event(process, fd, output, refreshed, timeout=10):
            raise AssertionError("Agenda did not refresh its schedules")
        h.wait_for_output(process, fd, output, b"AGENDA_SCHEDULE_39", start=refresh_start, timeout=10)
        require(b"alpha is holding AgendaHeld")
        h.send_and_wait(process, fd, output, b"G", b"alpha is holding AgendaHeld")
        h.send_and_wait(process, fd, output, b"\x1b[5~", b"AGENDA_SCHEDULE_")
        h.send_and_wait(process, fd, output, b"j", b"alpha is holding AgendaHeld")
        rows = h.screen_rows(bytes(output), preserve_styles=True)
        row = rows[h.screen_row_of(rows, b"alpha is holding AgendaHeld")]
        if b"\x1b[7m" not in row:
            raise AssertionError(f"refreshed target lost its visible selection: {row!r}")
        print("AGENDA_NAVIGATION_PTY " + json.dumps(
            require(b"alpha is holding AgendaHeld").decode("utf-8", "replace")), flush=True)
        h.send_and_wait(process, fd, output, b"\r", b"MASC Approvals")
        require(b"AgendaHeld")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description="Agenda schedules and held targets remain reachable",
                            interact=interact, http_fixtures=fixtures,
                            terminal_rows=24, refresh=0.5)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("Agenda independent page navigation: PASS")
