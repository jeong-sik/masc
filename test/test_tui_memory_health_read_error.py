"""A failed first Memory health read has one cause and unavailable counts."""

import os
import sys

import tui_keyboard_harness as _keyboard_harness
import tui_keyboard_memory as _keyboard_memory



ERROR = b"memory health load failed: HTTP 503: fixture memory unavailable"


def run(executable: str) -> None:
    fixtures = _keyboard_memory.memory_facts_http_fixtures()
    fixtures["/api/v1/dashboard/keeper-memory-health"] = (
        503, {"error": "fixture memory unavailable"}
    )

    def interact(process, fd, _slave, output, _base):
        _keyboard_harness.palette_go(process, fd, output, b"go memory", b"MASC Memory")
        _keyboard_harness.wait_for_output(process, fd, output, ERROR, start=0, timeout=10)
        _keyboard_harness.resize_and_wait(
            process, fd, output, rows=30, columns=160,
            needle=ERROR, controls=(_keyboard_harness.FULL_REDRAW,),
            final_cursor=b"\x1b[?25l",
        )
        screen = _keyboard_harness.screen_text(bytes(output))
        if screen.count(ERROR) != 1 or screen.count(b"load failed") != 1:
            raise AssertionError(f"Memory repeated or lost the cause: {screen!r}")
        for label in (b"Total:", b"Librarian:"):
            rows = [row for row in screen.splitlines() if label in row]
            if len(rows) != 1 or b"\xe2\x80\x94" not in rows[0]:
                raise AssertionError(
                    f"Memory did not mark {label!r} unavailable: {screen!r}"
                )
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(
        executable,
        description="Memory health first read failure is shown once",
        interact=interact,
        http_fixtures=fixtures,
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("Memory health first read failure once: PASS")
