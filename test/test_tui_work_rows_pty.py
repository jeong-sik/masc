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
    payload["tasks"] = [dict(payload["tasks"][0],
                             title="긴 작업 제목 " * 40)]
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
            row = rows[h.screen_row_of(rows, b"task-1")]
            if b"(todo)" not in row:
                raise AssertionError(f"state lost behind title at {width} columns: {row!r}")
            if "…".encode() not in row:
                raise AssertionError(f"long title not abbreviated at {width} columns: {row!r}")
        os.write(master_fd, b"q")

    h.run_terminal_scenario(executable, description="Work task rows preserve state on resize",
                            interact=interact, prepare_workspace=prepare,
                            terminal_rows=32)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("Work task row layout: PASS")
