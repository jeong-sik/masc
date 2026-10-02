"""Stored snapshot bytes and current Librarian failure state in the real PTY.

--baseline records the installed pre-change behavior without claiming that
behavior satisfies the new contract. Default mode validates the repaired TUI.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui_types.ml", "bin/masc_tui_render_memory.ml",
    "bin/masc_tui_context_inspector.ml",
)


def run(executable, baseline=False):
    print("STUDIO_BINARY_SHA256=" + hashlib.sha256(Path(executable).read_bytes()).hexdigest())
    for failed_now in (False, True):
        fixtures = h.memory_facts_http_fixtures()
        health = fixtures["/api/v1/dashboard/keeper-memory-health"][1]
        row = health["keepers"][0]
        row["snapshot_bytes"] = 262144
        row["librarian_failures"] = 0 if failed_now else 3
        row["librarian"].update(state="stopped" if failed_now else "drained",
                                detail="model unavailable" if failed_now else None)
        health["alert_summary"]["librarian_stopped_keepers"] = int(failed_now)
        health["totals"].update(snapshot_bytes=262144,
                                librarian_failures=row["librarian_failures"])

        def interact(process, fd, _slave, output, _base):
            h.palette_go(process, fd, output, b"go Memory", b"MASC Memory")
            h.wait_for_output(process, fd, output, b"Memory saved", start=0, timeout=10)
            for columns in (140, 80):
                frame = h.resize_and_wait(process, fd, output, rows=40, columns=columns,
                                         needle=b"Memory saved", controls=(h.FULL_REDRAW,),
                                         final_cursor=b"\x1b[?25l")
                plain = h.screen_text(frame)
                expected = (b"ok" if failed_now else b"degraded") if baseline else (
                    b"memory degraded" if failed_now else b"memory ok")
                status_rows = [line for line in plain.splitlines() if b"alpha" in line and b"Memory saved" in line]
                if not status_rows or expected not in status_rows[0]:
                    raise AssertionError(f"current memory state not visible: {plain!r}")
                if not baseline and b"256.0 KiB" not in plain:
                    raise AssertionError(f"observed stored bytes not visible: {plain!r}")
                if b"failed 3 since server start" not in plain and not failed_now:
                    raise AssertionError(f"historical failure evidence was lost: {plain!r}")
                print("STUDIO_CAPTURE=" + json.dumps({
                    "suite": "test_tui_memory_recall_state_pty",
                    "name": ("failed-now" if failed_now else "recovered") + f"-{columns}",
                    "rows": 40, "columns": columns,
                    "provenance": "installed binary fixture PTY baseline" if baseline else "candidate binary fixture PTY",
                    "frame_b64": base64.b64encode(frame).decode(),
                    "screen": b"\n".join(h.screen_rows(frame).get(r, b"") for r in range(1, 41)).decode(errors="replace"),
                }), flush=True)
            os.write(fd, b"q")

        h.run_terminal_scenario(executable, description="Memory state: " + ("failed now" if failed_now else "recovered"),
                                interact=interact, http_fixtures=fixtures)
    print("Memory recall state PTY baseline recorded" if baseline else "Memory recall state PTY: PASS")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("executable")
    parser.add_argument("--baseline", action="store_true")
    args = parser.parse_args()
    run(os.path.abspath(args.executable), args.baseline)
