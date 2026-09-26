"""A failed first Memory health read has one cause and unavailable counts."""

import os
import sys

import test_tui_keyboard_input as h

SOURCE_MODULES = ("bin/masc_tui_render.ml", "bin/masc_tui_render_memory.ml")

ERROR = b"memory health load failed: HTTP 503: fixture memory unavailable"


def run(executable: str) -> None:
    fixtures = h.memory_facts_http_fixtures()
    fixtures["/api/v1/dashboard/keeper-memory-health"] = (
        503, {"error": "fixture memory unavailable"}
    )

    def interact(process, fd, _slave, output, _base):
        h.tab_until(process, fd, output, b"MASC Memory")
        h.wait_for_output(process, fd, output, ERROR, start=0, timeout=10)
        h.resize_and_wait(
            process, fd, output, rows=30, columns=160,
            needle=ERROR, controls=(h.FULL_REDRAW,),
            final_cursor=b"\x1b[?25l",
        )
        screen = h.screen_text(bytes(output))
        if screen.count(ERROR) != 1 or screen.count(b"load failed") != 1:
            raise AssertionError(f"Memory repeated or lost the cause: {screen!r}")
        for label in (b"Total:", b"Librarian:"):
            rows = [row for row in screen.splitlines() if label in row]
            if len(rows) != 1 or b"\xe2\x80\x94" not in rows[0]:
                raise AssertionError(
                    f"Memory did not mark {label!r} unavailable: {screen!r}"
                )
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="Memory health first read failure is shown once",
        interact=interact,
        http_fixtures=fixtures,
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("Memory health first read failure once: PASS")
