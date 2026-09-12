"""One wheel detent is worth a notch, not a row.

[wheel_notch_rows] says a detent is worth three rows -- what a detent is
worth in a pager -- and the chat pane and the Activity pane both spend that.
Every other surface spent one, because the key a detent becomes sits beside
j and k in the dispatcher and those move a single step. The same flick of
the same wheel moved three times as far over the chat pane as over the list
beside it.
"""
import os
import sys
import test_tui_keyboard_input as h

POSTS = 12
# Wheel-down, away from the Activity pane's columns -- a detent over that
# pane is the pane's own and never becomes a key.
WHEEL_DOWN = b"\x1b[<65;20;70M"


def run(executable: str) -> None:
    fixtures = h.overview_event_http_fixtures()
    posts = [h.board_selection_post(f"{i:03d}", f"Post {i:03d}", "body")
             for i in range(POSTS)]
    fixtures["/api/v1/board?sort_by=hot"] = (200, {"posts": posts})

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b"cluster-a", start=0, timeout=15)
        h.palette_go(process, fd, output, b"go board", b"MASC Board")
        h.wait_for_output(process, fd, output, h.selected_row(b"post-000"),
                          start=0, timeout=8)

        # One detent, three rows. A detent worth one row would land on 001.
        h.send_and_wait(process, fd, output, WHEEL_DOWN,
                        h.selected_row(b"post-003"))

        # And again, so the owed presses of the first notch are not what the
        # second one is landing on.
        h.send_and_wait(process, fd, output, WHEEL_DOWN,
                        h.selected_row(b"post-006"))

        # j still means one row: the notch is the wheel's, not the key's.
        h.send_and_wait(process, fd, output, b"j",
                        h.selected_row(b"post-007"))

        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="a wheel detent is worth a notch",
        interact=interact,
        http_fixtures=fixtures)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("wheel detent is worth a notch: PASS")
