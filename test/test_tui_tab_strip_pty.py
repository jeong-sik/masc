"""A tab strip keeps the entry it marks readable at the width it is given."""
import os
import sys
import test_tui_keyboard_input as h

# The sources this scenario stands over. scripts/ci/run-edited-tests.sh runs
# a suite when a pull request changes a path the suite names. The strip and
# the width arithmetic under it are masc_tui_ansi.ml's; the rows that size it
# are drawn by the two render modules below.
#
# The regression this declaration exists for: #36290 narrowed the strip to
# the width it was given, which cut into the current entry's own name. The
# scenario that reads that name lived only inside the whole-screen walk,
# which names no source and does not fit the gate's per-suite timeout, so
# nothing ran. It merged green and main was red until #36327.
SOURCE_MODULES = (
    "bin/masc_tui_ansi.ml",
    "bin/masc_tui_render.ml",
    "bin/masc_tui_render_prim.ml",
)

CURRENT = b"\xe2\x96\xb8"
CUT = b"\xe2\x80\xa6"


def run(executable: str) -> None:
    def interact(process, master_fd, _slave_fd, output, _base_path):
        h.resize_and_wait(process, master_fd, output, rows=38, columns=150,
                          needle=b"MASC Overview", final_cursor=b"\x1b[?25l")
        h.drain_until_quiet(process, master_fd, output)
        # Keeper detail: [ from Info wraps to Runs, the last of nine tabs. The
        # strip must cut its far end rather than the entry it marks.
        h.send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
        h.select_keeper_row(process, master_fd, output, b"alpha")
        h.send_and_wait(process, master_fd, output, b"\r", CURRENT + b"Info")
        h.send_and_wait(process, master_fd, output, b"[", CURRENT + b"Runs")
        h.drain_until_quiet(process, master_fd, output)
        rows = h.screen_rows(
            bytes(output[: output.rfind(h.FRAME_END) + len(h.FRAME_END)]))
        title = rows[h.screen_row_of(rows, CURRENT + b"Runs")]
        if CUT not in title or b"Info" in title:
            raise AssertionError(
                f"the Keeper detail strip did not cut its far end to keep Runs: {title!r}")
        h.send_and_wait(process, master_fd, output, b"\x1b", b"MASC Keepers")
        # Config: p walks the panes, and every pane name must arrive whole.
        # "prompts" and "presets" are eight cells, one more than the six-cell
        # names before them, so a strip budget short by a cell shows here.
        h.tab_until(process, master_fd, output, b"MASC Config")
        for pane in (b"models", b"params", b"prompts", b"presets", b"themes",
                     b"voice"):
            h.send_and_wait(process, master_fd, output, b"p", CURRENT + pane)
        os.write(master_fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="A tab strip keeps its current entry on the row",
        interact=interact,
        http_fixtures=h.keeper_runtime_http_fixtures(),
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("tab strip keeps its current entry: PASS")
