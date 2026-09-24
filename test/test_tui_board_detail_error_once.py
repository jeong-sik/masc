"""A Board post read failure has one verdict in both read layouts."""

import os
import sys
import threading

import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui.ml",
    "bin/masc_tui_loader.ml",
    "bin/masc_tui_render.ml",
)

CAUSE = b"synthetic board read unavailable"


def run(executable: str) -> None:
    fixtures = h.overview_event_http_fixtures()
    post = h.board_selection_post("vocab", "Failure vocabulary", "List body")
    hide_list_post = threading.Event()
    fixtures["/api/v1/board?sort_by=hot"] = lambda: (
        200,
        {"posts": [] if hide_list_post.is_set() else [post]},
    )
    fixtures["/api/v1/board/post-vocab?format=flat"] = (
        503,
        {"error": CAUSE.decode()},
    )

    def check_frame(output: bytearray, layout: str) -> None:
        frame = h.unwrapped(h.screen_text(bytes(output)))
        if CAUSE not in frame:
            raise AssertionError(f"{layout} lost the Board cause: {frame!r}")
        if frame.count(b"Board post load failed:") != 1:
            raise AssertionError(f"{layout} repeated the failure verdict: {frame!r}")
        if b"Board detail unavailable: Board post load failed:" in frame:
            raise AssertionError(f"{layout} repeated the failure state: {frame!r}")

    def interact(process, fd, _slave, output, _base_path):
        h.wait_for_output(process, fd, output, b"Health: ", start=0, timeout=10)
        h.resize_and_wait(
            process, fd, output, rows=30, columns=160, needle=b"MASC Overview"
        )
        h.palette_go(process, fd, output, b"go board", b"MASC Board")
        h.send_and_wait(process, fd, output, b"\r", CAUSE)
        check_frame(output, "Board read with list post")

        hide_list_post.set()
        before = len(output)
        h.send_and_wait(process, fd, output, b"R", b"MASC Board / post-vocab")
        title_end = h.end_of_needle(output, b"MASC Board / post-vocab", before)
        h.wait_for_output(process, fd, output, CAUSE, start=title_end, timeout=5)
        h.wait_for_output(
            process,
            fd,
            output,
            h.FRAME_END,
            start=h.end_of_needle(output, CAUSE, title_end),
            timeout=5,
        )
        check_frame(output, "Board read without list post")
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Board")
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="Board detail failure is labelled once with or without list row",
        interact=interact,
        http_fixtures=fixtures,
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("Board detail failure once: PASS")
