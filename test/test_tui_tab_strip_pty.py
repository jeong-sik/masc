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

TAB_NAMES = (
    b"Info", b"Sandbox", b"Settings", b"Secrets", b"GitHub", b"Identity",
    b"Channels", b"Automation", b"Runs",
)

CURRENT = b"\xe2\x96\xb8"
# What a strip draws where it is holding entries back, with how many it holds
# on that side. Both are spelled in masc_tui_ansi.ml (hidden_before_mark and
# hidden_after_mark); a test outside OCaml has to repeat them, so it repeats
# the glyph alone and reads the count from the row.
HELD_BEFORE = b"\xe2\x80\xb9"
HELD_AFTER = b"\xe2\x80\xba"


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
        # Runs is the last of the nine, so nothing is held back past it and
        # the only mark belongs at the near end.
        if HELD_BEFORE not in title or b"Info" in title:
            raise AssertionError(
                f"the Keeper detail strip did not cut its far end to keep Runs: {title!r}")
        if HELD_AFTER in title:
            raise AssertionError(
                f"Runs is the last tab and the strip claimed entries past it: {title!r}")
        # The count says how many, which is the number of [ presses back to
        # the first tab. Nine tabs, five drawn beside Runs, four held.
        held = int(title.split(HELD_BEFORE)[1].split(b" ")[0])
        drawn = len([name for name in TAB_NAMES if name in title])
        if held + drawn != len(TAB_NAMES):
            raise AssertionError(
                f"the strip drew {drawn} tabs and claimed {held} held, of "
                f"{len(TAB_NAMES)}: {title!r}")
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
