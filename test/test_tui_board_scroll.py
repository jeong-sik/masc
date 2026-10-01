"""A long Board thread stays navigable across wheel bursts and live edits."""
import os
import re
import sys
import time

import tui_keyboard_harness as h

# The sources this scenario stands over. scripts/ci/run-edited-tests.sh runs
# a suite when a pull request changes a path the suite names, so without
# this a change to the drawn text below reaches main with no scenario run.
# The surface this scrolls ("MASC Board") is titled in masc_tui_render_board.ml.
SOURCE_MODULES = (
    "bin/masc_tui_render_board.ml",
    "bin/masc_tui_render_board.mli",
    "bin/masc_tui_render.ml",
    "bin/masc_tui_layout.ml",
    "test/tui_keyboard_harness.py",
    "bin/masc_tui.ml",
    "bin/masc_tui_loader.ml",
    "bin/masc_tui_types.ml",
    "bin/masc_tui_board_read_layout.ml",
    "bin/masc_tui_board_read_layout.mli",
    "bin/masc_tui_board_detail.ml",
)


# Enter opens the post under the cursor, so it has to wait for the list to
# hold one. "Health: " no longer says the first read landed: the Dashboard
# draws "Health: not observed" before any read (RFC-tui-measured-operator-home
# keeps unknown values unknown), and a Board opened then reads "(not loaded)"
# and Enter finds no row. The header count is drawn only from a list read.
ONE_POST_LISTED = h.screen_header(b"MASC Board", b" (1)")


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
    fixtures[detail_path] = (200, h.board_detail_page(post, comments))
    for offset in (0, 100):
        fixtures[f"{detail_path}&comment_offset={offset}&comment_limit=100"] = (
            200, h.board_detail_page(post, comments, offset=offset, limit=100))

    first_page_path = f"{detail_path}&comment_offset=0&comment_limit=100"
    fixtures[first_page_path] = h.SequencedHttpResponse([
        (503, {"error": "full history temporarily unavailable"}),
        (200, h.board_detail_page(post, comments, offset=0, limit=100)),
    ])

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b"Health: ", start=0, timeout=10)
        h.palette_go(process, fd, output, b"go board", b"MASC Board")
        h.wait_for_output(process, fd, output, ONE_POST_LISTED, start=0, timeout=10)
        h.send_and_wait(process, fd, output, b"\r", b"Showing 20 of 128 comments")
        h.send_and_wait(process, fd, output, b"o", b"full history temporarily unavailable")
        h.send_and_wait(process, fd, output, b"o", b"Showing 20 of 128 comments")
        h.send_and_wait(process, fd, output, b"o", b"Comment 000")
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
        edited_detail = h.SequencedHttpResponse(
            [(200, h.board_detail_page(post, changed))])
        fixtures[detail_path] = edited_detail
        fixtures[f"{detail_path}&comment_offset=0&comment_limit=100"] = (
            200, h.board_detail_page(post, changed, offset=0, limit=100))
        h.send_and_wait(process, fd, output, b"\r", b"Showing 20 of 128 comments")
        h.send_and_wait(process, fd, output, b"o", b"Live edit is visible")
        if edited_detail.served < 1:
            raise AssertionError("edited Board detail was not fetched from HTTP")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description="Long Board thread wheel burst",
                            interact=interact, http_fixtures=fixtures)


# The Board read pane gets what is left after two panes that stand beside it:
# the acting pane on the right (Masc_tui_acting_pane.pane_cols = 56, shown from
# threshold_cols = 158; render reserves it through get_terminal_size) and the
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
# (column 40 at 34 + 6). At the side-by-side minimum it starts after the
# 78-column post and the 2-column gutter, at 34 + 78 + 2 = 114. Anything in
# the right half of the read pane can only be beside the post. Columns are
# screen cells, not bytes: a box-drawing rule is one cell and three UTF-8 bytes.
SIDE_COMMENT_COLUMN_LEAST = ROSTER_PANE_COLUMNS + SIDE_READ_PANE_LEAST // 2


def run_side_by_side(executable: str) -> None:
    """From 120 read-pane columns the comments stand beside the post, in a
    right-hand column at its minimum width; narrower, they stay below it. The PTY
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
    fixtures["/api/v1/board/post-side?format=flat"] = (
        200, h.board_detail_page(post, comments))

    def comment_row(output: bytearray) -> tuple[int, bytes]:
        rows = h.screen_rows(bytes(output))
        row = h.screen_row_of(rows, b"Comment 000")
        if row < 0:
            raise AssertionError("Comment 000 is not on screen: " + repr(h.screen_text(bytes(output))))
        return row, rows[row]

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b"Health: ", start=0, timeout=10)
        h.palette_go(process, fd, output, b"go board", b"MASC Board")
        h.wait_for_output(process, fd, output, ONE_POST_LISTED, start=0, timeout=10)
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


# The window row at the foot of the read pane. Both halves count wrapped
# rows, so both say so: the comment half read "comments 1-10/6085" beside a
# header drawing the thread's own 157, and a reader meeting both numbers had
# no way to tell which one counted comments.
POST_WINDOW = re.compile(rb"post rows \d+-\d+/(\d+)")
COMMENT_WINDOW = re.compile(rb"comment rows \d+-\d+/(\d+)")
HEADER_COMMENTS = re.compile("💬".encode() + rb"(\d+)")


def run_window_names_what_it_counts(executable: str) -> None:
    """The comment window counts rows, and a thread whose rows outnumber its
    comments proves the row says which of the two it is showing."""
    fixtures = h.overview_event_http_fixtures()
    post = h.board_selection_post("rows", "Rows and comments", "One body line")
    # Six comments, each wrapping to far more than one row, so the two counts
    # cannot be read as the same number by accident.
    comments = [
        h.board_detail_comment(
            f"rows-comment-{i}", f"Comment {i:03d}\n" + ("a paragraph row\n" * 20)
        )
        for i in range(6)
    ]
    post["comment_count"] = len(comments)
    fixtures["/api/v1/board?sort_by=hot"] = (200, {"posts": [post]})
    fixtures["/api/v1/board/post-rows?format=flat"] = (
        200, h.board_detail_page(post, comments))

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b"Health: ", start=0, timeout=10)
        h.palette_go(process, fd, output, b"go board", b"MASC Board")
        h.wait_for_output(process, fd, output, ONE_POST_LISTED, start=0, timeout=10)
        h.send_and_wait(process, fd, output, b"\r", b"Comment 000")
        h.wait_for_output(process, fd, output, b"comment rows ", start=0, timeout=5)
        h.read_available(fd, output)
        rows = h.screen_rows(bytes(output))
        screen = h.screen_text(bytes(output))
        carrying = [text for _, text in sorted(rows.items())
                    if COMMENT_WINDOW.search(text)]
        if not carrying:
            raise AssertionError(
                "no row names the comment window: "
                + screen.decode("utf-8", "replace"))
        window = carrying[-1]
        if not POST_WINDOW.search(window):
            raise AssertionError(
                "the post half does not name what it counts: " + repr(window))
        counted = int(COMMENT_WINDOW.search(window).group(1))
        if counted <= len(comments):
            raise AssertionError(
                f"the comment window counted {counted} for {len(comments)} "
                "comments, so this thread cannot tell rows from comments: "
                + repr(window))
        # The header draws the thread's own count. The two numbers are both on
        # this screen, which is the reason each one says what it is.
        header = [text for _, text in sorted(rows.items())
                  if b"MASC Board" in text]
        if not header:
            raise AssertionError("no Board header on screen")
        header_count = HEADER_COMMENTS.search(header[0])
        if header_count is None or int(header_count.group(1)) != len(comments):
            raise AssertionError(
                f"the header does not draw the thread's {len(comments)} "
                "comments: " + repr(header[0]))
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="The Board read window says it counts rows",
        interact=interact,
        http_fixtures=fixtures)


def run_independent_windows(executable: str) -> None:
    """The focused half moves, and a wider read pane gives comments more room."""
    fixtures = h.overview_event_http_fixtures()
    body = "\n".join(f"Body mark {i:03d}" for i in range(80))
    post = h.board_selection_post("independent", "Independent read", body)
    comment = h.board_detail_comment(
        "independent-comment",
        "\n".join(f"Comment row {i:03d}" for i in range(90)),
    )
    post["comment_count"] = 1
    fixtures["/api/v1/board?sort_by=hot"] = (200, {"posts": [post]})
    fixtures["/api/v1/board/post-independent?format=flat"] = (
        200, h.board_detail_page(post, [comment]))

    def comment_width(output: bytearray, columns: int) -> int:
        rows = h.screen_rows(bytes(output))
        row = h.screen_row_of(rows, b"Comments (1)")
        if row < 0:
            raise AssertionError("focused comment heading is absent")
        line = rows[row].decode("utf-8", "replace")
        at = line.index("Comments (1)")
        # This pane is borderless on the right. The terminal edge, measured
        # from the drawn heading, distinguishes a growing column from a fixed
        # one: with a fixed comment width, the heading moves by every extra cell.
        return columns - at

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b"Health: ", start=0, timeout=10)
        h.palette_go(process, fd, output, b"go board", b"MASC Board")
        h.send_and_wait(process, fd, output, b"\r", b"Comment row 000")
        h.resize_and_wait(process, fd, output, rows=30, columns=SIDE_COLUMNS,
                          needle=b"Comment row 000", controls=(h.FULL_REDRAW,))
        h.send_and_wait(process, fd, output, b"b", b"> Comments (1)")
        h.send_and_wait(process, fd, output, b"\x1b[6~", b"comment rows ")
        comment_screen = h.screen_text(bytes(output))
        if b"Body mark 000" not in comment_screen:
            raise AssertionError("scrolling comments moved the first body line")
        visible_comments = re.findall(rb"Comment row \d{3}", comment_screen)
        if not visible_comments or b"Comment row 000" in visible_comments:
            raise AssertionError("PageDown did not scroll the focused comments")
        h.send_and_wait(process, fd, output, b"b", b"j/k:body")
        if b"> Independent read" not in h.screen_text(bytes(output)):
            raise AssertionError("the post focus is not visibly marked")
        h.send_and_wait(process, fd, output, b"\x1b[6~", b"post rows ")
        body_screen = h.screen_text(bytes(output))
        if b"Body mark 000" in body_screen:
            raise AssertionError("PageDown did not scroll the focused body")
        if re.findall(rb"Comment row \d{3}", body_screen) != visible_comments:
            raise AssertionError("scrolling the body moved the comment window")
        narrow_width = comment_width(output, SIDE_COLUMNS)
        h.resize_and_wait(process, fd, output, rows=30, columns=SIDE_COLUMNS + 60,
                          needle=b"Comments (1)", controls=(h.FULL_REDRAW,))
        wide_width = comment_width(output, SIDE_COLUMNS + 60)
        if wide_width <= narrow_width:
            raise AssertionError(
                f"comment column stayed fixed across widths: {narrow_width} -> {wide_width}")
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable, description="Board body and comments scroll independently",
        interact=interact, http_fixtures=fixtures)


def run_full_width_comments(executable: str) -> None:
    """Metadata must not determine paragraph, Korean or code-block width."""
    fixtures = h.overview_event_http_fixtures()
    post = h.board_selection_post("width", "Comment body width", "Body beside thread")
    paragraph = "Full width continuation stays readable"
    korean = "댓글 본문은 넓은 영역을 사용합니다"
    code = "document.documentElement.scrollWidth"
    comments = [
        dict(h.board_detail_comment("width-root", f"{paragraph}\n{paragraph}"),
             author="wkbl-layout-reviewer-with-long-name"),
        dict(h.board_detail_comment("width-child", f"{korean}\n```js\n{code}\n```"),
             parent_id="width-root", author="wkbl-layout-reviewer-with-long-name"),
        h.board_detail_comment("width-short", "OK"),
    ]
    post["comment_count"] = len(comments)
    fixtures["/api/v1/board?sort_by=hot"] = (200, {"posts": [post]})
    fixtures["/api/v1/board/post-width?format=flat"] = (
        200, h.board_detail_page(post, comments))

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b"Health: ", start=0, timeout=10)
        h.palette_go(process, fd, output, b"go board", b"MASC Board")
        h.wait_for_output(process, fd, output, ONE_POST_LISTED, start=0, timeout=10)
        h.send_and_wait(process, fd, output, b"\r", paragraph.encode())
        for columns in (240, 270, 100):
            h.resize_and_wait(process, fd, output, rows=48, columns=columns,
                              needle=paragraph.encode(), controls=(h.FULL_REDRAW,))
            screen = h.screen_text(bytes(output))
            for expected in (paragraph, korean, code):
                if expected.encode() not in screen:
                    raise AssertionError(
                        f"{columns} columns: comment body wrapped to metadata remainder: "
                        + screen.decode("utf-8", "replace"))
            if columns == 270:
                rows = h.screen_rows(bytes(output))
                short_row = h.screen_row_of(rows, b"OK")
                if short_row < 0 or b"@detail-author" not in rows[short_row]:
                    raise AssertionError("a short reply no longer joins its metadata")
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable, description="Board paragraphs use the full comment column",
        interact=interact, http_fixtures=fixtures)


def run_snapshot_context(executable: str) -> None:
    fixtures = h.overview_event_http_fixtures()
    post = h.board_selection_post("context", "Snapshot context", "One captured thread")
    comments = [h.board_detail_comment(f"context-{i}", f"Context row {i}") for i in range(121)]
    comments[0]["content"] = "Older ancestor retained in newest context"
    comments[-1]["parent_id"] = comments[0]["id"]
    fixtures["/api/v1/board?sort_by=hot"] = (200, {"posts": [post]})
    path = "/api/v1/board/post-context?format=flat"
    fixtures[path] = (200, h.board_detail_page(post, comments))
    fixtures[f"{path}&comment_offset=0&comment_limit=100"] = (
        200, h.board_detail_page(post, comments, offset=0, limit=100))
    changed = [dict(comment) for comment in comments]
    changed[-1]["content"] = "Changed generation must not enter history"
    changed[-1]["parent_id"] = comments[1]["id"]
    fixtures[f"{path}&comment_offset=100&comment_limit=100"] = (
        200, h.board_detail_page(post, changed, offset=100, limit=100))

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b"Health: ", start=0, timeout=10)
        h.palette_go(process, fd, output, b"go board", b"MASC Board")
        h.wait_for_output(process, fd, output, ONE_POST_LISTED, start=0, timeout=10)
        # Numeric page selection opens at its latest reply; Home can still
        # read the old root that only comment_context retained.
        h.send_and_wait(process, fd, output, b"\r", b"Context row 120")
        h.send_and_wait(process, fd, output, b"b", b"Comments")
        h.send_and_wait(process, fd, output, b"\x1b[H", b"Older ancestor retained in newest context")
        refused = h.send_and_wait(process, fd, output, b"o", b"Board comment thread changed")
        if b"Changed generation must not enter history" in h.screen_text(refused):
            raise AssertionError("mixed snapshot history was published despite refusal")
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Board")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description="Board context ancestors and mixed revision refusal",
        interact=interact, http_fixtures=fixtures)


def run_long_ancestor_landing(executable: str) -> None:
    fixtures = h.overview_event_http_fixtures()
    post = h.board_selection_post("deep", "Deep latest thread", "Short body")
    comments = [h.board_detail_comment(f"deep-{i}", f"Deep reply {i:03d}")
                for i in range(81)]
    for i in range(1, len(comments)):
        comments[i]["parent_id"] = comments[i - 1]["id"]
    post["comment_count"] = len(comments)
    path = "/api/v1/board/post-deep?format=flat"
    fixtures["/api/v1/board?sort_by=hot"] = (200, {"posts": [post]})
    fixtures[path] = (200, h.board_detail_page(post, comments))

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b"Health: ", start=0, timeout=10)
        h.palette_go(process, fd, output, b"go board", b"MASC Board")
        h.wait_for_output(process, fd, output, ONE_POST_LISTED, start=0, timeout=10)
        opened = h.send_and_wait(process, fd, output, b"\r", b"Deep reply 080")
        assert b"Deep reply 080" in h.screen_text(opened), "newest reply missing on open"
        assert b"Deep reply 000" not in h.screen_text(opened), "open stayed at old ancestors"
        h.send_and_wait(process, fd, output, b"b", b"Comments")
        h.send_and_wait(process, fd, output, b"\x1b[H", b"Deep reply 000")
        h.send_and_wait(process, fd, output, b"\x1b[F", b"Deep reply 080")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description="Board newest reply opens after long ancestor context",
                            interact=interact, http_fixtures=fixtures)


def run_history_refresh_ownership(executable: str) -> None:
    fixtures = h.overview_event_http_fixtures()
    post = h.board_selection_post("held", "Held history refresh", "Short body")
    comments = [h.board_detail_comment(f"held-{i}", f"Held reply {i:03d}")
                for i in range(41)]
    post["comment_count"] = len(comments)
    path = "/api/v1/board/post-held?format=flat"
    full_path = path + "&comment_offset=0&comment_limit=100"
    newest = h.SequencedHttpResponse([(200, h.board_detail_page(post, comments))])
    gate = h.GatedHttpResponse((200, h.board_detail_page(post, comments, offset=0, limit=100)),
                              hold_seconds=30.0)
    fixtures["/api/v1/board?sort_by=hot"] = (200, {"posts": [post]})
    fixtures[path] = newest
    fixtures[full_path] = (200, h.board_detail_page(post, comments, offset=0, limit=100))

    def interact(process, fd, _slave, output, _base):
        try:
            h.wait_for_output(process, fd, output, b"Health: ", start=0, timeout=10)
            h.palette_go(process, fd, output, b"go board", b"MASC Board")
            h.wait_for_output(process, fd, output, ONE_POST_LISTED, start=0, timeout=10)
            h.send_and_wait(process, fd, output, b"\r", b"Held reply 021")
            h.send_and_wait(process, fd, output, b"o", b"Held reply 000")
            fixtures[full_path] = gate
            os.write(fd, b"R")
            assert h.wait_for_fixture_event(process, fd, output, gate.requested, timeout=10)
            before = newest.served
            refreshing = h.send_and_wait(process, fd, output, b"o", b"Held reply 000")
            assert b"Held reply 000" in h.screen_text(refreshing)
            assert newest.served == before, "history toggled during its active request"
            assert not gate.completed.is_set(), "refresh fixture was not held"
            h.release_and_wait_for_frame(process, fd, output, gate, b"Held reply 000")
            h.send_and_wait(process, fd, output, b"o", b"Held reply 021")
            assert newest.served > before, "settled history could not return to newest page"
            os.write(fd, b"q")
        finally:
            gate.release.set()

    h.run_terminal_scenario(executable, description="Board history mode owns its held refresh",
                            interact=interact, http_fixtures=fixtures)


if __name__ == "__main__":
    run_long_ancestor_landing(os.path.abspath(sys.argv[1]))
    print("Board long ancestor latest landing: PASS")
    run_history_refresh_ownership(os.path.abspath(sys.argv[1]))
    print("Board history refresh ownership: PASS")
    run_snapshot_context(os.path.abspath(sys.argv[1]))
    print("Board context ancestors and mixed revision refusal: PASS")
    run_full_width_comments(os.path.abspath(sys.argv[1]))
    print("Board full width comments: PASS")
    run_independent_windows(os.path.abspath(sys.argv[1]))
    print("Board independent windows: PASS")
    run(os.path.abspath(sys.argv[1]))
    print("Long Board thread scrolling: PASS")
    run_side_by_side(os.path.abspath(sys.argv[1]))
    print("Board read comments beside the post: PASS")
    run_window_names_what_it_counts(os.path.abspath(sys.argv[1]))
    print("Board read window names what it counts: PASS")
