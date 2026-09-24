"""A held schedule says when the runner checked it, unless the runner is ok.

The schedule runner re-reads which occurrences it holds only on a tick that
succeeds. While its ticks fail, the list keeps the hold from the last good
tick, so the Schedules screen draws that hold at the time it was checked
instead of as the present (#38411). A list the TUI keeps on screen after a
failed reload is an earlier answer, so its hold is drawn the same way.
"""
import calendar
import copy
import os
import sys
import threading

import test_tui_keyboard_input as h

# The sources this scenario stands over. scripts/ci/run-edited-tests.sh runs a
# suite when a pull request changes a path the suite names. The hold is decoded
# in tui_decode.ml, which also decides current against checked-at; both lines
# are drawn in masc_tui_render.ml with the words in masc_tui_render_schedule.ml.
SOURCE_MODULES = (
    "lib/tui_decode.ml",
    "bin/masc_tui_render.ml",
    "bin/masc_tui_render_schedule.ml",
)

IDENTITY = b"schedule-proof-701 \xc2\xb7 status:"
HELD_ID = b"occurrence-proof-702"
# The terminal's clock, not the wire's: the scenario runs under TZ=UTC so the
# expected readings are the same on every machine.
CHECKED = b"held as of 2026-08-25 09:45:30"
CURRENT = b"held since 2026-08-25 09:40:00"


def fixtures_with_hold(runner_status: str):
    fixtures = h.schedule_detail_http_fixtures()
    payload = copy.deepcopy(fixtures[h.SCHEDULES_PATH][1])
    payload["schedule_runner"] = {**h.SCHEDULE_RUNNER_OK, "status": runner_status}
    row = payload["requests"][0]
    row["status"] = "due"
    row["runner_hold"] = {
        "occurrence_id": HELD_ID.decode(),
        "due_at": float(calendar.timegm((2026, 8, 25, 9, 40, 0))),
        "due_at_iso": "2026-08-25T09:40:00Z",
        "observed_at": float(calendar.timegm((2026, 8, 25, 9, 45, 30))),
        "observed_at_iso": "2026-08-25T09:45:30Z",
    }
    fixtures[h.SCHEDULES_PATH] = (200, payload)
    return fixtures


def screen_line(output: bytearray, needle: bytes) -> bytes:
    rows = h.screen_rows(bytes(output))
    index = h.screen_row_of(rows, needle)
    if index < 0:
        raise AssertionError(
            f"no row on screen carries {needle!r}: {h.screen_text(bytes(output))!r}")
    return rows[index]


def check(executable: str, runner_status: str, shown: bytes, hidden: bytes) -> None:
    def interact(process, fd, _slave, output, _base_path):
        h.palette_go(process, fd, output, b"go schedules", b"MASC Keepers / Schedules")
        h.resize_and_wait(process, fd, output, rows=40, columns=120,
                          needle=shown, controls=(h.FULL_REDRAW,))
        # The identity line under the list names the selected schedule, its
        # status and the hold, on one line.
        identity = screen_line(output, IDENTITY)
        if shown not in identity or hidden in identity:
            raise AssertionError(
                f"runner {runner_status}: the identity line should read {shown!r} "
                f"and not {hidden!r}: {identity!r}")
        h.send_and_wait(process, fd, output, b"\x1b[C", b"instance-proof-701")
        h.send_and_wait(process, fd, output, b"\x1b[6~", HELD_ID)
        held = screen_line(output, b"Held  ")
        if shown not in held or hidden in held:
            raise AssertionError(
                f"runner {runner_status}: the detail's Held row should read {shown!r} "
                f"and not {hidden!r}: {held!r}")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable,
                            description=f"Schedules hold with the runner {runner_status}",
                            interact=interact,
                            http_fixtures=fixtures_with_hold(runner_status),
                            extra_env={"TZ": "UTC"})


def check_kept_after_a_failed_reload(executable: str) -> None:
    fixtures = fixtures_with_hold("ok")
    answered = fixtures[h.SCHEDULES_PATH]
    reloads_fail = threading.Event()
    fixtures[h.SCHEDULES_PATH] = lambda: (
        (503, {"error": "unavailable"}) if reloads_fail.is_set() else answered
    )

    def interact(process, fd, _slave, output, _base_path):
        h.palette_go(process, fd, output, b"go schedules", b"MASC Keepers / Schedules")
        h.resize_and_wait(process, fd, output, rows=40, columns=120,
                          needle=CURRENT, controls=(h.FULL_REDRAW,))
        reloads_fail.set()
        # The list stays on screen under the source warning; its hold was read
        # by a runner that was ok then, and is drawn as of that reading now.
        h.send_and_wait(process, fd, output, b"r", CHECKED)
        warning = screen_line(output, b"HTTP 503")
        if "이전 조회 유지".encode() not in warning:
            raise AssertionError(f"the kept list lost its source warning: {warning!r}")
        identity = screen_line(output, IDENTITY)
        if CHECKED not in identity or b"held since" in identity:
            raise AssertionError(
                f"a kept list should draw its hold as {CHECKED!r}: {identity!r}")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable,
                            description="Schedules hold on a list kept after a failed reload",
                            interact=interact,
                            http_fixtures=fixtures,
                            extra_env={"TZ": "UTC"})


def run(executable: str) -> None:
    # A failed tick left the list as the last good tick read it.
    check(executable, "degraded", shown=CHECKED, hidden=b"held since")
    # No tick has finished within the threshold: the same.
    check(executable, "stale", shown=CHECKED, hidden=b"held since")
    # A word this build does not know says nothing about the runner, and the
    # list still loads over it.
    check(executable, "warming", shown=CHECKED, hidden=b"held since")
    # The newest tick read it, so the hold is the present.
    check(executable, "ok", shown=CURRENT, hidden=b"held as of")
    # Until a reload fails: then the list on screen is an earlier answer.
    check_kept_after_a_failed_reload(executable)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("a held schedule says when it was checked: PASS")
