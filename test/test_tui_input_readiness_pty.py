"""Exercise input ownership across waits, terminal resize, paste and exit."""
import os
import signal
import sys

import test_tui_keyboard_input as h

SOURCE_MODULES = ("bin/masc_tui.ml", "lib/core/eio_guard.ml")


def open_chat(process, fd, output):
    h.send_and_wait(process, fd, output, b"3", b"MASC Keepers")
    h.select_keeper_row(process, fd, output, b"alpha")
    title = b"Keepers \xe2\x96\xb8 \x1b[1malpha"
    h.send_and_wait(process, fd, output, b"\r", title)
    h.send_and_wait(process, fd, output, b"m",
                    b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")


def fragmented_unicode(process, fd, slave, output, _base):
    open_chat(process, fd, output)
    expected = ""
    for text, split, rows in (("한", 1, 29), ("🙂", 2, 30)):
        encoded = text.encode()
        h.write_all(fd, output, encoded[:split])
        h.wait_for_terminal_input_consumed(slave)
        # A completed resized frame proves the main loop advanced after the
        # incomplete scalar. It does not rely on a sleep to guess that the
        # decoder's continuation timeout expired.
        h.resize_and_wait(process, fd, output, rows=rows, columns=100,
            needle=b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat",
            controls=(h.FULL_REDRAW,), final_cursor=b"\x1b[?25h")
        expected += text
        h.send_and_wait(process, fd, output, encoded[split:],
                        h.composer_showing(expected.encode()))
    h.send_and_wait(process, fd, output, b"\x7f", h.composer_showing("한".encode()))
    h.escape_to_keeper_detail(process, fd, output, name=b"alpha")
    os.write(fd, b"q")


def terminate_incomplete_scalar(process, fd, slave, output, _base):
    open_chat(process, fd, output)
    h.write_all(fd, output, "🙂".encode()[:1])
    h.wait_for_terminal_input_consumed(slave)
    # No continuation or confirming key is supplied. The harness checks
    # exit status, Goodbye and the original terminal mode after SIGTERM.
    os.killpg(process.pid, signal.SIGTERM)


def run(executable):
    captured = []
    h.run_terminal_scenario(executable,
        description="Eio input preserves Unicode, malformed bytes and resize",
        interact=h.utf8_message_interaction(captured),
        http_fixtures={"/api/v1/keepers/chat/stream":
                       (503, {"error": "stop after UTF-8 request capture"})},
        http_requests=captured)
    h.run_terminal_scenario(executable,
        description="Eio input resumes fragmented Unicode after completed resize",
        interact=fragmented_unicode)
    pasted = []
    h.run_terminal_scenario(executable,
        description="Eio input preserves bracketed paste bytes",
        interact=h.bracketed_paste_interaction(pasted),
        http_fixtures={"/api/v1/keepers/chat/stream":
                       (503, {"error": "stop after paste request capture"})},
        http_requests=pasted)
    h.run_terminal_scenario(executable,
        description="Eio input exits during an incomplete scalar",
        interact=terminate_incomplete_scalar, confirm_exit=b"")
    print("input readiness ownership: PASS")


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
