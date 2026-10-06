"""An early Lane navigation resumes when initial workspace authority arrives."""

import os
import sys

import tui_keyboard_harness as _keyboard_harness
import tui_keyboard_keepers as _keyboard_keepers

SOURCE_MODULES = ("bin/masc_tui.ml", "bin/masc_tui_types.ml")


def run(executable):
    fixtures = _keyboard_harness.keeper_runtime_http_fixtures()
    fixtures[_keyboard_keepers.LANE_INVENTORY_PATH] = _keyboard_keepers.lane_inventory_response()
    health = _keyboard_harness.GatedHttpResponse(
        (200, {}), subsequent_response=(200, {}), hold_seconds=20.0
    )
    fixtures["/health"] = health

    def interact(process, master, _slave, output, _base):
        try:
            assert _keyboard_harness.wait_for_fixture_event(
                process, master, output, health.requested, timeout=3.0
            )
            _keyboard_harness.palette_go(process, master, output, b"go lanes", b"MASC Lanes")
            # No readiness barrier: the user has already entered Lanes while
            # the initial authority reading is still held by the fixture.
            assert _keyboard_harness.wait_for_fixture_event(
                process, master, output, health.subsequent_requested, timeout=3.0
            )
            _keyboard_harness.wait_for_output(
                process,
                master,
                output,
                b"Workspace identity changed or is unavailable",
                start=0,
                timeout=3.0,
            )
            assert not health.completed.is_set(), (
                "initial health escaped the fixture gate"
            )
            health.release.set()
            _keyboard_harness.wait_for_output(
                process, master, output, b"Librarian", start=0, timeout=3.0
            )
            _keyboard_harness.send_and_wait(process, master, output, b"/Librarian", b"Librarian")
            os.write(master, b"q")
        finally:
            health.release.set()

    _keyboard_harness.run_terminal_scenario(
        executable,
        description="early Lane navigation resumes after initial workspace confirmation",
        interact=interact,
        http_fixtures=fixtures,
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("TUI early Lane authority recovery: PASS")
