"""The goal list says which of the goals it is holding, when it holds some."""

import os
import re
import sys

import test_tui_keyboard_input as h

# The surface this reads ("MASC Work") is drawn here, and the source
# selector runs a suite when a pull request changes a path the suite names.
SOURCE_MODULES = ("bin/masc_tui_render.ml",)

# [Masc_tui_scroll.window_text] inside the reading this scenario is about.
WINDOW = re.compile(rb"\[goals (\d+)-(\d+)/(\d+)\]")

# More goals than a short frame can draw, few enough that a tall one draws
# them all. The list gets what is left after the header block, the legend,
# the selected goal's line and the footer.
GOAL_COUNT = 14


def goals_fixtures() -> h.HttpFixtures:
    fixtures = h.overview_event_http_fixtures()
    fixtures[h.PLANNING_PATH] = h.planning_snapshot(
        [
            h.planning_goal(f"goal-{index:02d}-window", f"plan-window-{index:02d}")
            for index in range(GOAL_COUNT)
        ]
    )
    return fixtures


def window_row(output: bytearray) -> bytes | None:
    rows = h.screen_rows(bytes(output))
    carrying = [text for _, text in sorted(rows.items()) if WINDOW.search(text)]
    return carrying[-1] if carrying else None


def drawn_goal_rows(output: bytearray) -> int:
    rows = h.screen_rows(bytes(output))
    return len([text for _, text in rows.items() if b"plan-window-" in text])


def run(executable: str) -> None:
    def says_which_goals(process, fd, _slave, output, _base):
        # Short enough that the list cannot hold all of them.
        h.resize_and_wait(process, fd, output, rows=24, columns=100,
                          needle=b"MASC Dashboard")
        h.palette_go(process, fd, output, b"go Work", b"MASC Work")
        h.wait_for_output(process, fd, output, b"plan-window-00", start=0, timeout=5.0)
        h.wait_for_output(process, fd, output, b"[goals ", start=0, timeout=5.0)
        h.read_available(fd, output)
        row = window_row(output)
        if row is None:
            raise AssertionError(
                "the list held back goals and said nothing: "
                + h.screen_text(bytes(output)).decode("utf-8", "replace"))
        first, last, total = (int(g) for g in WINDOW.search(row).groups())
        if total != GOAL_COUNT:
            raise AssertionError(f"the window counted {total}, not {GOAL_COUNT}: {row!r}")
        drawn = drawn_goal_rows(output)
        if last - first + 1 != drawn:
            raise AssertionError(
                f"the window says {first}-{last} and {drawn} rows are drawn: {row!r}")
        if drawn >= total:
            raise AssertionError(
                f"nothing was held back, so no window belongs on the row: {row!r}")
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="A goal list that holds back goals says so",
        interact=says_which_goals,
        http_fixtures=goals_fixtures())

    def a_whole_list_stays_quiet(process, fd, _slave, output, _base):
        # Tall enough to draw every goal.
        h.resize_and_wait(process, fd, output, rows=44, columns=100,
                          needle=b"MASC Dashboard")
        h.palette_go(process, fd, output, b"go Work", b"MASC Work")
        h.wait_for_output(process, fd, output,
                          f"plan-window-{GOAL_COUNT - 1:02d}".encode(),
                          start=0, timeout=5.0)
        h.read_available(fd, output)
        row = window_row(output)
        if row is not None:
            raise AssertionError(
                "every goal is on the row and the list still claimed a window: "
                + repr(row))
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="A goal list that holds every goal carries no window",
        interact=a_whole_list_stays_quiet,
        http_fixtures=goals_fixtures())


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("planning goal window: PASS")
