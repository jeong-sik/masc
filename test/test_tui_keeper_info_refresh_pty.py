"""Keeper Info follows composite execution reads while the pane stays open.

The actual TUI requests synthetic HTTP snapshots and renders their lifecycle,
turn, idle time and last outcome. A slow cadence isolates tab entry and [r];
a second scenario changes the endpoint without input to exercise automatic
refresh, retained-but-stale values, and retry after failure.
"""

from __future__ import annotations

import os
import sys

import tui_keyboard_harness as h
from tui_keyboard_keepers import KEEPER_LANES_PATH, keeper_lane_row, keeper_lanes_response


FIRST_ERROR = "composite-initial-read-unavailable"
REFRESH_ERROR = "composite-refresh-unavailable"


def snapshot(marker: str, *, executing: bool = False) -> h.HttpResponse:
    return keeper_lanes_response([
        keeper_lane_row(
            "alpha",
            phase="failing" if executing else "running",
            turn_phase="executing" if executing else "idle",
            idle_seconds=3599 if executing else 75,
            runtime_state="done",
            selected_model=marker,
            turn_healthy=not executing,
        )
    ])


def screen(output: bytearray) -> str:
    end = output.rfind(h.FRAME_END)
    if end < 0:
        return ""
    return " ".join(h.screen_text(bytes(output[:end + len(h.FRAME_END)])).decode().split())


def wait_for_info(process, fd, output, *, present: tuple[str, ...], absent: tuple[str, ...] = ()) -> None:
    def ready() -> bool:
        text = screen(output)
        return ("▸Info" in text and "Runtime Stats" in text
                and all(fact in text for fact in present)
                and all(fact not in text for fact in absent))

    if not h.wait_for_fixture_state(process, fd, output, ready, timeout=10.0):
        raise AssertionError(f"Info did not show {present!r} without {absent!r}: {screen(output)}")


def wait_for_snapshot(process, fd, output, marker: str, *, executing: bool = False) -> None:
    wait_for_info(process, fd, output, present=(
        "Lifecycle: failing (last turn failed)" if executing else "Lifecycle: running",
        "Turn: executing" if executing else "Turn: idle",
        "Idle: 59m" if executing else "Idle: 1m",
        "Last outcome: done · " + marker,
    ), absent=(FIRST_ERROR, REFRESH_ERROR, "stale · refresh failed"))


def open_info(process, fd, output) -> None:
    h.palette_go(process, fd, output, b"go Keepers", b"MASC Keepers")
    h.select_keeper_row(process, fd, output, b"alpha")
    h.send_and_wait(process, fd, output, b"\r", "▸Info".encode())
    h.resize_and_wait(process, fd, output, rows=70, columns=120,
                      needle=b"Runtime Stats", controls=(h.FULL_REDRAW,))


def entry_and_manual_refresh(executable: str) -> None:
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures[KEEPER_LANES_PATH] = (503, {"error": FIRST_ERROR})

    def interact(process, fd, _slave, output, _base):
        open_info(process, fd, output)
        wait_for_info(process, fd, output, present=("Execution: unavailable", FIRST_ERROR))

        # Switching back from another detail tab must retry the failed read.
        # No roster navigation or cadence refresh can supply this snapshot.
        h.send_and_wait(process, fd, output, b"]", "▸Items".encode())
        fixtures[KEEPER_LANES_PATH] = snapshot("info-entry-recovered")
        h.send_and_wait(process, fd, output, b"[", "▸Info".encode())
        wait_for_snapshot(process, fd, output, "info-entry-recovered")

        # A prior successful reading must not suppress the next tab-entry read.
        h.send_and_wait(process, fd, output, b"]", "▸Items".encode())
        fixtures[KEEPER_LANES_PATH] = snapshot("info-entry-current", executing=True)
        h.send_and_wait(process, fd, output, b"[", "▸Info".encode())
        wait_for_snapshot(process, fd, output, "info-entry-current", executing=True)

        fixtures[KEEPER_LANES_PATH] = snapshot("info-manual-current")
        os.write(fd, b"r")
        wait_for_snapshot(process, fd, output, "info-manual-current")

        fixtures[KEEPER_LANES_PATH] = (503, {"error": REFRESH_ERROR})
        os.write(fd, b"r")
        wait_for_info(process, fd, output, present=(
            "stale · refresh failed", REFRESH_ERROR, "Last outcome: done · info-manual-current"))

        fixtures[KEEPER_LANES_PATH] = snapshot("info-manual-recovered", executing=True)
        os.write(fd, b"r")
        wait_for_snapshot(process, fd, output, "info-manual-recovered", executing=True)
        os.write(fd, b"q")

    h.run_terminal_scenario(executable,
        description="Keeper Info entry and manual refresh retry composite readings",
        interact=interact, http_fixtures=fixtures, refresh=3600.0, terminal_cols=120)


def automatic_refresh(executable: str) -> None:
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures[KEEPER_LANES_PATH] = snapshot("info-cadence-initial")

    def interact(process, fd, _slave, output, _base):
        open_info(process, fd, output)
        wait_for_snapshot(process, fd, output, "info-cadence-initial")

        # No input follows until quit: updates, failures and recovery must
        # reach the still-open Info pane through its periodic read ownership.
        fixtures[KEEPER_LANES_PATH] = snapshot("info-cadence-current", executing=True)
        wait_for_snapshot(process, fd, output, "info-cadence-current", executing=True)

        fixtures[KEEPER_LANES_PATH] = (503, {"error": REFRESH_ERROR})
        wait_for_info(process, fd, output, present=(
            "stale · refresh failed", REFRESH_ERROR, "Last outcome: done · info-cadence-current"))

        fixtures[KEEPER_LANES_PATH] = snapshot("info-cadence-recovered")
        wait_for_snapshot(process, fd, output, "info-cadence-recovered")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable,
        description="Keeper Info stays current and retries composite reads without input",
        interact=interact, http_fixtures=fixtures, refresh=0.3, terminal_cols=120)


if __name__ == "__main__":
    executable = os.path.abspath(sys.argv[1])
    entry_and_manual_refresh(executable)
    automatic_refresh(executable)
    print("Keeper Info composite entry, manual and automatic refresh: PASS")
