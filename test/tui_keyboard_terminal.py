from __future__ import annotations

import json
import os
import re
import signal
import subprocess
import termios
from pathlib import Path

from tui_keyboard_harness import (
    BOARD_CELL_BODY,
    CONSOLE_DIAGNOSTIC,
    CSI_RE,
    FRAME_END,
    FULL_REDRAW,
    Interaction,
    keeper_metadata,
    read_available,
    resize_and_wait,
    run_terminal_scenario,
    select_keeper_row,
    send_and_wait,
    tab_until,
    wait_for_output,
)


def interrupt_with_ctrl_c(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    send_and_wait(
        process,
        master_fd,
        output,
        b"\x03",
        b"Ctrl-C: press again to quit",
    )


def terminate_with_sigterm(
    process: subprocess.Popen[bytes],
    _master_fd: int,
    _slave_fd: int,
    _output: bytearray,
    _base_path: str,
) -> None:
    # What `kill` and a service manager send. The handler only records the
    # signal; the loop has to read the record on its next pass and leave the
    # way q does, so the terminal restore and Goodbye the harness checks after
    # this come from that one exit path. A loop that never read it would sit
    # here until the harness's post-exit wait gives up. The launcher shell in
    # the same group ignores TERM (see run_terminal_scenario).
    os.killpg(process.pid, signal.SIGTERM)


def quit_from_compact_message(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    send_and_wait(process, master_fd, output, b"3", b"MASC Keepers")
    select_keeper_row(process, master_fd, output, b"alpha")
    send_and_wait(process, master_fd, output, b"\r", b"Keepers \xe2\x96\xb8 \x1b[1malpha")
    send_and_wait(process, master_fd, output, b"m", b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")
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
    os.write(master_fd, b"q")


def block_stderr_redirect(base_path: str) -> None:
    """Put a file where masc_tui wants its log directory.

    [redirect_stderr_off_terminal] opens <base>/.masc/logs/masc-tui-<pid>.log
    and gives up on any Unix_error or Sys_error, leaving stderr on the
    terminal. A regular file at .masc/logs makes both the mkdir and the open
    fail, which is the state a read-only or full disk produces.
    """
    masc = Path(base_path) / ".masc"
    masc.mkdir(parents=True, exist_ok=True)
    (masc / "logs").write_text("", encoding="utf-8")


def repair_after_console_diagnostic(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    base_path: str,
) -> None:
    read_available(master_fd, output)
    start = len(output)
    keeper_path = Path(base_path) / ".masc" / "keepers" / "alpha.json"
    keeper_path.write_text("{", encoding="utf-8")
    # This scenario is about the surface repairing itself after a console
    # line lands in the frame, which only happens when masc_tui cannot move
    # stderr off the terminal. [block_stderr_redirect] makes that real by
    # putting a file where the log directory has to go, so the open fails the
    # way a read-only or full disk would.
    #
    # Before masc#31881 the redirect failed on every temporary root -- the log
    # was opened with O_CREAT and nothing made the directory -- so the leak
    # happened by accident and this scenario passed without arranging it.
    wait_for_output(
        process,
        master_fd,
        output,
        CONSOLE_DIAGNOSTIC,
        start=start,
        timeout=3.0,
    )
    diagnostic_end = output.find(CONSOLE_DIAGNOSTIC, start) + len(CONSOLE_DIAGNOSTIC)
    keeper_path.write_text(json.dumps(keeper_metadata("alpha")), encoding="utf-8")
    wait_for_output(
        process,
        master_fd,
        output,
        FULL_REDRAW,
        start=diagnostic_end,
        timeout=3.0,
    )
    redraw_start = output.find(FULL_REDRAW, diagnostic_end)
    wait_for_output(
        process,
        master_fd,
        output,
        b"MASC Dashboard",
        start=redraw_start,
        timeout=3.0,
    )
    overview_start = output.find(b"MASC Dashboard", redraw_start)
    wait_for_output(
        process,
        master_fd,
        output,
        FRAME_END,
        start=overview_start + len(b"MASC Dashboard"),
        timeout=3.0,
    )
    os.write(master_fd, b"q")


def assert_row_budgeted_surfaces(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    # Home is interactive while connecting. This fixture's health reading,
    # rather than its early entry points, proves the briefing arrived.
    wait_for_output(process, master_fd, output, b"Health: ok", start=0, timeout=10.0)

    overview = resize_and_wait(
        process,
        master_fd,
        output,
        rows=16,
        columns=100,
        needle=b"MASC Dashboard",
        controls=(FULL_REDRAW,),
        final_cursor=b"\x1b[?25l",
    )
    # Home keeps decision entry points and a conversation entry visible;
    # generic incidents never become operator decisions by severity alone.
    for expected in (b"MASC Dashboard", b"Health:", b"Continue", b"q:quit"):
        if expected not in overview:
            raise AssertionError(f"compact Dashboard omitted {expected!r}: {overview!r}")
    expanded = resize_and_wait(
        process, master_fd, output, rows=30, columns=100,
        needle=b"Continue", controls=(FULL_REDRAW,), final_cursor=b"\x1b[?25l",
    )
    for forbidden in (b"attention-1", b"attention-2", b"linked tasks", b"scope windows in Usage"):
        if forbidden in expanded:
            raise AssertionError(f"Home repeated detail content: {expanded!r}")
    tab_until(process, master_fd, output, b"MASC Keepers")
    tab_until(process, master_fd, output, b"MASC Board")
    send_and_wait(process, master_fd, output, b"\r", b"comment-5")

    board = resize_and_wait(
        process,
        master_fd,
        output,
        rows=16,
        columns=100,
        needle=b"MASC Board",
        controls=(FULL_REDRAW,),
        final_cursor=b"\x1b[?25l",
    )
    # Two comment rows at this height. The surface spends the rest on its box,
    # on the key footer, and on the "post rows" line it writes because the
    # thread does not fit -- so the budget the thread is left with is the
    # smallest one this pane hands out. The box no longer spends a row on a
    # list of keys the footer carries.
    for expected in (BOARD_CELL_BODY.encode(), b"comment-1", b"comment-2"):
        if expected not in board:
            raise AssertionError(f"14-row Board omitted {expected!r}: {board!r}")
    if b"**comment-1**" in board:
        raise AssertionError(f"Board comment leaked Markdown source markers: {board!r}")
    for hidden in (b"comment-3", b"comment-4", b"comment-5"):
        if hidden in board:
            raise AssertionError(f"14-row Board exceeded its row budget: {board!r}")

    # Focus comments before testing their one-row scroll. The b repaint only
    # changes the header and footer, so it need not resend the body rows.
    focused = send_and_wait(process, master_fd, output, b"b", b"> Comments")
    if b"j/k:comments" not in focused:
        raise AssertionError(f"Board did not focus the comments: {focused!r}")

    # With two comment rows, each press moves the thread by one, and the whole
    # thread is still reachable.
    for comment in (b"comment-3", b"comment-4", b"comment-5"):
        send_and_wait(process, master_fd, output, b"j", comment)
    os.write(master_fd, b"q")


def flow_control_is_off_interaction() -> Interaction:
    """Ctrl-S has to reach the key layer, not the tty.

    IXON lives in c_iflag and ICANON in c_lflag, so raw mode did not clear it:
    the terminal answered Ctrl-S by stopping output and Ctrl-Q by resuming,
    and neither byte ever reached the program. With IXANY also on, the next
    key released it, so what an operator saw was a stall rather than a freeze
    -- and what it cost was a key that could not be bound to anything.

    Read off the tty rather than inferred from the drawing: the flag is the
    fact, and a screen that repaints cannot tell the difference."""

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        slave_fd: int,
        output: bytearray,
        base_path: str,
    ) -> None:
        wait_for_output(
            process, master_fd, output, b"MASC Dashboard", start=0, timeout=30.0
        )
        attributes = termios.tcgetattr(slave_fd)
        if attributes[0] & termios.IXON:
            raise AssertionError(
                "the tty still answers Ctrl-S itself; c_ixon must be cleared "
                "with the rest of raw mode or the key cannot be bound"
            )
        send_and_wait(process, master_fd, output, b"q", b"q: press again to quit")

    return interact


def run_theme_scheme_regression(executable: str) -> None:
    """Picking a scheme sends the whole scheme, colour codes included.

    The gap this closes: between #30781 and the OSC 4 change, a pick sent the
    page and the default text and nothing else. Everything masc says with
    colour is drawn by naming a code, so a scheme reached the two quietest
    colours on the screen and stopped. The catalogue's high-contrast schemes
    were hit hardest -- the readability lift was the only path a chosen colour
    had to a code, and a scheme that needs no lift got none, so picking the
    top row changed nothing at all.

    Driven through the picker rather than the presenter because the presenter
    already has unit cover. What was missing was nobody asking whether the key
    the reader presses reaches it.
    """

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        tab_until(process, master_fd, output, b"MASC System")
        # [p] cycles the Config panes and themes is the last of them, so the
        # walk stops on the header rather than counting presses.
        for _ in range(8):
            if b"MASC Themes" in CSI_RE.sub(b"", bytes(output)):
                break
            send_and_wait(process, master_fd, output, b"p", b"MASC ")
        else:
            raise AssertionError("[p] never reached the themes pane")

        # A scheme that ships only as TOML. Until the catalogue started
        # reading config/themes out of the binary, these loaded from the
        # reader's base path and a live workspace is not this repo, so the
        # picker listed only what OCaml carried and cyber was measured by the
        # contracts while nobody could choose it.
        pane = CSI_RE.sub(b"", bytes(output))
        if b"cyber" not in pane:
            raise AssertionError(
                "the picker does not list cyber: a shipped TOML scheme is not "
                "reaching the reader"
            )

        before = len(output)
        # The cursor opens on the first row, which the picker sorts to be a
        # native-pass scheme -- the case that used to send nothing.
        send_and_wait(process, master_fd, output, b"\r", b"Enter:pick another")
        sent = bytes(output[before:])

        if b"\x1b]4;" not in sent:
            raise AssertionError(
                "picking a scheme sent no OSC 4: the colour codes stayed the "
                "terminal's, so nothing masc says with colour moved"
            )
        if b"\x1b]10;" not in sent or b"\x1b]11;" not in sent:
            raise AssertionError("picking a scheme stopped sending the page")

        # Back to Overview, then arm the quit the harness confirms with its
        # own second press.
        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Dashboard")
        send_and_wait(
            process, master_fd, output, b"q", b"q: press again to quit"
        )

    run_terminal_scenario(
        executable,
        description="picking a theme sends its colour codes",
        interact=interact,
    )
