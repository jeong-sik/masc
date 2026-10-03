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
from typing import Any, Literal, cast

import test_tui_keyboard_input as h



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


def run(
    executable: str,
    *,
    columns: int,
    split: bool,
    refresh_error: bool,
    preflight: Literal["context", "continuity", "memory", "failed_memory", "memory_context_failure", "memory_continuity_failure"]
    | None = None,
) -> None:
    scenario = ("split" if split else "stacked") + (
        " cached refresh error" if refresh_error else ""
    )
    if preflight is not None:
        scenario = "preflight-" + preflight
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
    if preflight is not None:
        observed_output: dict[str, Any] = {
            "exact_output": "retained-generation-answer",
            "generation_path": "full_lane",
            "full_llm_skipped": False,
            "preflight_domain_rejection": None,
            "jev_preflight": {
                "status": "skipped" if preflight == "memory" else "ineligible",
                "reason": "disabled" if preflight == "memory" else "context pass",
                "elapsed_s": None,
            },
        }
        if preflight == "failed_memory":
            record.update(
                status="failed",
                code="provider_failure",
                detail="fixture generation failure",
            )
            observed_output["jev_preflight"] = {
                "status": "judged",
                "decision": "needs_generation",
                "confidence": 0.8,
                "probabilities": {
                    "keep_current": 0.1,
                    "needs_generation": 0.8,
                    "uncertain": 0.1,
                },
                "destination": {
                    "destination_uri": "https://fixture.invalid/evaluate",
                    "model": "requested-model",
                },
                "model": "received-model",
                "request_body_sha256": "a" * 64,
                "passed_over": [],
                "elapsed_s": 0.05,
            }
        elif preflight in ("memory", "memory_context_failure", "memory_continuity_failure"):
            observed_output["after"] = {
                "commit": "unchanged",
                "revision": 4,
                "fact_count": 2,
                "change": {"added_count": 0, "removed_count": 0},
            }
        else:
            observed_output["memory_write"] = "skipped_context_only"
            observed_output["context_write"] = {
                "status": "committed",
                "generation": "context-generation",
                "revision": 3,
            }
            if preflight == "continuity":
                observed_output["continuity_write"] = {
                    "status": "committed",
                    "end_atom": 42,
                    "prefix_sha256": "a" * 64,
                }
        if preflight in ("memory_context_failure", "memory_continuity_failure"):
            side = "context" if preflight == "memory_context_failure" else "continuity"
            observed_output[side + "_write"] = {
                "status": "failed", "detail": side + "-side-write-refused",
            }
        record["output"] = observed_output
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
            "code",
            "detail",
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
        h.send_and_wait(
            process, master, output, b"\r", b"JEV" if preflight else b"INPUT"
        )
        if preflight is not None:
            h.resize_and_wait(
                process,
                master,
                output,
                rows=80,
                columns=columns,
                needle=b"JEV",
                controls=(h.FULL_REDRAW,),
                final_cursor=b"\x1b[?25l",
            )

            def completed_screen() -> bytes:
                end = output.rfind(h.FRAME_END)
                if end < 0:
                    raise AssertionError("preflight has no completed terminal frame")
                return h.screen_text(bytes(output[: end + len(h.FRAME_END)]))

            screen = completed_screen()
            marker = b"retained-generation-answer"
            if preflight in ("memory", "failed_memory", "memory_context_failure", "memory_continuity_failure"):
                if marker in screen or b"received-model" in screen:
                    raise AssertionError(
                        "memory evidence must start compact even without a snapshot"
                    )
                if preflight in ("memory", "memory_context_failure", "memory_continuity_failure") and "변경 없음".encode() not in screen:
                    raise AssertionError("compact memory snapshot result is missing")
                if preflight in ("memory_context_failure", "memory_continuity_failure"):
                    side = "context" if preflight == "memory_context_failure" else "continuity"
                    label = (side.capitalize() + ": failed").encode()
                    reason = (side + "-side-write-refused").encode()
                    if label not in screen or reason not in screen:
                        raise AssertionError("compact Memory success hid a side-write failure")
                if preflight == "failed_memory" and b"needs_generation" not in screen:
                    raise AssertionError("failed memory status summary is missing")
            else:
                for key in (b"memory_write", b"context_write", b"committed"):
                    if key not in screen:
                        raise AssertionError(f"default context result hid {key!r}")
                if preflight == "continuity" and b"continuity_write" not in screen:
                    raise AssertionError("default continuity result was hidden")
            h.send_and_wait(process, master, output, b"d", marker)
            if marker not in completed_screen():
                raise AssertionError("expanded evidence lost the recorded output")
            print(f"Librarian {preflight} default and expanded readings: PASS")
            os.write(master, b"q")
            return
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
    for preflight in ("context", "continuity", "memory", "failed_memory", "memory_context_failure", "memory_continuity_failure"):
        run(
            executable,
            columns=180,
            split=False,
            refresh_error=False,
            preflight=preflight,
        )
    print("TUI lane run paging: PASS")
