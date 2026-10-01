"""Keeper metrics facts and read diagnostics remain reachable at narrow widths."""
import json
from decimal import Decimal
import os
from pathlib import Path
import re
import sys
import unicodedata

import test_tui_keyboard_input as h

SOURCE_MODULES = ("bin/masc_tui_observation_layout.ml", "bin/masc_tui_types.ml",
                  "bin/masc_tui_render.ml", "bin/masc_tui_render_prim.ml",
                  "bin/masc_tui.ml", "bin/masc_tui_loader.ml")
TOOLS = ["/tool/" + "long-path/" * 20 + "TOOL-ASCII-END",
         "한글 도구 경로 " * 20 + "TOOL-CJK-END", "third-tool-END"]


def prepare(base):
    directory = Path(base) / ".masc" / "keepers" / "alpha" / "metrics" / "2026-09"
    directory.mkdir(parents=True, exist_ok=True)
    common = {"schema": "keeper.metrics.v1", "name": "alpha", "trace_id": "fixture-trace"}
    heartbeat = {**common, "record_kind": "heartbeat", "ts": "2026-09-30T00:00:00Z",
                 "ts_unix": 1790726400.0, "channel": "heartbeat", "message_count": 123}
    usage = {"input_tokens": 10, "output_tokens": 12, "cache_creation_tokens": 3,
             "cache_read_tokens": 4, "total_tokens": 22, "usage_trust": "trusted",
             "usage_anomaly": False, "usage_anomaly_reasons": []}
    turn = {**common, "record_kind": "turn", "ts": "2026-09-30T01:00:00Z",
            "ts_unix": 1790730000.0, "channel": "scheduled_autonomous", "message_count": 7,
            "usage": usage, "usage_trust": "trusted", "usage_anomaly_reasons": [],
            "latency_ms": 0, "cost_usd": 123456789.125, "turn_mode": "tool_use",
            "tool_call_count": len(TOOLS), "tools_used": TOOLS}
    tiny = {**turn, "ts": "2026-09-30T00:40:00Z", "ts_unix": 1790728800.0,
            "cost_usd": 0.0004, "tools_used": [], "tool_call_count": 0}
    zero = {**turn, "ts": "2026-09-30T00:20:00Z", "ts_unix": 1790727600.0,
            "cost_usd": 0.0, "tools_used": [], "tool_call_count": 0}
    # Invalid JSON is a real store diagnostic, distinct from a valid turn.
    # The heartbeat has no cost; zero and tiny positive are separate observed
    # turns, so a rounded zero cannot satisfy the small-cost control.
    entries = (heartbeat, zero, tiny, turn)
    (directory / "30.jsonl").write_text(
        "\n".join(json.dumps(entry) for entry in entries)
        + "\n{invalid fixture JSON\n", encoding="utf-8")


def press(process, fd, output, key):
    h.write_all(fd, output, key)
    h.drain_until_quiet(process, fd, output)


def completed_frame(output):
    end = output.rfind(h.FRAME_END)
    assert end >= 0, "Keeper logs have no completed frame"
    return bytes(output[:end + len(h.FRAME_END)])


def window(output, columns):
    complete = completed_frame(output)
    rows = h.screen_rows(complete)
    for row in rows.values():
        cells = sum(0 if unicodedata.combining(char)
                    else 2 if unicodedata.east_asian_width(char) in ("W", "F") else 1
                    for char in row.decode("utf-8"))
        if cells > columns:
            raise AssertionError(f"log row overflows {columns} columns: {row!r}")
    text = h.screen_text(complete)
    match = re.search(rb"newest rows (\d+)-(\d+) of (\d+)", text)
    if not match:
        raise AssertionError(f"wrapped reader omitted row window: {text!r}")
    return text, tuple(int(value) for value in match.groups())


def run(executable):
    def interact(process, fd, _slave, output, _base):
        h.send_and_wait(process, fd, output, b"3", b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"alpha")
        # Both actual entry keys must open the newest wrapped row before any
        # Home key can repair the position. A long diagnostic/entry forces a
        # nonzero maximum, so the previous bottom-opening behavior fails here.
        for opening_key in (b"l", b"L"):
            h.send_and_wait(process, fd, output, opening_key, b"logs")
            h.drain_until_quiet(process, fd, output)
            text, initial = window(output, 40)
            if initial[0] != 1 or b"malformed JSON" not in text:
                raise AssertionError(f"{opening_key!r} hid initial diagnostics: {text!r}")
            if initial[2] <= initial[1]:
                raise AssertionError("initial-entry fixture did not overflow the reader")
            if opening_key == b"l":
                info = h.send_and_wait(process, fd, output, b"\x1b", b"Identity")
                if b"Keepers \xe2\x96\xb8 alpha" not in h.screen_text(info):
                    raise AssertionError("Logs did not return to Keeper Info")
                h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
                h.select_keeper_row(process, fd, output, b"alpha")
        for columns in (40, 60, 80):
            h.resize_and_wait(process, fd, output, rows=24, columns=columns,
                              needle=b"logs", controls=(h.FULL_REDRAW,))
            _, reflowed = window(output, columns)
            if reflowed[0] != 1:
                raise AssertionError(f"width reflow did not return to newest rows: {reflowed!r}")
            press(process, fd, output, b"\x1b[H")
            text, previous = window(output, columns)
            if previous[0] != 1 or b"malformed JSON" not in text:
                raise AssertionError(f"Home did not reach latest diagnostics: {text!r}")
            seen = set()
            costs_seen = set()
            expected_costs = {Decimal("123456789.125"), Decimal("0.0004"), Decimal("0"), None}
            expected = (b"30.jsonl", b"TOOL-ASCII-END", b"TOOL-CJK-END", b"third-tool-END",
                        b"123456789.125", b"Messages: 123", b"Work: tool_use", b"0ms")
            for _ in range(80):
                text, current = window(output, columns)
                joined = b"".join(row.strip() for _, row in sorted(h.screen_rows(completed_frame(output)).items()))
                seen.update(token for token in expected if token in text or token in joined)
                # Read each whole labelled cost cell, rather than matching
                # "$0." as a prefix of the tiny positive value. Decimal also
                # accepts an equivalent scientific spelling without rounding.
                for match in re.finditer(rb"Cost: (\$[0-9.eE+\-]+|--)", text):
                    value = match.group(1)
                    costs_seen.add(None if value == b"--" else Decimal(value[1:].decode()))
                if current[1] == current[2]:
                    break
                press(process, fd, output, b"\x1b[6~")
                _, following = window(output, columns)
                step = current[1] - current[0]
                if following[0] != min(current[0] + step, current[2] - step):
                    raise AssertionError(f"page skipped wrapped facts: {current!r} -> {following!r}")
            if seen != set(expected):
                raise AssertionError(f"unreachable log facts: {set(expected) - seen!r}")
            if costs_seen != expected_costs:
                raise AssertionError(f"log cost precision/presence changed: {costs_seen!r}")
            press(process, fd, output, b"\x1b[H")
            _, home = window(output, columns)
            press(process, fd, output, b"j")
            _, older = window(output, columns)
            press(process, fd, output, b"k")
            _, newer = window(output, columns)
            if older[0] != home[0] + 1 or newer != home:
                raise AssertionError(f"j/k changed temporal direction: {home!r}, {older!r}, {newer!r}")
            # The presented Logs frame owns a Keeper_logs_scroll receipt.
            # Real mouse input first reads that receipt's current position,
            # then follows the existing bounded Metrics_tail key route.
            h.wait_for_output(process, fd, output, b"\x1b[?1006;1000h", start=0, timeout=3.0)
            press(process, fd, output, b"\x1b[<65;5;5M")
            _, wheeled_older = window(output, columns)
            press(process, fd, output, b"\x1b[<64;5;5M")
            _, wheeled_newer = window(output, columns)
            if wheeled_older != older or wheeled_newer != home:
                raise AssertionError(
                    f"Logs receipt/wheel lost bounded row movement: {home!r}, "
                    f"{wheeled_older!r}, {wheeled_newer!r}")
            press(process, fd, output, b"\x1b[F")
            text, oldest = window(output, columns)
            if oldest[1] != oldest[2] or b"Messages: 123" not in text:
                raise AssertionError(f"End did not reach oldest facts: {text!r}")
            press(process, fd, output, b"\x1b[5~")
            _, paged_back = window(output, columns)
            if paged_back[0] != max(1, oldest[0] - (oldest[1] - oldest[0])):
                raise AssertionError(f"PageUp skipped wrapped facts: {oldest!r} -> {paged_back!r}")
            press(process, fd, output, b"r")
            _, refreshed = window(output, columns)
            if refreshed != paged_back:
                raise AssertionError(f"refresh moved unchanged log position: {paged_back!r} -> {refreshed!r}")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description="Keeper log facts wrap without skipping rows",
                           interact=interact, http_fixtures=h.keeper_runtime_http_fixtures(),
                           prepare_workspace=prepare, terminal_cols=40,
                           startup_frame_marker=b"MASC Dashboard")


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("Keeper logs narrow reading: PASS")
