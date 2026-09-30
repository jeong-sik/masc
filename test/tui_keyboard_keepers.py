from __future__ import annotations

import fcntl
import hashlib
import json
import os
import re
import shutil
import signal
import struct
import subprocess
import tempfile
import termios
import time
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path

from tui_keyboard_harness import (
    ACTING_PANE_CYCLE_COLUMNS,
    ACTING_PANE_NARROW_COLUMNS,
    ACTING_PANE_SURFACE_FLOOR_COLUMNS,
    ACTING_PANE_THRESHOLD_COLUMNS,
    ACTING_PANE_WIDE_COLUMNS,
    CONSOLE_DIAGNOSTIC,
    CSI_RE,
    DASHBOARD_GOALS_PATH,
    FRAME_END,
    FULL_REDRAW,
    KEEPER_DETAIL_SCROLL_BOUND,
    KEEPER_RUNTIME_COLUMN_COLUMNS,
    PLANNING_PATH,
    RUNTIME_RESOLVED_PATH,
    STRIP_CUT_COLUMNS,
    WINDOW_TEXT_RE,
    GatedHttpResponse,
    HttpFixtures,
    HttpRequests,
    HttpResponse,
    Interaction,
    Needle,
    RequestHttpResponse,
    drain_until_quiet,
    empty_runtime_resolved_fixture,
    escape_to_keeper_detail,
    find_needle,
    frame_containing,
    keeper_metadata,
    keeper_row_selected,
    keeper_runtime_http_fixtures,
    kill_process_group,
    overview_event_http_fixtures,
    palette_go,
    planning_goal,
    planning_snapshot,
    read_available,
    release_and_wait_for_frame,
    resize_and_wait,
    run_terminal_scenario,
    screen_header,
    screen_row_of,
    screen_rows,
    screen_text,
    select_keeper_row,
    send_and_wait,
    tab_until,
    wait_for_fixture_event,
    wait_for_http_request,
    wait_for_output,
    wait_for_stop,
    wait_for_terminal_input_consumed,
    write_all,
)
from tui_keyboard_runtime import (
    RUNTIME_CONFIG_RAW_PATH,
    runtime_config_read_metadata,
    runtime_resolved_response,
)


def acting_pane_header_cell(output: bytearray) -> int:
    """The cell "[Recent]" starts at on the screen now, or -1 when no pane
    header is drawn. Cells are counted as code points: the surface beside
    the pane at this size draws no wide glyph."""
    for _row, text in sorted(screen_rows(bytes(output)).items()):
        plain = text.decode("utf-8", "replace")
        cell = plain.find("[Recent]")
        if cell >= 0:
            return cell
    return -1


def acting_pane_floor_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    """One column short of the threshold the surface has the whole terminal;
    at the threshold the narrow pane stands at the right edge. A pane that
    opens with less than the floor left would narrow a screen's tables below
    the columns the floor keeps."""
    # Keepers exercises the shared width floor beside its flag columns.
    tab_until(process, master_fd, output, b"MASC Keepers")
    for columns, expected in (
        (ACTING_PANE_THRESHOLD_COLUMNS - 1, -1),
        (
            ACTING_PANE_THRESHOLD_COLUMNS,
            ACTING_PANE_THRESHOLD_COLUMNS - ACTING_PANE_NARROW_COLUMNS + 1,
        ),
    ):
        resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=columns,
            needle=b"MASC Keepers",
        )
        drain_until_quiet(process, master_fd, output, cap=4.0)
        drawn = acting_pane_header_cell(output)
        if drawn != expected:
            raise AssertionError(
                f"at {columns} columns: pane header at cell {drawn}, "
                f"expected {expected}: {screen_text(bytes(output))!r}"
            )
    send_and_wait(process, master_fd, output, b"q", b"q: press again to quit")


def acting_pane_ctrl_l_cycle_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    resize_and_wait(
        process,
        master_fd,
        output,
        rows=30,
        columns=ACTING_PANE_CYCLE_COLUMNS,
        needle=b"MASC Dashboard",
    )
    # Exercise the shared width cycle beside the Keepers list.
    send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
    drain_until_quiet(process, master_fd, output, cap=4.0)

    def header_for(pane_columns: int) -> int:
        return ACTING_PANE_CYCLE_COLUMNS - pane_columns + 1

    expected = [
        ("the pane opens narrow", header_for(ACTING_PANE_NARROW_COLUMNS)),
        ("one press: wide", header_for(ACTING_PANE_WIDE_COLUMNS)),
        ("two presses: hidden", -1),
        ("three presses: narrow again", header_for(ACTING_PANE_NARROW_COLUMNS)),
    ]
    for index, (label, cell) in enumerate(expected):
        if index > 0:
            write_all(master_fd, output, b"\x0c")
            drain_until_quiet(process, master_fd, output, cap=4.0)
        drawn = acting_pane_header_cell(output)
        if drawn != cell:
            raise AssertionError(
                f"{label}: pane header at cell {drawn}, expected {cell}: "
                f"{screen_text(bytes(output))!r}"
            )
    send_and_wait(process, master_fd, output, b"q", b"q: press again to quit")


# The Keeper chat lays out in the columns every surface gets -- the terminal
# less the Activity pane -- and the pane is drawn in the rest (#39574). The
# chat used to reserve those columns and leave them empty beside it. The width
# is past Masc_tui_acting_pane.threshold_cols with room to spare, so the pane
# opens in its default narrow layout while that threshold moves (#39593).
KEEPER_CHAT_PANE_COLUMNS = 160


def keeper_chat_draws_activity_pane_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    # Tab rather than a number key: the number that reaches Keepers is being
    # reassigned (#38801), the Tab ring reaches it either way.
    tab_until(process, master_fd, output, b"MASC Keepers")
    select_keeper_row(process, master_fd, output, b"alpha")
    send_and_wait(
        process,
        master_fd,
        output,
        b"c",
        b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat",
    )
    drain_until_quiet(process, master_fd, output, cap=4.0)
    expected = KEEPER_CHAT_PANE_COLUMNS - ACTING_PANE_NARROW_COLUMNS + 1
    drawn = acting_pane_header_cell(output)
    if drawn != expected:
        raise AssertionError(
            f"chat: pane header at cell {drawn}, expected {expected}: "
            f"{screen_text(bytes(output))!r}"
        )
    send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
    send_and_wait(process, master_fd, output, b"q", b"q: press again to quit")


def keeper_runtime_phase_and_identity_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    resize_and_wait(
        process,
        master_fd,
        output,
        rows=30,
        columns=KEEPER_RUNTIME_COLUMN_COLUMNS,
        needle=b"MASC Dashboard",
    )
    send_and_wait(
        process,
        master_fd,
        output,
        b"3",
        b"anthropic.claude-opus-5",
    )
    wait_for_output(
        process,
        master_fd,
        output,
        b"LIFECYCLE / RUNTIME",
        start=0,
        timeout=3.0,
    )
    # The roster column, not the chat header: "configured: " is the header's
    # label for the configured runtime (#35455), and the roster row draws the
    # phase straight against the model name.
    wait_for_output(
        process,
        master_fd,
        output,
        b"paused anthropic.claude-sonnet-4",
        start=0,
        timeout=3.0,
    )
    # Delete is offered for every keeper state, and for one whose configuration
    # failed to read it is the only offer -- `primary` withholds it from the
    # toggle on purpose. The footer named no key for it, so the single action
    # that worked was the one the screen never mentioned. The needle carries the
    # reset that follows the key, which is what separates an offered hint from
    # the dim `\x1b[2mx:delete` an unavailable one would draw. The footer moved
    # to the key table's key:label form, so the label follows a colon now.
    wait_for_output(
        process,
        master_fd,
        output,
        b"x\x1b[0m:delete",
        start=0,
        timeout=3.0,
    )
    os.write(master_fd, b"q")


def keeper_long_runtime_identity_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    resize_and_wait(
        process,
        master_fd,
        output,
        rows=30,
        columns=KEEPER_RUNTIME_COLUMN_COLUMNS,
        needle=b"MASC Dashboard",
    )
    # Both keepers run the same provider subscription, so their ids differ
    # only in the variant suffix after a 51-character shared prefix. What
    # has to hold is that the elision cuts the shared middle and leaves the
    # tail that tells the two apart. Where exactly it cuts is a function of
    # the column width, so pinning the cut point spells a needle that a
    # wider column retires -- the earlier b"antigrav\xe2\x80\xa6.gemini-3-7-flash"
    # was written against a narrower column and stopped matching without the
    # behaviour changing.
    #
    # The ids are 55 and 58 cells wide because the column now sizes itself
    # to the widest id the rows hold (#38320): at this scenario's 126
    # columns the cell reaches 53 cells, and the narrowest inner width that
    # draws the column at all (118) still gives it 47, so the shorter ids
    # this scenario drew before -- 40 and 41 cells -- fit whole at every
    # width and stopped exercising the elision (issue #38323).
    send_and_wait(
        process,
        master_fd,
        output,
        b"3",
        b"flash-thinking-preview",
    )
    wait_for_output(
        process,
        master_fd,
        output,
        b"thinking-lite",
        start=0,
        timeout=3.0,
    )
    frame = frame_containing(bytes(output), b"thinking-lite")
    for full_id in (
        b"antigravity_subscription.gemini-3-7-flash-thinking-preview",
        b"antigravity_subscription.gemini-3-7-flash-thinking-lite",
    ):
        if full_id in frame:
            raise AssertionError(
                f"{full_id!r} was drawn whole, so this scenario is no longer "
                f"exercising the elision it guards: {frame!r}"
            )
    os.write(master_fd, b"q")


def press_label_on_screen(
    process: subprocess.Popen[bytes],
    master_fd: int,
    output: bytearray,
    label: bytes,
    *,
    row: int,
    needle: Needle,
) -> None:
    """Press the first cell of [label] where the screen draws it on [row].

    The column is read from the drawn screen, not from a layout constant, so
    the press lands where a reader would put the pointer. Every strip glyph
    is one cell wide, so the column is the count of characters before it."""
    text = screen_rows(bytes(output)).get(row, b"")
    index = text.find(label)
    if index < 0:
        raise AssertionError(f"{label!r} is not drawn on row {row}: {text!r}")
    column = len(text[:index].decode("utf-8")) + 1
    press = b"\x1b[<0;%d;%dM\x1b[<0;%d;%dm" % (column, row, column, row)
    send_and_wait(process, master_fd, output, press, needle)


def pressing_a_tab_opens_it(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    """A press on a tab's name is the key that reaches that tab.

    The Tab ring on the first row and the pane strip in a surface's title
    are drawn as text; the renderer marks each name and the TUI reads where
    the marks landed in the frame it presented. Here the press goes to the
    cells the name occupies on screen, and the surface it names opens."""
    wait_for_output(
        process, master_fd, output, b"\x1b[?1006;1000h", start=0, timeout=3.0
    )
    wait_for_output(process, master_fd, output, b"MASC Dashboard", start=0, timeout=3.0)
    press_label_on_screen(
        process, master_fd, output, b"Board", row=1, needle=b"MASC Board"
    )
    # The cheat sheet keeps the strip on its first row. A press there must not
    # move the surface under it: Esc closes the sheet onto Board, not onto
    # the surface that was pressed.
    send_and_wait(process, master_fd, output, b"?", b"MASC Cheat Sheet")
    strip = screen_rows(bytes(output)).get(1, b"")
    workspace = strip.find(b"Workspace")
    if workspace < 0:
        raise AssertionError(f"the sheet does not keep the strip: {strip!r}")
    column = len(strip[:workspace].decode("utf-8")) + 1
    write_all(master_fd, output, b"\x1b[<0;%d;1M\x1b[<0;%d;1m" % (column, column))
    send_and_wait(process, master_fd, output, b"\x1b", b"MASC Board")
    press_label_on_screen(
        process, master_fd, output, b"System", row=1, needle=b"MASC System"
    )
    # At a hundred columns the System title keeps its path, clock and badge
    # and leaves the pane strip room for the current pane alone. Wide enough,
    # every pane is drawn and each is a place to press.
    resize_and_wait(
        process,
        master_fd,
        output,
        rows=40,
        columns=220,
        needle=b"MASC System",
        controls=(FULL_REDRAW,),
        final_cursor=b"\x1b[?25l",
    )
    title_row = screen_row_of(screen_rows(bytes(output)), b"runtime.toml")
    if title_row < 0:
        raise AssertionError(
            f"the System pane strip is not on screen: {screen_text(bytes(output))!r}"
        )
    press_label_on_screen(
        process, master_fd, output, b"models", row=title_row, needle=b"MASC Models"
    )
    # A screen's own strip leads to the place its cycle key reaches: Work's
    # stops are surfaces of their own, which [v] walks.
    press_label_on_screen(
        process, master_fd, output, b"Work", row=1, needle=b"MASC Work"
    )
    title_row = screen_row_of(screen_rows(bytes(output)), b"Task Review")
    if title_row < 0:
        raise AssertionError(
            f"the Work strip is not on screen: {screen_text(bytes(output))!r}"
        )
    press_label_on_screen(
        process,
        master_fd,
        output,
        b"Task Review",
        row=title_row,
        needle=b"\xe2\x96\xb8Task Review",
    )
    os.write(master_fd, b"q")


def pressing_a_row_chooses_then_opens_it(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    """A press on a Keepers row chooses that Keeper; a press on the chosen
    row opens it, as Enter does. The row is named by the Keeper, so the
    press lands on the name the reader pointed at."""
    wait_for_output(process, master_fd, output, b"Awaiting you", start=0, timeout=3.0)
    send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
    # The fleet and live-roster reads add rows above the list independently.
    # Wait for both fixture results before capturing a pointer coordinate;
    # otherwise the second press can land on the row above the first one.
    wait_for_output(process, master_fd, output, b"fleet ok", start=0, timeout=3.0)
    wait_for_output(
        process, master_fd, output,
        b"live keeper status unavailable: fixture endpoint unavailable",
        start=0, timeout=3.0,
    )
    select_keeper_row(process, master_fd, output, b"alpha")
    beta_row = screen_row_of(screen_rows(bytes(output)), b"beta")
    if beta_row < 0:
        raise AssertionError(
            f"beta is not on the Keepers list: {screen_text(bytes(output))!r}"
        )
    press_label_on_screen(
        process, master_fd, output, b"beta", row=beta_row,
        needle=keeper_row_selected(b"beta"),
    )
    press_label_on_screen(
        process, master_fd, output, b"beta", row=beta_row,
        needle=b"Keepers \xe2\x96\xb8 \x1b[1mbeta",
    )
    os.write(master_fd, b"q")


# More Keepers than the list has rows, so the list scrolls.
LONG_ROSTER_CREW = tuple("crew-%02d" % index for index in range(40))


def seed_long_roster(base_path: str) -> None:
    keepers_path = Path(base_path) / ".masc" / "keepers"
    for name in LONG_ROSTER_CREW:
        (keepers_path / f"{name}.json").write_text(
            json.dumps(keeper_metadata(name)), encoding="utf-8"
        )


def pressing_a_row_of_a_scrolled_list_opens_it(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    """The second press lands on the Keeper the first one chose.

    The window was worked out from the cursor alone, which held the cursor on
    the bottom row once the list had scrolled. Choosing the top row moved the
    window, so the second press at the same place named another Keeper."""
    wait_for_output(process, master_fd, output, b"Awaiting you", start=0, timeout=3.0)
    send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
    # The fleet and live-roster reads add rows above the list independently.
    # Wait for both fixture results before capturing a pointer coordinate;
    # otherwise the second press can land on the row above the first one.
    wait_for_output(process, master_fd, output, b"fleet ok", start=0, timeout=3.0)
    wait_for_output(
        process, master_fd, output,
        b"live keeper status unavailable: fixture endpoint unavailable",
        start=0, timeout=3.0,
    )
    select_keeper_row(process, master_fd, output, b"alpha")
    last = LONG_ROSTER_CREW[-1].encode()
    notches = b"\x1b[<65;5;5M" * (len(LONG_ROSTER_CREW) + 2)
    send_and_wait(process, master_fd, output, notches, keeper_row_selected(last))
    drain_until_quiet(process, master_fd, output)
    rows = screen_rows(bytes(output))
    crew_rows = [
        (number, match.group(0))
        for number, text in sorted(rows.items())
        for match in [re.search(rb"crew-\d\d", text)]
        if match is not None
    ]
    if len(crew_rows) < 2 or crew_rows[-1][1] != last:
        raise AssertionError(
            f"the list did not scroll to its end: {screen_text(bytes(output))!r}"
        )
    top_row, top_name = crew_rows[0]
    press_label_on_screen(
        process, master_fd, output, top_name, row=top_row,
        needle=keeper_row_selected(top_name),
    )
    press_label_on_screen(
        process, master_fd, output, top_name, row=top_row,
        needle=b"Keepers \xe2\x96\xb8 \x1b[1m" + top_name,
    )
    os.write(master_fd, b"q")


def wheel_scrolls_and_clicks_do_not(
    process: subprocess.Popen[bytes],
    master_fd: int,
    slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    # The enable sequence must be out before any wheel can arrive: without it
    # the terminal keeps the wheel for its own scrollback and the TUI never
    # sees the report at all.
    wait_for_output(
        process, master_fd, output, b"\x1b[?1006;1000h", start=0, timeout=3.0
    )
    wait_for_output(process, master_fd, output, b"Awaiting you", start=0, timeout=3.0)
    send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
    # The header is drawn before the asynchronous roster; a wheel report on a
    # list that has not arrived moves nothing. Start from alpha's row, which
    # presses nothing when alpha is already selected.
    select_keeper_row(process, master_fd, output, b"alpha")
    # An SGR wheel report moves the cursor exactly as the arrow key does.
    send_and_wait(
        process,
        master_fd,
        output,
        b"\x1b[<65;5;5M",
        keeper_row_selected(b"beta"),
    )
    send_and_wait(
        process,
        master_fd,
        output,
        b"\x1b[<64;5;5M",
        keeper_row_selected(b"alpha"),
    )
    # Click press and release must not leak into a key: after both, the next
    # wheel-down still starts from alpha and lands on beta. The click goes to
    # the title, which names no place to go; a press on a row is the row's.
    read_available(master_fd, output)
    title_row = screen_row_of(screen_rows(bytes(output)), b"MASC Keepers")
    if title_row < 0:
        raise AssertionError(
            f"the Keepers title is not on screen: {screen_text(bytes(output))!r}"
        )
    os.write(master_fd, b"\x1b[<0;3;%dM" % title_row)
    os.write(master_fd, b"\x1b[<0;3;%dm" % title_row)
    time.sleep(0.3)
    send_and_wait(
        process,
        master_fd,
        output,
        b"\x1b[<65;5;5M",
        keeper_row_selected(b"beta"),
    )
    send_and_wait(process, master_fd, output, b"iq2Q", b"to beta q2Q")

    resize_and_wait(
        process,
        master_fd,
        output,
        rows=8,
        columns=100,
        needle=b"terminal too small",
        controls=(b"\x1b[2J",),
        final_cursor=b"\x1b[?25l",
    )
    os.write(master_fd, b"\x1b[200~hidden compact paste\x1b[201~")
    os.write(master_fd, b"x\r")
    wait_for_terminal_input_consumed(slave_fd)
    resize_and_wait(
        process,
        master_fd,
        output,
        rows=8,
        columns=99,
        needle=b"terminal too small",
        controls=(b"\x1b[2J",),
        final_cursor=b"\x1b[?25l",
    )
    restored_message_patch = resize_and_wait(
        process,
        master_fd,
        output,
        rows=30,
        columns=100,
        needle=b"to beta q2Q",
        controls=(b"\x1b[2J",),
        final_cursor=b"\x1b[?25h",
    )
    if (
        b"hidden compact paste" in restored_message_patch
        or b"q2Qx" in restored_message_patch
        or b"(sending " in restored_message_patch
    ):
        raise AssertionError(
            "compact viewport accepted hidden message input: "
            f"{restored_message_patch!r}"
        )

    # Esc leaves insert mode: the draft stays on the composer row and the
    # keys belong to the roster again. Enter then opens the selected keeper
    # -- beta, where the wheel left the cursor.
    os.write(master_fd, b"\x1b")
    wait_for_terminal_input_consumed(slave_fd)
    drain_until_quiet(process, master_fd, output)
    send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1mbeta")

    # The tab the detail screen opened on says so in the text, not only in
    # bold and underline. A capture like this one is where style-only
    # marking goes missing -- the bytes name the tab, or nothing does. And
    # Info's own body opens with a section called "Identity", which is
    # another tab's name, so a reader with no mark has a wrong guess ready.
    if b"\xe2\x96\xb8Info" not in output:
        raise AssertionError(
            "the keeper detail screen did not mark the tab it opened on"
        )

    # Wait until the process is back inside its input read, then resize and
    # send one surface shortcut without waiting for the compact frame. The
    # SIGWINCH lands after the loop's first resize poll; input must consume
    # that pending resize before it can act on the old normal frame.
    drain_until_quiet(process, master_fd, output)
    os.killpg(process.pid, signal.SIGSTOP)
    wait_for_stop(
        process,
        master_fd,
        output,
        timeout=2.0,
        description="compact resize/input race control point",
    )
    read_available(master_fd, output)
    compact_race_start = len(output)
    fcntl.ioctl(
        master_fd,
        termios.TIOCSWINSZ,
        struct.pack("HHHH", 14, 100, 0, 0),
    )
    os.write(master_fd, b"3")
    os.killpg(process.pid, signal.SIGCONT)
    wait_for_terminal_input_consumed(slave_fd)
    wait_for_output(
        process,
        master_fd,
        output,
        b"terminal too small",
        start=compact_race_start,
        timeout=3.0,
    )
    resize_and_wait(
        process,
        master_fd,
        output,
        rows=30,
        columns=100,
        needle=b"Keepers \xe2\x96\xb8 \x1b[1mbeta",
        controls=(b"\x1b[2J",),
        final_cursor=b"\x1b[?25l",
    )

    resize_and_wait(
        process,
        master_fd,
        output,
        # The agenda strip takes one of these fourteen rows. The renderer
        # therefore shows a thirteen-row compact frame; the input gate must
        # measure the same body rather than route this hidden `3`.
        rows=14,
        columns=100,
        needle=b"terminal too small",
        controls=(b"\x1b[2J",),
        final_cursor=b"\x1b[?25l",
    )
    os.write(master_fd, b"3")
    wait_for_terminal_input_consumed(slave_fd)
    resize_and_wait(
        process,
        master_fd,
        output,
        rows=30,
        columns=100,
        needle=b"Keepers \xe2\x96\xb8 \x1b[1mbeta",
        controls=(b"\x1b[2J",),
        final_cursor=b"\x1b[?25l",
    )

    send_and_wait(process, master_fd, output, b"l", b"Keepers \xe2\x96\xb8 beta \xe2\x96\xb8 logs")
    resize_and_wait(
        process,
        master_fd,
        output,
        rows=8,
        columns=100,
        needle=b"terminal too small",
        controls=(b"\x1b[2J",),
        final_cursor=b"\x1b[?25l",
    )
    resize_and_wait(
        process,
        master_fd,
        output,
        rows=30,
        columns=100,
        needle=b"Keepers \xe2\x96\xb8 beta \xe2\x96\xb8 logs",
        controls=(b"\x1b[2J",),
        final_cursor=b"\x1b[?25l",
    )
    send_and_wait(
        process,
        master_fd,
        output,
        b"\x1b[D",
        b"Keepers \xe2\x96\xb8 \x1b[1mbeta",
    )
    send_and_wait(process, master_fd, output, b"\x1b[D", b"MASC Keepers")
    send_and_wait(
        process,
        master_fd,
        output,
        b"\x1b[A",
        keeper_row_selected(b"alpha"),
    )
    resize_and_wait(
        process,
        master_fd,
        output,
        rows=8,
        columns=100,
        needle=b"terminal too small",
        controls=(b"\x1b[2J",),
        final_cursor=b"\x1b[?25l",
    )
    os.write(master_fd, b"\x1b[B")
    wait_for_terminal_input_consumed(slave_fd)
    resize_and_wait(
        process,
        master_fd,
        output,
        rows=30,
        columns=100,
        needle=keeper_row_selected(b"alpha"),
        controls=(b"\x1b[2J",),
        final_cursor=b"\x1b[?25l",
    )
    # An armed search prefixes the footer with its query at the one seam
    # every surface shares (footer_line). What follows it is the surface's
    # own hint text -- Keepers spells its first hint "j/k move", and at 100
    # columns the strip is elided anyway. The prefix is what says the
    # search is armed. An empty query draws the input cursor after the slash
    # (#35410), so the armed prefix is "/" followed by that block.
    send_and_wait(process, master_fd, output, b"/", b"/\xe2\x96\x8c  ")
    resize_and_wait(
        process,
        master_fd,
        output,
        rows=8,
        columns=100,
        needle=b"terminal too small",
        controls=(b"\x1b[2J",),
        final_cursor=b"\x1b[?25l",
    )
    # The fallback says q quits. A hidden search prompt must not reclaim it.
    os.write(master_fd, b"q")
    wait_for_terminal_input_consumed(slave_fd)


def compact_input_gate_http_fixtures() -> HttpFixtures:
    fixtures = overview_event_http_fixtures()
    fixtures["/api/v1/keepers/tool-approvals"] = (
        200,
        {
            "pending": [
                {
                    "keeper": "alpha",
                    "tool_call_id": "tool-awaiting-compact-gate",
                    "tool": "Execute",
                    "args": "{}",
                    "question": "Run the compact-gate probe?",
                    "because": None,
                    "asked_at": 1787766400.0,
                    "timeout_sec": 300.0,
                }
            ]
        },
    )
    return fixtures


def keeper_detail_overscroll_interaction(
    fixtures: HttpFixtures,
    refresh_gate: GatedHttpResponse,
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
            wait_for_output(
                process, master_fd, output, b"Health: ", start=0, timeout=10.0
            )
            cluster_end = output.find(b"Health: ") + len(b"Health: ")
            wait_for_output(
                process,
                master_fd,
                output,
                FRAME_END,
                start=cluster_end,
                timeout=3.0,
            )
            send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
            # Confirm which row Enter will open rather than assuming the list
            # opens on its first entry. The roster order is a property of the
            # fixture and of whatever the live read returned, so pressing
            # Enter blind waits for a detail header that may never come.
            select_keeper_row(process, master_fd, output, b"alpha")
            send_and_wait(
                process,
                master_fd,
                output,
                b"\r",
                b"Keepers \xe2\x96\xb8 \x1b[1malpha",
            )
            detail = resize_and_wait(
                process,
                master_fd,
                output,
                rows=16,
                columns=100,
                needle=b"Keepers \xe2\x96\xb8 \x1b[1malpha",
                controls=(FULL_REDRAW,),
                final_cursor=b"\x1b[?25l",
            )
            # The indicator is the window the pane drew, "first-last/count"
            # (Masc_tui_scroll.window_text). Opened at the top, its first row
            # is 1 and its height is the rows the pane shows; the scroll
            # positions are the rows past that height, plus the top.
            indicators = WINDOW_TEXT_RE.findall(CSI_RE.sub(b"", detail))
            if not indicators:
                raise AssertionError(
                    f"Keeper detail did not expose a scroll indicator: {detail!r}"
                )
            first, last, total = (int(value) for value in indicators[-1])
            if first != 1:
                raise AssertionError(
                    f"Keeper detail did not open at its first row: {detail!r}"
                )
            height = last - first + 1
            position_count = total - height + 1
            if position_count < 3:
                raise AssertionError(
                    f"Keeper detail fixture has too few scroll positions: {detail!r}"
                )

            def window(top: int) -> bytes:
                return f"{top}-{top + height - 1}/{total}".encode()

            bottom = window(position_count)
            send_and_wait(
                process,
                master_fd,
                output,
                b"j" * (position_count - 1),
                bottom,
            )

            fixtures["/api/v1/dashboard/briefing"] = refresh_gate
            read_available(master_fd, output)
            os.write(master_fd, b"jr")
            if not wait_for_fixture_event(
                process, master_fd, output, refresh_gate.requested, timeout=10.0
            ):
                raise AssertionError(
                    "Keeper detail overscroll refresh did not reach its fixture"
                )
            resize_and_wait(
                process,
                master_fd,
                output,
                rows=16,
                columns=99,
                needle=bottom,
                controls=(FULL_REDRAW,),
                final_cursor=b"\x1b[?25l",
            )
            refresh_gate.release.set()

            previous = window(position_count - 1)
            send_and_wait(process, master_fd, output, b"k", previous)
            send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
            send_and_wait(
                process,
                master_fd,
                output,
                b"j",
                keeper_row_selected(b"beta"),
            )
            beta = send_and_wait(
                process,
                master_fd,
                output,
                b"\r",
                b"Keepers \xe2\x96\xb8 \x1b[1mbeta",
            )
            top = window(1)
            if top not in beta:
                raise AssertionError(
                    f"new Keeper detail did not reset to the top: {beta!r}"
                )
            os.write(master_fd, b"q")
            completed = True
        finally:
            refresh_gate.release.set()
            if not completed and process.poll() is None:
                kill_process_group(process)

    return interact


def keeper_selection_identity_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    base_path: str,
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
    send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
    # j on a roster that has not arrived moves nothing and redraws
    # nothing, so the wait for beta's band times out. Ask for the row.
    select_keeper_row(process, master_fd, output, b"beta")
    send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1mbeta")

    keepers_path = Path(base_path) / ".masc" / "keepers"
    beta_metadata = keeper_metadata("beta")
    # A value only a fresh read can draw, so pressing r below is observable.
    # This used to ride on the keeper's generation counter, which the schema
    # no longer has. The current task id is drawn under Current Work in the
    # detail's Info tab.
    beta_metadata["current_task_id"] = "task-29453"
    (keepers_path / "beta.json").write_text(json.dumps(beta_metadata), encoding="utf-8")
    (keepers_path / "aardvark.json").write_text(
        json.dumps(keeper_metadata("aardvark")), encoding="utf-8"
    )
    read_available(master_fd, output)
    refresh_start = len(output)
    os.write(master_fd, b"r")
    wait_for_output(
        process, master_fd, output, FRAME_END, start=refresh_start, timeout=3.0
    )
    drain_until_quiet(process, master_fd, output)
    # Since the portrait opens Info (#39750), Current Work sits below the
    # first screen at the harness height, so the detail is walked down to it.
    # Each j is judged once its frames stop arriving, as tab_until does. The
    # value was written before r, so it appears only if r read it again.
    for _ in range(KEEPER_DETAIL_SCROLL_BOUND):
        if find_needle(output, b"29453", refresh_start) >= 0:
            break
        read_available(master_fd, output)
        step_start = len(output)
        os.write(master_fd, b"j")
        wait_for_output(
            process, master_fd, output, FRAME_END, start=step_start, timeout=3.0
        )
        drain_until_quiet(process, master_fd, output)
    else:
        raise AssertionError(
            "r did not draw the refreshed current task within "
            f"{KEEPER_DETAIL_SCROLL_BOUND} lines of the detail: "
            f"{bytes(output[refresh_start:])[-4000:]!r}"
        )
    send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 beta \xe2\x96\xb8 chat")
    escape_to_keeper_detail(process, master_fd, output, name=b"beta")

    (keepers_path / "beta.json").write_text("{", encoding="utf-8")
    read_available(master_fd, output)
    error_start = len(output)
    os.write(master_fd, b"r")
    wait_for_output(
        process,
        master_fd,
        output,
        CONSOLE_DIAGNOSTIC,
        start=error_start,
        timeout=3.0,
    )
    unreliable = resize_and_wait(
        process,
        master_fd,
        output,
        rows=30,
        columns=99,
        needle=b"Keepers \xe2\x96\xb8 \x1b[1mbeta",
        controls=(FULL_REDRAW,),
        final_cursor=b"\x1b[?25l",
    )
    if b"Keepers \xe2\x96\xb8 \x1b[1malpha" in unreliable:
        raise AssertionError(
            f"unreliable Keeper snapshot retargeted beta detail: {unreliable!r}"
        )
    stale_gate = send_and_wait(
        process,
        master_fd,
        output,
        b"ml",
        b"Keepers \xe2\x96\xb8 beta \xe2\x96\xb8 logs",
    )
    if b"Keepers \xe2\x96\xb8 beta \xe2\x96\xb8 chat" in CSI_RE.sub(b"", stale_gate):
        raise AssertionError(
            f"unreliable Keeper snapshot opened message mode: {stale_gate!r}"
        )
    escape_to_keeper_detail(process, master_fd, output, name=b"beta")
    alpha_metadata = keeper_metadata("alpha")
    alpha_metadata["current_task_id"] = "task-29454"
    (keepers_path / "alpha.json").write_text(
        json.dumps(alpha_metadata), encoding="utf-8"
    )
    (keepers_path / "aardvark.json").unlink()
    (keepers_path / "beta.json").unlink()
    missing = send_and_wait(process, master_fd, output, b"r", b"29454")
    missing_plain = CSI_RE.sub(b"", missing)
    failures = []
    if find_needle(missing_plain, screen_header(b"MASC Keepers", b" (1)")) < 0:
        failures.append("missing beta detail did not return to MASC Keepers (1)")
    if b"Keepers \xe2\x96\xb8 alpha" in missing_plain:
        failures.append("missing beta detail silently retargeted to alpha")

    after_selection = send_and_wait(
        process,
        master_fd,
        output,
        b"\r",
        b"Keepers \xe2\x96\xb8 \x1b[1malpha",
    )
    after_selection_plain = CSI_RE.sub(b"", after_selection)
    if b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat" in after_selection_plain:
        failures.append("m opened Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat after beta disappeared")
    if failures:
        raise AssertionError("; ".join(failures))
    os.write(master_fd, b"q")


KEEPER_LANES_PATH = "/api/v1/keepers/composite"
STANDALONE_LANES_PATH = "/api/v1/dashboard/standalone-lanes"


def standalone_lane_fixture(
    lane_id: str, label: str, *, status: str = "idle", retained: int = 12
) -> dict[str, object]:
    """One row of the observation matrix, in the wire shape the strict
    decoder accepts: every known lane exactly once, observation_only set."""
    lane_contracts = {
        "board_attention_exact": (
            "Judges one durable Board candidate for Keeper attention.",
            True,
        ),
        "hitl_auto_judge": (
            "Produces the structured judgment for one held approval.",
            True,
        ),
        "librarian_exact": (
            "Selects the next Memory OS snapshot from immutable Keeper history.",
            False,
        ),
        "workspace_curator_exact": (
            "Synthesizes attributed proposals after committed workspace memory "
            "changes; semantic verification is not performed.",
            False,
        ),
        "candle_appraiser": (
            "Appraises a confirmed Goal payout grade, each candidate Task's relation to the Goal, and Keeper contribution weights.",
            False,
        ),
        "verifier_exact": (
            "Reviews Task completion and Goal proof evidence.",
            False,
        ),
        "browser_stagehand_exact": (
            "Answers structured model requests from the Stagehand browser lane; "
            "run records are not retained yet.",
            False,
        ),
    }
    purpose, required = lane_contracts[lane_id]
    row = {
        "lane_id": lane_id,
        "label": label,
        "purpose": purpose,
        "required": required,
        "observation_only": True,
        "configured": True,
        "configuration_state": "ready",
        "declared_slots": ["glm-coding.glm-5-turbo"],
        "declared_cli_slots": [],
        "admitted_slots": ["glm-coding.glm-5-turbo"],
        # The projection writes both declared lists and their admission
        # readings. Omitting any list fails the row decode, and the
        # whole snapshot with it, so the observation matrix simply never
        # draws -- the surface has no per-row gap to show.
        "cli_slots": [],
        "dropped_slots": [],
        "admission_error": None,
        "status": status,
        "retained_run_count": retained,
        "running_count": 0,
        "succeeded_count": retained,
        "failed_count": 0,
        "cancelled_count": 0,
        "last_started_at": 1787557600.0 if retained else None,
        "last_terminal_at": 1787557660.0 if retained else None,
        "last_outcome": "succeeded" if retained else None,
        "p50_elapsed_s": 8.0 if retained else None,
        "selected_slots": (
            [{"slot_id": "glm-coding.glm-5-turbo", "count": retained}]
            if retained
            else []
        ),
        "runs_without_slot": {"vendor_system_one": 0, "server_restarted": 0, "no_slot": 0},
    }
    if lane_id == "board_attention_exact":
        row["jev"] = {"state": "off"}
    return row


def standalone_lanes_response() -> HttpResponse:
    return (
        200,
        {
            "schema": "masc.standalone_llm_lanes.v2",
            "generated_at": "2026-08-27T20:36:29Z",
            "observed_at_unix": 1787557669.715736,
            "exact_run_projection_count": 60,
            "exact_run_source_total": 60,
            "exact_run_projection_truncated": False,
            "observation_only": True,
            "lanes": [
                standalone_lane_fixture(
                    "board_attention_exact", "Board Attention", status="running"
                ),
                standalone_lane_fixture("hitl_auto_judge", "HITL Auto Judge"),
                standalone_lane_fixture("librarian_exact", "Librarian"),
                # The decoder takes the registry's lane list as the wire contract
                # and refuses a snapshot missing one (#35688 added this lane), so
                # the fixture lists it where the server projection does.
                standalone_lane_fixture(
                    "workspace_curator_exact", "Workspace Curator"
                ),
                standalone_lane_fixture("verifier_exact", "Verifier"),
                standalone_lane_fixture(
                    "browser_stagehand_exact", "Browser Stagehand",
                    status="no_retained_observation", retained=0,
                ),
                standalone_lane_fixture("candle_appraiser", "Candle Appraiser"),
            ],
        },
    )


def lane_runs_path(lane_id: str) -> str:
    return f"/api/v1/dashboard/exact-lane-runs?limit=50&lane={lane_id}"


def verifier_lane_runs_response() -> HttpResponse:
    return (
        200,
        {
            "runs": [
                {
                    "run_id": "vrf-fixture",
                    "run_kind": "task_verification",
                    "lane": "verifier_exact",
                    "subject_id": "task-9",
                    "actor": "verifier_exact",
                    "started_at": 1787557000.0,
                    "status": "rejected",
                    "elapsed_s": 3.0,
                    "selected_slot": "verifier-primary",
                }
            ],
            "has_more": False,
        },
    )


def standalone_lane_runtime_config_response() -> HttpResponse:
    return (
        200,
        {
            **runtime_config_read_metadata(),
            "path": "/workspace/config/runtime.toml",
            "source_text": "\n".join(
                [
                    "[runtime.exact_output_lanes.board_attention_exact]",
                    'slots = ["glm-coding.glm-5-turbo"]',
                    "",
                    "[runtime.exact_output_lanes.hitl_auto_judge]",
                    'slots = ["glm-coding.glm-5-turbo"]',
                    "",
                    "[runtime.exact_output_lanes.librarian_exact]",
                    'slots = ["glm-coding.glm-5-turbo"]',
                    "",
                    "[runtime.exact_output_lanes.verifier_exact]",
                    'slots = ["glm-coding.glm-5-turbo"]',
                ]
            ),
        },
    )


def verifier_lane_run_detail_response() -> HttpResponse:
    return (
        200,
        {
            "run": {
                "run_id": "vrf-fixture",
                "run_kind": "task_verification",
                "lane": "verifier_exact",
                "subject_id": "task-9",
                "actor": "verifier_exact",
                "started_at": 1787557000.0,
                "status": "rejected",
                "elapsed_s": 3.0,
                "selected_slot": "verifier-primary",
                "skill_evidence": {"state": "no_keeper_skills"},
                "payload_availability": {
                    "input": {"state": "available"},
                    "output": {"state": "available"},
                },
                "input": {
                    "kind": "exact",
                    "payload": {
                        "kind": "task_verification",
                        "task_id": "task-9",
                        "producer": "alpha",
                        "evidence": [
                            f"request-evidence-{index:02d}" for index in range(24)
                        ],
                    },
                },
                "output": {
                    "reason": "missing proof",
                    "checks": [f"verifier-check-{index:02d}" for index in range(24)],
                    "tools": [
                        {
                            "tool_name": "masc_task_get",
                            "input": {"task_id": "task-9"},
                            "disposition": "completed",
                            "output_excerpt": "awaiting verification",
                            "output_truncated": False,
                            "duration_ms": 12.0,
                        },
                        {
                            "tool_name": "tool_read_file",
                            "input": {"file_path": "proof.json"},
                            "disposition": "failed",
                            "output_excerpt": "proof missing",
                            "output_truncated": False,
                            "duration_ms": 7.0,
                        }
                    ],
                },
            }
        },
    )


def hitl_lane_runs_response() -> HttpResponse:
    return (
        200,
        {
            "runs": [
                {
                    "run_id": "hitl-fixture",
                    "run_kind": "exact_output",
                    "lane": "hitl_auto_judge",
                    "actor": "auto_judge",
                    "started_at": 1787557000.0,
                    "status": "succeeded",
                    "elapsed_s": 2.0,
                    "selected_slot": "judge-primary",
                }
            ],
            "has_more": False,
        },
    )


def hitl_lane_run_detail_response() -> HttpResponse:
    return (
        200,
        {
            "run": {
                "run_id": "hitl-fixture",
                "run_kind": "exact_output",
                "lane": "hitl_auto_judge",
                "actor": "auto_judge",
                "started_at": 1787557000.0,
                "status": "succeeded",
                "elapsed_s": 2.0,
                "selected_slot": "judge-primary",
                "skill_evidence": {"state": "no_keeper_skills"},
                "payload_availability": {
                    "input": {"state": "available"},
                    "output": {"state": "available"},
                },
                "input": {
                    "kind": "exact",
                    "payload": {"tool_name": "network_read"},
                },
                "output": {
                    "summary_version": 2,
                    "judgment": "approve",
                    "rationale": "the requested read is bounded",
                },
            }
        },
    )


def assert_verifier_tool_color_summary(frame: bytes) -> None:
    """The executed PTY path must preserve typed severity and per-call color."""
    plain = CSI_RE.sub(b"", frame)
    expected = (
        b"TOOLS  \xe2\x9c\x97 FAILED 1   \xe2\x9c\x93 COMPLETED 1   "
        b"\xe2\x94\x80\xe2\x94\x80  2 CALLS  \xe2\x94\x82  "
        b"\xe2\x9c\x93 masc_task_get \xe2\x80\xb9completed \xc2\xb7 12ms\xe2\x80\xba  "
        b"\xe2\x94\x82  \xe2\x9c\x97 tool_read_file "
        b"\xe2\x80\xb9failed \xc2\xb7 7ms\xe2\x80\xba"
    )
    if expected not in plain:
        raise AssertionError(
            f"Verifier detail omitted its typed Tool rollup/calls: {frame!r}"
        )
    if b"\x1b[1mTOOLS\x1b[0m \x1b[91m\x1b[7m\x1b[1m" not in frame:
        raise AssertionError(
            "Verifier detail did not put the worst severity immediately after "
            f"the emphasized Tool label as an ANSI badge: {frame!r}"
        )
    for style, mark, count, status, tool in (
        (b"\x1b[91m", b"\xe2\x9c\x97", b"1", b"failed", b"tool_read_file"),
        (b"\x1b[92m", b"\xe2\x9c\x93", b"1", b"completed", b"masc_task_get"),
    ):
        rollup = (
            style
            + b"\x1b[7m\x1b[1m "
            + mark
            + b" "
            + status.upper()
            + b" "
            + count
            + b" "
        )
        detail = style + b"\x1b[1m" + mark + b" " + tool
        if rollup not in frame or detail not in frame:
            raise AssertionError(
                f"Verifier detail did not map {status!r} to its semantic "
                f"color/glyph for {tool!r}: {frame!r}"
            )


def keeper_lanes_response(lanes: list[dict[str, object]]) -> HttpResponse:
    return (
        200,
        {
            "generated_at": 1787557669.715736,
            "count": len(lanes),
            "snapshots": lanes,
        },
    )


def keeper_lane_row(
    keeper: str,
    *,
    phase: str,
    turn_phase: str,
    idle_seconds: int,
    runtime_state: str | None,
    selected_model: str | None,
    turn_healthy: bool = True,
) -> dict[str, object]:
    last_outcome: object = None
    if runtime_state is not None:
        last_outcome = {
            "runtime_state": runtime_state,
            "selected_model": selected_model,
        }
    return {
        "keeper": keeper,
        "phase": phase,
        "turn_phase": turn_phase,
        "idle_seconds": idle_seconds,
        "last_outcome": last_outcome,
        "phase_diagnosis": {
            "conditions": {
                "launch_pending": False,
                "heartbeat_healthy": True,
                "turn_healthy": turn_healthy,
            }
        },
    }


def keeper_lanes_ia_interaction(
    gate: GatedHttpResponse, fixtures: HttpFixtures
) -> Interaction:
    """Keeper composite facts live on Keepers; Lanes is Standalone-only."""

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        tab_until(process, master_fd, output, b"MASC Keepers")
        # tab_until returns as soon as the title is on screen, and the roster is
        # a live read that lands after that. Pressing j on the (0) list moves
        # nothing and redraws nothing, so waiting for beta's band times out.
        # select_keeper_row waits for the row to exist and is indifferent to how
        # many frames the surface drew getting there.
        select_keeper_row(process, master_fd, output, b"beta")
        if not wait_for_fixture_event(
            process, master_fd, output, gate.requested, timeout=10.0
        ):
            raise AssertionError("Keepers did not request the composite snapshot")
        keepers = release_and_wait_for_frame(
            process, master_fd, output, gate, b"OPERATIONS"
        )
        keepers_plain = CSI_RE.sub(b"", keepers).decode("utf-8")
        for needle in (
            "OPERATIONS",
            "lifecycle failing (last turn failed)",
            "turn executing",
            "idle 59m",
            "last done",
        ):
            if needle not in keepers_plain:
                raise AssertionError(
                    f"Keepers did not draw composite fact {needle!r}: "
                    f"{keepers_plain!r}"
                )

        palette_go(process, master_fd, output, b"go lanes", b"MASC Lanes")
        resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=220,
            needle="Lanes · observed ".encode(),
            controls=(FULL_REDRAW,),
        )
        # The resize clears the screen and repaints the lane list -- ten rows
        # -- and the selected lane's detail arrives in a later frame. So the
        # frame that carries the list carries none of the detail below it,
        # and the reading waits for the frames to stop before asking the
        # screen.
        drain_until_quiet(process, master_fd, output)
        lanes_plain = screen_text(bytes(output)).decode("utf-8")
        if "MASC Lanes" not in lanes_plain:
            raise AssertionError(
                f"Lanes did not name the standalone scope: {lanes_plain!r}"
            )
        for duplicate in ("TURN STEP", "LAST OUTCOME", "DIAGNOSIS"):
            if duplicate in lanes_plain:
                raise AssertionError(
                    f"Lanes still repeated Keeper column {duplicate!r}: "
                    f"{lanes_plain!r}"
                )
        for detail in (
            "Judges one durable Board candidate for Keeper attention.",
            "Config: [runtime.exact_output_lanes.board_attention_exact]",
            "JEV OFF",
            "Catalog attempts (admitted order): 1 glm-coding.glm-5-turbo",
            "Then CLI (after catalog exhaustion): (none)",
            "Output meaning: the accepted candidate judgment JSON.",
            "Evidence: structured-output generation, not a MASC tool loop;",
        ):
            if detail not in lanes_plain:
                raise AssertionError(
                    f"Lanes omitted selected-lane detail {detail!r}: "
                    f"{lanes_plain!r}"
                )

        # The list is a table under one header, not five rows each carrying
        # its own labels: the labels cost some forty cells a row, so beside
        # the roster pane every row was cut at "runs 12", and the name column
        # was a literal fifteen that "Workspace Curator" overran, pushing its
        # whole row two cells right of the others. The header's words and the
        # column each begins at are read in cells (one code point each here),
        # and the lane whose name overran must start its status, its counts
        # and its slots where the running lane and the header do.
        lane_rows = {
            row: text.decode("utf-8")
            for row, text in screen_rows(bytes(output)).items()
        }
        header_row = screen_row_of(
            screen_rows(bytes(output)), b"OK/FAIL/CANCEL"
        )
        if header_row < 0:
            raise AssertionError(f"Lanes drew no column header: {lanes_plain!r}")
        header = lane_rows[header_row]
        column_words = (
            "LANE", "STATUS", "ACTIVE", "RUNS", "OK/FAIL/CANCEL", "P50",
            "SLOTS", "OBSERVED",
        )
        word_columns = [header.find(word) for word in column_words]
        if word_columns != sorted(word_columns) or -1 in word_columns:
            raise AssertionError(
                f"Lanes header does not carry {column_words} in order: "
                f"{header!r}"
            )
        status_column = header.index("STATUS")
        counts_column = header.index("OK/FAIL/CANCEL")
        slots_column = header.index("SLOTS")
        for lane_name, status_word in (
            ("Board Attention", "running "),
            ("Workspace Curator", "idle "),
        ):
            row = lane_rows[
                screen_row_of(screen_rows(bytes(output)), lane_name.encode())
            ]
            for column, cell in (
                (status_column, status_word),
                (counts_column, "12/0/0 "),
                (slots_column, "glm-coding.glm-5-turbo "),
            ):
                if row.find(cell) != column:
                    raise AssertionError(
                        f"{lane_name} row puts {cell!r} at {row.find(cell)}, "
                        f"header column is {column}: {row!r}"
                    )
        for own_label in ("slots glm", "runs 12", "ok/fail/cancel"):
            if own_label in lanes_plain:
                raise AssertionError(
                    f"a lane row still carries its own label {own_label!r}: "
                    f"{lanes_plain!r}"
                )

        banded_hitl = re.compile(rb"\x1b\[7m[^\x1b\n]*HITL Auto Judge")
        banded_librarian = re.compile(rb"\x1b\[7m[^\x1b\n]*Librarian")
        banded_curator = re.compile(rb"\x1b\[7m[^\x1b\n]*Workspace Curator")
        banded_verifier = re.compile(rb"\x1b\[7m[^\x1b\n]*Verifier")
        banded_board = re.compile(rb"\x1b\[7m[^\x1b\n]*Board Attention")
        send_and_wait(process, master_fd, output, b"j", banded_hitl)
        send_and_wait(process, master_fd, output, b"j", banded_librarian)
        # The projection lists the workspace curator between Librarian and
        # Verifier (#35688), so the walk to Verifier passes its row.
        send_and_wait(process, master_fd, output, b"j", banded_curator)
        send_and_wait(process, master_fd, output, b"j", banded_verifier)
        verifier_runs = send_and_wait(
            process, master_fd, output, b"\r", b"task task-9"
        )
        if b"rejected" not in CSI_RE.sub(b"", verifier_runs):
            raise AssertionError(
                f"Verifier run list omitted its rejection: {verifier_runs!r}"
            )
        verifier_detail = send_and_wait(
            process,
            master_fd,
            output,
            b"\r",
            b"OUTPUT \xc2\xb7 VERDICT + TOOL EVIDENCE (2 CALLS)",
        )
        verifier_detail_plain = CSI_RE.sub(b"", verifier_detail)
        for evidence in (
            b"DECISION  REJECTED",
            b"SKILLS  none",
        ):
            if evidence not in verifier_detail_plain:
                raise AssertionError(
                    f"Verifier detail omitted {evidence!r}: {verifier_detail!r}"
                )
        assert_verifier_tool_color_summary(verifier_detail)
        narrow_detail = resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=28,
            needle=b"TOOLS",
            controls=(FULL_REDRAW,),
        )
        if (
            b"\x1b[1mTOOLS\x1b[0m \x1b[91m\x1b[7m\x1b[1m \xe2\x9c\x97"
            not in narrow_detail
        ):
            raise AssertionError(
                "Ultra-narrow Verifier detail clipped the worst Tool severity "
                f"before its badge: {narrow_detail!r}"
            )
        resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=220,
            needle=b"OUTPUT \xc2\xb7 VERDICT + TOOL EVIDENCE (2 CALLS)",
            controls=(FULL_REDRAW,),
        )
        send_and_wait(process, master_fd, output, b"\x1b", b"rejected")
        send_and_wait(process, master_fd, output, b"\x1b", banded_verifier)
        send_and_wait(process, master_fd, output, b"k", banded_curator)
        send_and_wait(process, master_fd, output, b"k", banded_librarian)
        send_and_wait(process, master_fd, output, b"k", banded_hitl)
        send_and_wait(process, master_fd, output, b"\r", b"succeeded")
        hitl_detail = send_and_wait(
            process,
            master_fd,
            output,
            b"\r",
            b"GATE RESOLUTION  NOT PROVEN BY THIS RUN",
        )
        hitl_detail_plain = CSI_RE.sub(b"", hitl_detail)
        for evidence in (
            b"DECISION  NOT A VERDICT",
            b"JUDGMENT  ADVISORY APPROVE",
            b"TOOLS  none",
            b"SKILLS  none",
        ):
            if evidence not in hitl_detail_plain:
                raise AssertionError(
                    f"HITL detail omitted {evidence!r}: {hitl_detail!r}"
                )
        compact_hitl_detail = resize_and_wait(
            process,
            master_fd,
            output,
            # 14 surface rows plus navigation; this fixture's agenda is silent
            # and the composer yields its row at this minimum size.
            rows=15,
            columns=220,
            needle=b"Left / Esc",
            controls=(FULL_REDRAW,),
        )
        if b"Left / Esc" not in CSI_RE.sub(b"", compact_hitl_detail):
            raise AssertionError(
                "Minimum-height HITL detail clipped its footer: "
                f"{compact_hitl_detail!r}"
            )
        compact_narrow_hitl_detail = resize_and_wait(
            process,
            master_fd,
            output,
            # 14 surface rows plus navigation; this fixture's agenda is silent
            # and the composer yields its row at this minimum size.
            rows=15,
            columns=100,
            needle=b"Left / Esc",
            controls=(FULL_REDRAW,),
        )
        if b"Left / Esc" not in CSI_RE.sub(b"", compact_narrow_hitl_detail):
            raise AssertionError(
                "Minimum-height narrow HITL detail clipped its footer: "
                f"{compact_narrow_hitl_detail!r}"
            )
        fixtures[
            "/api/v1/dashboard/exact-lane-runs/hitl-fixture"
        ] = (503, {"error": "stale hitl detail"})
        compact_narrow_refresh_error = send_and_wait(
            process,
            master_fd,
            output,
            b"r",
            b"lane run detail: HTTP 503",
        )
        compact_narrow_refresh_error_plain = CSI_RE.sub(
            b"", compact_narrow_refresh_error
        )
        stale_evidence = (
            b"lane run detail: HTTP 503",
            b"JUDGMENT  ADVISORY APPROVE",
            b"Left / Esc",
        )
        for evidence in stale_evidence:
            if evidence not in compact_narrow_refresh_error_plain:
                raise AssertionError(
                    "Minimum-height narrow stale HITL detail clipped evidence "
                    f"{evidence!r}: {compact_narrow_refresh_error!r}"
                )
        compact_wide_refresh_error = resize_and_wait(
            process,
            master_fd,
            output,
            # 14 surface rows plus navigation; this fixture's agenda is silent
            # and the composer yields its row at this minimum size.
            rows=15,
            columns=220,
            needle=b"Left / Esc",
            controls=(FULL_REDRAW,),
        )
        compact_wide_refresh_error_plain = CSI_RE.sub(
            b"", compact_wide_refresh_error
        )
        for evidence in stale_evidence:
            if evidence not in compact_wide_refresh_error_plain:
                raise AssertionError(
                    "Minimum-height wide stale HITL detail clipped evidence "
                    f"{evidence!r}: {compact_wide_refresh_error!r}"
                )
        resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=220,
            needle=b"GATE RESOLUTION  NOT PROVEN BY THIS RUN",
            controls=(FULL_REDRAW,),
        )
        send_and_wait(process, master_fd, output, b"\x1b", b"succeeded")
        send_and_wait(process, master_fd, output, b"\x1b", banded_hitl)
        send_and_wait(process, master_fd, output, b"k", banded_board)
        send_and_wait(
            process,
            master_fd,
            output,
            b"c",
            b"These lanes have no Keeper; use Keepers",
        )
        config = send_and_wait(
            process,
            master_fd,
            output,
            b"e",
            b"runtime.exact_output_lanes.board_attention_exact",
        )
        config_plain = CSI_RE.sub(b"", config).decode("utf-8")
        if 'slots = ["glm-coding.glm-5-turbo"]' not in config_plain:
            raise AssertionError(
                f"Lanes e did not land on the selected TOML table: {config_plain!r}"
            )
        os.write(master_fd, b"q")

    return interact


def keeper_gate_mode_footer_interaction(
    gate: GatedHttpResponse,
) -> Interaction:
    """The footer names the action `g` performs, so it must name only one.

    The approval-mode override arrives over HTTP, and until it does the Keeper
    is not known to be in YOLO, so the first footer legitimately offers
    `g:yolo`. Holding the response makes that first frame certain instead of
    timing-dependent: on a fast machine it was already gone by the time the
    assertion looked, and on CI it was not.
    """

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        tab_until(process, master_fd, output, b"MASC Keepers")
        before = resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=200,
            needle=re.compile(rb"g\x1b\[0m:yolo"),
            final_cursor=b"\x1b[?25l",
        )
        if not wait_for_fixture_event(
            process, master_fd, output, gate.requested, timeout=10.0
        ):
            raise AssertionError("the approval-mode override never reached its fixture")
        gate.release.set()
        footer = wait_for_output(
            process,
            master_fd,
            output,
            re.compile(rb"g\x1b\[0m:auto"),
            start=len(before),
            timeout=10.0,
        )
        del footer
        # Read the row, not the byte window. The window that carries the Auto
        # footer also carries the YOLO one drawn before the override landed, so
        # a substring check over it fails on a footer already replaced.
        # screen_rows keys by cursor address, so the later write to a row wins.
        drawn_rows = screen_rows(bytes(output))
        footer_row = screen_row_of(drawn_rows, b"g:auto")
        if footer_row < 0:
            raise AssertionError(
                f"no footer row offers Auto: {bytes(output[-2000:])!r}"
            )
        if b"g:yolo" in drawn_rows[footer_row]:
            raise AssertionError(
                "the footer offers Auto and YOLO on the same row: "
                f"{drawn_rows[footer_row]!r}"
            )
        # The Info row names the stance with the word the footer offers and
        # the chat header wears: alpha is in yolo, so the row says so, with
        # what that does beside it. It used to say "skipped" under a header
        # saying YOLO.
        select_keeper_row(process, master_fd, output, b"alpha")
        send_and_wait(process, master_fd, output, b"\r", b"\xe2\x96\xb8Info")
        drain_until_quiet(process, master_fd, output)
        rows = screen_rows(bytes(output[: output.rfind(FRAME_END) + len(FRAME_END)]))
        stance_row = rows.get(screen_row_of(rows, b"Tool calls:"), b"")
        if b"yolo \xc2\xb7 unasked" not in stance_row:
            raise AssertionError(
                f"the Info row does not name the stance as the footer does: {stance_row!r}"
            )
        os.write(master_fd, b"q")

    return interact

CONNECTORS_PATH = "/api/v1/gate/connectors"
CONNECTOR_NAMES_PATH = "/api/v1/gate/connector/names"
CONNECTOR_UNBIND_PATH = "/api/v1/gate/connector/unbind"


def connector_unbind_all_fixtures(
    requests: HttpRequests | None = None,
) -> HttpFixtures:
    """alpha holds two Discord channels, beta one; one of alpha's is rebound.

    The name directory knows 111 only, so the other channel has to say its
    name is unknown. The unbind answers 409 for 333 -- the server's reply when
    the channel now names another Keeper -- so the result has a skip in it.
    """
    fixtures = keeper_runtime_http_fixtures()

    def connectors() -> HttpResponse:
        # With [requests], a removed binding leaves the list once its unbind
        # was answered 200 -- the reading the post-unbind reload must show.
        removed = {
            json.loads(body)["channel_id"]
            for path, body in (requests or [])
            if path.startswith(CONNECTOR_UNBIND_PATH)
        } - {"333"}
        bindings = [
            {"channel_id": channel, "keeper_name": keeper}
            for channel, keeper in (("111", "alpha"), ("444", "beta"), ("333", "alpha"))
            if channel not in removed
        ]
        return (
            200,
            {
                "connectors": [
                    {
                        "connector_id": "discord",
                        "display_name": "Discord",
                        "status": "connected",
                        "available": True,
                        "connected": True,
                        "configured_bindings": bindings,
                    }
                ],
                "total": 1,
                "active_count": 1,
            },
        )

    fixtures[CONNECTORS_PATH] = connectors
    fixtures[CONNECTOR_NAMES_PATH] = (
        200,
        {
            "connector_id": "discord",
            "kind": "channel",
            "mapping_scope": "workspace",
            "path": "connector_names/discord/channel",
            "total": 1,
            "has_more": False,
            "mappings": [{"id": "111", "name": "general"}],
        },
    )

    def unbind(body: bytes) -> HttpResponse:
        channel = json.loads(body).get("channel_id")
        if channel == "333":
            return (409, {"error": "binding changed"})
        return (200, {"ok": True})

    fixtures[CONNECTOR_UNBIND_PATH] = RequestHttpResponse(unbind)
    return fixtures


def run_keeper_unbind_all_channels_regression(executable: str) -> None:
    """U twice on the Channels tab removes every binding of that Keeper.

    #38167: the tab removed one binding per two presses, so five channels
    took ten presses and five selections. The first U names what it will
    remove; the second sends one conditional unbind per binding and reports
    each answer. beta's binding is not sent at all.
    """
    requests: HttpRequests = []

    def interact(process: subprocess.Popen[bytes], master_fd: int,
                 _slave_fd: int, output: bytearray, _base_path: str) -> None:
        send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
        select_keeper_row(process, master_fd, output, b"alpha")
        send_and_wait(process, master_fd, output, b"\r", b"\xe2\x96\xb8Info")
        # [ from Info wraps to Runs; Channels is two further back.
        send_and_wait(process, master_fd, output, b"[", b"\xe2\x96\xb8Runs")
        send_and_wait(process, master_fd, output, b"[", b"\xe2\x96\xb8Automation")
        send_and_wait(process, master_fd, output, b"[", b"\xe2\x96\xb8Channels")
        wait_for_output(process, master_fd, output, b"333 (name unknown)",
                        start=0, timeout=5.0)
        drain_until_quiet(process, master_fd, output)
        listed = screen_text(bytes(output[: output.rfind(FRAME_END) + len(FRAME_END)]))
        if b"general (111)" not in listed:
            raise AssertionError(
                f"the binding list did not name channel 111: {listed!r}"
            )
        send_and_wait(process, master_fd, output, b"U",
                      b"unbind all armed: press U again")
        if any(path.startswith(CONNECTOR_UNBIND_PATH) for path, _ in requests):
            raise AssertionError(f"the first U sent an unbind: {requests!r}")
        send_and_wait(process, master_fd, output, b"U",
                      b"unbind all of alpha: 1 removed, 1 kept, 0 not found, 0 failed")
        sent = sorted(
            (json.loads(body)["channel_id"], json.loads(body)["keeper_name"])
            for path, body in requests
            if path.startswith(CONNECTOR_UNBIND_PATH)
        )
        if sent != [("111", "alpha"), ("333", "alpha")]:
            raise AssertionError(
                f"unbind all did not send exactly alpha's two bindings: {sent!r}"
            )
        # The pane reads the bindings again after the write: 111 is gone and
        # 333, kept by the 409, is still alpha's.
        wait_for_output(process, master_fd, output, b"1 here / 2 total",
                        start=0, timeout=5.0)
        os.write(master_fd, b"q")

    run_terminal_scenario(
        executable,
        description="U U on the Channels tab unbinds every binding of the Keeper",
        interact=interact,
        http_fixtures=connector_unbind_all_fixtures(requests),
        http_requests=requests,
    )


def run_keeper_info_requeue_key_regression(executable: str) -> None:
    """On the Info tab b reaches the Board requeue; Q still asks to quit.

    The requeue key was Q, but the global quit test takes Q as well as q and
    runs before the Info tab's arm, so Q armed the exit and the requeue was
    unreachable. b answers with the requeue's own reply -- here that the
    partitions are not read, since no fixture serves them -- and must not
    arm the exit. Q keeps quitting, so its notice still appears after.
    """

    def interact(process: subprocess.Popen[bytes], master_fd: int,
                 _slave_fd: int, output: bytearray, _base_path: str) -> None:
        send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
        select_keeper_row(process, master_fd, output, b"alpha")
        send_and_wait(process, master_fd, output, b"\r", b"\xe2\x96\xb8Info")
        drain_until_quiet(process, master_fd, output)
        mark = len(output)
        os.write(master_fd, b"b")
        wait_for_output(
            process,
            master_fd,
            output,
            re.compile(rb"nothing requeued|No blocked Board partition to requeue"),
            start=mark,
            timeout=5.0,
        )
        if b"press again to quit" in bytes(output[mark:]):
            raise AssertionError(
                f"b on the Info tab armed the exit: {bytes(output[mark:])[-600:]!r}"
            )
        if process.poll() is not None:
            raise AssertionError("b on the Info tab ended the TUI")
        send_and_wait(process, master_fd, output, b"Q", b"press again to quit")
        os.write(master_fd, b"q")

    run_terminal_scenario(
        executable,
        description="b on the Info tab requeues Board and Q still asks to quit",
        interact=interact,
        http_fixtures=keeper_runtime_http_fixtures(),
    )


def run_pause_offers_channel_unbind_regression(executable: str) -> None:
    """Pausing a Keeper that holds bindings offers to remove them, once.

    #38167: a paused Keeper still routes its Discord channels to itself and
    answers on them as soon as it runs again. After the pause is accepted the
    footer names the channels and the one key that removes them. y takes the
    offer; any other key leaves the bindings. U is not that key: on the list
    it opens the runtime picker, and "pause, then pick another runtime" must
    not remove the Keeper's channels.
    """

    def pause_alpha(process: subprocess.Popen[bytes], master_fd: int,
                    output: bytearray) -> None:
        send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
        select_keeper_row(process, master_fd, output, b"alpha")
        # The list can draw its durable row before the separate live roster
        # read permits lifecycle actions. Wait for the enabled key the operator
        # sees, so this exercises Pause rather than the unread fail-closed path.
        wait_for_output(process, master_fd, output,
                        b"\x1b[96mp\x1b[0m:pause", start=0, timeout=5.0)
        # Pause is not a two-press action; one p sends it.
        send_and_wait(process, master_fd, output, b"p",
                      b"y: also unbind alpha's 2 channels")

    def unbinds(requests: HttpRequests) -> list[tuple[str, str]]:
        return sorted(
            (json.loads(body)["channel_id"], json.loads(body)["keeper_name"])
            for path, body in requests
            if path.startswith(CONNECTOR_UNBIND_PATH)
        )

    def fixtures() -> HttpFixtures:
        served = connector_unbind_all_fixtures()
        served["/api/v1/keepers/alpha/directive"] = (200, {"ok": True})
        return served

    taken: HttpRequests = []

    def take_offer(process: subprocess.Popen[bytes], master_fd: int,
                   _slave_fd: int, output: bytearray, _base_path: str) -> None:
        pause_alpha(process, master_fd, output)
        send_and_wait(process, master_fd, output, b"y",
                      b"unbind all of alpha: 1 removed, 1 kept, 0 not found, 0 failed")
        if unbinds(taken) != [("111", "alpha"), ("333", "alpha")]:
            raise AssertionError(
                f"the offer did not send exactly alpha's two bindings: {unbinds(taken)!r}"
            )
        os.write(master_fd, b"q")

    run_terminal_scenario(
        executable,
        description="y after a pause removes the paused Keeper's channel bindings",
        interact=take_offer,
        http_fixtures=fixtures(),
        http_requests=taken,
    )

    declined: HttpRequests = []

    def decline_offer(process: subprocess.Popen[bytes], master_fd: int,
                      _slave_fd: int, output: bytearray, _base_path: str) -> None:
        pause_alpha(process, master_fd, output)
        # U straight after the offer is the runtime picker, not a yes.
        send_and_wait(process, master_fd, output, b"U", b"\xe2\x96\xb8 runtime")
        if unbinds(declined):
            raise AssertionError(
                f"a declined offer still sent unbinds: {unbinds(declined)!r}"
            )
        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        os.write(master_fd, b"q")

    run_terminal_scenario(
        executable,
        description="U after a pause opens the runtime picker and keeps the bindings",
        interact=decline_offer,
        http_fixtures=fixtures(),
        http_requests=declined,
    )


def run_keeper_runtime_picker_filter_regression(executable: str) -> None:
    """The Keeper runtime picker is walked without holding an arrow key.

    Keepers, U lists the declared lanes and then the whole catalogue. End and
    Home jump, [/] narrows the list to the typed text across both groups, and
    Esc drops the filter before it closes the picker. While the filter is
    open [q] and [d] are letters: neither quits nor resets the Keeper to the
    default. Enter assigns the row the filter left under the cursor.
    """
    filter_cursor = "\u258f".encode()

    def selected_row(output: bytearray) -> bytes:
        for row in screen_text(bytes(output)).split(b"\n"):
            is_picker_row = b"[LANE]" in row or b"[MODEL]" in row
            if is_picker_row and row.lstrip(b"\xe2\x94\x82 ").startswith(b"> "):
                return row
        raise AssertionError(f"no picker row is selected: {bytes(output)!r}")

    def expect_selected(process: subprocess.Popen[bytes], master_fd: int,
                        output: bytearray, target: bytes) -> None:
        drain_until_quiet(process, master_fd, output)
        row = selected_row(output)
        if target not in row:
            raise AssertionError(f"expected {target!r} under the cursor, got {row!r}")

    def fixtures() -> HttpFixtures:
        served = keeper_runtime_http_fixtures()
        served[RUNTIME_RESOLVED_PATH] = runtime_resolved_response()
        served["/api/v1/keepers/alpha/config"] = (200, {
            "config_revision": {
                "manifest": {"state": "missing"},
                "runtime_assignment": {"state": "runtime_config_missing"},
            },
        })
        return served

    requests: HttpRequests = []

    # Every assignment written, as (keeper, runtime id); [d]'s reset to the
    # default is one with no runtime id.
    def assignments() -> list[tuple[str | None, str | None]]:
        return [
            (body.get("keeper_name"), body.get("runtime_id"))
            for body in (
                json.loads(raw) for path, raw in requests
                if path == "/api/v1/runtime/config/assignment"
            )
        ]

    def interact(process: subprocess.Popen[bytes], master_fd: int,
                 _slave_fd: int, output: bytearray, _base_path: str) -> None:
        send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
        select_keeper_row(process, master_fd, output, b"alpha")
        # Three declared lanes, then five runtimes.
        send_and_wait(process, master_fd, output, b"U",
                      "8 of 8 \u00b7 / filter".encode())
        expect_selected(process, master_fd, output, b"primary")
        os.write(master_fd, b"\x1b[F")
        expect_selected(process, master_fd, output, b"runtime-e")
        os.write(master_fd, b"\x1b[H")
        expect_selected(process, master_fd, output, b"primary")
        # One wheel notch is one row: the shared list steps on the wheel, and
        # nothing else here moves the picker a second time.
        os.write(master_fd, b"\x1b[<65;5;5M")
        expect_selected(process, master_fd, output, b"degraded")
        os.write(master_fd, b"\x1b[<64;5;5M")
        expect_selected(process, master_fd, output, b"primary")

        send_and_wait(process, master_fd, output, b"/",
                      b"filter: " + filter_cursor + b" 8 of 8")
        # "-d" is in the unobserved lane's route and in runtime-d: one list.
        send_and_wait(process, master_fd, output, b"-d",
                      b"filter: -d" + filter_cursor + b" 2 of 8")
        expect_selected(process, master_fd, output, b"unobserved")
        send_and_wait(process, master_fd, output, b"q",
                      b"(no lane or runtime among 8 matches the filter)")
        send_and_wait(process, master_fd, output, b"d",
                      b"filter: -dqd" + filter_cursor + b" 0 of 8")
        send_and_wait(process, master_fd, output, b"\x7f\x7f",
                      b"filter: -d" + filter_cursor + b" 2 of 8")
        os.write(master_fd, b"\x1b[B")
        expect_selected(process, master_fd, output, b"runtime-d")
        # Esc drops the filter and keeps runtime-d under the cursor.
        send_and_wait(process, master_fd, output, b"\x1b",
                      "8 of 8 \u00b7 / filter".encode())
        expect_selected(process, master_fd, output, b"runtime-d")
        if assignments():
            raise AssertionError(
                f"typing into the filter sent an assignment: {assignments()!r}"
            )

        # The filter again, then Enter: runtime-e is assigned to alpha.
        send_and_wait(process, master_fd, output, b"/model-e",
                      b"filter: model-e" + filter_cursor + b" 1 of 8")
        send_and_wait(process, master_fd, output, b"\r", b"MASC Keepers")
        deadline = time.monotonic() + 3.0
        while not assignments() and time.monotonic() < deadline:
            time.sleep(0.05)
        if assignments() != [("alpha", "runtime-e")]:
            raise AssertionError(f"assignment posts: {assignments()!r}")

        # A second picker opens with no filter, and Esc closes it.
        send_and_wait(process, master_fd, output, b"U",
                      "8 of 8 \u00b7 / filter".encode())
        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        os.write(master_fd, b"q")

    run_terminal_scenario(
        executable,
        description="Keeper runtime picker filters across lanes and runtimes",
        interact=interact,
        http_fixtures=fixtures(),
        http_requests=requests,
    )


def run_tab_strip_keeps_current_entry_regression(executable: str) -> None:
    """At STRIP_CUT_COLUMNS the row is 92 cells; a strip wider than that
    used to be cut from the right, so the Keeper detail's Runs tab and
    Config's voice pane drew with no mark on the row at all. The strip now
    cuts around the current entry."""

    def interact(process: subprocess.Popen[bytes], master_fd: int,
                 _slave_fd: int, output: bytearray, _base_path: str) -> None:
        resize_and_wait(process, master_fd, output, rows=38,
                        columns=STRIP_CUT_COLUMNS, needle=b"MASC Dashboard",
                        final_cursor=b"\x1b[?25l")
        # Open Keepers to exercise the detail strip at this narrow width.
        send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
        drain_until_quiet(process, master_fd, output)
        # Keeper detail: [ from Info wraps to Runs, the last of nine tabs.
        select_keeper_row(process, master_fd, output, b"alpha")
        send_and_wait(process, master_fd, output, b"\r", b"\xe2\x96\xb8Info")
        send_and_wait(process, master_fd, output, b"[", b"\xe2\x96\xb8Runs")
        drain_until_quiet(process, master_fd, output)
        rows = screen_rows(bytes(output[: output.rfind(FRAME_END) + len(FRAME_END)]))
        title = rows[screen_row_of(rows, b"\xe2\x96\xb8Runs")]
        # The cut end carries the count it holds back (Masc_tui_ansi
        # hidden_before_mark, "\xe2\x80\xb9N"), not a bare ellipsis (#38713).
        if b"\xe2\x80\xb9" not in title or b"Info" in title:
            raise AssertionError(
                f"the Keeper detail strip did not cut its far end to keep Runs: {title!r}"
            )
        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        # Config: p walks the panes; voice is the seventh and was the one cut.
        tab_until(process, master_fd, output, b"MASC System")
        for pane in (b"models", b"params", b"prompts", b"presets", b"themes", b"voice"):
            send_and_wait(process, master_fd, output, b"p", b"\xe2\x96\xb8" + pane)
        os.write(master_fd, b"q")

    run_terminal_scenario(
        executable,
        description="A tab strip keeps its current entry on the row",
        interact=interact,
        http_fixtures=keeper_runtime_http_fixtures(),
    )


def run_activity_logs_tab_pane_regression(executable: str) -> None:
    """Dashboard, Work and Usage share the pane's 102-column surface floor.

    Home stays compact by default. An explicit Ctrl-L choice opens the
    Recent pane, whose 102-column surface boundary then persists on Work and
    Usage. Activity Events and Logs suppress it because they own that content.
    """

    def pane_row(output: bytearray) -> int:
        completed = bytes(output[: output.rfind(FRAME_END) + len(FRAME_END)])
        return screen_row_of(screen_rows(completed), b"[Recent]")

    def interact(process: subprocess.Popen[bytes], master_fd: int,
                 _slave_fd: int, output: bytearray, _base_path: str) -> None:
        # D12: the same 158-column boundary on each destination, leaving
        # exactly 102 columns for the surface beside the 56-column pane.
        resize_and_wait(process, master_fd, output, rows=38,
                        columns=ACTING_PANE_THRESHOLD_COLUMNS,
                        needle=b"MASC Dashboard", final_cursor=b"\x1b[?25l")
        # Home starts without a feed. An explicit pane choice still applies
        # on Home and survives the following surface switches.
        drain_until_quiet(process, master_fd, output)
        assert pane_row(output) < 0, screen_text(bytes(output))
        send_and_wait(process, master_fd, output, b"\x0c", b"[Recent]")
        for title, ready, whole_row in (
            (b"MASC Dashboard", b"Continue", b"Choose a Keeper"),
            (b"MASC Work", b"D12 Goal", b"D12 Goal"),
            (b"MASC Usage", b"D12 provider", b"40%"),
        ):
            ready_start = 0
            if title != b"MASC Dashboard":
                ready_start = len(output)
                tab_until(process, master_fd, output, title)
            wait_for_output(process, master_fd, output, ready, start=ready_start, timeout=10.0)
            drain_until_quiet(process, master_fd, output)
            completed = bytes(output[: output.rfind(FRAME_END) + len(FRAME_END)])
            drawn = screen_text(completed)
            header_cell = acting_pane_header_cell(bytearray(completed))
            if pane_row(output) < 0 or header_cell != ACTING_PANE_SURFACE_FLOOR_COLUMNS + 1:
                raise AssertionError(f"{title!r} lost the shared pane boundary: {drawn!r}")
            if ready not in drawn or whole_row not in drawn:
                raise AssertionError(f"{title!r} clipped its fixture row: {drawn!r}")
            print("ACTIVITY_PANE_158_SCREEN=" + json.dumps({
                "surface": title.decode(), "terminal_columns": ACTING_PANE_THRESHOLD_COLUMNS,
                "surface_columns": ACTING_PANE_SURFACE_FLOOR_COLUMNS,
                "pane_header_cell": header_cell,
                "screen": drawn.decode("utf-8", errors="replace"),
            }), flush=True)
        tab_until(process, master_fd, output, b"MASC System")
        send_and_wait(process, master_fd, output, b"A", b"MASC Activity")
        for key, tab in ((b"l", b"\xe2\x96\xb8Logs"), (b"e", b"\xe2\x96\xb8Events"),
                         (b"l", b"\xe2\x96\xb8Logs")):
            send_and_wait(process, master_fd, output, key, tab)
            drain_until_quiet(process, master_fd, output)
            if pane_row(output) >= 0:
                raise AssertionError(
                    f"the acting pane opened on the Activity tab {tab!r}: {screen_text(bytes(output))!r}"
                )
        os.write(master_fd, b"q")

    fixtures = keeper_runtime_http_fixtures()
    goal = planning_goal("goal-d12", "D12 Goal")
    goal.update({"metric": "checks", "target_value": "5", "task_count": 1,
                 "task_done_count": 0, "measurement": {"state": "not_recorded"},
                 "stagnation_seconds": None, "tasks": [{"id": "task-d12"}],
                 "children": []})
    fixtures[PLANNING_PATH] = planning_snapshot([goal])
    fixtures[DASHBOARD_GOALS_PATH] = (200, {"tree": [goal]})
    _, runtime = empty_runtime_resolved_fixture()
    assert isinstance(runtime, dict)
    runtime["provider_usage_windows"] = [{
        "scope": "provider:d12", "scope_id": hashlib.md5(b"provider:d12").hexdigest(),
        "providers": [{"id": "d12", "display_name": "D12 provider"}],
        "state": "reported", "windows": [{
            "limit_id": None, "window": {"kind": "five_hour"},
            "role": "gates_model_calls", "utilization": {"unit": "fraction", "value": 0.4},
            "resets_at": None, "observed_at": time.time(), "source": "fixture",
        }],
    }]
    fixtures[RUNTIME_RESOLVED_PATH] = (200, runtime)
    run_terminal_scenario(
        executable,
        description="Activity Logs tab keeps the acting pane off",
        interact=interact,
        http_fixtures=fixtures,
    )


def open_turn_roster_http_fixtures(started_at_unix: float) -> HttpFixtures:
    """alpha healthy and beta failing, each with a turn open.

    A failing keeper's keepalive runs the next attempt, so its turn is open
    while the roster header counts it failing; alpha is the working keeper
    its row must not look like.
    """
    fixtures = keeper_runtime_http_fixtures()
    status, roster = fixtures["/api/v1/gate/keepers?detailed=true"]
    alpha, beta = roster["keepers"]
    beta = {
        **beta,
        "status": "active",
        "health": "failing",
        "paused": False,
        "phase": "failing",
        "activation_mode": "autonomous",
    }
    fixtures["/api/v1/gate/keepers?detailed=true"] = (
        status,
        {**roster, "keepers": [alpha, beta]},
    )
    fixtures["/api/v1/keepers/turns"] = (
        200,
        {
            "schema": "masc.keeper_turns.v1",
            "keepers": [
                {
                    "keeper_name": name,
                    "status": "ok",
                    "chat_control_token": f"control-{name}",
                    "turn": {
                        "lane": "autonomous",
                        "started_at_unix": started_at_unix,
                        "interrupt_token": token,
                        "preview": None,
                    },
                }
                for name, token in (
                    ("alpha", "4f3c2a10-5b6d-4e7f-8a9b-0c1d2e3f4a5b"),
                    ("beta", "7a8b9c0d-1e2f-4a3b-9c4d-5e6f7a8b9c0d"),
                )
            ],
        },
    )
    return fixtures


def a_failing_keepers_open_turn_reads_failing(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    tab_until(process, master_fd, output, b"MASC Keepers")
    # Both turns opened about 42 seconds ago. The HEALTH cell carries the
    # health word the header counts -- nothing for healthy alpha, "failing"
    # for beta -- and the TURN cell after the name carries the open turn's run
    # time on both rows. A clock kept in HEALTH would leave it off beta's row,
    # whose only age would then be its last recorded turn's: the failure's.
    working = re.compile(rb"\balpha\b[^\n]*?\b\d+s\b")
    failing = re.compile(rb"\bfailing +beta\b[^\n]*?\b\d+s\b")
    deadline = time.monotonic() + 10.0
    screen = b""
    while time.monotonic() < deadline:
        read_available(master_fd, output)
        screen = screen_text(bytes(output))
        if working.search(screen) and failing.search(screen):
            break
        time.sleep(0.1)
    else:
        raise AssertionError(
            "the roster did not draw both open turns' run time in TURN, and "
            f"beta's failing word in HEALTH: {screen!r}"
        )
    if not re.search(rb"\b1 failing\b", screen):
        raise AssertionError(f"the header did not count beta failing: {screen!r}")
    os.write(master_fd, b"q")


def lanes_press_selects_the_lane_under_the_pointer(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    """A press lands on the lane drawn under it.

    The hit test turns a terminal row into a lane index by subtracting the
    rows drawn above the list. That count and the unit test holding it were
    each written by hand, agreed with each other, and both said five while
    seven were drawn -- so a press on the first lane opened the third. Here
    the row comes off the screen the binary just painted, which is the only
    reading that cannot drift from it.

    The pointer goes to the last lane rather than the first: the cursor
    starts on the first, so selecting it again would pass without the press
    doing anything."""
    palette_go(process, master_fd, output, b"go lanes", b"MASC Lanes")
    resize_and_wait(
        process,
        master_fd,
        output,
        rows=30,
        columns=220,
        needle="Lanes · observed ".encode(),
        controls=(FULL_REDRAW,),
    )
    drain_until_quiet(process, master_fd, output)
    drawn = bytes(output)
    row = screen_row_of(screen_rows(drawn), b"Verifier")
    if row < 0:
        raise AssertionError(
            f"Lanes drew no Verifier row: {screen_text(drawn).decode('utf-8')!r}"
        )
    # SGR reports carry the column before the row, and both count from one --
    # the same numbering [screen_rows] keys by.
    press = b"\x1b[<0;6;%dM" % row
    release = b"\x1b[<0;6;%dm" % row
    send_and_wait(
        process,
        master_fd,
        output,
        press + release,
        b"Reviews Task completion and Goal proof evidence.",
    )
    # Exit is armed: the first press asks, and the harness sends the second.
    os.write(master_fd, b"q")


KEEPER_SETTINGS_PATH = "/api/v1/keepers/alpha/config"
KEEPER_SETTINGS_REVISION = {
    "manifest": {"state": "sha256", "value": "a" * 64},
    "runtime_assignment": {
        "state": "runtime_config_present",
        "source_revision": "b" * 64,
        "assignment": {"state": "assigned", "runtime_id": "anthropic.claude-opus-5"},
    },
}
ACTIVATION_VALUES = b"manual | on_demand | autonomous"


def keeper_settings_fixture() -> RequestHttpResponse:
    """GET answers the settings snapshot; POST answers as the server does.

    The same path serves both, so the fixture tells them apart by the body.
    A POST carrying a value outside the closed activation set gets the
    server's own 400 (keeper_turn_up_args.ml), so main's behaviour -- send,
    then show the refusal -- is what the red run records.
    """

    def resolve(body: bytes) -> HttpResponse:
        if not body:
            return 200, {
                "config_revision": KEEPER_SETTINGS_REVISION,
                "activation_mode": "manual",
                "input_policy": "small",
                "max_context_override": None,
                "sandbox_profile": "docker",
                "network_mode": "none",
                "prompt": {"instructions": "be exact"},
                "execution": {"selected_runtime_id": "anthropic.claude-opus-5"},
                "skills": {"names": None},
                "workspace": {"mention_targets": ["@alpha"], "board_interests": []},
            }
        mode = json.loads(body).get("activation_mode")
        if mode not in (None, "manual", "on_demand", "autonomous"):
            # Keeper_turn_up_args.parse refuses before any write, and the
            # route answers with error_json: {"error": <sentence>}.
            return 400, {
                "error": "activation_mode must be manual, on_demand, or autonomous"
            }
        return 200, {
            "runtime_sync": "lane_restarted",
            "config_write": {
                "revision": KEEPER_SETTINGS_REVISION,
                "applied": True,
                "warnings": [],
            },
        }

    return RequestHttpResponse(resolve)


@contextmanager
def activation_editor_script(value: str) -> Iterator[tuple[str, str]]:
    """An $EDITOR that sets activation_mode to [value] and saves (exit 0).

    It is the operator's `e`, one edit, `:w`: every buffer it is handed is
    copied to seen.<n> first, so the scenario can count how many times the
    editor opened and read what each opening showed. A second opening gets
    the same edit applied again -- an operator who saves without fixing.
    """
    workdir = tempfile.mkdtemp(prefix="masc-tui-activation-editor-")
    path = os.path.join(workdir, "editor.sh")
    with open(path, "w", encoding="utf-8") as script:
        script.write(
            "#!/bin/sh\n"
            f'n=$(ls "{workdir}" | grep -c "^seen\\.")\n'
            f'cp "$1" "{workdir}/seen.$n"\n'
            f"sed 's/\"activation_mode\": \"[a-z_]*\"/\"activation_mode\": \"{value}\"/' "
            '"$1" > "$1.new" && mv "$1.new" "$1"\n'
        )
    os.chmod(path, 0o755)
    try:
        yield path, workdir
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def editor_buffers(workdir: str) -> list[bytes]:
    names = sorted(
        (name for name in os.listdir(workdir) if name.startswith("seen.")),
        key=lambda name: int(name.split(".", 1)[1]),
    )
    buffers = []
    for name in names:
        with open(os.path.join(workdir, name), "rb") as handle:
            buffers.append(handle.read())
    return buffers


def activation_settings_interaction(
    requests: HttpRequests, workdir: str, *, value: str
) -> Interaction:
    """`e` on the Keepers list, activation_mode set to [value], `:w`.

    A value outside the closed set must never reach the wire: the editor
    opens again with the operator's text and the allowed values above it,
    and saving that same text again closes it with the reason on the status
    line -- not a loop the operator can only escape with :cq. A valid value
    is sent once, as the only changed field.
    """

    def settings_posts() -> list[bytes]:
        return [body for path, body in requests if path == KEEPER_SETTINGS_PATH]

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        tab_until(process, master_fd, output, b"MASC Keepers")
        wait_for_output(process, master_fd, output, b"alpha", start=0, timeout=5.0)
        drain_until_quiet(process, master_fd, output)
        start = len(output)
        os.write(master_fd, b"e")
        if value == "autonomous":
            body = wait_for_http_request(
                process, master_fd, output, requests, path=KEEPER_SETTINGS_PATH
            )
            patch = json.loads(body)
            if patch.get("activation_mode") != "autonomous":
                raise AssertionError(f"valid activation was not sent: {patch!r}")
            if set(patch) != {"expected_config_revision", "activation_mode"}:
                raise AssertionError(f"patch carried more than the edit: {patch!r}")
            wait_for_output(
                process,
                master_fd,
                output,
                b"alpha: changed settings applied",
                start=start,
                timeout=5.0,
            )
            if len(editor_buffers(workdir)) != 1:
                raise AssertionError("a valid edit reopened the editor")
        else:
            wait_for_output(
                process, master_fd, output, ACTIVATION_VALUES, start=start, timeout=10.0
            )
            drain_until_quiet(process, master_fd, output)
            buffers = editor_buffers(workdir)
            posts = settings_posts()
            if posts:
                raise AssertionError(
                    f"an activation outside the closed set reached the wire: {posts!r}"
                )
            if len(buffers) != 2:
                raise AssertionError(
                    f"the editor should open twice (edit, then the refusal), "
                    f"opened {len(buffers)} time(s): {buffers!r}"
                )
            first, second = buffers
            if b"//" in first:
                raise AssertionError(f"the first opening carried a refusal: {first!r}")
            if ACTIVATION_VALUES not in second or f'"{value}"'.encode() not in second:
                raise AssertionError(
                    f"the reopened editor did not name the value and the allowed set: {second!r}"
                )
        os.write(master_fd, b"q")

    return interact


def run_keeper_settings_activation_regression(executable: str) -> None:
    for value in ("auto", "autonomous"):
        requests: HttpRequests = []
        fixtures = keeper_runtime_http_fixtures()
        fixtures[KEEPER_SETTINGS_PATH] = keeper_settings_fixture()
        with activation_editor_script(value) as (editor, workdir):
            run_terminal_scenario(
                executable,
                description=f"Keeper settings activation_mode {value!r} then :w",
                interact=activation_settings_interaction(requests, workdir, value=value),
                http_fixtures=fixtures,
                http_requests=requests,
                extra_env={"EDITOR": editor},
            )


def run_keeper_lanes_regression(executable: str) -> None:
    fixtures = keeper_runtime_http_fixtures()
    gate = GatedHttpResponse(
        keeper_lanes_response(
            [
                keeper_lane_row(
                    "alpha",
                    phase="running",
                    turn_phase="idle",
                    idle_seconds=75,
                    runtime_state="done",
                    selected_model="claude-opus-5",
                ),
                keeper_lane_row(
                    "beta",
                    phase="failing",
                    turn_phase="executing",
                    idle_seconds=3599,
                    runtime_state="done",
                    selected_model=None,
                    turn_healthy=False,
                ),
            ]
        )
    )
    fixtures[KEEPER_LANES_PATH] = gate
    fixtures[STANDALONE_LANES_PATH] = standalone_lanes_response()
    fixtures[lane_runs_path("verifier_exact")] = verifier_lane_runs_response()
    fixtures[
        "/api/v1/dashboard/exact-lane-runs/vrf-fixture"
    ] = verifier_lane_run_detail_response()
    fixtures[lane_runs_path("hitl_auto_judge")] = hitl_lane_runs_response()
    fixtures[
        "/api/v1/dashboard/exact-lane-runs/hitl-fixture"
    ] = hitl_lane_run_detail_response()
    fixtures[RUNTIME_CONFIG_RAW_PATH] = standalone_lane_runtime_config_response()
    run_terminal_scenario(
        executable,
        description="a failing keeper's open turn reads failing",
        interact=a_failing_keepers_open_turn_reads_failing,
        http_fixtures=open_turn_roster_http_fixtures(time.time() - 42),
    )
    run_terminal_scenario(
        executable,
        description="Keepers operations and Standalone-only Lanes",
        interact=keeper_lanes_ia_interaction(gate, fixtures),
        http_fixtures=fixtures,
    )
    # Its own copy, with the gate replaced by a plain answer: this walk reads
    # Standalone rows only, and a gate another scenario has to release would
    # make it depend on running after that one.
    pointer_fixtures = dict(fixtures)
    pointer_fixtures[KEEPER_LANES_PATH] = keeper_lanes_response([])
    run_terminal_scenario(
        executable,
        description="a press on a Standalone lane row selects that lane",
        interact=lanes_press_selects_the_lane_under_the_pointer,
        http_fixtures=pointer_fixtures,
    )
