"""Page keys must follow the payload window the terminal actually displays."""

from __future__ import annotations

import copy
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from typing import Any, cast

import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui.ml",
    "bin/masc_tui_render.ml",
    "bin/masc_tui_render.mli",
    "bin/masc_tui_types.ml",
    "bin/masc_tui_scroll.ml",
    "bin/masc_tui_scroll.mli",
)

PAYLOAD_ROWS = tuple(f"payload-row-{index:03d}" for index in range(1, 97))
PAYLOAD_ROW_RE = re.compile(rb"payload-row-(\d+)")


@dataclass(frozen=True)
class Window:
    first: int
    last: int
    total: int
    payload_rows: tuple[int, ...]

    @property
    def height(self) -> int:
        return self.last - self.first + 1


def visible_window(output: bytearray, *, split: bool) -> Window:
    # Presenters update changed rows only. Replay all completed frames so an
    # unchanged payload row remains visible, but an unfinished frame cannot
    # contribute a new range with old payload rows.
    end = output.rfind(h.FRAME_END)
    if end < 0:
        raise AssertionError("lane run has no completed terminal frame")
    screen = h.screen_text(bytes(output[: end + len(h.FRAME_END)]))
    if split:
        # The input and output titles share one physical row. The output
        # window is the one after OUTPUT, not the short input's first range.
        ranges = [
            match
            for row in screen.splitlines()
            if b"OUTPUT" in row
            for match in h.WINDOW_TEXT_RE.finditer(row.split(b"OUTPUT", 1)[1])
        ]
    else:
        ranges = list(h.WINDOW_TEXT_RE.finditer(screen))
    if len(ranges) != 1:
        raise AssertionError(f"expected one payload window: {screen!r}")
    first, last, total = (int(value) for value in ranges[0].groups())
    markers = tuple(int(value) for value in PAYLOAD_ROW_RE.findall(screen))
    if markers and markers != tuple(range(markers[0], markers[-1] + 1)):
        raise AssertionError(f"visible payload rows are not consecutive: {markers!r}")
    if not 1 <= first <= last <= total:
        raise AssertionError(f"invalid visible window: {(first, last, total)!r}")
    return Window(first, last, total, markers)


def assert_page(before: Window, after: Window, *, down: bool) -> None:
    if (after.total, after.height) != (before.total, before.height):
        raise AssertionError(f"page key changed payload geometry: {before} -> {after}")
    if down:
        valid = before.first < after.first <= before.last
        # A final page can overlap more when its bottom is clamped to the end.
        if after.last < after.total:
            valid = valid and after.first == before.last
    else:
        valid = after.first < before.first <= after.last
        if after.first > 1:
            valid = valid and after.last == before.first
    if not valid:
        direction = "PageDown" if down else "PageUp"
        raise AssertionError(
            f"{direction} skipped the visible boundary or lost its one-row overlap: "
            f"{before} -> {after}"
        )


def turn_page(
    process: subprocess.Popen[bytes],
    master: int,
    output: bytearray,
    before: Window,
    *,
    split: bool,
    down: bool,
) -> Window:
    # An unrelated refresh can finish after the key is sent. Wait for the
    # completed screen's window to move, not a marker that every frame has.
    h.write_all(master, output, b"\x1b[6~" if down else b"\x1b[5~")

    def moved() -> bool:
        first = visible_window(output, split=split).first
        return first > before.first if down else first < before.first

    if not h.wait_for_fixture_state(process, master, output, moved, timeout=3.0):
        raise AssertionError(f"page key did not move the completed window: {before}")
    return visible_window(output, split=split)


def run(executable: str, *, columns: int, split: bool, refresh_error: bool) -> None:
    scenario = ("split" if split else "stacked") + (
        " cached refresh error" if refresh_error else ""
    )
    run_id = "paging-" + scenario.replace(" ", "-")
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures[h.KEEPER_LANES_PATH] = h.keeper_lanes_response([])
    fixtures[h.STANDALONE_LANES_PATH] = h.standalone_lanes_response()
    detail = cast(dict[str, Any], copy.deepcopy(h.hitl_lane_run_detail_response()[1]))
    record = cast(dict[str, Any], detail["run"])
    record.update(
        run_id=run_id,
        lane="librarian_exact",
        actor="fixture",
        input={"kind": "exact", "payload": {"request": "retained-input"}},
        output=[
            {"marker": row, "event": "one retained execution result"}
            for row in PAYLOAD_ROWS
        ],
    )
    summary = {
        key: record[key]
        for key in (
            "run_id",
            "run_kind",
            "lane",
            "actor",
            "started_at",
            "status",
            "elapsed_s",
            "selected_slot",
        )
        if key in record
    }
    fixtures[h.lane_runs_path("librarian_exact")] = (
        200,
        {"runs": [summary], "has_more": False, "total": 1},
    )
    detail_reads: list[int] = []
    fail_refresh = False

    def read_detail() -> h.HttpResponse:
        status = 503 if fail_refresh else 200
        detail_reads.append(status)
        return status, {
            "error": "cached-detail-refresh-error"
        } if fail_refresh else detail

    fixtures["/api/v1/dashboard/exact-lane-runs/" + run_id] = read_detail

    def interact(
        process: subprocess.Popen[bytes],
        master: int,
        _slave: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        nonlocal fail_refresh
        h.palette_go(process, master, output, b"go lanes", b"Librarian")
        h.send_and_wait(
            process,
            master,
            output,
            b"/Librarian",
            re.compile(rb"\x1b\[7m[^\x1b\n]*Librarian"),
        )
        h.send_and_wait(process, master, output, b"\x1b", b"j/k:move")
        h.send_and_wait(process, master, output, b"\r", b"1 loaded / 1 retained")
        h.send_and_wait(process, master, output, b"\r", b"INPUT")
        h.resize_and_wait(
            process,
            master,
            output,
            rows=42,
            columns=columns,
            needle=h.WINDOW_TEXT_RE,
            controls=(h.FULL_REDRAW,),
            final_cursor=b"\x1b[?25l",
        )
        initial = visible_window(output, split=split)
        if refresh_error:
            fail_refresh = True
            h.send_and_wait(
                process, master, output, b"r", b"cached-detail-refresh-error"
            )
            cached = visible_window(output, split=split)
            if cached.total != initial.total or cached.height != initial.height - 1:
                raise AssertionError(
                    f"cached detail did not retain its rows: {initial} -> {cached}"
                )
            initial = cached
        if initial.first != 1 or initial.last == initial.total:
            raise AssertionError(
                f"fixture does not start with a scrollable payload: {initial}"
            )

        current = initial
        windows = [current]
        seen = set(current.payload_rows)
        for down in (True, False):
            while (current.last < current.total) if down else (current.first > 1):
                following = turn_page(
                    process, master, output, current, split=split, down=down
                )
                assert_page(current, following, down=down)
                windows.append(following)
                seen.update(following.payload_rows)
                current = following
        if current != initial:
            raise AssertionError(
                f"PageUp did not return to the initial window: {current}"
            )
        expected = set(range(1, len(PAYLOAD_ROWS) + 1))
        if seen != expected:
            raise AssertionError(
                f"paging omitted payload rows: {sorted(expected - seen)!r}"
            )
        # A new frame must replace the previous frame's paging height.
        # Keep the width stable so wrapping and row identities stay unchanged.
        h.resize_and_wait(
            process,
            master,
            output,
            rows=34,
            columns=columns,
            needle=h.WINDOW_TEXT_RE,
            controls=(h.FULL_REDRAW,),
            final_cursor=b"\x1b[?25l",
        )
        resized = visible_window(output, split=split)
        if resized.first != initial.first or resized.height >= initial.height:
            raise AssertionError(f"resize did not shrink the payload: {resized}")
        resized_down = turn_page(
            process, master, output, resized, split=split, down=True
        )
        assert_page(resized, resized_down, down=True)
        resized_up = turn_page(
            process, master, output, resized_down, split=split, down=False
        )
        assert_page(resized_down, resized_up, down=False)
        if resized_up != resized:
            raise AssertionError(
                f"resized PageUp lost its starting window: {resized_up}"
            )
        expected_reads = [200, 503] if refresh_error else [200]
        if detail_reads != expected_reads:
            raise AssertionError(f"unexpected detail requests: {detail_reads!r}")
        print(
            "LANE_RUN_PAGING_PTY_EVIDENCE "
            + json.dumps(
                {
                    "scenario": scenario,
                    "rows": 42,
                    "columns": columns,
                    "binary_sha256": hashlib.sha256(
                        Path(executable).read_bytes()
                    ).hexdigest(),
                    "detail_reads": detail_reads,
                    "resized_height": resized.height,
                    "resized_page_down_first": resized_down.first,
                    "windows": [
                        {
                            "first": w.first,
                            "last": w.last,
                            "total": w.total,
                            "payload_rows": w.payload_rows,
                        }
                        for w in windows
                    ],
                }
            ),
            flush=True,
        )
        os.write(master, b"q")

    h.run_terminal_scenario(
        executable,
        description="Lane run page keys follow the visible payload: " + scenario,
        interact=interact,
        http_fixtures=fixtures,
    )


if __name__ == "__main__":
    executable = os.path.abspath(sys.argv[1])
    run(executable, columns=180, split=True, refresh_error=False)
    run(executable, columns=100, split=False, refresh_error=False)
    run(executable, columns=180, split=True, refresh_error=True)
    print("TUI lane run paging: PASS")
