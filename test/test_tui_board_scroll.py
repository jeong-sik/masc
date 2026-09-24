"""A long Board thread stays navigable across wheel bursts and live edits."""
import os
import sys
import time
import test_tui_keyboard_input as h

# The sources this scenario stands over. scripts/ci/run-edited-tests.sh runs
# a suite when a pull request changes a path the suite names, so without
# this a change to the drawn text below reaches main with no scenario run.
# The surface this scrolls ("MASC Board") is titled in masc_tui_render.ml.
SOURCE_MODULES = (
    "bin/masc_tui_render.ml",
    "bin/masc_tui_layout.ml",
)


def run(executable: str) -> None:
    fixtures = h.overview_event_http_fixtures()
    post = h.board_selection_post("scroll", "Long thread", "Short body")
    post["comment_count"] = 128
    comments = [h.board_detail_comment(f"comment-{i}",
        f"Comment {i:03d}\n" + (
            "\n\n**관측 결과** 긴 댓글 스크롤을 검증합니다. `result` **confirmed**.\n" * 24))
        for i in range(128)]
    fixtures["/api/v1/board?sort_by=hot"] = (200, {"posts": [post]})
    detail_path = "/api/v1/board/post-scroll?format=flat"
    fixtures[detail_path] = (200, {"post": post, "comments": comments})

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b"Health: ", start=0, timeout=10)
        h.palette_go(process, fd, output, b"go board", b"MASC Board")
        h.send_and_wait(process, fd, output, b"\r", b"Comment 000")
        h.read_available(fd, output)
        start = len(output)
        # Same input stream as a terminal wheel burst followed by Escape.
        # Returning to the list must not wait for 100 complete thread layouts.
        deadline = time.monotonic() + 3.0
        # A nonblocking PTY may accept only part of this 1,201-byte burst.
        # Deliver its trailing Escape too, and count delivery in the deadline.
        h.write_all(fd, output, b"\x1b[<65;70;20M" * 100 + b"\x1b")
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise AssertionError("wheel burst delivery exceeded the return-to-list deadline")
        list_header = h.screen_header(b"MASC Board", b" (1)")
        h.wait_for_output(process, fd, output,
                          list_header, start=start, timeout=remaining)
        h.wait_for_output(process, fd, output, h.FRAME_END,
                          start=h.end_of_needle(output, list_header, start), timeout=3)
        changed = [dict(c) for c in comments]
        changed[0]["content"] = "Live edit is visible"
        edited_detail = h.SequencedHttpResponse([(200, {"post": post, "comments": changed})])
        fixtures[detail_path] = edited_detail
        h.send_and_wait(process, fd, output, b"\r", b"Live edit is visible")
        if edited_detail.served < 1:
            raise AssertionError("edited Board detail was not fetched from HTTP")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description="Long Board thread wheel burst",
                            interact=interact, http_fixtures=fixtures)


# The Board read pane gets what is left after two panes that stand beside it:
# the acting pane on the right (Masc_tui_acting_pane.pane_cols = 56, shown from
# threshold_cols = 132; render reserves it through get_terminal_size) and the
# roster pane on the left (Masc_tui_roster_pane.pane_cols = 34). The side layout
# needs 120 read-pane columns (Masc_tui_layout.board_read_side_minimum_cols),
# so the terminal must be at least 56 + 34 + 120 = 210. At 180 the read pane is
# only 90 and the comments stay below the post (CI run 35555076683 drew the
# acting pane in columns 124-179 of the 180-column screen).
ACTING_PANE_COLUMNS = 56
ROSTER_PANE_COLUMNS = 34
SIDE_READ_PANE_LEAST = 120
SIDE_COLUMNS = ACTING_PANE_COLUMNS + ROSTER_PANE_COLUMNS + SIDE_READ_PANE_LEAST
# In the stacked layout a comment starts near the read pane's left edge
# (column 40 at 34 + 6). Beside the post it sits in the fixed 40-column comment
# column plus its 2-column gutter, at 34 + 120 - 42 = 112. Anything in the
# right half of the read pane can only be beside the post. Columns are screen
# cells, not bytes: a box-drawing rule is one cell and three UTF-8 bytes.
SIDE_COMMENT_COLUMN_LEAST = ROSTER_PANE_COLUMNS + SIDE_READ_PANE_LEAST // 2


def run_side_by_side(executable: str) -> None:
    """From 120 read-pane columns the comments stand beside the post, in a
    fixed-width column on the right; narrower, they stay below it. The PTY
    starts at 100 columns (no roster pane, stacked) and is resized to 210
    (roster pane, a 120-column read pane and the acting pane, side by side),
    so both layouts are drawn in one run."""
    fixtures = h.overview_event_http_fixtures()
    body = "\n".join(f"Side body line {i:02d}" for i in range(12))
    post = h.board_selection_post("side", "Side by side", body)
    comments = [h.board_detail_comment(f"side-comment-{i}", f"Comment {i:03d}\nshort comment {i}")
                for i in range(3)]
    post["comment_count"] = len(comments)
    fixtures["/api/v1/board?sort_by=hot"] = (200, {"posts": [post]})
    fixtures["/api/v1/board/post-side?format=flat"] = (200, {"post": post, "comments": comments})

    def comment_row(output: bytearray) -> tuple[int, bytes]:
        rows = h.screen_rows(bytes(output))
        row = h.screen_row_of(rows, b"Comment 000")
        if row < 0:
            raise AssertionError("Comment 000 is not on screen: " + repr(h.screen_text(bytes(output))))
        return row, rows[row]

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b"Health: ", start=0, timeout=10)
        h.palette_go(process, fd, output, b"go board", b"MASC Board")
        h.send_and_wait(process, fd, output, b"\r", b"Comment 000")
        h.read_available(fd, output)
        _, stacked = comment_row(output)
        if b"Side body line" in stacked:
            raise AssertionError("at 100 columns the comment shares a row with the post body: " + repr(stacked))
        h.resize_and_wait(process, fd, output, rows=30, columns=SIDE_COLUMNS,
                          needle=b"Comment 000", controls=(h.FULL_REDRAW,))
        h.read_available(fd, output)
        _, beside = comment_row(output)
        at = beside.decode("utf-8", "replace").index("Comment 000")
        if at < SIDE_COMMENT_COLUMN_LEAST:
            # The whole screen, not just this row: whether the columns right of
            # the read pane hold the acting pane or nothing decides whether the
            # test's width model or the pane reservation is wrong.
            raise AssertionError(
                f"the comment starts at column {at}, not in the right-hand column: " + repr(beside)
                + "\nscreen:\n" + h.screen_text(bytes(output)).decode("utf-8", "replace"))
        if beside[:at].count("│".encode()) < 2:
            raise AssertionError(
                f"at {SIDE_COLUMNS} columns the comment has no separate body/comment columns: " + repr(beside))
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description="Board read comments beside the post",
                            interact=interact, http_fixtures=fixtures)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("Long Board thread scrolling: PASS")
    run_side_by_side(os.path.abspath(sys.argv[1]))
    print("Board read comments beside the post: PASS")
