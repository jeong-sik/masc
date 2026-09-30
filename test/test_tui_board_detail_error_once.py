"""A Board post read failure has one verdict in both read layouts."""

import os
import sys
import threading

import tui_keyboard_chat as _keyboard_chat
import tui_keyboard_harness as _keyboard_harness

SOURCE_MODULES = (
    "bin/masc_tui_render_board.ml",
    "bin/masc_tui_render_board.mli",
    "bin/masc_tui.ml",
    "bin/masc_tui_loader.ml",
    "bin/masc_tui_keys.ml",
    "bin/masc_tui_render.ml",
    "test/tui_keyboard_chat.py",
    "test/tui_keyboard_harness.py",
    "test/tui_keyboard_observer.py",
    "test/tui_keyboard_tools.py",
)

CAUSE = b"synthetic board read unavailable"


def run(executable: str) -> None:
    fixtures = _keyboard_harness.overview_event_http_fixtures()
    post = _keyboard_harness.board_selection_post("vocab", "Failure vocabulary", "List body")
    hide_list_post = threading.Event()
    fixtures["/api/v1/board"] = lambda: (
        200,
        {"posts": [] if hide_list_post.is_set() else [post]},
    )
    fixtures["/api/v1/board?sort_by=hot"] = fixtures["/api/v1/board"]
    fixtures["/api/v1/board/post-vocab?format=flat"] = (
        503,
        {"error": CAUSE.decode()},
    )

    def check_frame(output: bytearray, layout: str, *, no_list_post: bool = False) -> None:
        frame = _keyboard_chat.unwrapped(_keyboard_harness.screen_text(bytes(output)))
        if CAUSE not in frame:
            raise AssertionError(f"{layout} lost the Board cause: {frame!r}")
        if frame.count(b"Board post load failed:") != 1:
            raise AssertionError(f"{layout} repeated the failure verdict: {frame!r}")
        if b"Board detail unavailable: Board post load failed:" in frame:
            raise AssertionError(f"{layout} repeated the failure state: {frame!r}")
        if no_list_post:
            if b"MASC Board / post-vocab" not in frame:
                raise AssertionError(f"{layout} did not use the fallback page: {frame!r}")
            if b"Failure vocabulary" in frame:
                raise AssertionError(f"{layout} retained the removed list post: {frame!r}")
            if b"Left / Esc:back r:refresh Tab:next" not in frame:
                raise AssertionError(f"{layout} lost the fallback controls: {frame!r}")

    def interact(process, fd, _slave, output, _base_path):
        _keyboard_harness.wait_for_output(process, fd, output, b"Health: ", start=0, timeout=10)
        _keyboard_harness.resize_and_wait(
            process, fd, output, rows=30, columns=160, needle=b"MASC Dashboard"
        )
        before_board = len(output)
        _keyboard_harness.palette_go(process, fd, output, b"go board", b"MASC Board")
        _keyboard_harness.wait_for_output(
            process, fd, output, b"Failure vocabulary", start=before_board, timeout=5
        )
        _keyboard_harness.wait_for_output(
            process,
            fd,
            output,
            _keyboard_harness.FRAME_END,
            start=_keyboard_harness.end_of_needle(output, b"Failure vocabulary", before_board),
            timeout=5,
        )
        list_frame = _keyboard_chat.unwrapped(_keyboard_harness.screen_text(bytes(output)))
        for hint in (b"Right / Enter:read", b"Left / Esc:back", b"v / V:up / down"):
            if hint not in list_frame:
                raise AssertionError(f"Board list lost {hint!r}: {list_frame!r}")
        _keyboard_harness.send_and_wait(process, fd, output, b"\r", CAUSE)
        check_frame(output, "Board read with list post")

        hide_list_post.set()
        before = len(output)
        _keyboard_harness.send_and_wait(process, fd, output, b"R", b"MASC Board / post-vocab")
        title_end = _keyboard_harness.end_of_needle(output, b"MASC Board / post-vocab", before)
        _keyboard_harness.wait_for_output(process, fd, output, CAUSE, start=title_end, timeout=5)
        _keyboard_harness.wait_for_output(
            process,
            fd,
            output,
            _keyboard_harness.FRAME_END,
            start=_keyboard_harness.end_of_needle(output, CAUSE, title_end),
            timeout=5,
        )
        check_frame(output, "Board read without list post", no_list_post=True)
        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b", b"MASC Board")
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(
        executable,
        description="Board detail failure is labelled once with or without list row",
        interact=interact,
        http_fixtures=fixtures,
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("Board detail failure once: PASS")
