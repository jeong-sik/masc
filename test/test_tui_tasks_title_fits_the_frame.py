"""The Work / Tasks summary stops at the frame, like every row around it."""
import os
import re
import sys

import test_tui_keyboard_input as h

# The sources this scenario stands over. scripts/ci/run-edited-tests.sh runs a
# suite when a pull request changes a path the suite names.
SOURCE_MODULES = ("bin/masc_tui_render.ml",)

# The active Task count belongs to this row, above the task list.
TITLE = b"Open tasks"
SGR = re.compile(rb"\x1b\[[0-9;]*m")
OSC = re.compile(rb"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")


def cells(row: bytes) -> int:
    """The row's width in cells.

    Every character this title draws -- ASCII, the middle dot, the cut mark --
    is one cell wide, so the decoded length is the count. A row with CJK in it
    would need the terminal's own table; this one never has any.
    """
    plain = SGR.sub(b"", OSC.sub(b"", row)).rstrip()
    return len(plain.decode("utf-8", "replace"))


def run(executable: str) -> None:
    def interact(process, fd, _slave, output, _base_path):
        h.wait_for_output(process, fd, output, b"MASC Dashboard", start=0, timeout=15)
        h.send_and_wait(process, fd, output, b"\t", b"MASC Work")
        h.send_and_wait(process, fd, output, b"t", b"MASC Work / Tasks")
        h.wait_for_output(process, fd, output, TITLE, start=0, timeout=20)
        for columns in (50, 56, 100):
            # Wait on the row this measures, not on the title above it: the
            # panel is drawn below the fold and arrives in a later frame than
            # the one that carries the screen's own name.
            drawn = h.resize_and_wait(process, fd, output, rows=24,
                                      columns=columns, needle=TITLE,
                                      controls=(h.FULL_REDRAW,))
            rows = h.screen_rows(drawn)
            index = h.screen_row_of(rows, TITLE)
            if index < 0:
                raise AssertionError(
                    f"at {columns} columns Work drew no Tasks summary")
            row = rows[index]
            width = cells(row)
            if width > columns:
                raise AssertionError(
                    f"at {columns} columns the Tasks title is {width} cells "
                    f"wide: {row!r}")
            print(f"  {columns} columns: title is {width} cells")
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="The Tasks title stops at the frame",
        interact=interact,
        http_fixtures=h.keeper_runtime_http_fixtures(),
        prepare_workspace=h.seed_row_budget_workspace,
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("tasks title fits the frame: PASS")
