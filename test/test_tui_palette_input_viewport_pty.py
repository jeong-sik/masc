"""Long palette filters retain the edited tail and caret across resize."""
import os
import sys
import test_tui_keyboard_input as h

SOURCE_MODULES = ("bin/masc_tui_render.ml",)


def run(executable, no_color=False):
    query = ("long-query-" * 12 + "한글입력TAIL987").encode()
    caret = "▌".encode()

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b"Health: ", start=0, timeout=10)
        h.send_and_wait(process, fd, output, b":", b"MASC Command palette")
        h.send_and_wait(process, fd, output,
                        b"\x1b[200~" + query + b"\x1b[201~", b"(no match)")
        for width in (40, 60, 120, 28, 31):
            h.resize_and_wait(process, fd, output, rows=24, columns=width,
                              needle=b"(no match)", controls=(h.FULL_REDRAW,))
            screen = h.screen_text(bytes(output))
            if b"TAIL987" + caret not in screen:
                raise AssertionError(f"{width} columns hide filter tail or caret: {screen!r}")
        h.send_and_wait(process, fd, output, "끝".encode(), "끝".encode())
        screen = h.screen_text(bytes(output))
        if "끝▌".encode() not in screen:
            raise AssertionError(f"31 columns hide last Korean glyph: {screen!r}")
        h.send_and_wait(process, fd, output, b"\x7f", b"TAIL987")
        h.send_and_wait(process, fd, output, b"\x7f", b"TAIL98")
        screen = h.screen_text(bytes(output))
        if b"TAIL98" + caret not in screen or b"TAIL987" in screen:
            raise AssertionError(f"Backspace did not update visible filter tail: {screen!r}")
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Dashboard")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable,
        description="Palette edited tail remains visible" + (" without color" if no_color else ""),
        interact=interact, http_fixtures=h.overview_event_http_fixtures(),
        extra_env={"NO_COLOR": "1"} if no_color else {})


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    run(os.path.abspath(sys.argv[1]), no_color=True)
    print("Palette input tail and caret: PASS")
