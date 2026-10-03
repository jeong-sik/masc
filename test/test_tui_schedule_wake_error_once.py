"""Schedule detail keeps the wake-history cause without a second verdict."""

import os
import sys

import tui_keyboard_chat as _keyboard_chat
import tui_keyboard_harness as _keyboard_harness
import tui_keyboard_schedule as _keyboard_schedule




def run(executable: str) -> None:
    for kind, response, cause, verdict in (
        (
            "HTTP",
            (503, {"error": "synthetic wake history offline"}),
            b"synthetic wake history offline",
            b"schedule detail load failed:",
        ),
        (
            "lookup",
            (
                200,
                {
                    "status": "unavailable",
                    "schedule_id": "schedule-proof-701",
                    "reason": "synthetic wake store unreadable",
                },
            ),
            b"synthetic wake store unreadable",
            b"schedule lookup unavailable:",
        ),
    ):
        fixtures = _keyboard_schedule.schedule_detail_http_fixtures()
        fixtures[_keyboard_schedule.SCHEDULES_PATH + "?schedule_id=schedule-proof-701"] = response

        def interact(process, fd, _slave, output, _base_path):
            _keyboard_harness.palette_go(
                process, fd, output, b"go schedules", b"status:running"
            )
            _keyboard_harness.send_and_wait(process, fd, output, b"\x1b[C", b"instance-proof-701")
            _keyboard_harness.send_and_wait(
                process, fd, output, b"\x1b[6~", b"Wake history:"
            )
            frame = _keyboard_chat.unwrapped(_keyboard_harness.screen_text(bytes(output)))
            for needle in (b"Wake history:", cause, verdict):
                if needle not in frame:
                    raise AssertionError(
                        f"Schedule {kind} wake failure lost {needle!r}: {frame!r}"
                    )
            if frame.count(b"Wake history:") != 1 or frame.count(verdict) != 1:
                raise AssertionError(
                    f"Schedule {kind} wake failure repeated its verdict: {frame!r}"
                )
            if b"wake history unavailable:" in frame:
                raise AssertionError(
                    f"Schedule {kind} wake failure added another verdict: {frame!r}"
                )
            os.write(fd, b"q")

        _keyboard_harness.run_terminal_scenario(
            executable,
            description=f"Schedule wake {kind} failure says its cause once",
            interact=interact,
            http_fixtures=fixtures,
        )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("Schedule wake error once: PASS")
