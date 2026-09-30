"""Read complete memo authors and bodies in narrow and split file panes."""
import os
import re
import sys
import unicodedata
import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui.ml", "bin/masc_tui_render.ml", "bin/masc_tui_keys.ml",
    "bin/masc_tui_scroll.ml", "bin/masc_tui_roster_pane.ml",
    "bin/masc_tui_acting_pane.ml", "bin/masc_tui_render_prim.ml",
    "bin/masc_tui_message_layout.ml", "lib/ide_memo/ide_memo.ml",
)
AUTHOR = "author-" + "a" * 120 + "AUTHORTAIL"
BODY = "MEMOHEAD " + "한글 memo evidence " * 80 + "MEMOTAIL"
SECOND = "SECOND-MEMO-END"
LITERAL_BODIES = ("---", "# literal-heading", "```", "```ocaml",
                  "> quoted literal", "*emphasis*", "[label](literal-target)",
                  "- list-item", "1. numbered", "`code`")
WINDOW = re.compile(r"rows (\d+)-(\d+) of (\d+)")


def cell_width(text):
    return sum(0 if unicodedata.combining(char) else
               2 if unicodedata.east_asian_width(char) in ("W", "F") else 1
               for char in text)


def from_cell(text, boundary):
    cells = 0
    for index, char in enumerate(text):
        if cells == boundary:
            return text[index:]
        cells += cell_width(char)
        assert cells <= boundary, (boundary, text)
    assert cells == boundary, (boundary, text)
    return ""


def window(output, columns):
    rows = h.screen_rows(bytes(output))
    position, match = next((index, WINDOW.search(text.decode("utf-8")))
        for index, text in sorted(rows.items()) if WINDOW.search(text.decode("utf-8")))
    first, last, total = map(int, match.groups())
    # Locate the reader in the rendered frame: a wide terminal can reserve
    # an Activity pane and still render Code without its left tree.
    counter = rows[position].decode("utf-8", errors="strict")
    boundary = cell_width(counter[:match.start()])
    body = []
    for offset in range(last - first + 1):
        line = rows.get(position + 1 + offset, b"").decode("utf-8", errors="strict")
        cells = cell_width(line)
        assert cells <= columns, (columns, cells, line)
        body.append(from_cell(line, boundary))
    return first, last, total, body


def run(executable, columns, no_color):
    fixtures = h.code_memo_fixtures()
    literal_memos = "".join(f"-- masc(literal-{index}): {body}\n"
                            for index, body in enumerate(LITERAL_BODIES))
    fixtures[h.CODE_MEMO_FILE_PATH] = (200, {"ok": True, "content":
        f"local lock = 1\n-- masc({AUTHOR}) decision: {BODY}\n"
        f"-- masc(beta): {SECOND}\n" + literal_memos
        + "local function read() return lock end\n"})

    def interact(process, fd, _slave, output, _base):
        h.palette_go(process, fd, output, b"go code", b"init.lua")
        h.send_and_wait(process, fd, output, b"\r", b"local lock = 1")
        # Hide the default Recent pane at a width that permits its complete
        # narrow -> wide -> hidden cycle. Physical widths then equal the Code
        # surface widths used by the split-pane and wrapping assertions.
        h.resize_and_wait(process, fd, output, rows=18,
                          columns=h.ACTING_PANE_CYCLE_COLUMNS,
                          needle=b"local lock = 1", controls=(h.FULL_REDRAW,))
        h.send_and_wait(process, fd, output, b"\x0c", b"[Recent]")
        assert h.acting_pane_header_cell(output) == (
            h.ACTING_PANE_CYCLE_COLUMNS - h.ACTING_PANE_WIDE_COLUMNS + 1)
        h.send_and_wait(process, fd, output, b"\x0c", b"local lock = 1")
        assert h.acting_pane_header_cell(output) == -1
        # Resize while the file is open; the fixture starts at 100 columns.
        h.resize_and_wait(process, fd, output, rows=18, columns=columns,
                          needle=b"local lock = 1", controls=(h.FULL_REDRAW,))
        assert h.acting_pane_header_cell(output) == -1
        h.send_and_wait(process, fd, output, b"m", b"rows 1-")
        screen = h.screen_text(bytes(output)).decode("utf-8")
        assert "Esc:back" in screen, (columns, no_color, screen)
        captured = {}
        while True:
            first, last, total, body = window(output, columns)
            captured.update((first + index, line) for index, line in enumerate(body))
            if last == total:
                break
            height = last - first + 1
            next_first = min(total - height + 1, first + max(1, height - 1))
            h.send_and_wait(process, fd, output, b"\x1b[6~", f"rows {next_first}-".encode())
        compact = "".join("".join(captured[index].split()) for index in sorted(captured))
        for field in (AUTHOR, BODY, SECOND, "L2", "(decision)", "L3"):
            assert "".join(field.split()) in compact, (columns, field, compact)
        for index, body in enumerate(LITERAL_BODIES):
            literal = f"literal-{index}" + "".join(body.split())
            assert literal in compact, (columns, literal, compact)
        h.send_and_wait(process, fd, output, b"\x1b[H", b"rows 1-")
        first, last, total, _ = window(output, columns)
        height = last - first + 1
        h.send_and_wait(process, fd, output, b"\x1b[F", f"rows {max(1, total-height+1)}-".encode())
        assert window(output, columns)[1] == total
        resized_columns = 160 if columns != 160 else 40
        h.resize_and_wait(process, fd, output, rows=18, columns=resized_columns,
                          needle=b"notes: init.lua", controls=(h.FULL_REDRAW,))
        shown_first = window(output, resized_columns)[0]
        expected_first = max(1, shown_first - 1)
        h.send_and_wait(process, fd, output, b"k", f"rows {expected_first}-".encode())
        assert window(output, resized_columns)[0] == expected_first
        h.send_and_wait(process, fd, output, b"m", b"local lock = 1")
        h.send_and_wait(process, fd, output, b"m", b"rows 1-")
        assert window(output, resized_columns)[0] == 1
        os.write(fd, b"q")

    h.run_terminal_scenario(executable,
        description=f"Code memo full text {columns} columns NO_COLOR={no_color}",
        interact=interact, http_fixtures=fixtures,
        extra_env={"NO_COLOR": "1"} if no_color else {})


if __name__ == "__main__":
    for plain in (False, True):
        for width in (30, 40, 60, 80, 120, 160):
            run(os.path.abspath(sys.argv[1]), width, plain)
    print("Code memo complete author/body and physical scrolling: PASS")
