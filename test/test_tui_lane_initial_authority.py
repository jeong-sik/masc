"""An early Lane navigation resumes when initial workspace authority arrives."""

import os
import sys

import test_tui_keyboard_input as h

SOURCE_MODULES = ("bin/masc_tui.ml", "bin/masc_tui_types.ml")


def run(executable):
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures[h.STANDALONE_LANES_PATH] = h.standalone_lanes_response()
    health = h.GatedHttpResponse((200, {}), subsequent_response=(200, {}))
    fixtures["/health"] = health

    def interact(process, master, _slave, output, _base):
        try:
            assert h.wait_for_fixture_event(
                process, master, output, health.requested, timeout=3.0
            )
            h.palette_go(process, master, output, b"go lanes", b"MASC Lanes")
            # No readiness barrier: the user has already entered Lanes while
            # the initial authority reading is still held by the fixture.
            assert h.wait_for_fixture_event(
                process, master, output, health.subsequent_requested, timeout=3.0
            )
            health.release.set()
            h.wait_for_output(
                process, master, output, b"Librarian", start=0, timeout=3.0
            )
            h.send_and_wait(process, master, output, b"/Librarian", b"Librarian")
            os.write(master, b"q")
        finally:
            health.release.set()

    h.run_terminal_scenario(
        executable,
        description="early Lane navigation resumes after initial workspace confirmation",
        interact=interact,
        http_fixtures=fixtures,
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("TUI early Lane authority recovery: PASS")
