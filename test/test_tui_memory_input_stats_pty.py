"""Memory input statistics and token/KiB switching through the real TUI."""
import base64
import copy
import hashlib
import json
import os
import sys
from pathlib import Path

from tui_keyboard_context import context_inspector_fixtures
import tui_keyboard_harness as h
from tui_keyboard_memory import memory_facts_http_fixtures


def fixtures():
    result = memory_facts_http_fixtures()
    path = "/api/v1/keepers/alpha/turn-records?limit=50"
    template = context_inspector_fixtures()[path][1]["entries"][0]["record"]
    entries = []
    for turn, (tokens, body, scope) in enumerate(
        [(10000, 1024, "per_request"), (0, 2048, "per_request"),
         (30000, 3072, "per_request"), (900000, 8192, "conversation_cumulative"),
         (None, None, "per_request")], start=1
    ):
        record = copy.deepcopy(template)
        record.update(absolute_turn=turn, turn_ref=f"trace-context#{turn}",
                      ts=1787600000.0 + turn, input_tokens=tokens,
                      request_body_bytes=body, usage_scope=scope)
        record.pop("cache_read_input_tokens", None)
        if tokens is None:
            record.pop("input_tokens", None)
        if body is None:
            record["request_runtime_profile"] = None
        entries.append({"record": record, "diff_vs_prev": None})
    result[path] = (200, {"keeper": "alpha", "skipped_rows": 0, "entries": entries})
    return result


def run(executable):
    print("STUDIO_BINARY_SHA256=" + hashlib.sha256(Path(executable).read_bytes()).hexdigest())

    def interact(process, fd, _slave, output, _base):
        h.palette_go(process, fd, output, b"go Memory", b"MASC Memory")
        h.wait_for_output(process, fd, output, b"3/5 recorded", start=0, timeout=10)
        for columns, rows in ((140, 40), (80, 30), (80, 24)):
            for byte_mode in (False, True):
                needle = b"4/5 recorded" if byte_mode else b"3/5 recorded"
                if byte_mode:
                    h.send_and_wait(process, fd, output, b"u", needle)
                    # TIOCSWINSZ at unchanged dimensions emits no resize. Get
                    # an acknowledged alternate frame before returning to the
                    # exact size whose byte-mode layout we are testing.
                    h.resize_and_wait(process, fd, output, rows=rows + 1,
                                      columns=columns, needle=needle,
                                      controls=(h.FULL_REDRAW,), final_cursor=b"\x1b[?25l")
                frame = h.resize_and_wait(
                    process, fd, output, rows=rows, columns=columns,
                    needle=needle, controls=(h.FULL_REDRAW,),
                    final_cursor=b"\x1b[?25l",
                )
                screen = h.screen_text(frame)
                expected = (
                    [b"Request KiB", b"avg 3.5", b"max 8.0", b"min 1.0"]
                    if byte_mode else
                    [b"Input tok", b"avg 13.3k", b"max 30.0k", b"min 0"]
                )
                for value in expected + [b"last unreported", needle]:
                    if value not in screen:
                        raise AssertionError(f"missing {value!r}: {screen!r}")
                if not byte_mode and "≈".encode() not in screen:
                    raise AssertionError("stored knowledge lost its estimate mark")
                print("STUDIO_CAPTURE=" + json.dumps({
                    "suite": "test_tui_memory_input_stats_pty",
                    "name": f"{'bytes' if byte_mode else 'tokens'}-{columns}x{rows}",
                    "rows": rows, "columns": columns,
                    "provenance": "candidate binary fixture PTY",
                    "frame_b64": base64.b64encode(frame).decode(),
                    "screen": screen.decode(errors="replace"),
                }), flush=True)
                if byte_mode:
                    h.send_and_wait(process, fd, output, b"u", b"3/5 recorded")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description="Memory input statistics and units",
                            interact=interact, http_fixtures=fixtures())
    print("Memory input statistics PTY: PASS")


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
