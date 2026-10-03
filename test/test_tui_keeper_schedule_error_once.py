"""Keeper Automation names a schedule read failure once with its cause."""

import os
import sys

import tui_keyboard_chat as _keyboard_chat
import tui_keyboard_harness as _keyboard_harness



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
        fixtures = _keyboard_harness.keeper_runtime_http_fixtures()
        for value in ("keeper%3Aalpha", "keeper%3aalpha", "keeper:alpha"):
            fixtures[f"{SCHEDULES}?payload_target={value}"] = response

        def interact(process, fd, _slave, output, _base_path):
            _keyboard_harness.resize_and_wait(
                process, fd, output, rows=30, columns=160, needle=b"MASC Dashboard"
            )
            _keyboard_harness.send_and_wait(process, fd, output, b"3", b"MASC Keepers")
            _keyboard_harness.select_keeper_row(process, fd, output, b"alpha")
            _keyboard_harness.send_and_wait(process, fd, output, b"\r", b"\xe2\x96\xb8Info")
            _keyboard_harness.send_and_wait(process, fd, output, b"[", b"\xe2\x96\xb8Runs")
            before = len(output)
            _keyboard_harness.send_and_wait(process, fd, output, b"[", b"\xe2\x96\xb8Automation")
            failure = b"keeper schedule load failed:"
            _keyboard_harness.wait_for_output(process, fd, output, failure, start=before, timeout=5)
            _keyboard_harness.wait_for_output(
                process,
                fd,
                output,
                _keyboard_harness.FRAME_END,
                start=_keyboard_harness.end_of_needle(output, failure, before),
                timeout=5,
            )
            frame = _keyboard_chat.unwrapped(_keyboard_harness.screen_text(bytes(output)))
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
            _keyboard_harness.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
            os.write(fd, b"q")

        _keyboard_harness.run_terminal_scenario(
            executable,
            description=f"Keeper Automation shows one {kind} read failure",
            interact=interact,
            http_fixtures=fixtures,
        )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("Keeper Automation schedule error once: PASS")
