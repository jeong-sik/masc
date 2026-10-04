from __future__ import annotations

import os
import subprocess
import termios
import time
from pathlib import Path

from tui_keyboard_harness import (
    drain_until_quiet,
    keeper_row_selected,
    overview_event_http_fixtures,
    run_terminal_scenario,
    screen_text,
    send_and_wait,
    wait_for_output,
)
from tui_keyboard_terminal import (
    terminate_with_sigterm,
)


def cli_base_path_overrides_environment_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    wait_for_output(process, master_fd, output, b"Health: ", start=0, timeout=10.0)
    frame = send_and_wait(
        process,
        master_fd,
        output,
        b"3",
        keeper_row_selected(b"alpha"),
    )
    if b"env-only" in frame:
        raise AssertionError(
            f"--base-path leaked Keeper metadata from MASC_BASE_PATH: {frame!r}"
        )
    os.write(master_fd, b"q")


def ctrl_y_reaches_the_tui_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    """Ctrl-Y is the speak key, and it has to arrive as a byte.

    On BSD terminals the tty takes it as VDSUSP: read with ISIG on -- which
    raw mode keeps -- it sends SIGTSTP instead of being delivered. On macOS 26
    one press ended the TUI with exit 2 on Unix_error(EAGAIN, "read"). Linux
    has no VDSUSP, so there the check on the key is skipped and the press is
    the whole test.
    """
    wait_for_output(process, master_fd, output, b"Health: ", start=0, timeout=10.0)
    if hasattr(termios, "VDSUSP"):
        cc = termios.tcgetattr(slave_fd)[6][termios.VDSUSP]
        dsusp = cc if isinstance(cc, int) else cc[0]
        if dsusp != os.fpathconf(slave_fd, "PC_VDISABLE"):
            raise AssertionError("raw mode did not reclaim Ctrl-Y from VDSUSP")
    # Overview has no conversation, so the key's answer there is the link
    # preview's notice on the footer -- a sentence the TUI can only draw if
    # it read the byte. The needle stops short of the end in case the footer
    # cuts it.
    send_and_wait(
        process,
        master_fd,
        output,
        b"\x19",
        b"No web links found in this conversa",
    )
    if process.poll() is not None:
        raise AssertionError(f"Ctrl-Y ended the TUI with exit {process.returncode}")
    os.write(master_fd, b"q")


def first_install_waits_for_its_workspace_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    """A first install's boot line names the missing workspace, not a command.

    The unit suite pins the sentence and the level the boot decision reports;
    this pins what the operator actually sees. The harness seeds no
    ``.masc/auth`` and this scenario omits ``MASC_TOKEN``, so the boot decision
    is the one a fresh install takes -- no workspace to mint into yet. The
    TUI session block on Usage / Telemetry draws that notice, and the ``masc login``
    command the old single-constructor line handed over is not on the screen.
    The block trims a long row at the frame width, so the needle is the
    notice's opening.
    """
    wait_for_output(
        process, master_fd, output, b"MASC Dashboard", start=0, timeout=30.0
    )
    send_and_wait(process, master_fd, output, b"m", b"MASC Usage")
    send_and_wait(process, master_fd, output, b"p", b"TUI session")
    drain_until_quiet(process, master_fd, output)
    screen = screen_text(bytes(output))
    if b"no operator token yet" not in screen:
        raise AssertionError(
            f"a first install did not name the missing workspace: {screen!r}"
        )
    if b"masc login" in screen:
        raise AssertionError(
            f"a first install was handed the login command: {screen!r}"
        )
    # The pending workspace is the ordinary path, so its row carries no error
    # mark: the clock's bracket is followed straight by the sentence.
    if b"] no operator token yet" not in screen:
        raise AssertionError(
            f"the pending workspace row is marked as an error: {screen!r}"
        )
    os.write(master_fd, b"q")


def seed_a_workspace_that_refuses_a_credential(base_path: str) -> None:
    """A workspace that is here and cannot take a credential.

    ``.masc/auth`` exists, so the boot decision is to mint; ``agents`` beside
    it is a file where the credential store is a directory, so the mint's
    write fails. A file rather than a read-only directory because a runner
    that tests as root writes through a mode bit, and would mint.
    """
    auth = Path(base_path) / ".masc" / "auth"
    auth.mkdir(parents=True)
    (auth / "agents").write_text("not a directory\n", encoding="utf-8")


def failed_mint_is_marked_as_an_error_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    """A mint that failed reads as an error in the TUI session block on Usage / Telemetry.

    Its row carries the chat pane's failure glyph after the clock, which a
    pending workspace's row does not; the mark is a shape, so it holds under
    NO_COLOR as well. The block trims the sentence at the frame width, so the
    needle is the mark and the notice's opening.
    """
    wait_for_output(
        process, master_fd, output, b"MASC Dashboard", start=0, timeout=30.0
    )
    send_and_wait(process, master_fd, output, b"m", b"MASC Usage")
    send_and_wait(process, master_fd, output, b"p", b"TUI session")
    drain_until_quiet(process, master_fd, output)
    screen = screen_text(bytes(output))
    if b"\xe2\x9c\x97 no operator token, and" not in screen:
        raise AssertionError(
            f"a failed mint did not read as a marked error: {screen!r}"
        )
    os.write(master_fd, b"q")


def run_cli_base_path_regression(executable: str) -> None:
    run_terminal_scenario(
        executable,
        description="CLI base path overrides inherited environment",
        interact=cli_base_path_overrides_environment_interaction,
        http_fixtures=overview_event_http_fixtures(),
        conflicting_env_base_path=True,
    )


def run_ctrl_y_regression(executable: str) -> None:
    run_terminal_scenario(
        executable,
        description="Ctrl-Y reaches the TUI instead of the tty's delayed suspend",
        interact=ctrl_y_reaches_the_tui_interaction,
        http_fixtures=overview_event_http_fixtures(),
    )


def exit_reason_log(base_path: str) -> str:
    """Everything the TUI wrote to its own per-PID stderr log, or "".

    The TUI redirects stderr to ``.masc/logs/masc-tui-<pid>.log`` at boot, so
    the exit line lands there. The pid is the TUI's, not the launcher shell's,
    so the file is found by glob rather than by name.
    """
    logs = sorted(Path(base_path, ".masc", "logs").glob("masc-tui-*.log"))
    if not logs:
        return ""
    return logs[-1].read_text(encoding="utf-8", errors="replace")


def wait_for_exit_reason(base_path: str, needle: str, timeout: float = 10.0) -> str:
    """The log text once it carries [needle], or an assertion naming what it held.

    The line is written as the process exits, so the read races the write; the
    poll is what makes the scenario wait for the fact rather than for a sleep.
    """
    deadline = time.monotonic() + timeout
    text = ""
    while time.monotonic() < deadline:
        text = exit_reason_log(base_path)
        if needle in text:
            return text
        time.sleep(0.05)
    raise AssertionError(
        f"no exit reason {needle!r} in {base_path}/.masc/logs/masc-tui-*.log; "
        f"the log held:\n{text}"
    )


def quit_writes_its_reason_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    base_path: str,
) -> None:
    """Leave with q and read the reason back from the log the TUI wrote.

    The per-PID log held only the boot lines, so a session that ended left no
    reason behind. The first q arms, the second leaves; the exit line is
    written as the process returns.
    """
    send_and_wait(process, master_fd, output, b"q", b"q: press again to quit")
    os.write(master_fd, b"q")
    # The prefix is part of the contract: the guide tells operators to collect
    # these rows with `grep '[masc-tui] exit:'`, so the test asks for what that
    # grep asks for rather than for the bare reason.
    text = wait_for_exit_reason(base_path, "[masc-tui] exit: normal (quit key)")
    if "exit: abnormal" in text:
        raise AssertionError(f"a q quit read as abnormal:\n{text}")
    # One row per session. at_exit stops at the first callback that raises and
    # OCaml may retry the rest, so a writer with no guard can leave two -- and
    # a reader counting a day's ends by cause would count this session twice.
    rows = text.count("[masc-tui] exit:")
    if rows != 1:
        raise AssertionError(
            f"the session wrote {rows} exit rows, not one:\n{text}"
        )


def sigterm_writes_its_reason_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    slave_fd: int,
    output: bytearray,
    base_path: str,
) -> None:
    """A terminate signal leaves the same record, naming the signal.

    A service manager's SIGTERM is not the operator's q, and the log has to
    tell them apart, so the reason carries the signal's name.
    """
    terminate_with_sigterm(process, master_fd, slave_fd, output, base_path)
    wait_for_exit_reason(base_path, "[masc-tui] exit: normal (signal SIGTERM)")


def run_exit_reason_regression(executable: str) -> None:
    # #37813's sibling: the per-PID log held only the boot lines, so a session
    # that ended left no reason behind. These read the reason back from the log
    # the process wrote, one per way out.
    run_terminal_scenario(
        executable,
        description="a q quit writes its reason to the session log",
        interact=quit_writes_its_reason_interaction,
        http_fixtures=overview_event_http_fixtures(),
    )
    run_terminal_scenario(
        executable,
        description="a SIGTERM writes its reason to the session log",
        interact=sigterm_writes_its_reason_interaction,
        http_fixtures=overview_event_http_fixtures(),
        confirm_exit=b"",
    )


def run_first_install_credential_regression(executable: str) -> None:
    run_terminal_scenario(
        executable,
        description="a first install waits for its workspace instead of the login command",
        interact=first_install_waits_for_its_workspace_interaction,
        http_fixtures=overview_event_http_fixtures(),
        omit_operator_token=True,
    )
    run_terminal_scenario(
        executable,
        description="a mint that failed is marked as an error in the TUI session block",
        interact=failed_mint_is_marked_as_an_error_interaction,
        http_fixtures=overview_event_http_fixtures(),
        prepare_workspace=seed_a_workspace_that_refuses_a_credential,
        omit_operator_token=True,
    )
    # The mark is a shape, not a colour, so the same row must read the same
    # with colour off -- the case the task names. The harness clears NO_COLOR
    # for every other scenario, so this one sets it back.
    run_terminal_scenario(
        executable,
        description="a mint that failed is marked as an error under NO_COLOR",
        interact=failed_mint_is_marked_as_an_error_interaction,
        http_fixtures=overview_event_http_fixtures(),
        prepare_workspace=seed_a_workspace_that_refuses_a_credential,
        omit_operator_token=True,
        extra_env={"NO_COLOR": "1"},
    )
