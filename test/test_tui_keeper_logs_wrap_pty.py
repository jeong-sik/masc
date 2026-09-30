"""Keeper metrics facts and read diagnostics remain reachable at narrow widths."""
import json
import os
from pathlib import Path
import re
import sys
import unicodedata

import test_tui_keyboard_input as h

SOURCE_MODULES = ("bin/masc_tui_observation_layout.ml", "bin/masc_tui_types.ml",
                  "bin/masc_tui_render.ml", "bin/masc_tui.ml", "bin/masc_tui_loader.ml")
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
    # Invalid JSON is a real store diagnostic, distinct from a valid turn.
    (directory / "30.jsonl").write_text(json.dumps(heartbeat) + "\n" + json.dumps(turn)
                                       + "\n{invalid fixture JSON\n", encoding="utf-8")


def press(process, fd, output, key):
    h.write_all(fd, output, key)
    h.drain_until_quiet(process, fd, output)


def window(output, columns):
    rows = h.screen_rows(bytes(output))
    for row in rows.values():
        cells = sum(0 if unicodedata.combining(char)
                    else 2 if unicodedata.east_asian_width(char) in ("W", "F") else 1
                    for char in row.decode("utf-8"))
        if cells > columns:
            raise AssertionError(f"log row overflows {columns} columns: {row!r}")
    text = h.screen_text(bytes(output))
    match = re.search(rb"newest rows (\d+)-(\d+) of (\d+)", text)
    if not match:
        raise AssertionError(f"wrapped reader omitted row window: {text!r}")
    return text, tuple(int(value) for value in match.groups())


def run(executable):
    def interact(process, fd, _slave, output, _base):
        h.send_and_wait(process, fd, output, b"3", b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"alpha")
        h.send_and_wait(process, fd, output, b"l", b"logs")
        h.drain_until_quiet(process, fd, output)
        for columns in (40, 60, 80):
            h.resize_and_wait(process, fd, output, rows=24, columns=columns,
                              needle=b"logs", controls=(h.FULL_REDRAW,))
            press(process, fd, output, b"\x1b[H")
            text, previous = window(output, columns)
            if previous[0] != 1 or b"malformed JSON" not in text:
                raise AssertionError(f"Home did not reach latest diagnostics: {text!r}")
            seen = set()
            expected = (b"30.jsonl", b"TOOL-ASCII-END", b"TOOL-CJK-END", b"third-tool-END",
                        b"123456789.125", b"Messages: 123", b"Work: tool_use", b"0ms")
            for _ in range(80):
                text, current = window(output, columns)
                joined = b"".join(row.strip() for _, row in sorted(h.screen_rows(bytes(output)).items()))
                seen.update(token for token in expected if token in text or token in joined)
                if current[1] == current[2]:
                    break
                press(process, fd, output, b"\x1b[6~")
                _, following = window(output, columns)
                step = current[1] - current[0]
                if following[0] != min(current[0] + step, current[2] - step):
                    raise AssertionError(f"page skipped wrapped facts: {current!r} -> {following!r}")
            if seen != set(expected):
                raise AssertionError(f"unreachable log facts: {set(expected) - seen!r}")
            press(process, fd, output, b"\x1b[H")
            _, home = window(output, columns)
            press(process, fd, output, b"j")
            _, older = window(output, columns)
            press(process, fd, output, b"k")
            _, newer = window(output, columns)
            if older[0] != home[0] + 1 or newer != home:
                raise AssertionError(f"j/k changed temporal direction: {home!r}, {older!r}, {newer!r}")
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
                           prepare_workspace=prepare)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("Keeper logs narrow reading: PASS")
