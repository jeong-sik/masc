"""Diff tails are reachable without moving the file behind the overlay."""
import re
import sys
import test_tui_keyboard_input as h

SOURCE_MODULES = ("bin/masc_tui_code_results.ml", "bin/masc_tui_code_results.mli",
                  "bin/masc_tui.ml", "bin/masc_tui_render.ml",
                  "bin/masc_tui_types.ml", "bin/masc_tui_keys.ml")
FILE_START = "가".encode()
ADDED_GUTTER = b"    -     1 + "
RIGHT = b"\x1b[1;2C"
LEFT = b"\x1b[1;2D"
ADDED = 'let x = "' + '가' * 35 + 'ADDTAIL"'
REMOVED = 'let old = "' + 'r' * 150 + 'REMOVETAIL"'


def run(executable, no_color):
    fixtures = h.code_lane_fixtures()
    for enc in ("lib/a.ml", "lib%2Fa.ml"):
        fixtures[f"/api/v1/workspace/file?path={enc}"] = (
            200, {"ok": True, "content": ADDED + "\n(* memo *)\n"})
        fixtures[f"/api/v1/git/diff?path={enc}&base_ref=HEAD"] = (200, {
            "has_changes": True, "unified": [
                {"kind": "delete", "oldLine": 1, "newLine": None, "text": REMOVED},
                {"kind": "add", "oldLine": None, "newLine": 1, "text": ADDED}]})

    def screen(output):
        return h.screen_text(bytes(output)).decode("utf-8", errors="strict")

    def interact(process, fd, _slave, output, _base):
        h.resize_and_wait(process, fd, output, rows=24, columns=100,
                          needle=b"MASC Dashboard")
        h.palette_go(process, fd, output, b"go code", b"README.md")
        h.send_and_wait(process, fd, output, b"\r", b"a.ml")
        h.send_and_wait(process, fd, output, b"\r", FILE_START)
        # Preserve an existing file offset across opening and closing diff.
        h.send_and_wait(process, fd, output, RIGHT * 2, b"(col 3)")
        for columns in (40, 60, 80, 120):
            h.send_and_wait(process, fd, output, b"d", ADDED_GUTTER)
            h.resize_and_wait(process, fd, output, rows=24, columns=columns,
                              needle=b"diff col 1 vs HEAD")
            h.drain_until_quiet(process, fd, output)
            initial = screen(output)
            assert "REMOVETAIL" not in initial, initial
            assert "Shift-←/→:pan" in initial, initial
            assert "Esc:back" in initial, initial
            # Added CJK text is lexed from the file. Pan by display cells and
            # keep both file coordinates and change markers at their origins.
            h.send_and_wait(process, fd, output, RIGHT * 70, b"diff col 71 vs HEAD")
            h.drain_until_quiet(process, fd, output)
            middle = screen(output)
            assert "ADDTAIL" in middle, middle
            assert re.search(r"\b1\s+-\s+-", middle), middle
            assert re.search(r"-\s+1\s+\+", middle), middle
            h.send_and_wait(process, fd, output, RIGHT * 80, b"diff col 151 vs HEAD")
            h.drain_until_quiet(process, fd, output)
            tail = screen(output)
            # At the narrow width, column 151 reaches the suffix but cannot
            # hold it all beside the gutter. Pan to its actual text origin.
            suffix_column = REMOVED.index("REMOVETAIL") + 1
            h.send_and_wait(process, fd, output, RIGHT * (suffix_column - 151),
                            f"diff col {suffix_column} vs HEAD".encode())
            h.drain_until_quiet(process, fd, output)
            tail = screen(output)
            assert "REMOVETAIL" in tail, tail
            # A removed row is wider than the current file: its actual width
            # controls the upper clamp, rather than the hidden file's width.
            last_column = len(REMOVED)
            h.send_and_wait(process, fd, output, RIGHT * 300,
                            f"diff col {last_column} vs HEAD".encode())
            h.send_and_wait(process, fd, output, LEFT * 400, b"diff col 1 vs HEAD")
            h.send_and_wait(process, fd, output, b"\x1b", b"(col 3)")
            h.drain_until_quiet(process, fd, output)
            assert "diff col" not in screen(output), screen(output)
            # Neither history nor notes may silently move the file underneath.
            h.send_and_wait(process, fd, output, b"H", b"abc1234")
            h.write_all(fd, output, RIGHT * 12)
            h.drain_until_quiet(process, fd, output)
            h.send_and_wait(process, fd, output, b"\x1b", b"(col 3)")
            h.send_and_wait(process, fd, output, b"m", b"notes:")
            h.write_all(fd, output, RIGHT * 12)
            h.drain_until_quiet(process, fd, output)
            h.send_and_wait(process, fd, output, b"\x1b", b"(col 3)")
            print(f"Code diff pan: width={columns} NO_COLOR={no_color} tails/gutters/clamp/isolation OK")

    h.run_terminal_scenario(executable, description=f"Code diff pan NO_COLOR={no_color}",
        interact=interact, http_fixtures=fixtures, terminal_cols=100,
        extra_env={"NO_COLOR": "1"} if no_color else {})


if __name__ == "__main__":
    for no_color in (False, True):
        run(sys.argv[1], no_color)
    print("Code diff horizontal viewport: PASS")
