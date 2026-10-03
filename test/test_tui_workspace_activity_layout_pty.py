"""Workspace Activity exposes file identities and full selected metadata."""
import json
import os
import re
import sys
import unicodedata
from pathlib import Path
import test_tui_keyboard_input as h


FILE_PATH = "lib/" + "long-한글-" * 35 + "Z.ml"
TITLE = "TITLEHEAD " + "한글 task evidence " * 45 + "TITLEEND"
EXECUTION = "exec-" + "e" * 110 + "EXECTAIL"
WINDOW = re.compile(r"Context \[(\d+)-(\d+)/(\d+)\]")


def completed(output):
    end = output.rfind(h.FRAME_END)
    assert end >= 0, "No completed redraw"
    return bytes(output[:end + len(h.FRAME_END)])


def visible(output):
    return h.screen_text(completed(output)).decode("utf-8", errors="strict")


def context(output):
    rows = h.screen_rows(completed(output))
    title_row, match = next((row, WINDOW.search(text.decode("utf-8", errors="strict")))
        for row, text in sorted(rows.items()) if WINDOW.search(text.decode("utf-8", errors="strict")))
    first, last, total = map(int, match.groups())
    body = [rows.get(title_row + 2 + index, b"").decode("utf-8", errors="strict").strip()
            for index in range(last - first + 1)]
    return first, last, total, body


def run(executable, no_color):
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures[h.REPOSITORIES_PATH] = h.repositories_fixture()
    _, changes = h.file_changes_alpha_response()
    selected = changes["changes"][-1]
    selected["location"]["path"] = FILE_PATH
    selected["task_id"] = "task-linked"
    selected["execution_id"] = EXECUTION
    selected["succeeded"] = False
    fixtures[h.FILE_CHANGES_ALPHA_PATH] = (200, changes)

    def prepare(base):
        Path(base, ".masc", "tasks", "backlog.json").write_text(json.dumps({
            "tasks": [{"id": "task-linked", "title": TITLE, "status": "awaiting_verification", "priority": 1,
                       "assignee": "alpha", "verification_id": "verify-activity",
                       "started_at": "2026-08-22T00:00:00Z", "submitted_at": "2026-08-22T00:00:00Z",
                       "created_at": "2026-08-22T00:00:00Z"}],
            "last_updated": "2026-08-22T00:00:00Z", "version": 1}), encoding="utf-8")

    def interact(process, fd, _slave, output, _base):
        ready = b"MASC Dashboard"
        h.wait_for_output(process, fd, output, ready, start=0, timeout=10)
        h.wait_for_output(process, fd, output, h.FRAME_END,
                          start=h.end_of_needle(output, ready, 0), timeout=3)
        h.tab_until(process, fd, output, b"MASC Workspace")
        h.wait_for_output(process, fd, output, b"/srv/masc/workspace/masc", start=0, timeout=10)
        h.send_and_wait(process, fd, output, b"h", b"MASC Workspace / Activity")
        h.wait_for_output(process, fd, output, b"Z.ml", start=0, timeout=10)
        for columns in (30, 40, 60, 80, 120):
            start = len(output)
            h.resize_and_wait(process, fd, output, rows=18, columns=columns,
                              needle=b"FILE", controls=(h.FULL_REDRAW,))
            h.wait_for_output(process, fd, output, h.FRAME_END,
                              start=h.end_of_needle(output, b"FILE", start), timeout=3)
            screen = visible(output)
            selected_rows = [row for row in screen.splitlines() if "failed" in row and "Z.ml" in row]
            assert len(selected_rows) == 1, (columns, screen)
            cells = sum(0 if unicodedata.combining(char) else
                        2 if unicodedata.east_asian_width(char) in ("W", "F") else 1
                        for char in selected_rows[0])
            assert cells <= columns, (columns, cells, selected_rows)
            h.send_and_wait(process, fd, output, b"v", b"Context [1-")
            captured = {}
            while True:
                first, last, total, body = context(output)
                captured.update((first + index, line) for index, line in enumerate(body))
                if last == total:
                    break
                height = last - first + 1
                expected_first = min(total - height + 1, first + max(1, height - 1))
                h.send_and_wait(process, fd, output, b"\x1b[6~",
                                f"Context [{expected_first}-".encode())
            compact = "".join("".join(captured[index].split()) for index in sorted(captured))
            for field in (FILE_PATH, TITLE, EXECUTION, "task-linked", "Result:failed"):
                assert "".join(field.split()) in compact, (columns, field, compact)
            h.send_and_wait(process, fd, output, b"\x1b[H", b"Context [1-")
            assert context(output)[0] == 1
            h.send_and_wait(process, fd, output, b"\x1b", b"FILE")
            h.send_and_wait(process, fd, output, b"j", b"second.ml")
            h.send_and_wait(process, fd, output, b"v", b"Context [1-")
            assert "long-" not in visible(output), visible(output)
            h.send_and_wait(process, fd, output, b"\x1b", b"FILE")
            h.send_and_wait(process, fd, output, b"k", b"Z.ml")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable,
        description=f"Workspace Activity full context NO_COLOR={no_color}",
        interact=interact, prepare_workspace=prepare, http_fixtures=fixtures,
        extra_env={"NO_COLOR": "1"} if no_color else {})


if __name__ == "__main__":
    for no_color in (False, True):
        run(os.path.abspath(sys.argv[1]), no_color)
    print("Workspace Activity responsive rows and full context: PASS")
