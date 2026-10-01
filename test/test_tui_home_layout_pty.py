"""Home preserves its destinations and honors explicit pane choices."""
import base64
import json
import os
import sys

import test_tui_home_journey_pty as home
import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui_approvals_model.ml", "bin/masc_tui_approvals_model.mli",
    "bin/masc_tui_home.ml", "bin/masc_tui_home.mli",
    "bin/masc_tui.ml", "bin/masc_tui_types.ml", "bin/masc_tui_render.ml",
)


def capture(process, fd, output, *, name, rows, columns, needle):
    frame = h.resize_and_wait(
        process, fd, output, rows=rows, columns=columns, needle=needle,
        controls=(h.FULL_REDRAW,), final_cursor=b"\x1b[?25l",
    )
    screen = h.screen_rows(frame)
    assert max(screen) <= rows
    assert all(h.fixture_cell_width(row.decode("utf-8")) <= columns for row in screen.values())
    print("HOME_JOURNEY_FRAME " + json.dumps({
        "name": name, "rows": rows, "columns": columns,
        "encoding": "base64", "pty": base64.b64encode(frame).decode(),
    }))
    return h.screen_text(frame)


def explicit_pane_choice(executable):
    fixtures, _items, _new = h.approval_selection_http_fixtures()
    fixtures["/api/v1/keepers/beta/chat/history"] = (200, [])
    requests = []

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b"Approvals and questions: 3", start=0, timeout=10)
        # A key below the shared pane floor must not turn an invisible
        # press into a preference that appears after the terminal grows.
        h.send_and_wait(process, fd, output, b"\x0c", b"Activity pane needs")
        frame = capture(process, fd, output, name="wide-home-default", rows=32,
                        columns=180, needle=b"Choose a Keeper")
        assert b"[Recent]" not in frame, frame
        h.send_and_wait(process, fd, output, b"\x0c", b"[Recent]")
        assert h.acting_pane_header_cell(output) == 180 - h.ACTING_PANE_NARROW_COLUMNS + 1
        h.send_and_wait(process, fd, output, b"\x0c", b"[Recent]")
        assert h.acting_pane_header_cell(output) == 180 - h.ACTING_PANE_WIDE_COLUMNS + 1
        h.send_and_wait(process, fd, output, b"\x0c", b"Continue")
        assert h.acting_pane_header_cell(output) == -1
        h.palette_go(process, fd, output, b"go keepers", b"MASC Keepers")
        assert h.acting_pane_header_cell(output) == -1
        h.select_keeper_row(process, fd, output, b"beta")
        h.send_and_wait(process, fd, output, b"c", b"Esc:list")
        h.send_and_wait(process, fd, output, b"/activity fleet\r", b"Activity pane on Recent")
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
        h.palette_go(process, fd, output, b"go dashboard", b"Continue with beta")
        assert h.acting_pane_header_cell(output) >= 0
        small = capture(process, fd, output, name="chosen-pane-narrow-terminal",
                        rows=24, columns=80, needle=b"Continue with beta")
        assert b"[Recent]" not in small, small
        restored = capture(process, fd, output, name="chosen-pane-restored",
                           rows=32, columns=180, needle=b"Continue with beta")
        assert b"[Recent]" in restored, restored
        home.assert_no_decision_posts(requests)
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable, description="Home pane opens only after an explicit choice",
        interact=interact, http_fixtures=fixtures, http_requests=requests,
        prepare_workspace=home.seed_goals,
    )


def short_home_keeps_destinations(executable):
    fixtures, _items, _new = h.approval_selection_http_fixtures()
    fixtures["/api/v1/keepers/beta/chat/history"] = (200, [])
    requests = []
    goal = {
        "id": "goal-home-layout", "title": "Confirm this retained goal",
        "criterion_revision": "r1", "phase": "awaiting_confirmation", "priority": 2,
        "created_at": "2026-09-28T00:00:00Z", "updated_at": "2026-09-29T00:00:00Z",
    }

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b"Confirm Goal", start=0, timeout=10)
        h.wait_for_output(process, fd, output, b"Approvals and questions: 3", start=0, timeout=10)
        h.send_and_wait(process, fd, output, b"i", b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"beta")
        h.send_and_wait(process, fd, output, b"c", b"Esc:list")
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
        h.palette_go(process, fd, output, b"go dashboard", b"Continue with beta")
        frame = capture(process, fd, output, name="short-home-all-destinations",
                        rows=17, columns=80, needle=b"New work")
        for expected in (b"Approval", b"Needs your decision", b"Continue with beta", b"New work", b"Enter:open"):
            assert expected in frame, (expected, frame)
        # Individual cards are windowed, rather than all forced into 17 rows.
        for label in (b"Confirm Goal", b"Approvals and questions:"):
            home.select_destination(process, fd, output, label)
            visible = h.screen_text(bytes(output))
            assert label in visible and b"Continue with beta" in visible and b"New work" in visible
        # Home fits its minimum chrome height; grow before entering the
        # composer, whose own fixed chrome requires additional rows.
        capture(process, fd, output, name="short-home-before-chat",
                rows=24, columns=80, needle=b"New work")
        home.select_destination(process, fd, output, b"Continue with beta")
        h.send_and_wait(process, fd, output, b"\r", b"Esc:Dashboard")
        h.send_and_wait(process, fd, output, b"short-draft", b"short-draft")
        h.send_and_wait(process, fd, output, b"\x1b", b"Continue with beta")
        h.send_and_wait(process, fd, output, b"\r", b"short-draft")
        h.send_and_wait(process, fd, output, b"\x1b", b"Continue with beta")
        home.assert_no_decision_posts(requests)
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable, description="Short Home preserves decisions resume and new work",
        interact=interact, http_fixtures=fixtures, http_requests=requests,
        prepare_workspace=lambda base: home.seed_goals(base, [goal]),
    )


if __name__ == "__main__":
    executable = os.path.abspath(sys.argv[1])
    explicit_pane_choice(executable)
    short_home_keeps_destinations(executable)
    print("Home layout PTY: PASS (2 scenarios)")
