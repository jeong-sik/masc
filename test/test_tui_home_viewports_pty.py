"""Home's next action and unknown readings fit the accepted terminal sizes."""
import base64
import json
import os
import re
import sys

import test_tui_home_journey_pty as home
import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui_render_approvals.ml",
    "bin/masc_tui_render_approvals.mli",
    "bin/masc_tui_render.ml",
    "bin/masc_tui_types.ml",
    "bin/masc_tui_render_prim.ml",
    "bin/masc_tui_keys.ml",
)

VIEWPORTS = ((80, 24), (120, 32), (160, 48))


def viewport_journey(executable, *, unread, no_color):
    if unread:
        fixtures = h.overview_event_http_fixtures()
        ready = b"Choose a Keeper"
        expected = b"not fully read"
    else:
        fixtures, _items, _new = h.approval_selection_http_fixtures()
        ready = b"Approvals and questions: 3"
        expected = b"3 need you"
    requests = []

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, ready, start=0, timeout=10)
        for columns, rows in VIEWPORTS:
            frame = h.resize_and_wait(
                process, fd, output, rows=rows, columns=columns,
                needle=b"Enter:open", controls=(h.FULL_REDRAW,),
                final_cursor=b"\x1b[?25l",
            )
            visible = h.screen_text(frame)
            screen = h.screen_rows(frame)
            for needle in (expected, b"Continue", b"Choose a Keeper", b"Enter:open"):
                assert needle in visible, (columns, rows, needle, visible)
                assert 1 <= h.screen_row_of(screen, needle) <= rows
            if unread:
                assert b"No decision is waiting" not in visible, visible
            assert b"[Recent]" not in visible, visible
            assert b"[Changes]" not in visible, visible
            # Verify terminal row addresses, not just presence in a log that
            # could contain offscreen output from an earlier size.
            assert max(screen) <= rows, visible
            for row in screen.values():
                assert h.fixture_cell_width(row.decode("utf-8")) <= columns, row
            if no_color:
                for sgr in re.findall(rb"\x1b\[([0-9;]*)m", frame):
                    parameters = [int(part) for part in sgr.split(b";") if part]
                    assert not any(
                        30 <= value <= 48 and value != 39 or 90 <= value <= 107
                        for value in parameters
                    ), ("NO_COLOR emitted a color", sgr)
            print("HOME_JOURNEY_FRAME " + json.dumps({
                "name": "unread" if unread else "requests",
                "columns": columns, "rows": rows, "no_color": no_color,
                "encoding": "base64", "pty": base64.b64encode(frame).decode(),
            }))
            # Exercise Home's selected-row dispatch at each size, rather
            # than proving only that a global shortcut works at the last one.
            home.select_destination(process, fd, output, b"Approvals and questions:")
            h.send_and_wait(process, fd, output, b"\r", b"MASC Approvals")
            home.assert_no_decision_posts(requests)
            h.palette_go(process, fd, output, b"go dashboard", ready)
        # The same recipient-selection action remains available after all
        # three resizes; this is navigation, so no product POST is allowed.
        h.send_and_wait(process, fd, output, b"i", b"MASC Keepers")
        home.assert_no_decision_posts(requests)
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable,
        description=f"Home viewports unread={unread} no_color={no_color}",
        interact=interact, http_fixtures=fixtures, http_requests=requests,
        prepare_workspace=home.seed_goals,
        extra_env={"NO_COLOR": "1"} if no_color else None,
    )


if __name__ == "__main__":
    executable = os.path.abspath(sys.argv[1])
    for unread in (True, False):
        for no_color in (False, True):
            viewport_journey(executable, unread=unread, no_color=no_color)
    print("Home viewport PTY: PASS (4 scenarios, 12 frames)")
