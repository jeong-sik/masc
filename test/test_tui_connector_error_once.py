"""Connector read failures keep one source verdict on the Keeper Channels tab."""

import os
import sys

import tui_keyboard_chat as _keyboard_chat
import tui_keyboard_harness as _keyboard_harness

SOURCE_MODULES = (
    'bin/masc_tui.ml',
    'bin/masc_tui_loader.ml',
    'bin/masc_tui_render.ml',
    'lib/tui_decode_connectors.ml',
    'lib/tui_decode_connectors.mli',
    'test/tui_keyboard_chat.py',
    'test/tui_keyboard_harness.py',
    'test/tui_keyboard_observer.py',
    'test/tui_keyboard_tools.py',
)

CONNECTORS = "/api/v1/gate/connectors"
EMPTY = (200, {"connectors": [], "total": 0, "active_count": 0})


def run(executable: str) -> None:
    for kind, responses, cause, stale in (
        (
            "first HTTP",
            [(503, {"error": "synthetic connector offline"})],
            b"synthetic connector offline",
            False,
        ),
        (
            "stale HTTP",
            [EMPTY, (503, {"error": "synthetic connector offline"})],
            b"synthetic connector offline",
            True,
        ),
        ("stale decode", [EMPTY, (200, {})], b"connectors", True),
    ):
        fixtures = _keyboard_harness.keeper_runtime_http_fixtures()
        fixtures[CONNECTORS] = _keyboard_harness.SequencedHttpResponse(responses)

        def interact(process, fd, _slave, output, _base_path):
            _keyboard_harness.resize_and_wait(
                process, fd, output, rows=30, columns=160, needle=b"MASC Dashboard"
            )
            _keyboard_harness.send_and_wait(process, fd, output, b"3", b"MASC Keepers")
            _keyboard_harness.select_keeper_row(process, fd, output, b"alpha")
            _keyboard_harness.send_and_wait(process, fd, output, b"\r", b"\xe2\x96\xb8Info")
            _keyboard_harness.send_and_wait(process, fd, output, b"[", b"\xe2\x96\xb8Runs")
            _keyboard_harness.send_and_wait(process, fd, output, b"[", b"\xe2\x96\xb8Automation")
            _keyboard_harness.send_and_wait(process, fd, output, b"[", b"\xe2\x96\xb8Channels")
            if stale:
                _keyboard_harness.wait_for_output(process, fd, output, b"0 transports", start=0, timeout=5)
                drawn = _keyboard_harness.send_and_wait(process, fd, output, b"r", b"STALE")
            else:
                _keyboard_harness.wait_for_output(
                    process, fd, output, b"connector load failed:", start=0, timeout=5
                )
                _keyboard_harness.drain_until_quiet(process, fd, output)
                drawn = bytes(output)
            frame = _keyboard_chat.unwrapped(_keyboard_harness.screen_text(drawn))
            expected = (
                b"STALE \xc2\xb7 connector load failed:"
                if stale
                else b"connector load failed:"
            )
            if expected not in frame or cause not in frame:
                raise AssertionError(f"Channels lost its failure cause: {frame!r}")
            if frame.count(b"connector load failed:") != 1:
                raise AssertionError(f"Channels repeated its failure: {frame!r}")
            if b"channel transports unavailable: connector load failed:" in frame:
                raise AssertionError(f"Channels repeated its subject: {frame!r}")
            _keyboard_harness.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
            os.write(fd, b"q")

        _keyboard_harness.run_terminal_scenario(
            executable,
            description=f"Keeper Channels shows one {kind} connector failure",
            interact=interact,
            http_fixtures=fixtures,
        )

    fixtures = _keyboard_harness.keeper_runtime_http_fixtures()
    fixtures[CONNECTORS] = (503, {"error": "synthetic connector offline"})

    def list_interaction(process, fd, _slave, output, _base_path):
        _keyboard_harness.resize_and_wait(
            process, fd, output, rows=30, columns=160, needle=b"MASC Dashboard"
        )
        _keyboard_harness.palette_go(process, fd, output, b"go Connectors", b"MASC Connectors")
        _keyboard_harness.wait_for_output(
            process, fd, output, b"connector load failed:", start=0, timeout=5
        )
        _keyboard_harness.drain_until_quiet(process, fd, output)
        frame = _keyboard_chat.unwrapped(_keyboard_harness.screen_text(bytes(output)))
        if b"synthetic connector offline" not in frame:
            raise AssertionError(f"Connector list lost the failure cause: {frame!r}")
        if frame.count(b"load failed") != 1:
            raise AssertionError(f"Connector title repeated the body verdict: {frame!r}")
        # Connectors Esc returns to the selected Keeper detail, so a Keeper
        # has to be selected before Esc. The roster read is asynchronous and
        # nothing above waits for it: pressed before it lands, Esc opens a
        # detail that says "No keeper selected.", and the roster that lands
        # next sends the view back to the Keeper list. The composer row reads
        # "› to <keeper>" only once the roster is read and its cursor names a
        # Keeper; until then it reads "› no keeper selected".
        _keyboard_harness.wait_for_output(process, fd, output, b"\xe2\x80\xba to alpha", start=0, timeout=5)
        # "Current failure" is the first section under Identity, so it is on
        # the first screen of the detail whether or not the portrait opens
        # Info. Later sections such as Current Work sit below the fold once the
        # portrait band is drawn at the harness height.
        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b", b"Current failure")
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(
        executable,
        description="Connector list shows one failure verdict",
        interact=list_interaction,
        http_fixtures=fixtures,
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("Keeper Channels connector errors: PASS")
