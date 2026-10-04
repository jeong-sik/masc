"""A stale health snapshot's fleet reading is drawn as a past one (#38499)."""
import os
import sys
import time
import tui_keyboard_harness as _keyboard_harness



FLEET_PATH = "/health?full=1"
# The fleet fixture draws "turn capacity 0/0" on the Keepers header; waiting
# for it says the reading arrived.
FLEET_LINE = b"turn capacity 0/0"
STALE_TAG = b"fleet reading: stale \xc2\xb7 measured 4m"
# The server's wire word is said in words (#39194): the /health contract's
# last_good_refresh_timeout draws as "refresh timed out".
REASON = b"(refresh timed out)"
# Four minutes back, so the age reads "4m…" for the first minute after the
# fixture is swapped; the scenario reaches both checks within seconds.
STALE_AGE_SEC = 240
MAX_SCROLL_STEPS = 40


def screen_text(output: bytearray) -> bytes:
    rows = _keyboard_harness.screen_rows(bytes(output))
    return b"\n".join(rows[row] for row in sorted(rows))


def with_snapshot(fixtures: _keyboard_harness.HttpFixtures, snapshot: dict[str, object]) -> None:
    # In place, and on the merged body, so the paths block the harness filled
    # in stays: only how current the reading is changes.
    existing = fixtures[FLEET_PATH]
    if not isinstance(existing, tuple):
        raise AssertionError(f"the fleet fixture is not a status and body: {existing!r}")
    status, body = existing
    if not isinstance(body, dict):
        raise AssertionError(f"the fleet fixture body is not an object: {body!r}")
    fixtures[FLEET_PATH] = (status, {**body, "full_health_snapshot": snapshot})


def run(executable: str) -> None:
    fixtures: _keyboard_harness.HttpFixtures = {FLEET_PATH: _keyboard_harness.fleet_safety_fixture()}

    def refresh_until(process, fd, output, needle: bytes) -> None:
        start = len(output)
        os.write(fd, b"r")
        _keyboard_harness.wait_for_output(process, fd, output, needle, start=start, timeout=10)

    # The readiness rows close the Work section, below a thirty-row frame. A
    # [j] at the end of the section draws nothing, so no new frame means the
    # whole section has been on screen without the needle.
    def scroll_until(process, fd, output, needle: bytes) -> None:
        for _ in range(MAX_SCROLL_STEPS):
            _keyboard_harness.read_available(fd, output)
            if needle in screen_text(output):
                return
            start = len(output)
            os.write(fd, b"j")
            if not _keyboard_harness.poll_for_output(
                process, fd, output, _keyboard_harness.FRAME_END, start=start, timeout=3
            ):
                break
        raise AssertionError(f"the Work section never showed {needle!r}")

    def interact(process, fd, _slave, output, _base):
        _keyboard_harness.send_and_wait(process, fd, output, b"3", b"MASC Keepers")
        _keyboard_harness.wait_for_output(process, fd, output, FLEET_LINE, start=0, timeout=10)
        _keyboard_harness.read_available(fd, output)
        if b"fleet reading:" in screen_text(output):
            raise AssertionError("a reading the latest refresh measured drew a stale tag")

        with_snapshot(fixtures, {
            "status": "stale",
            "computed_at_unix": time.time() - STALE_AGE_SEC,
            "stale_reason": "last_good_refresh_timeout",
        })
        refresh_until(process, fd, output, STALE_TAG)
        _keyboard_harness.read_available(fd, output)
        keepers = screen_text(output)
        if REASON not in keepers:
            raise AssertionError("the stale tag does not carry the server's reason")
        # The counts stay on their own line: the tag is a row of its own, so
        # a narrow frame cutting from the right does not take the numbers.
        if FLEET_LINE not in keepers:
            raise AssertionError("the stale tag pushed the fleet counts off the header")

        _keyboard_harness.palette_go(process, fd, output, b"go Usage", b"MASC Usage")
        _keyboard_harness.send_and_wait(process, fd, output, b"p", b"MASC Usage / Telemetry")
        _keyboard_harness.send_and_wait(process, fd, output, b"2", b"Retained task outcomes")
        scroll_until(process, fd, output, b"stale \xc2\xb7 measured 4m")

        # A read that failed is not a read that has not happened yet.
        fixtures[FLEET_PATH] = (503, {"error": "fleet fixture unavailable"})
        refresh_until(process, fd, output, b"Execution readiness: ")
        _keyboard_harness.read_available(fd, output)
        metrics = screen_text(output)
        if b"Execution readiness not observed" in metrics:
            raise AssertionError("a failed fleet read drew as one never made")
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(
        executable,
        description="Fleet reading says when it was measured",
        interact=interact,
        http_fixtures=fixtures,
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("fleet reading says when it was measured: PASS")
