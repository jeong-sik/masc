"""A stale health snapshot's fleet reading is drawn as a past one (#38499)."""
import os
import sys
import time
import test_tui_keyboard_input as h

# The sources this scenario stands over. scripts/ci/run-edited-tests.sh runs a
# suite when a pull request changes a path the suite names. The tag is worded
# in masc_tui_fleet_line.ml, read out of the body by tui_decode.ml, and drawn
# by the Keepers header and the Metrics readiness section.
SOURCE_MODULES = (
    "bin/masc_tui_fleet_line.ml",
    "bin/masc_tui_render.ml",
    "bin/masc_tui_render_metrics.ml",
    "lib/tui_decode.ml",
)

FLEET_PATH = "/health?full=1"
# The fleet fixture draws "turn capacity 0/0" on the Keepers header; waiting
# for it says the reading arrived.
FLEET_LINE = b"turn capacity 0/0"
STALE_TAG = b"fleet reading: stale \xc2\xb7 measured 4m"
REASON = b"(last_good_refresh_timeout)"
# Old enough that the age reads in minutes however long the TUI takes to ask.
STALE_AGE_SEC = 240
MAX_SCROLL_STEPS = 40


def screen_text(output: bytearray) -> bytes:
    rows = h.screen_rows(bytes(output))
    return b"\n".join(rows[row] for row in sorted(rows))


def with_snapshot(fixtures: h.HttpFixtures, snapshot: dict[str, object]) -> None:
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
    fixtures: h.HttpFixtures = {FLEET_PATH: h.fleet_safety_fixture()}

    def refresh_until(process, fd, output, needle: bytes) -> None:
        start = len(output)
        os.write(fd, b"r")
        h.wait_for_output(process, fd, output, needle, start=start, timeout=10)

    # The readiness rows close the Work section, below a thirty-row frame.
    def scroll_until(process, fd, output, needle: bytes) -> None:
        for _ in range(MAX_SCROLL_STEPS):
            h.read_available(fd, output)
            if needle in screen_text(output):
                return
            start = len(output)
            os.write(fd, b"j")
            h.wait_for_output(process, fd, output, h.FRAME_END, start=start, timeout=3)
        raise AssertionError(f"scrolled {MAX_SCROLL_STEPS} rows without reaching {needle!r}")

    def interact(process, fd, _slave, output, _base):
        h.send_and_wait(process, fd, output, b"2", b"MASC Keepers")
        h.wait_for_output(process, fd, output, FLEET_LINE, start=0, timeout=10)
        h.read_available(fd, output)
        if b"fleet reading:" in screen_text(output):
            raise AssertionError("a reading the latest refresh measured drew a stale tag")

        with_snapshot(fixtures, {
            "status": "stale",
            "computed_at_unix": time.time() - STALE_AGE_SEC,
            "stale_reason": "last_good_refresh_timeout",
        })
        refresh_until(process, fd, output, STALE_TAG)
        h.read_available(fd, output)
        keepers = screen_text(output)
        if REASON not in keepers:
            raise AssertionError("the stale tag does not carry the server's reason")
        # The counts stay on their own line: the tag is a row of its own, so
        # a narrow frame cutting from the right does not take the numbers.
        if FLEET_LINE not in keepers:
            raise AssertionError("the stale tag pushed the fleet counts off the header")

        h.palette_go(process, fd, output, b"go metrics", b"MASC Metrics")
        h.send_and_wait(process, fd, output, b"2", b"Retained task outcomes")
        scroll_until(process, fd, output, b"stale \xc2\xb7 measured 4m")

        # A read that failed is not a read that has not happened yet.
        fixtures[FLEET_PATH] = (503, {"error": "fleet fixture unavailable"})
        refresh_until(process, fd, output, b"Execution readiness: ")
        h.read_available(fd, output)
        metrics = screen_text(output)
        if b"Execution readiness not observed" in metrics:
            raise AssertionError("a failed fleet read drew as one never made")
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="Fleet reading says when it was measured",
        interact=interact,
        http_fixtures=fixtures,
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("fleet reading says when it was measured: PASS")
