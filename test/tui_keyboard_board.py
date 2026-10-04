from __future__ import annotations

import os
import re
import subprocess

from tui_keyboard_harness import (
    board_detail_page,
    ACTING_PANE_NARROW_TERMINAL_COLUMNS,
    CSI_RE,
    FRAME_END,
    FULL_REDRAW,
    GatedHttpResponse,
    HttpFixtures,
    HttpResponse,
    Interaction,
    board_json_http_fixtures,
    board_selection_post,
    copy_reference,
    drain_until_quiet,
    end_of_needle,
    frame_containing,
    kill_process_group,
    overview_event_briefing,
    overview_event_http_fixtures,
    palette_go,
    read_available,
    release_and_wait_for_frame,
    resize_and_wait,
    run_terminal_scenario,
    screen_header,
    screen_row_of,
    screen_rows,
    selected_row,
    send_and_wait,
    tab_until,
    wait_for_fixture_event,
    wait_for_output,
)

# A body says what it is about by writing the reference the TUI itself writes.
# Two posts naming the same task are about the same thing; a post that merely
# spells the id in prose is not, because nobody wrote that connection down.
#
# The last post carries an id whose percent escapes decode to real terminal
# control bytes. Link.parse decodes, so that row is the one place a board post
# could have driven the reader's terminal.
BOARD_REFERENCE_TASK = "masc://overview/tasks/task-77"
BOARD_REFERENCE_GOAL = "masc://planning/goal-9"


def board_reference_http_fixtures() -> HttpFixtures:
    # One body per post, in the list and in the detail. The related block reads
    # the bodies the list carries, and board_post_dashboard_json sends p.body
    # whole -- a list body that summarised would leave the block permanently
    # empty while every unit test still passed.
    bodies = {
        "r1": ("Retry", f"we changed {BOARD_REFERENCE_TASK} for {BOARD_REFERENCE_GOAL}"),
        "r2": ("Rollout", f"also about {BOARD_REFERENCE_TASK}"),
        "r3": ("Prose", "task-77 and goal-9 in prose only"),
        "r4": ("Hostile", "see masc://board/post%1b%5b2Jdanger"),
    }
    posts = [
        board_selection_post(suffix, title, body)
        for suffix, (title, body) in bodies.items()
    ]
    fixtures = overview_event_http_fixtures()
    fixtures["/api/v1/board?sort_by=hot"] = (200, {"posts": posts})
    for suffix, (title, body) in bodies.items():
        fixtures[f"/api/v1/board/post-{suffix}?format=flat"] = (
            200,
            board_detail_page(board_selection_post(suffix, title, body), []),
        )
    return fixtures


def board_reference_interaction(fixtures: HttpFixtures) -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        wait_for_output(process, master_fd, output, b"Health: ", start=0, timeout=10.0)
        cluster_end = output.find(b"Health: ") + len(b"Health: ")
        wait_for_output(
            process, master_fd, output, FRAME_END, start=cluster_end, timeout=3.0
        )
        tab_until(process, master_fd, output, b"MASC Keepers")
        tab_until(process, master_fd, output, screen_header(b"MASC Board", b" (4)"))
        resize_and_wait(
            process,
            master_fd,
            output,
            rows=40,
            columns=180,
            needle=screen_header(b"MASC Board", b" (4)"),
            final_cursor=b"\x1b[?25l",
        )

        opened = send_and_wait(process, master_fd, output, b"\r", b"POINTS AT")
        plain = CSI_RE.sub(b"", frame_containing(opened, b"POINTS AT"))
        for needle in (b"task", b"task-77", b"goal", b"goal-9"):
            if needle not in plain:
                raise AssertionError(
                    f"POINTS AT dropped {needle!r}: {plain!r}"
                )
        if b"ALSO ABOUT THIS (1)" not in plain:
            raise AssertionError(f"related posts miscounted: {plain!r}")
        if b"post-r2" not in plain:
            raise AssertionError(f"the post naming the same task is missing: {plain!r}")
        if b"post-r3" in plain:
            raise AssertionError(
                f"an id spelled in prose became a link: {plain!r}"
            )

        # Down three rows to the hostile post, whose id decodes to control bytes.
        back = send_and_wait(process, master_fd, output, b"\x1b", b"MASC Board")
        del back
        for row in (b"post-r2", b"post-r3", b"post-r4"):
            send_and_wait(process, master_fd, output, b"j", selected_row(row))
        hostile = send_and_wait(process, master_fd, output, b"\r", b"POINTS AT")
        hostile_frame = frame_containing(hostile, b"POINTS AT")
        if rb"\x1B[2Jdanger" not in CSI_RE.sub(b"", hostile_frame):
            raise AssertionError(
                f"the decoded id was not rendered as text: {hostile_frame!r}"
            )
        if b"\x1b[2Jdanger" in hostile_frame:
            raise AssertionError(
                "a board post drove the reader's terminal: "
                f"{hostile_frame!r}"
            )

        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Board")
        # Arm the exit; the harness supplies the confirming press.
        os.write(master_fd, b"q")

    return interact


def board_json_interaction() -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        wait_for_output(process, master_fd, output, b"Health: ", start=0, timeout=10.0)
        tab_until(process, master_fd, output, b"MASC Keepers")
        tab_until(process, master_fd, output, screen_header(b"MASC Board", b" (2)"))
        resize_and_wait(
            process,
            master_fd,
            output,
            rows=40,
            columns=160,
            needle=screen_header(b"MASC Board", b" (2)"),
            final_cursor=b"\x1b[?25l",
        )

        opened = send_and_wait(
            process, master_fd, output, b"\r", b'"verification_request"'
        )
        frame = frame_containing(opened, b'"verification_request"')
        plain = CSI_RE.sub(b"", frame)
        for needle in (
            b'"verification_request": {',
            b'"task_id": "task-1200"',
            b'"approved": true',
            b'"attempt": 3',
        ):
            if needle not in plain:
                raise AssertionError(
                    f"Board JSON was not pretty-printed ({needle!r}): {plain!r}"
                )
        if b'{"verification_request":{"id"' in plain:
            raise AssertionError(f"Board kept compact JSON on one line: {plain!r}")
        highlighted_key = re.compile(
            rb'(?:\x1b\[[0-9;]*m)+'
            + re.escape(b'"verification_request"')
            + rb'(?:\x1b\[[0-9;]*m)+'
        )
        if highlighted_key.search(frame) is None:
            raise AssertionError(f"Board JSON key has no syntax colour: {frame!r}")
        detail_start = len(output)
        comment_needle = b'Evidence note: {"probe": true}'
        wait_for_output(
            process, master_fd, output, comment_needle, start=detail_start, timeout=3.0
        )
        wait_for_output(
            process,
            master_fd,
            output,
            FRAME_END,
            start=end_of_needle(output, comment_needle, detail_start),
            timeout=3.0,
        )
        detail_frame = frame_containing(bytes(output[detail_start:]), comment_needle)
        if comment_needle not in CSI_RE.sub(b"", detail_frame):
            raise AssertionError(f"plain Board comment text changed: {detail_frame!r}")

        markdown = send_and_wait(
            process, master_fd, output, b"]", b"Normal heading"
        )
        markdown_plain = CSI_RE.sub(b"", frame_containing(markdown, b"Normal heading"))
        for needle in (b"Normal heading", b"Markdown stays authored."):
            if needle not in markdown_plain:
                raise AssertionError(
                    f"ordinary Board Markdown lost {needle!r}: {markdown_plain!r}"
                )
        if b"# Normal heading" in markdown_plain or b"**Markdown" in markdown_plain:
            raise AssertionError(
                f"ordinary Board Markdown rendered as source: {markdown_plain!r}"
            )
        os.write(master_fd, b"q")

    return interact


def board_selection_identity_interaction(fixtures: HttpFixtures) -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        wait_for_output(process, master_fd, output, b"Health: ", start=0, timeout=10.0)
        cluster_end = output.find(b"Health: ") + len(b"Health: ")
        wait_for_output(
            process,
            master_fd,
            output,
            FRAME_END,
            start=cluster_end,
            timeout=3.0,
        )

        tab_until(process, master_fd, output, b"MASC Keepers")
        tab_until(process, master_fd, output, screen_header(b"MASC Board", b" (3)"))
        resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=180,
            needle=screen_header(b"MASC Board", b" (3)"),
            final_cursor=b"\x1b[?25l",
        )
        selected_b = selected_row(b"post-b")
        selected_a = selected_row(b"post-a")
        selected_new = selected_row(b"post-new")
        send_and_wait(process, master_fd, output, b"j", selected_b)
        detail = send_and_wait(process, master_fd, output, b"\r", b"detail-body-bravo")
        reference = b"masc://board/post-b"
        if reference not in detail:
            raise AssertionError(f"Board detail omitted its stable link: {detail!r}")
        copy_reference(process, master_fd, output, reference)
        # The label is where the key goes, so the wide detail offers the list
        # back rather than the width it already has.
        wide = send_and_wait(process, master_fd, output, b"z", b"z:list")
        wide_frame = frame_containing(wide, reference)
        if b"Board (3)" in wide_frame:
            raise AssertionError(
                f"Board wide detail kept the list pane visible: {wide_frame!r}"
            )
        # iTerm reports Ctrl-W as CSI-u after the TUI enables keyboard
        # disambiguation. It must reach the same pane binding as legacy 0x17.
        send_and_wait(process, master_fd, output, b"z", b"h/l:pane")
        # The Board cycle has three stops since #37691: list, detail, and the
        # Activity pane when the frame draws it (it does at 180 columns). From
        # the detail pane the press puts the pane's cursor on its first row,
        # painted in reverse video over the whole row; the row it lands on is
        # the pane's "[Recent]" header. Focus is a caret on the pane title,
        # not a key list (keys live in the footer), so the next press is
        # observed by the caret coming back to the list.
        send_and_wait(
            process,
            master_fd,
            output,
            b"\x1b[119;5u",
            re.compile(rb"\x1b\[7m(?:\x1b\[[0-9;]*m)*\[Recent\]"),
        )
        send_and_wait(process, master_fd, output, b"\x1b[119;5u", "\u25b8 Board (3)".encode())
        send_and_wait(process, master_fd, output, b"j", b"detail-body-charlie")
        send_and_wait(process, master_fd, output, b"k", b"detail-body-bravo")
        send_and_wait(process, master_fd, output, b"l", b"j/k:body")
        send_and_wait(process, master_fd, output, b"\x1b[6~", b"bravo-25")

        board = send_and_wait(process, master_fd, output, b"\x1b", screen_header(b"MASC Board", b" (3)"))
        if not selected_b.search(board) or selected_a.search(board):
            raise AssertionError(
                f"Board detail return changed the selected post: {board!r}"
            )

        fixtures["/api/v1/board?sort_by=trending"] = (
            200,
            {
                "posts": [
                    board_selection_post(
                        "trend", "Trending order", "server-trending-order"
                    ),
                    board_selection_post("a", "Alpha", "list-body-a"),
                    board_selection_post("b", "Bravo", "list-body-b"),
                    board_selection_post("c", "Charlie", "list-body-c"),
                ]
            },
        )
        sort_start = len(output)
        send_and_wait(process, master_fd, output, b"s", b"post-trend")
        # The header names the order by what it does, not by its key: the pane
        # draws Board_trending as "Sort [s]: net votes / \u221aage-hours", and no
        # screen has drawn "sort:trending". The header row and the reordered
        # list need not arrive in one frame, so wait for the header from the
        # press rather than reading it out of the frame that carried the rows.
        wait_for_output(
            process,
            master_fd,
            output,
            "Sort [s]: net votes / \u221aage-hours".encode(),
            start=sort_start,
            timeout=3.0,
        )

        fixtures["/api/v1/board?sort_by=trending"] = (
            200,
            {
                "posts": [
                    board_selection_post("new", "New", "list-body-new"),
                    board_selection_post("a", "Alpha", "list-body-a"),
                    board_selection_post("b", "Bravo", "list-body-b"),
                    board_selection_post("c", "Charlie", "list-body-c"),
                ]
            },
        )
        send_and_wait(process, master_fd, output, b"r", b"post-new")
        board = resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=179,
            needle=screen_header(b"MASC Board", b" (4)"),
            controls=(FULL_REDRAW,),
            final_cursor=b"\x1b[?25l",
        )
        if not selected_b.search(board) or selected_new.search(board):
            raise AssertionError(
                f"Board list refresh changed the selected post: {board!r}"
            )

        send_and_wait(process, master_fd, output, b"\r", b"detail-body-bravo")
        os.write(master_fd, b"q")

    return interact


def open_loaded_board(
    process: subprocess.Popen[bytes],
    master_fd: int,
    output: bytearray,
    *,
    post_count: int,
) -> None:
    wait_for_output(process, master_fd, output, b"Health: ", start=0, timeout=10.0)
    cluster_end = output.find(b"Health: ") + len(b"Health: ")
    wait_for_output(
        process,
        master_fd,
        output,
        FRAME_END,
        start=cluster_end,
        timeout=3.0,
    )
    tab_until(process, master_fd, output, b"MASC Keepers")
    tab_until(
        process,
        master_fd,
        output,
        screen_header(b"MASC Board", f" ({post_count})".encode()),
    )


def board_detail_isolation_interaction(b_failure: GatedHttpResponse) -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        completed = False
        try:
            open_loaded_board(process, master_fd, output, post_count=2)
            send_and_wait(process, master_fd, output, b"\r", b"a-only-comment")
            send_and_wait(process, master_fd, output, b"\x1b", screen_header(b"MASC Board", b" (2)"))
            send_and_wait(
                process,
                master_fd,
                output,
                b"j",
                selected_row(b"post-b"),
            )

            loading = send_and_wait(process, master_fd, output, b"\r", b"list-body-b")
            if b"Loading Board detail" not in loading or b"a-only-comment" in loading:
                raise AssertionError(
                    f"Board B loading leaked the prior detail: {loading!r}"
                )
            if not wait_for_fixture_event(
                process, master_fd, output, b_failure.requested, timeout=10.0
            ):
                raise AssertionError("Board B detail request did not reach its fixture")

            release_and_wait_for_frame(
                process,
                master_fd,
                output,
                b_failure,
                b"b-detail-failed",
            )
            failed = resize_and_wait(
                process,
                master_fd,
                output,
                rows=29,
                columns=100,
                needle=b"b-detail-failed",
                controls=(FULL_REDRAW,),
                final_cursor=b"\x1b[?25l",
            )
            if b"a-only-comment" in failed:
                raise AssertionError(
                    f"Board B failure leaked the prior detail: {failed!r}"
                )
            os.write(master_fd, b"q")
            completed = True
        finally:
            b_failure.release.set()
            if not completed and process.poll() is None:
                kill_process_group(process)

    return interact


def board_detail_authority_interaction(
    fixtures: HttpFixtures,
    late_list: GatedHttpResponse,
) -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        completed = False
        try:
            open_loaded_board(process, master_fd, output, post_count=2)
            fixtures["/api/v1/board?sort_by=hot"] = late_list
            # Home retains the briefing's unreadable-source reason. Use it
            # to observe the refresh without relying on removed incident cards.
            late_briefing = overview_event_briefing()
            late_briefing["keepers_listing"] = {
                "state": "unreadable", "detail": "late-list-applied"
            }
            fixtures["/api/v1/dashboard/briefing"] = (200, late_briefing)

            read_available(master_fd, output)
            os.write(master_fd, b"r")
            if not wait_for_fixture_event(
                process, master_fd, output, late_list.requested, timeout=10.0
            ):
                raise AssertionError(
                    "late Board list request did not reach its fixture"
                )
            detail = send_and_wait(
                process,
                master_fd,
                output,
                b"\r",
                b"a-authoritative-detail",
            )
            if b"a-only-comment" not in detail:
                raise AssertionError(f"Board A detail did not become ready: {detail!r}")

            late_list.release.set()
            tab_until(process, master_fd, output, b"MASC Work")
            tab_until(process, master_fd, output, b"MASC System")
            send_and_wait(process, master_fd, output, b"A", b"MASC Activity")
            tab_until(process, master_fd, output, b"late-list-applied")
            tab_until(process, master_fd, output, b"MASC Keepers")
            board = tab_until(
                process,
                master_fd,
                output,
                b"a-authoritative-detail",
            )
            if b"a-late-light-body" in board:
                raise AssertionError(
                    f"late Board list replaced the ready detail post: {board!r}"
                )

            board_list = send_and_wait(
                process, master_fd, output, b"\x1b", screen_header(b"MASC Board", b" (3)")
            )
            if b"post-c" not in board_list:
                raise AssertionError(
                    f"late Board list application was not observed: {board_list!r}"
                )
            os.write(master_fd, b"q")
            completed = True
        finally:
            late_list.release.set()
            if not completed and process.poll() is None:
                kill_process_group(process)

    return interact


def board_paginated_detail_interaction(
    fixtures: HttpFixtures,
    late_b: GatedHttpResponse,
) -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        completed = False
        try:
            open_loaded_board(process, master_fd, output, post_count=2)
            send_and_wait(
                process,
                master_fd,
                output,
                b"j",
                selected_row(b"post-b"),
            )
            send_and_wait(process, master_fd, output, b"\r", b"b-initial-comment")

            # An empty recent page is not an exact-ID deletion response.
            fixtures["/api/v1/board?sort_by=hot"] = (200, {"posts": []})
            fixtures["/api/v1/board/post-b?format=flat"] = late_b
            os.write(master_fd, b"R")
            if not wait_for_fixture_event(
                process, master_fd, output, late_b.requested, timeout=10.0
            ):
                raise AssertionError("late Board B request did not reach its fixture")
            refreshing = resize_and_wait(
                process, master_fd, output, rows=30, columns=179,
                needle=b"b-initial-comment", controls=(FULL_REDRAW,),
                final_cursor=b"\x1b[?25l",
            )
            if b"b-initial-comment" not in refreshing:
                raise AssertionError("page omission cleared the refreshing exact detail")

            release_and_wait_for_frame(
                process, master_fd, output, late_b, b"b-late-comment"
            )
            # Prove the page is still empty after the exact detail becomes ready.
            # It must not insert the historical detail into the ranked feed.
            fixtures["/api/v1/board/post-b?format=flat"] = (
                404, {"error": "fixture-exact-post-not-found"}
            )
            failed = send_and_wait(
                process, master_fd, output, b"R", b"fixture-exact-post-not-found"
            )
            if b"Board post load failed" not in CSI_RE.sub(b"", failed):
                raise AssertionError("the exact lookup failure was not shown")
            send_and_wait(
                process, master_fd, output, b"\x1b", screen_header(b"MASC Board", b" (0)")
            )
            os.write(master_fd, b"q")
            completed = True
        finally:
            late_b.release.set()
            if not completed and process.poll() is None:
                kill_process_group(process)

    return interact


# The Board draft is written in the default keyboard lane, which stops at an
# earlier scenario's exit step (#34125). This lane runs the one thing: the
# footer's offer and what the key it offered actually does.
def run_board_list_footer_regression(executable: str) -> None:
    """Measure completed native frames, including the bottom of a long list.

    Titles fit the Board column with the acting pane open beside it.
    A truncated title is valid rendering, so it cannot be a full-string barrier.
    """
    for state in ("populated", "empty", "unread", "failed"):
        fixtures = overview_event_http_fixtures()
        posts = [board_selection_post(str(i), f"board-{i:02d}",
                                      f"footer-body-{i:02d}") for i in range(70)]
        response: HttpResponse = (200, {"posts": posts if state == "populated" else []})
        gate = GatedHttpResponse(response, hold_seconds=60.0)
        fixtures["/api/v1/board?sort_by=hot"] = (
            gate if state == "unread" else
            (503, {"error": "board-down"}) if state == "failed" else response
        )
        fixtures["/api/v1/board/post-69?format=flat"] = (
            200, board_detail_page(posts[-1], []))
        marker = {"populated": b"board-00", "empty": b"(no board posts)",
                  "unread": b"not loaded yet", "failed": b"board-down"}[state]

        def interact(process: subprocess.Popen[bytes], master_fd: int,
                     _slave_fd: int, output: bytearray, _base_path: str) -> None:
            try:
                palette_go(process, master_fd, output, b"go board", b"MASC Board")
                wait_for_output(process, master_fd, output, marker, start=0, timeout=10.0)
                for height in (30, 44, 60):
                    resize_and_wait(process, master_fd, output, rows=height,
                                    columns=ACTING_PANE_NARROW_TERMINAL_COLUMNS,
                                    needle=marker, final_cursor=b"\x1b[?25l")
                    drain_until_quiet(process, master_fd, output)
                    completed = bytes(output[:output.rfind(FRAME_END) + len(FRAME_END)])
                    rows = screen_rows(completed)
                    if screen_row_of(rows, b"[Recent]") < 0:
                        raise AssertionError(
                            f"Board {state} at {height}: the acting pane is not open at "
                            f"{ACTING_PANE_NARROW_TERMINAL_COLUMNS} columns: {rows!r}")
                    footer = screen_row_of(rows, b"j/k:move")
                    composer = screen_row_of(rows, "›".encode())
                    if footer < 1 or composer != footer + 1:
                        raise AssertionError(
                            f"Board {state} at {height}: footer={footer}, composer={composer}: {rows!r}")
                    if screen_row_of(rows, marker) < 1:
                        raise AssertionError(f"Board {state} lost its current state: {rows!r}")
                    if state == "populated":
                        send_and_wait(process, master_fd, output, b"j" * 69, b"board-69")
                        send_and_wait(process, master_fd, output, b"\r", b"footer-body-69")
                        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Board")
                        send_and_wait(process, master_fd, output, b"k" * 69, b"board-00")
                os.write(master_fd, b"q")
            finally:
                gate.release.set()

        run_terminal_scenario(executable, description=f"Board list footer: {state}",
                              interact=interact, http_fixtures=fixtures)


def run_board_compose_footer_regression(executable: str) -> None:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        palette_go(process, master_fd, output, b"go board", b"MASC Board")
        writing = send_and_wait(process, master_fd, output, b"w", b"type to write")
        if b"q:quit" in CSI_RE.sub(b"", writing):
            raise AssertionError(
                "the writing footer offers q:quit, and q types a q: "
                f"{CSI_RE.sub(b'', writing)!r}"
            )
        # The other half of the same fact. The footer may not name a key as
        # quit while the draft takes it as a letter, so the letter has to be
        # seen landing.
        try:
            send_and_wait(process, master_fd, output, b"quit-goes-in", b"quit-goes-in")
        except AssertionError as timed_out:
            raise AssertionError(
                "the draft did not take 'quit-goes-in' as text, so whether the "
                f"footer may name q as quit is unmeasured here: {timed_out}"
            ) from timed_out
        # Out the way the armed footer names, not the way the old one did.
        send_and_wait(process, master_fd, output, b"\x1b", b"d:discard")
        send_and_wait(process, master_fd, output, b"d", b"MASC Board")
        os.write(master_fd, b"q")

    run_terminal_scenario(
        executable,
        description="The Board writing footer offers no key that types",
        interact=interact,
    )


def run_board_json_regression(executable: str) -> None:
    run_terminal_scenario(
        executable,
        description="Board JSON pretty-print and syntax highlighting",
        interact=board_json_interaction(),
        http_fixtures=board_json_http_fixtures(),
    )
