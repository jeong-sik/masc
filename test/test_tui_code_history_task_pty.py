"""Follow a recorded Task and return without losing file/history selection."""
import json
import os
import sys
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import tui_keyboard_harness as h
import test_tui_code_history_layout_pty as history

TASK = "task-history"


def run(executable, columns, mode):
    requests = []
    fixtures = history.fixtures(False, requests)
    fixtures["/api/v1/git/log"] = (200, {"ok": True, "commits": []})
    status, payload = fixtures["/api/v1/ide/file-activity"].resolve("/api/v1/ide/file-activity")
    change = payload["data"]["changes"][0]
    change.update(keeper="alpha", task_id=None if mode == "unlinked" else TASK,
                  execution_id="exec-history")
    fixtures["/api/v1/ide/file-activity"] = (status, payload)
    history_reads = []
    def task_history(path):
        history_reads.append(parse_qs(urlsplit(path).query))
        return 200, [{"ts": "2026-10-08T10:00:00Z", "action": "submit_for_verification",
                      "actor": "alpha", "handoff_context": {"summary": "HISTORY_PROOF"}}]
    fixtures["/api/v1/dashboard/tasks/history"] = h.PathHttpResponse(task_history)

    def prepare(base):
        backlog = Path(base) / ".masc/tasks/backlog.json"
        if mode == "unavailable":
            backlog.write_text("{unreadable backlog")
            return
        task = {"id": TASK, "title": "Explain recorded change", "description": "WHY_THE_CHANGE",
                "status": "done" if mode == "done" else "todo", "priority": 1,
                "created_at": "2026-10-08T09:00:00Z"}
        if mode == "done":
            task.update(assignee="alpha", completed_at="2026-10-08T10:00:00Z", notes="VERIFIED_OUTPUT")
        backlog.write_text(json.dumps({"tasks": [] if mode == "missing" else [task],
                                       "last_updated": "2026-10-08T10:00:00Z", "version": 1}))

    def interact(process, fd, _slave, output, _base):
        h.palette_go(process, fd, output, b"go code", b"[draft]")
        h.send_and_wait(process, fd, output, b"\r", b"local lock = 1")
        h.resize_and_wait(process, fd, output, rows=30, columns=columns,
            needle=b"local lock = 1", controls=(h.FULL_REDRAW,))
        h.send_and_wait(process, fd, output, b"H", b"Keeper: alpha")
        h.send_and_wait(process, fd, output, b"d", b"Recorded change")
        # Select a metadata continuation instead of relying on the first row.
        h.send_and_wait(process, fd, output, b"j", b"rows 2-")
        before = history.window(output, columns)
        if mode in ("linked", "done"):
            h.read_available(fd, output)
            followed_at = len(output)
            h.send_and_wait(process, fd, output, b"t", b"Explain recorded change")
            # This short detail fits the viewport. The asynchronous proof may
            # arrive with the title or afterwards; observe both from before t
            # instead of requiring a fresh redraw from a no-op End key.
            h.wait_for_output(process, fd, output, b"HISTORY_PROOF",
                start=followed_at, timeout=3)
            h.wait_for_output(process, fd, output, h.FRAME_END,
                start=h.end_of_needle(output, b"HISTORY_PROOF", followed_at), timeout=3)
            screen = h.screen_text(history.completed(output))
            assert b"HISTORY_PROOF" in screen and b"WHY_THE_CHANGE" in screen, screen
            if mode == "done":
                assert b"VERIFIED_OUTPUT" in screen, screen
            assert history_reads and all(query.get("task_id") == [TASK] for query in history_reads), history_reads
            h.send_and_wait(process, fd, output, b"\x1b", b"history:")
            assert history.window(output, columns) == before
        else:
            needle = {"unlinked": b"no Task link", "missing": b"not in the current",
                      "unavailable": b"Tasks unavailable"}[mode]
            h.send_and_wait(process, fd, output, b"t", needle)
            assert history.window(output, columns) == before
            assert not history_reads, history_reads
        os.write(fd, b"q")

    h.run_terminal_scenario(executable,
        description=f"Code history Task follow {mode} {columns}", interact=interact,
        http_fixtures=fixtures, prepare_workspace=prepare)


if __name__ == "__main__":
    for width in (60, 120):
        for case in ("linked", "done", "missing", "unlinked", "unavailable"):
            run(os.path.abspath(sys.argv[1]), width, case)
    print("Code history Task follow and return: PASS")
