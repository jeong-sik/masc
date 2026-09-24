"""Connector read failures keep one source verdict on the Keeper Channels tab."""

import os
import sys

import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui.ml",
    "bin/masc_tui_loader.ml",
    "bin/masc_tui_render.ml",
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
        fixtures = h.keeper_runtime_http_fixtures()
        fixtures[CONNECTORS] = h.SequencedHttpResponse(responses)

        def interact(process, fd, _slave, output, _base_path):
            h.resize_and_wait(
                process, fd, output, rows=30, columns=160, needle=b"MASC Overview"
            )
            h.send_and_wait(process, fd, output, b"2", b"MASC Keepers")
            h.select_keeper_row(process, fd, output, b"alpha")
            h.send_and_wait(process, fd, output, b"\r", b"\xe2\x96\xb8Info")
            h.send_and_wait(process, fd, output, b"[", b"\xe2\x96\xb8Runs")
            h.send_and_wait(process, fd, output, b"[", b"\xe2\x96\xb8Automation")
            h.send_and_wait(process, fd, output, b"[", b"\xe2\x96\xb8Channels")
            if stale:
                h.wait_for_output(process, fd, output, b"0 transports", start=0, timeout=5)
                drawn = h.send_and_wait(process, fd, output, b"r", b"STALE")
            else:
                h.wait_for_output(
                    process, fd, output, b"connector load failed:", start=0, timeout=5
                )
                h.drain_until_quiet(process, fd, output)
                drawn = bytes(output)
            frame = h.unwrapped(h.screen_text(drawn))
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
            h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
            os.write(fd, b"q")

        h.run_terminal_scenario(
            executable,
            description=f"Keeper Channels shows one {kind} connector failure",
            interact=interact,
            http_fixtures=fixtures,
        )

    fixtures = h.keeper_runtime_http_fixtures()
    fixtures[CONNECTORS] = (503, {"error": "synthetic connector offline"})

    def list_interaction(process, fd, _slave, output, _base_path):
        h.resize_and_wait(
            process, fd, output, rows=30, columns=160, needle=b"MASC Overview"
        )
        h.palette_go(process, fd, output, b"go Connectors", b"MASC Connectors")
        h.wait_for_output(
            process, fd, output, b"connector load failed:", start=0, timeout=5
        )
        h.drain_until_quiet(process, fd, output)
        frame = h.unwrapped(h.screen_text(bytes(output)))
        if b"synthetic connector offline" not in frame:
            raise AssertionError(f"Connector list lost the failure cause: {frame!r}")
        if frame.count(b"load failed") != 1:
            raise AssertionError(f"Connector title repeated the body verdict: {frame!r}")
        # Connectors Esc returns to the selected Keeper detail.
        h.send_and_wait(process, fd, output, b"\x1b", b"Current Work")
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="Connector list shows one failure verdict",
        interact=list_interaction,
        http_fixtures=fixtures,
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("Keeper Channels connector errors: PASS")
