"""Long task titles leave their state and priority visible after resizing."""
import json
import os
from pathlib import Path
import sys
import test_tui_keyboard_input as h

SOURCE_MODULES = ("bin/masc_tui_render.ml",)


def prepare(base_path):
    h.seed_row_budget_workspace(base_path)
    path = Path(base_path) / ".masc" / "tasks" / "backlog.json"
    payload = json.loads(path.read_text())
    original = payload["tasks"][0]
    payload["tasks"] = [
        dict(original, title="긴 작업 제목 " * 40),
        dict(original, id="task-2", title="검증 대기 작업 " * 40,
             status="awaiting_verification", assignee="wkbl-web-leader",
             started_at="2026-08-22T00:00:00Z",
             submitted_at="2026-08-22T01:00:00Z", verification_id="vrf-layout"),
    ]
    path.write_text(json.dumps(payload))


def run(executable):
    def interact(process, master_fd, _slave_fd, output, _base_path):
        h.palette_go(process, master_fd, output, b"go Work", b"MASC Work")
        h.send_and_wait(process, master_fd, output, b"t", b"MASC Work / Tasks")
        h.wait_for_output(process, master_fd, output, b"task-1", start=0, timeout=10)
        for width in (80, 120, 60):
            h.resize_and_wait(process, master_fd, output, rows=32, columns=width,
                              needle=b"task-1", final_cursor=b"\x1b[?25l")
            h.drain_until_quiet(process, master_fd, output)
            rows = h.screen_rows(bytes(output))
            for task_id, status in ((b"task-1", b"todo"),
                                    (b"task-2", b"awaiting_verification")):
                row = rows[h.screen_row_of(rows, task_id)]
                if status not in row or b"!" not in row:
                    raise AssertionError(f"state or priority lost at {width} columns: {row!r}")
                if "…".encode() not in row:
                    raise AssertionError(f"long field not abbreviated at {width} columns: {row!r}")
            verification_row = rows[h.screen_row_of(rows, b"task-2")]
            if b"@wkbl" not in verification_row:
                raise AssertionError(f"owner missing at {width} columns: {verification_row!r}")
        os.write(master_fd, b"q")

    h.run_terminal_scenario(executable, description="Work task rows preserve state on resize",
                            interact=interact, prepare_workspace=prepare)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("Work task row layout: PASS")
