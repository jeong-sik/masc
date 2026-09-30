"""Keeper Automation names a schedule read failure once with its cause."""

import os
import sys

import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui.ml",
    "bin/masc_tui_loader.ml",
    "bin/masc_tui_render.ml",
)

SCHEDULES = "/api/v1/dashboard/scheduled-automation"


def run(executable: str) -> None:
    for kind, response, cause in (
        (
            "HTTP",
            (503, {"error": "synthetic Keeper schedule offline"}),
            b"synthetic Keeper schedule offline",
        ),
        ("decode", (200, {}), b"status"),
    ):
        fixtures = h.keeper_runtime_http_fixtures()
        for value in ("keeper%3Aalpha", "keeper%3aalpha", "keeper:alpha"):
            fixtures[f"{SCHEDULES}?payload_target={value}"] = response

        def interact(process, fd, _slave, output, _base_path):
            h.resize_and_wait(
                process, fd, output, rows=30, columns=160, needle=b"MASC Dashboard"
            )
            h.send_and_wait(process, fd, output, b"3", b"MASC Keepers")
            h.select_keeper_row(process, fd, output, b"alpha")
            h.send_and_wait(process, fd, output, b"\r", b"\xe2\x96\xb8Info")
            h.send_and_wait(process, fd, output, b"[", b"\xe2\x96\xb8Runs")
            before = len(output)
            h.send_and_wait(process, fd, output, b"[", b"\xe2\x96\xb8Automation")
            failure = b"keeper schedule load failed:"
            h.wait_for_output(process, fd, output, failure, start=before, timeout=5)
            h.wait_for_output(
                process,
                fd,
                output,
                h.FRAME_END,
                start=h.end_of_needle(output, failure, before),
                timeout=5,
            )
            frame = h.unwrapped(h.screen_text(bytes(output)))
            if cause not in frame:
                raise AssertionError(f"Automation lost the {kind} cause: {frame!r}")
            if frame.count(failure) != 1:
                raise AssertionError(f"Automation repeated the verdict: {frame!r}")
            # The source is named once in the whole frame, not only once
            # in front of "load failed:": a cause that still carries its
            # own "keeper schedule" prefix names the source twice.
            if frame.count(b"keeper schedule") != 1:
                raise AssertionError(f"Automation named the source twice: {frame!r}")
            if b"schedules unavailable: keeper schedule load failed:" in frame:
                raise AssertionError(f"Automation repeated the status: {frame!r}")
            h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
            os.write(fd, b"q")

        h.run_terminal_scenario(
            executable,
            description=f"Keeper Automation shows one {kind} read failure",
            interact=interact,
            http_fixtures=fixtures,
        )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("Keeper Automation schedule error once: PASS")
