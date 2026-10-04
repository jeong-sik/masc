"""Fixture Home overflow journeys; navigation only, never decision submission.

All held authorities are visited at each size, including exact detail and Esc.
This is client/fixture coverage, not owner-store or production evidence.
"""
import base64
import json
import os
import re
import sys

import test_tui_home_decision_cards_pty as cards
import test_tui_home_journey_pty as home
import test_tui_keyboard_input as h


VIEWPORTS = ((80, 24), (120, 32), (160, 48))
# More authorities than the tallest terminal has rows, even without chrome.
REQUEST_COUNT = 64
WINDOW = re.compile(rb"rows (\d+)-(\d+)/(\d+)")
# Ten-character authority IDs fit Home's twelve-cell identity label intact.
CALL = re.compile(rb"\[ov-call-\d{2}\]")


def inspect_home(output, label, *, columns, rows):
    """Reconstruct current rows without redrawing or repairing the viewport."""
    frame = bytes(output)
    screen = h.screen_rows(frame)
    visible = h.screen_text(frame)
    assert screen and max(screen) <= rows, screen
    for row in screen.values():
        assert h.fixture_cell_width(row.decode()) <= columns, row
    for required in (b"Continue with beta", b"New work", b"Enter:open"):
        assert required in visible, (required, visible)
        assert 1 <= h.screen_row_of(screen, required) <= rows, screen
    position = WINDOW.search(visible)
    assert position, visible
    first, last, total = map(int, position.groups())
    assert 1 <= first <= last <= total == REQUEST_COUNT + 1, visible
    assert last - first + 1 < total, "fixture did not overflow"
    cards.assert_selected(frame, label)
    request_rows = {
        number: CALL.findall(row)
        for number, row in sorted(screen.items()) if CALL.search(row)
    }
    expected = [f"[ov-call-{index:02}]".encode()
                for index in range(first - 1, min(last, REQUEST_COUNT))]
    actual = [identity for identities in request_rows.values() for identity in identities]
    assert actual == expected, (position.group(), expected, actual)
    aggregate_rows = sum(b"Approvals and questions:" in row for row in screen.values())
    assert aggregate_rows == int(last == total), (position.group(), screen)
    assert len(actual) + aggregate_rows == last - first + 1, screen
    return frame, (first, last, total), request_rows


def capture(frame, name, *, columns, rows):
    """Emit the existing raw screen replay without causing a redraw."""
    # Preserve differential frames since the last clear, which is the same
    # replay screen_rows uses; avoid including the entire journey's output.
    start = frame.rfind(h.FULL_REDRAW)
    assert start >= 0, "no complete screen replay available"
    frame = frame[start:]
    print("HOME_JOURNEY_FRAME " + json.dumps({
        "name": name, "columns": columns, "rows": rows,
        "encoding": "base64", "pty": base64.b64encode(frame).decode(),
    }))


def overflow_journey(executable, *, columns, rows):
    held = [cards.held(f"ov-call-{index:02}", f"overflow-request-{index:02}")
            for index in range(REQUEST_COUNT)]
    fixtures = cards.fixtures_with_held(held)
    fixtures["/api/v1/keepers/beta/chat/history"] = (200, [])
    requests = []

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b"overflow-request-00", start=0, timeout=10)
        # Use an intermediate size so the smallest target resize
        # produces a frame. There are no resizes during request traversal.
        if (columns, rows) == (80, 24):
            h.resize_and_wait(process, fd, output, rows=rows, columns=columns + 1,
                              needle=b"Enter:open", controls=(h.FULL_REDRAW,),
                              final_cursor=b"\x1b[?25l")
        # Establish an explicit remembered conversation before asserting
        # Home's resume and new-work destinations, as in the cards journey.
        h.send_and_wait(process, fd, output, b"i", b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"beta")
        h.send_and_wait(process, fd, output, b"c", b"Esc:list")
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
        h.palette_go(process, fd, output, b"go dashboard", b"Continue with beta")
        h.resize_and_wait(process, fd, output, rows=rows, columns=columns,
                          needle=b"Enter:open", controls=(h.FULL_REDRAW,),
                          final_cursor=b"\x1b[?25l")
        cards.select_home(process, fd, output, b"[ov-call-00]",
                          destinations=REQUEST_COUNT + 3)
        visited = set()
        windows = set()
        first_position = None
        boundary_captured = False
        for index in range(REQUEST_COUNT):
            call_id = f"ov-call-{index:02}".encode()
            label = b"[" + call_id + b"]"
            before, position, before_rows = inspect_home(
                output, label, columns=columns, rows=rows,
            )
            if first_position is None:
                first_position = position
            first_boundary = not boundary_captured and position != first_position
            emit = index in (0, REQUEST_COUNT - 1) or first_boundary
            assert position[0] <= index + 1 <= position[1], (index, position)
            windows.add(position)
            # The argument appears only in detail, unlike an ID also drawn
            # in Home or the Approvals list. Wait for it before inspecting.
            detail = h.send_and_wait(process, fd, output, b"\r", b"echo " + call_id)
            detail_screen = h.screen_text(detail)
            assert b"MASC Approval" in detail_screen, detail_screen
            assert b"echo " + call_id in detail_screen, detail_screen
            assert re.search(rb"\bcall\s+" + re.escape(call_id) + rb"\b",
                             detail_screen), detail_screen
            for other in held:
                other_id = other["tool_call_id"].encode()
                if other_id != call_id:
                    assert other_id not in detail_screen, detail_screen
            home.assert_no_decision_posts(requests)
            h.send_and_wait(process, fd, output, b"\x1b", b"Enter:open")
            after, returned_position, after_rows = inspect_home(
                output, label, columns=columns, rows=rows,
            )
            assert returned_position == position, (position, returned_position)
            # Same identities at the same terminal rows: not merely the same
            # scroll indicator with a different visible request window.
            assert before_rows == after_rows, (before_rows, after_rows)
            if emit:
                for suffix, snapshot in (("selected", before), ("returned", after)):
                    capture(snapshot, f"overflow-{index:02}-{suffix}",
                            columns=columns, rows=rows)
            boundary_captured |= first_boundary
            visited.add(call_id)
            if index + 1 < REQUEST_COUNT:
                h.send_and_wait(process, fd, output, b"j",
                                cards.selected(f"[ov-call-{index + 1:02}]".encode()))
        assert visited == {item["tool_call_id"].encode() for item in held}, visited
        assert len(windows) > 1, "traversal never moved the request viewport"
        home.assert_no_decision_posts(requests)
        os.write(fd, b"q")

    cards.run(
        executable, f"Home overflow {columns}x{rows}: all 64 exact requests and Esc",
        fixtures, interact, requests,
    )


if __name__ == "__main__":
    executable = os.path.abspath(sys.argv[1])
    for columns, rows in VIEWPORTS:
        overflow_journey(executable, columns=columns, rows=rows)
    print("Home overflow PTY: PASS (3 scenarios, 192 exact detail round trips)")
