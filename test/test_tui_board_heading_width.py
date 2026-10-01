"""The Board's two heading rows drop their tail rather than cut it."""
import os
import base64
import hashlib
import json
import sys
import test_tui_keyboard_input as h

# The sources this scenario stands over. scripts/ci/run-edited-tests.sh runs
# a suite when a pull request changes a path the suite names, so without this
# a change to the drawn text below reaches main with no scenario run. Both
# rows are built in masc_tui_render_board.ml.
SOURCE_MODULES = (
    "bin/masc_tui_render_board.ml",
    "bin/masc_tui_render_board.mli",
    "bin/masc_tui_render.ml",
)

SORT_ROW = b"Sort [s]:"
HEARTH_ROW = b"f/F:next/previous"
# What each row carries only when it carries it whole. A key hint and the
# clause that finishes a sentence are both atomic: "H:choo" names no key and
# "f narrows once" stops before the condition.
SORT_TAIL = b"\xc2\xb7 H:choose hearth"
HEARTH_TAIL = b"\xe2\x80\x94 f narrows once they are"
# Every mark either tail could leave behind if it were cut instead of dropped.
SORT_MARK = b"H:"
HEARTH_MARK = b"\xe2\x80\x94"
CUT = b"\xe2\x80\xa6"


def row_carrying(rows: dict[int, bytes], needle: bytes) -> bytes:
    row = h.screen_row_of(rows, needle)
    if row < 0:
        raise AssertionError(f"no row carries {needle!r}")
    return rows[row].rstrip()


def check_row(rows: dict[int, bytes], columns: int, needle: bytes,
              tail: bytes, mark: bytes) -> bool:
    text = row_carrying(rows, needle)
    if CUT in text:
        raise AssertionError(
            f"at {columns} columns the row carrying {needle!r} was cut: {text!r}")
    whole = tail in text
    if not whole and mark in text:
        raise AssertionError(
            f"at {columns} columns the row carrying {needle!r} kept part of its "
            f"tail: {text!r}")
    return whole


def run(executable: str) -> None:
    fixtures = h.overview_event_http_fixtures()
    post = h.board_selection_post("heading", "Heading width", "Short body")
    fixtures["/api/v1/board?sort_by=hot"] = (200, {"posts": [post]})

    def interact(process, fd, _slave, output, _base):
        h.wait_for_output(process, fd, output, b"Health: ", start=0, timeout=10)
        h.palette_go(process, fd, output, b"go board", b"MASC Board")
        # The scenario opens at a hundred columns, and resizing to the size
        # the terminal already has sends no SIGWINCH -- so that width is read
        # off the screen as drawn rather than asked for again.
        carried = {}

        def measure(columns: int, rows: dict[int, bytes]) -> None:
            carried[columns] = (
                check_row(rows, columns, SORT_ROW, SORT_TAIL, SORT_MARK),
                check_row(rows, columns, HEARTH_ROW, HEARTH_TAIL, HEARTH_MARK),
            )

        h.read_available(fd, output)
        measure(100, h.screen_rows(bytes(output)))
        # Widest first, so the widths that drop a tail are measured after a
        # screen that was seen carrying it. A tail nobody ever draws would
        # otherwise pass every narrow case.
        for columns in (72, 68, 67, 66, 62, 58):
            drawn = h.resize_and_wait(process, fd, output, rows=30,
                                      columns=columns, needle=SORT_ROW,
                                      controls=(h.FULL_REDRAW,))
            measure(columns, h.screen_rows(drawn))
        if carried[100] != (True, True):
            raise AssertionError(
                f"a hundred columns held neither tail whole: {carried[100]}")
        if carried[58] != (False, False):
            raise AssertionError(
                f"fifty-eight columns still drew a tail: {carried[58]}")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable,
                            description="Board heading rows across widths",
                            interact=interact, http_fixtures=fixtures)


def run_primary_list_studio(executable: str, no_color: bool = False) -> None:
    fixtures = h.keeper_runtime_http_fixtures()
    title = "Selected post title is readable above compact table columns"
    next_title = "Second post follows the selected row"
    fixtures["/api/v1/board?sort_by=hot"] = (200, {"posts": [
        h.board_selection_post("studio-first", title, "First body"),
        h.board_selection_post("studio-second", next_title, "Second body")]})

    def interact(process, fd, _slave, output, _base):
        def key(value, needle):
            return h.send_and_wait(process, fd, output, value, needle)

        def capture(name, rows, columns, needle):
            h.resize_and_wait(process, fd, output, rows=rows, columns=columns + 1,
                              needle=needle, controls=(h.FULL_REDRAW,), final_cursor=b"\x1b[?25l")
            frame = h.resize_and_wait(process, fd, output, rows=rows, columns=columns,
                                      needle=needle, controls=(h.FULL_REDRAW,), final_cursor=b"\x1b[?25l")
            screen = h.screen_text(frame)
            print("STUDIO_CAPTURE=" + json.dumps({
                "suite": "test_tui_board_heading_width",
                "name": name + ("-no-color" if no_color else ""),
                "rows": rows, "columns": columns, "provenance": "CI fixture PTY",
                "frame_b64": base64.b64encode(frame).decode(),
                "screen": b"\n".join(h.screen_rows(frame).get(row, b"") for row in range(1, rows + 1)).decode(errors="replace")}), flush=True)
            if name.startswith("keepers-") and not h.keeper_row_selected(b"alpha").search(frame):
                raise AssertionError("Keeper selected row vanished from the captured viewport")
            return h.screen_rows(frame)

        h.wait_for_output(process, fd, output, b"Health: ", start=0, timeout=10)
        key(b":go Keepers\r", b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"alpha")
        for name, rows, columns in (("keepers-wide", 32, 140), ("keepers-narrow", 24, 80), ("keepers-short", 16, 80)):
            drawn = capture(name, rows, columns, b"  Health  ")
            heading_row = h.screen_row_of(drawn, b"MASC Keepers")
            health_row = h.screen_row_of(drawn, b"  Health  ")
            if heading_row < 0 or health_row <= heading_row:
                raise AssertionError("Keeper health was not separated from the title")
            if b"connected" not in drawn[heading_row] or b"Health" in drawn[heading_row]:
                raise AssertionError("Keeper title lost connection identity or mixes health")
        # The preceding short-viewport case leaves 80 columns active. Restore
        # the wide geometry before waiting for the entire long Board title;
        # narrow previews intentionally fit their text to the current cells.
        h.resize_and_wait(process, fd, output, rows=32, columns=140,
                          needle=b"  Health  ", controls=(h.FULL_REDRAW,),
                          final_cursor=b"\x1b[?25l")
        key(b":go Board\r", title.encode())
        capture("board-wide", 32, 140, title.encode())
        key(b"j", next_title.encode())
        narrow = capture("board-narrow", 24, 80, next_title.encode())
        preview_row = h.screen_row_of(narrow, b"Selected post")
        if preview_row < 0 or next_title.encode() not in narrow[preview_row]:
            raise AssertionError("Board selected title vanished at 80 columns")
        key(b":go Dashboard\r", b"MASC Dashboard")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable,
        description="Primary list studio" + (" without color" if no_color else ""),
        interact=interact, http_fixtures=fixtures, workspace="Primary lists fixture",
        extra_env={"NO_COLOR": "1"} if no_color else None)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("Board heading tails are whole or absent: PASS")
    executable = os.path.abspath(sys.argv[1])
    with open(executable, "rb") as binary:
        print("STUDIO_BINARY_SHA256=" + hashlib.sha256(binary.read()).hexdigest(), flush=True)
    run_primary_list_studio(executable)
    run_primary_list_studio(executable, no_color=True)
    print("tui primary list studio PTY: PASS", flush=True)
