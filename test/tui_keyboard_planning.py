from __future__ import annotations

import os
import re
import subprocess

from tui_keyboard_approvals import (
    VERIFICATION_QUEUE_PATH,
    verification_snapshot,
    verification_verdict_fixtures,
)
from tui_keyboard_harness import (
    CSI_RE,
    FRAME_END,
    FULL_REDRAW,
    PLANNING_LIST_HEADER,
    PLANNING_PATH,
    GatedHttpResponse,
    HttpFixtures,
    Interaction,
    copy_reference,
    drain_until_quiet,
    fixture_cell_width,
    frame_containing,
    frame_row_of,
    palette_go,
    planning_activity_http_fixtures,
    planning_goal,
    planning_selection_http_fixtures,
    planning_snapshot,
    release_and_wait_for_frame,
    resize_and_wait,
    run_terminal_scenario,
    screen_row_of,
    screen_rows,
    screen_text,
    send_and_wait,
    tab_until,
    wait_for_fixture_event,
    wait_for_output,
)


def assert_planning_goal_selected(frame: bytes, title: bytes) -> None:
    """The goal named by [title] is the row the cursor is on.

    Anchored on the gutter marker and the title, with the columns between them
    left unread. Those columns carry a phase label, a proof mark and a priority,
    and each is its own contract with its own tests; pinning their exact shape
    here made this assertion fail whenever one of them changed. It did:
    #29786 put a proof mark between the phase and the priority, and this regex
    had required whitespace there.
    """
    plain = CSI_RE.sub(b"", frame)
    # What sits between the status bracket, priority, goal id, and title is the
    # renderer's business. This assertion means only "this goal is the selected
    # row"; information columns can be inserted without changing that fact.
    selected = re.compile(
        rb">[ \t]+\[[^\]\r\n]+\][^\r\n]*?P1[^\r\n]*?" + re.escape(title)
    )
    if selected.search(plain) is None:
        raise AssertionError(f"Planning did not select {title!r}: {frame!r}")


def open_loaded_planning(
    process: subprocess.Popen[bytes],
    master_fd: int,
    output: bytearray,
) -> None:
    # Navigate by named surface so Planning tests do not depend on tab order.
    palette_go(process, master_fd, output, b"go Work", b"plan-alpha-29424")


def planning_footer_dispatch_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    open_loaded_planning(process, master_fd, output)
    resize_and_wait(
        process, master_fd, output, rows=32, columns=360,
        needle=b"plan-alpha-29424", controls=(FULL_REDRAW,),
        final_cursor=b"\x1b[?25l",
    )

    def footer() -> bytes:
        rows = [row for row in screen_rows(bytes(output)).values()
                if b"j/k:move" in row]
        if len(rows) != 1:
            raise AssertionError(f"Planning drew {len(rows)} footer rows")
        return rows[0]

    list_footer = footer()
    for hint in (b"Right / Enter:detail", b"f:filter", b"s:sort"):
        if hint not in list_footer:
            raise AssertionError(f"Planning list omitted {hint!r}: {list_footer!r}")
    if b"[ / ]:previous / next" in list_footer:
        raise AssertionError(f"Planning list offered detail-only navigation: {list_footer!r}")

    send_and_wait(
        process, master_fd, output, b"\r", b"masc://planning/goal-a-29424"
    )
    detail_footer = footer()
    if b"[ / ]:previous / next" not in detail_footer:
        raise AssertionError(f"Planning detail omitted goal navigation: {detail_footer!r}")
    if b"Right / Enter:detail" in detail_footer:
        raise AssertionError(f"Planning detail offered list-only open: {detail_footer!r}")
    send_and_wait(
        process, master_fd, output, b"]", b"masc://planning/goal-b-29424"
    )
    if b"[ / ]:previous / next" not in footer():
        raise AssertionError("Planning detail step lost its footer")
    send_and_wait(
        process, master_fd, output, b"\x1b[D", b"Right / Enter:detail"
    )
    if b"[ / ]:previous / next" in footer():
        raise AssertionError("Planning list retained the detail-only hint")
    send_and_wait(
        process, master_fd, output, b"f", b"filter:completed"
    )
    if b"f:filter" not in footer():
        raise AssertionError("Planning list filter lost its footer")
    os.write(master_fd, b"q")


def planning_reorder_identity_interaction(fixtures: HttpFixtures) -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        open_loaded_planning(process, master_fd, output)
        selected = send_and_wait(process, master_fd, output, b"j", b"plan-beta-29424")
        if b"metric-goal-b-29424" not in CSI_RE.sub(b"", selected):
            raise AssertionError(
                f"Planning selected row omitted its metric/target: {selected!r}"
            )
        assert_planning_goal_selected(
            frame_containing(selected, b"plan-beta-29424"),
            b"plan-beta-29424",
        )

        fixtures[PLANNING_PATH] = planning_snapshot(
            [
                planning_goal("goal-new-29424", "plan-new-reorder-applied-29424"),
                planning_goal("goal-a-29424", "plan-alpha-29424"),
                planning_goal("goal-b-29424", "plan-beta-29424"),
                planning_goal("goal-c-29424", "plan-charlie-29424"),
            ]
        )
        send_and_wait(
            process,
            master_fd,
            output,
            b"r",
            b"plan-new-reorder-applied-29424",
        )
        refreshed = resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=99,
            needle=b"plan-new-reorder-applied-29424",
            controls=(FULL_REDRAW,),
            final_cursor=b"\x1b[?25l",
        )
        assert_planning_goal_selected(refreshed, b"plan-beta-29424")

        detail = send_and_wait(process, master_fd, output, b"\x1b[C", b"goal-b-29424")
        goal_reference = b"masc://planning/goal-b-29424"
        if (
            b"plan-beta-29424" not in detail
            # The footer is built from the key table now, which spells the
            # pair "Left / Esc:back". The flat "left/Esc:back" is the string
            # this surface carried before it read its hints from the bindings.
            or b"Left / Esc:back" not in detail
            or goal_reference not in detail
        ):
            raise AssertionError(
                f"Planning refresh opened a different goal detail: {detail!r}"
            )
        copy_reference(process, master_fd, output, goal_reference)
        listing = send_and_wait(process, master_fd, output, b"\x1b[D", b"MASC Work")
        assert_planning_goal_selected(listing, b"plan-beta-29424")
        os.write(master_fd, b"q")

    return interact


def planning_resize_budget_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    open_loaded_planning(process, master_fd, output)
    # The surface strip and composer consume two rows. Exercise the old
    # zero-goal case (19 surface rows) and the minimum supported surface (14).
    for terminal_rows, columns in (
        (21, 120),
        (16, 120),
        (16, 80),
        (17, 120),
        (20, 120),
        (24, 120),
        (16, 120),
    ):
        frame = resize_and_wait(
            process,
            master_fd,
            output,
            rows=terminal_rows,
            columns=columns,
            needle=b"MASC Work",
            controls=(FULL_REDRAW,),
            final_cursor=b"\x1b[?25l",
        )
        assert_planning_goal_selected(frame, b"plan-alpha-29424")
        if b"earlier-plan-29424" not in CSI_RE.sub(b"", frame):
            raise AssertionError(f"Planning lost retained goal history: {frame!r}")
        if b"metric-goal-a-29424" not in CSI_RE.sub(b"", frame):
            raise AssertionError(f"Planning lost the selected goal detail: {frame!r}")
        for label in (b"Goals:", b"No longer listed:", b"sort:", b"filter:active"):
            if label not in CSI_RE.sub(b"", frame):
                raise AssertionError(f"Planning lost {label!r}: {frame!r}")
        if terminal_rows == 24 and b"Backlog:" not in CSI_RE.sub(b"", frame):
            raise AssertionError(f"Planning did not restore its full summary: {frame!r}")
        footer_row = frame_row_of(frame, b"j/k:move")
        goal_row = frame_row_of(frame, b"plan-alpha-29424")
        detail_row = frame_row_of(frame, b"metric-goal-a-29424")
        # Row addresses include the prepended surface strip; the footer sits
        # immediately above the composer on the terminal's last row.
        if not goal_row < detail_row < footer_row < terminal_rows:
            raise AssertionError(f"Planning overflowed its surface: {frame!r}")
        selected = send_and_wait(
            process, master_fd, output, b"j", b"plan-beta-29424"
        )
        assert_planning_goal_selected(selected, b"plan-beta-29424")
        if b"metric-goal-b-29424" not in CSI_RE.sub(b"", selected):
            raise AssertionError(f"Planning navigation lost selected detail: {selected!r}")
        restored = send_and_wait(
            process, master_fd, output, b"k", b"plan-alpha-29424"
        )
        assert_planning_goal_selected(restored, b"plan-alpha-29424")

    mode_prefix = re.search(
        rb" MASC Work[^\r\n]*?filter:active", CSI_RE.sub(b"", frame)
    )
    if mode_prefix is None:
        raise AssertionError(f"Planning wide header omitted its modes: {frame!r}")
    # Four cells belong to the frame margins. At this width the title and
    # modes exactly fill the content area, before the timestamp is appended.
    boundary_cols = fixture_cell_width(mode_prefix.group().decode("utf-8")) + 4
    # A boundary that stops at the modes describes a row Planning has never
    # drawn: the clock and the badge follow them on the same row. The widths
    # between the two boundaries are where the row overflowed -- at a hundred
    # columns it ran to 112 cells of the 96 it had, and the frame cut off
    # "HTTP [connected]" and the seconds of the clock. Both sides of the real
    # boundary are exercised below.
    chrome_re = re.compile(rb"\d\d:\d\d:\d\d  HTTP \[[^\]\r\n]+\]")
    chrome = chrome_re.search(CSI_RE.sub(b"", frame))
    if chrome is None:
        raise AssertionError(f"Planning wide header omitted its badge: {frame!r}")
    # Two more cells for the gap the row puts in front of the clock.
    riding_cols = (
        boundary_cols + fixture_cell_width(chrome.group().decode("utf-8")) + 2
    )
    for columns in (80, boundary_cols, riding_cols - 1, riding_cols):
        narrow = resize_and_wait(
            process,
            master_fd,
            output,
            rows=24,
            columns=columns,
            needle=b"MASC Work",
            controls=(FULL_REDRAW,),
            final_cursor=b"\x1b[?25l",
        )
        plain_narrow = CSI_RE.sub(b"", narrow)
        if b"filter:active" not in plain_narrow or b"sort:" not in plain_narrow:
            raise AssertionError(f"Planning hid its modes behind the title: {narrow!r}")
        # Whichever row the modes took, the title row keeps what has nowhere
        # else to go. On Planning the clock and the badge are the only things
        # that say whether the screen is a live reading, and the modes have a
        # row of their own to fall to.
        title_row = next(
            (
                text
                for _, text in sorted(screen_rows(narrow).items())
                if b"MASC Work" in text
            ),
            None,
        )
        if title_row is None:
            raise AssertionError(f"Planning drew no title row: {narrow!r}")
        if chrome_re.search(title_row) is None:
            raise AssertionError(
                f"Planning title row lost its clock and badge at {columns} "
                f"columns: {title_row!r}"
            )
    terminal_rows = 24

    # One press, not two. The pane opens on Planning_filter_active, so the
    # first press lands on completed, which these fixtures leave empty --
    # the note this step is about is already on that screen. The old pair
    # was written for a default of Planning_filter_all: it waited for
    # "filter:active", the filter the pane had just left, and then for a note
    # that a second press had already carried past.
    empty = send_and_wait(process, master_fd, output, b"f", b"filter:completed")
    if b"no goals in this filter" not in CSI_RE.sub(b"", empty):
        raise AssertionError(
            f"the empty filter drew no note: {empty!r}"
        )
    if frame_row_of(empty, b"no goals in this filter") >= terminal_rows - 2:
        raise AssertionError(f"Planning empty note overflowed: {empty!r}")
    os.write(master_fd, b"q")


def planning_missing_detail_interaction(fixtures: HttpFixtures) -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        open_loaded_planning(process, master_fd, output)
        selected = send_and_wait(process, master_fd, output, b"j", b"plan-beta-29424")
        assert_planning_goal_selected(
            frame_containing(selected, b"plan-beta-29424"),
            b"plan-beta-29424",
        )
        detail = send_and_wait(process, master_fd, output, b"\r", b"goal-b-29424")
        if b"plan-beta-29424" not in detail or b"Esc:back" not in detail:
            raise AssertionError(f"fixture did not open Planning B detail: {detail!r}")

        fixtures[PLANNING_PATH] = planning_snapshot(
            [
                planning_goal("goal-a-29424", "plan-alpha-29424"),
                planning_goal("goal-c-29424", "plan-charlie-29424"),
                planning_goal("goal-d-29424", "plan-delta-missing-applied-29424"),
            ]
        )
        send_and_wait(
            process,
            master_fd,
            output,
            b"r",
            b"plan-delta-missing-applied-29424",
        )
        recovered = resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=99,
            needle=b"plan-delta-missing-applied-29424",
            controls=(FULL_REDRAW,),
            final_cursor=b"\x1b[?25l",
        )
        assert_planning_goal_selected(recovered, b"plan-charlie-29424")
        # What has to hold is that the surface fell back to the list rather
        # than drawing a detail for a goal the snapshot no longer carries.
        # The footer stopped answering that: it is built from the key table
        # now and publishes "Left / Esc:back" in both modes, and it never says
        # "Enter:detail" -- the Planning row spells that key "Right / Enter"
        # (Masc_tui_keys, Planning) and this width does not reach it anyway.
        # The column header is the list pane's own line and the goal link and
        # timeline heading are the detail pane's, so the two together say
        # which mode drew the screen.
        if (
            not PLANNING_LIST_HEADER.search(recovered)
            or b"masc://planning/" in recovered
            or b"TIMELINE" in recovered
        ):
            raise AssertionError(
                f"missing Planning detail did not render list mode: {recovered!r}"
            )

        moved = send_and_wait(
            process,
            master_fd,
            output,
            b"j",
            b"plan-delta-missing-applied-29424",
        )
        assert_planning_goal_selected(
            frame_containing(moved, b"plan-delta-missing-applied-29424"),
            b"plan-delta-missing-applied-29424",
        )
        delta_detail = send_and_wait(process, master_fd, output, b"\r", b"goal-d-29424")
        if (
            b"plan-delta-missing-applied-29424" not in delta_detail
            or b"Esc:back" not in delta_detail
        ):
            raise AssertionError(
                f"recovered Planning list did not open D detail: {delta_detail!r}"
            )
        os.write(master_fd, b"q")

    return interact


def verification_unread_interaction(gate: GatedHttpResponse) -> Interaction:
    """A surface that has not been read says so; only a read that came back
    empty says the queue is empty.

    The Verification surface used to print "(nothing waiting on a verdict)"
    under a header that still said "(not loaded)", so the two rows disagreed
    about whether anything had been asked. The fixture holds the response
    until the first frame has been read off.
    """

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        tab_until(process, master_fd, output, b"MASC Work")
        unread = send_and_wait(
            process, master_fd, output, b"v", b"Task Review"
        )
        if b"(not loaded)" not in unread:
            raise AssertionError(
                f"Verification header did not say not loaded: {unread!r}"
            )
        if b"(not loaded yet" not in unread:
            raise AssertionError(
                f"Verification body claimed a reading before one was made: {unread!r}"
            )
        if b"nothing waiting" in unread:
            raise AssertionError(
                f"Verification body read an empty queue off no reading: {unread!r}"
            )
        if not wait_for_fixture_event(
            process, master_fd, output, gate.requested, timeout=10.0
        ):
            raise AssertionError("Verification surface did not ask for its queue")
        loaded = release_and_wait_for_frame(
            process, master_fd, output, gate, b"(nothing waiting on a verdict)"
        )
        # The title and the count are asserted apart: a style reset may sit
        # between them once surface titles carry their own styling.
        if (
            b"MASC Work" not in loaded
            or b"Task Review" not in loaded
            or b"(0 of 0)" not in loaded
        ):
            raise AssertionError(
                f"Verification header did not report the read: {loaded!r}"
            )
        os.write(master_fd, b"q")

    return interact


def planning_review_hierarchy_interaction() -> Interaction:
    """Planning owns Goals and Task Review while Tab sees one parent."""

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        goals = tab_until(process, master_fd, output, b"MASC Work")
        for needle in (
            b"\xe2\x96\xb8Goals",
            b"Task Review",
            b"Task Verdicts",
        ):
            if needle not in goals:
                raise AssertionError(
                    f"Planning did not expose its ordered child views "
                    f"({needle!r}): {goals!r}"
                )
        review = send_and_wait(
            process, master_fd, output, b"v", b"\xe2\x96\xb8Task Review"
        )
        wait_for_output(process, master_fd, output, b"task-901", start=0, timeout=3.0)
        plain_review = CSI_RE.sub(b"", review)
        if b"MASC Work" not in plain_review:
            raise AssertionError(f"Task Review lost its Planning parent: {plain_review!r}")
        # The badge says the queue holds two; a page holding both says
        # nothing more. It used to read "Task Review·2 (2 of 2)".
        drain_until_quiet(process, master_fd, output)
        rows = screen_rows(bytes(output[: output.rfind(FRAME_END) + len(FRAME_END)]))
        title = rows.get(screen_row_of(rows, b"\xe2\x96\xb8Task Review"), b"")
        if b"\xe2\x96\xb8Task Review\xc2\xb72  Task Verdicts" not in title:
            raise AssertionError(
                f"the Task Review title repeats the badge's count: {title!r}"
            )
        # The request's detail: Created in the terminal's zone, not the
        # server's RFC 3339 text with its offset, and the reading note whole
        # rather than cut at the row's end.
        send_and_wait(process, master_fd, output, b"\r", b"VERIFICATION REQUEST")
        drain_until_quiet(process, master_fd, output)
        rows = screen_rows(bytes(output[: output.rfind(FRAME_END) + len(FRAME_END)]))
        created = rows.get(screen_row_of(rows, b"Created"), b"")
        if b"+09:00" in created or not re.search(rb"Created\s+\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}", created):
            raise AssertionError(
                f"the request's Created is not the terminal's clock: {created!r}"
            )
        if screen_row_of(rows, b"inspect now.") < 0:
            raise AssertionError(
                f"the reading note was cut instead of wrapped: {screen_text(bytes(output))!r}"
            )
        send_and_wait(process, master_fd, output, b"\x1b", b"\xe2\x96\xb8Task Review")
        verdicts = send_and_wait(
            process,
            master_fd,
            output,
            b"v",
            b"\xe2\x96\xb8Task Verdicts",
        )
        verdicts_plain = CSI_RE.sub(b"", verdicts)
        for needle in (b"automatic Gate rulings on Tasks", b"not Goal proof", b"Task Verdicts"):
            if needle not in verdicts_plain:
                raise AssertionError(
                    f"Task Verdicts did not explain itself ({needle!r}): "
                    f"{verdicts_plain!r}"
                )
        # And it keeps its footer. The surface declared its chrome as a
        # constant that said seven where the head draws nine, so it ran three
        # rows past its budget; a surface that overruns loses its last rows,
        # and the last row here is the footer. The screen drew no key hints at
        # all, at every terminal height. "y / x" is this surface's own pair, so
        # a row left over from another screen cannot stand in for it.
        #
        # The ledger block is what makes the head nine rows, and it rides the
        # refresh rather than the first paint: without this wait the screen
        # under assertion is the six-row head, where the old constant was
        # right and the footer was never lost.
        wait_for_output(process, master_fd, output, b"12 ruled", start=0,
                        timeout=20.0)
        drain_until_quiet(process, master_fd, output)
        rows = screen_rows(
            bytes(output[: output.rfind(FRAME_END) + len(FRAME_END)]))
        if screen_row_of(rows, b"y / x:agree / overrule") < 0:
            raise AssertionError(
                "Task Verdicts drew no key hints: its footer was cut. Screen: "
                + repr(screen_text(bytes(output)))
            )
        # Planning's [v] strip has exactly three stops — Goals, Task Review,
        # Task Verdicts — and wraps back round to Goals. The walk used to
        # keep two extra children, Schedules and Fusion, but Schedules was
        # promoted to its own top-level surface (palette: "go Schedules";
        # the wake-schedule scenario asserts that entry point) and Fusion
        # became a tab of the selected Keeper (RFC-tui-operator-ia 3.1).
        # Waiting for their boxed titles here starved with the strip
        # redrawn every stop but theirs never drawn.
        goals_again = send_and_wait(
            process, master_fd, output, b"v", b"\xe2\x96\xb8Goals"
        )
        if b"Task Review" not in goals_again:
            raise AssertionError(
                f"Goals did not retain the Task Review sibling: {goals_again!r}"
            )
        # The children are [v] stops, not the next top-level Tab destination.
        # Work is one Tab stop; the next top-level destination is Keepers.
        send_and_wait(process, master_fd, output, b"\t", b"MASC Keepers")
        os.write(master_fd, b"q")

    return interact


def planning_activity_actor_interaction() -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        before_work = len(output)
        work_frame = tab_until(process, master_fd, output, b"MASC Work")
        work_start = bytes(output).find(work_frame, before_work)
        wait_for_output(
            process, master_fd, output, b"Actor-visible goal activity",
            start=work_start, timeout=3.0,
        )
        detail = send_and_wait(
            process, master_fd, output, b"\r", b"completed by beta"
        )
        plain = CSI_RE.sub(b"", detail)
        for needle in (
            b"RELATED ACTIVITY",
            b"latest state per linked item",
            b"task-actor",
            b"completed by beta",
            b"handoff by",
            b"alpha:",
        ):
            if needle not in plain:
                raise AssertionError(
                    f"Planning activity omitted {needle!r}: {plain!r}"
                )
        os.write(master_fd, b"q")

    return interact


def run_planning_review_regression(executable: str) -> None:
    run_terminal_scenario(
        executable,
        description="Planning footer follows list and detail dispatch",
        interact=planning_footer_dispatch_interaction,
        http_fixtures=planning_selection_http_fixtures(),
    )
    run_terminal_scenario(
        executable,
        description="Planning preserves selected goals and footer across resize",
        interact=planning_resize_budget_interaction,
        http_fixtures=planning_selection_http_fixtures(),
    )
    verification_gate = GatedHttpResponse((200, verification_snapshot([])))
    run_terminal_scenario(
        executable,
        description="Planning Task Review unread before read",
        interact=verification_unread_interaction(verification_gate),
        http_fixtures={
            VERIFICATION_QUEUE_PATH: verification_gate,
        },
    )
    run_terminal_scenario(
        executable,
        description="Planning owns Goals and Task Review",
        interact=planning_review_hierarchy_interaction(),
        http_fixtures=verification_verdict_fixtures(),
    )
    run_terminal_scenario(
        executable,
        description="Planning activity names actor role and handoff author",
        interact=planning_activity_actor_interaction(),
        http_fixtures=planning_activity_http_fixtures(),
    )
