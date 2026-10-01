"""Task transition evidence shares a physical-row reading with its body."""
import json
import os
import re
import shlex
import sys
import tempfile
from pathlib import Path

import test_tui_keyboard_input as h

SOURCE_MODULES = ("bin/masc_tui_render.ml", "bin/masc_tui.ml")
TASK_ID = "task-metadata-501"
TITLE = "TITLEHEAD " + "한 " * 20 + "task title evidence " * 5 + "TITLEEND"
ACTOR = "actor-" + "delegated-" * 14 + "ACTOREND"
CREATOR = "creator-" + "owner-" * 18 + "CREATOREND"
VERIFICATION = "verification-" + "0123456789abcdef" * 7 + "VERIFYEND"
NOTES = "NOTESHEAD\n\n" + "completed evidence " * 12 + "\nNOTESEND"
REASON = "REASONHEAD\n\n" + "cancelled because source changed " * 8 + "\nREASONEND"
HISTORY = "HISTORYHEAD " + "handoff observation " * 9 + "HISTORYEND"
HANDOFF_STAMP = "2026-09-30T02:03:04Z"
HANDOFF_EDITOR = "handoff-editor-" + "delegated-" * 8 + "HANDOFFEDITOREND"
STAMP = "2026-09-30T01:02:03Z"
WINDOW = re.compile(rb"\[lines (\d+)-(\d+)/(\d+)\]")


def screen(output):
    end = output.rfind(h.FRAME_END)
    rows = h.screen_rows(bytes(output[:end + len(h.FRAME_END)]) if end >= 0 else bytes(output))
    return b"\n".join(rows[key] for key in sorted(rows))


def compact(text):
    return b"".join(h.unwrapped(text).split())


def window(output):
    match = WINDOW.search(screen(output))
    if match is None:
        raise AssertionError(f"Task window missing: {screen(output)!r}")
    return tuple(int(group) for group in match.groups())


def task(status):
    row = {"id": TASK_ID, "title": TITLE, "description": "Task description remains readable.",
           "status": status, "assignee": ACTOR, "priority": 2, "cycle_count": 7,
           "created_at": STAMP, "created_by": CREATOR, "files": ["docs/evidence/task-metadata.md"],
           "reclaim_policy": "block_reclaim",
           "handoff_context": {"summary": "Operator handoff", "reclaim_policy": "allow_reclaim",
                               "updated_at": HANDOFF_STAMP, "updated_by": HANDOFF_EDITOR}}
    if status == "awaiting_verification":
        row.update(started_at=STAMP, submitted_at=STAMP, verification_id=VERIFICATION)
    elif status == "done":
        row.update(completed_at=STAMP, notes=NOTES)
    elif status == "cancelled":
        row.update(cancelled_by=ACTOR, cancelled_at=STAMP, reason=REASON)
    return row


def save_task(base, status):
    path = Path(base) / ".masc" / "tasks" / "backlog.json"
    path.write_text(json.dumps({"tasks": [task(status)], "last_updated": STAMP, "version": 1}), encoding="utf-8")


def run(executable):
    fixtures = h.overview_event_http_fixtures()
    fixtures[f"/api/v1/dashboard/tasks/history?task_id={TASK_ID}&limit=50"] = (200, [{
        "ts": STAMP, "action": "submit", "from_status": "in_progress",
        "to_status": "awaiting_verification", "actor": ACTOR,
        "handoff_context": {"summary": HISTORY},
    }])
    requests = []
    with tempfile.TemporaryDirectory(prefix="masc-task-editor-") as directory:
        marker = Path(directory) / "opened"
        editor = Path(directory) / "cancel-empty.sh"
        editor.write_text("#!/bin/sh\nprintf %s '{\"reason\":\"\"}' > \"$1\"\nprintf opened > "
                          + shlex.quote(str(marker)) + "\n", encoding="utf-8")
        editor.chmod(0o755)

        def prepare(base):
            save_task(base, "awaiting_verification")

        def interact(process, fd, _slave, output, base):
            # Task palette entries derive from the loaded durable snapshot.
            # Startup's Dashboard header appears before that async read; Enter
            # on a query with no matching entry simply closes the palette.
            ready = b"1 awaiting verification"
            h.wait_for_output(process, fd, output, ready, start=0, timeout=5)
            h.wait_for_output(process, fd, output, h.FRAME_END,
                              start=h.end_of_needle(output, ready, 0), timeout=3)
            h.palette_go(process, fd, output, ("task " + TASK_ID).encode(), b"TITLEHEAD")
            # x on a Task owns its existing cancel editor, rather than the
            # Goal lifecycle handler. An empty reason must leave it untouched.
            original = (Path(base) / ".masc" / "tasks" / "backlog.json").read_bytes()
            os.write(fd, b"x")
            h.drain_until_quiet(process, fd, output)
            assert marker.exists(), "Task cancel key never opened its own reason editor"
            assert not any(b"masc_transition" in body for _, body in requests), requests
            assert (Path(base) / ".masc" / "tasks" / "backlog.json").read_bytes() == original
            assert b"MASC Task" in screen(output), screen(output)

            for status, evidence in (("awaiting_verification", VERIFICATION), ("done", NOTES), ("cancelled", REASON)):
                if status != "awaiting_verification":
                    h.resize_and_wait(process, fd, output, rows=150, columns=80,
                                      needle=b"TITLEHEAD", final_cursor=b"\x1b[?25l")
                    save_task(base, status)
                    h.send_and_wait(process, fd, output, b"r",
                                    b"NOTESHEAD" if status == "done" else b"REASONHEAD")
                for width in (30, 60, 80, 120):
                    # Tall frames prove all source fields reconstruct exactly;
                    # ordinary short frames exercise actual row navigation.
                    h.resize_and_wait(process, fd, output, rows=150, columns=width,
                                      needle=b"TITLEHEAD", final_cursor=b"\x1b[?25l")
                    h.wait_for_output(process, fd, output, b"HISTORYEND", start=0, timeout=10)
                    h.drain_until_quiet(process, fd, output)
                    all_text = compact(screen(output))
                    for value in (TITLE, TASK_ID, ACTOR, CREATOR, STAMP, evidence, HISTORY,
                                  "handoff policy: allow_reclaim", "reclaim policy: block_reclaim",
                                  "handoff updated: " + HANDOFF_STAMP, "handoff editor: " + HANDOFF_EDITOR):
                        assert compact(value.encode()) in all_text, (status, width, value, all_text)
                    h.resize_and_wait(process, fd, output, rows=18, columns=width,
                                      needle=b"TITLEHEAD", final_cursor=b"\x1b[?25l")
                    h.drain_until_quiet(process, fd, output)
                    first, last, total = window(output)
                    assert first == 1 and last < total, (first, last, total)
                    h.send_and_wait(process, fd, output, b"\x1b[6~", b"[lines ")
                    h.drain_until_quiet(process, fd, output)
                    after, _last, count = window(output)
                    assert after == first + max(1, last - first) and count == total, (first, last, after, total)
                    h.send_and_wait(process, fd, output, b"\x1b[5~", b"TITLEHEAD")
                    h.send_and_wait(process, fd, output, b"j", b"[lines ")
                    h.drain_until_quiet(process, fd, output)
                    assert window(output)[0] == 2, window(output)
                    h.send_and_wait(process, fd, output, b"k", b"TITLEHEAD")
                    h.send_and_wait(process, fd, output, b"\x1b[F", b"HISTORYEND")
                    h.drain_until_quiet(process, fd, output)
                    start, end, count = window(output)
                    assert start > 1 and end == count, (start, end, count)
                    print("TASK_METADATA_VIEWPORT " + json.dumps({"status": status, "width": width,
                          "window": [start, end, count], "screen": screen(output).decode("utf-8", "replace")}), flush=True)
                    h.send_and_wait(process, fd, output, b"\x1b[H", b"TITLEHEAD")
                if status == "awaiting_verification":
                    h.send_and_wait(process, fd, output, b"\x1b", b"MASC Work")
                    h.palette_go(process, fd, output, ("task " + TASK_ID).encode(), b"TITLEHEAD")
            # A stale detail ID survives a task leaving the durable backlog,
            # but the visible Work list owns keys after that refresh.
            marker.unlink()
            backlog = Path(base) / ".masc" / "tasks" / "backlog.json"
            backlog.write_text(json.dumps({"tasks": [], "last_updated": STAMP, "version": 1}), encoding="utf-8")
            h.send_and_wait(process, fd, output, b"r", b"MASC Work")
            os.write(fd, b"x")
            h.drain_until_quiet(process, fd, output)
            assert not marker.exists(), "a hidden task accepted cancellation after removal"
            assert not any(b"masc_transition" in body for _, body in requests), requests
            assert b"MASC Work" in screen(output) and b"MASC Task" not in screen(output), screen(output)
            os.write(fd, b"q")

        h.run_terminal_scenario(executable, description="Task metadata and terminal evidence are fully scrollable",
                                interact=interact, prepare_workspace=prepare, http_fixtures=fixtures,
                                http_requests=requests, extra_env={"EDITOR": str(editor), "VISUAL": str(editor)})


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("Task metadata physical-row viewport: PASS")
