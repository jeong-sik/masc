"""Recorded, keeper-tree and project-tree diffs expose full body tails."""
import json
import os
import re
import sys
import urllib.parse

import test_tui_keyboard_input as h

SOURCE_MODULES = ("bin/masc_tui.ml", "bin/masc_tui_render.ml",
                  "bin/masc_tui_render_prim.ml", "bin/masc_tui_types.ml")
RIGHT = b"\x1b[1;2C"
LEFT = b"\x1b[1;2D"
REMOVED = "REMOVEHEAD " + "r" * 140 + " REMOVETAILZ"
ADDED = "ADDHEAD " + "한" * 35 + " ADDTAILQ"
SECOND = "SECONDHEAD short file"
WIDTHS = (40, 60, 80, 120)


def screen(output):
    end = output.rfind(h.FRAME_END)
    completed = bytes(output[:end + len(h.FRAME_END)]) if end >= 0 else bytes(output)
    return h.screen_text(completed).decode("utf-8", "strict")


def changed_key(process, fd, output, key, column):
    # Wait on a fresh completed frame, not a needle already painted before
    # this operation. Draining afterwards consumes all batched pan presses.
    start = len(output)
    h.write_all(fd, output, key)
    needle = f"col {column} ".encode()
    h.wait_for_output(process, fd, output, needle, start=start, timeout=5)
    h.wait_for_output(process, fd, output, h.FRAME_END,
                      start=h.end_of_needle(output, needle, start), timeout=5)
    h.drain_until_quiet(process, fd, output)


def body_rows(output, recorded):
    lines = screen(output).splitlines()
    pattern = r"^\s*([+-]) (.*)$" if recorded else r"^\s*(?:1\s+-\s+-|-\s+1\s+\+) (.*)$"
    return [line for line in lines if re.match(pattern, line)]


def assert_gutters(output, recorded):
    rows = body_rows(output, recorded)
    if recorded:
        assert any(re.match(r"^\s*- ", row) for row in rows), rows
        assert any(re.match(r"^\s*\+ ", row) for row in rows), rows
    else:
        assert any(re.match(r"^\s*1\s+-\s+- ", row) for row in rows), rows
        assert any(re.match(r"^\s*-\s+1\s+\+ ", row) for row in rows), rows


def diff_payload(after=ADDED, before=REMOVED):
    return 200, {"has_changes": True, "unified": [
        {"kind": "delete", "oldLine": 1, "newLine": None, "text": before},
        {"kind": "add", "oldLine": None, "newLine": 1, "text": after}]}


def fixtures_for_readers():
    fixtures = h.code_lane_fixtures()
    status, changes = h.file_changes_alpha_response()
    changes["changes"] = changes["changes"][:2]
    changes["changes"][0]["change"] = {"kind": "edit", "before": REMOVED, "after": ADDED}
    changes["changes"][1]["change"] = {"kind": "edit", "before": "old second", "after": SECOND}
    fixtures[h.FILE_CHANGES_ALPHA_PATH] = status, changes
    fixtures["/api/v1/git/status"] = (200, {"scope": {"kind": "project"}, "total": 2,
        "changes": [{"path": path, "staged": False, "unstaged": True,
                     "untracked": False, "conflicted": False}
                    for path in ("lib/a.ml", "lib/second.ml")]})
    for path, payload in (("lib/a.ml", diff_payload()),
                          ("lib/second.ml", diff_payload(SECOND, "old second"))):
        for encoded in (path, urllib.parse.quote(path, safe="")):
            fixtures[f"/api/v1/git/diff?path={encoded}&base_ref=HEAD"] = payload
    for path, payload in (("repos/masc/lib/example.ml", diff_payload()),
                          ("repos/masc/lib/second.ml", diff_payload(SECOND, "old second"))):
        for encoded in (path, urllib.parse.quote(path, safe="")):
            fixtures[f"/api/v1/git/diff?path={encoded}&base_ref=HEAD&keeper=alpha"] = payload
    return fixtures


def exercise(process, fd, output, *, reader, columns, no_color):
    recorded = reader == "recorded"
    # An unchanged PTY size produces no SIGWINCH frame. The reader entry
    # already waited for its body; validate that frame at the existing size.
    if os.get_terminal_size(fd) != os.terminal_size((columns, 24)):
        h.resize_and_wait(process, fd, output, rows=24, columns=columns,
                          needle=b"REMOVEHEAD", final_cursor=b"\x1b[?25l")
    h.drain_until_quiet(process, fd, output)
    painted = h.screen_rows(bytes(output))
    assert max(painted) <= 24, (reader, columns, max(painted))
    for text in painted.values():
        assert h.fixture_cell_width(text.decode("utf-8", "strict")) <= columns, (reader, columns, text)
    initial = screen(output)
    assert "REMOVETAILZ" not in initial, (reader, columns, initial)
    assert_gutters(output, recorded)
    initial_gutters = [re.search(r"[+-] ", row).start() for row in body_rows(output, recorded)]
    changed_key(process, fd, output, RIGHT * 70, 71)
    middle = screen(output)
    assert "ADDTAILQ" in middle, (reader, columns, middle)
    assert_gutters(output, recorded)
    assert initial_gutters == [re.search(r"[+-] ", row).start() for row in body_rows(output, recorded)], middle
    changed_key(process, fd, output, RIGHT * 80, 151)
    tail = screen(output)
    assert "REMOVETAILZ" in tail, (reader, columns, tail)
    changed_key(process, fd, output, RIGHT * 300, len(REMOVED))
    # The longer removed ASCII row sets the bound, not the CJK added row.
    # At its last display cell only Z remains after the fixed minus gutter.
    clamped = body_rows(output, recorded)
    assert any(re.match(r"^\s*(?:- |1\s+-\s+- )Z\s*$", row) for row in clamped), clamped
    if not recorded:
        assert f"col {len(REMOVED)}" in screen(output), screen(output)
    changed_key(process, fd, output, LEFT * 400, 1)
    assert "REMOVEHEAD" in screen(output) and "ADDHEAD" in screen(output), screen(output)
    print("RECORDED_DIFF_PAN_PTY " + json.dumps({"reader": reader, "width": columns,
          "no_color": no_color, "clamped_rows": clamped}), flush=True)


def run(executable, no_color):
    fixtures = fixtures_for_readers()

    def interact(process, fd, _slave, output, _base):
        h.open_changes(process, fd, output)
        for columns in WIDTHS:
            for reader, key in (("recorded", b"\r"), ("keeper_tree", b"d")):
                # Recorded detail is local; the tree detail waits for HTTP
                # body data, not its header or the recorded preview beneath.
                h.send_and_wait(process, fd, output, key, b"REMOVEHEAD")
                exercise(process, fd, output, reader=reader, columns=columns, no_color=no_color)
                # Reopening the same file resets its body's offset.
                changed_key(process, fd, output, RIGHT * 30, 31)
                h.send_and_wait(process, fd, output, b"\x1b", b"preview")
                h.send_and_wait(process, fd, output, key, b"REMOVEHEAD")
                assert "ADDHEAD" in screen(output), screen(output)
                h.send_and_wait(process, fd, output, b"\x1b", b"preview")
                h.send_and_wait(process, fd, output, b"j", b"second.ml")
                h.send_and_wait(process, fd, output, key, b"SECONDHEAD")
                assert "REMOVEHEAD" not in screen(output), screen(output)
                h.send_and_wait(process, fd, output, b"\x1b", b"preview")
                h.send_and_wait(process, fd, output, b"k", b"example.ml")
        # Project Git Changes uses a separate scroll/width and a project path,
        # with no Keeper query parameter or clone-relative bundle prefix.
        h.resize_and_wait(process, fd, output, rows=24, columns=100,
                          needle=b"example.ml", final_cursor=b"\x1b[?25l")
        h.palette_go(process, fd, output, b"go code", b"README.md")
        h.send_and_wait(process, fd, output, b"d", b"lib/a.ml")
        for columns in WIDTHS:
            h.send_and_wait(process, fd, output, b"\r", b"REMOVEHEAD")
            exercise(process, fd, output, reader="project_tree", columns=columns, no_color=no_color)
            changed_key(process, fd, output, RIGHT * 30, 31)
            h.send_and_wait(process, fd, output, b"\x1b", b"lib/a.ml")
            h.send_and_wait(process, fd, output, b"\r", b"REMOVEHEAD")
            assert "ADDHEAD" in screen(output), screen(output)
            h.send_and_wait(process, fd, output, b"\x1b", b"lib/a.ml")
            # The list folds lib/second.ml at 40 columns. Wait for the
            # visible distinguishing tail, then prove the selected full path
            # by opening its unique SECONDHEAD payload below.
            h.send_and_wait(process, fd, output, b"j", b"cond.ml")
            h.send_and_wait(process, fd, output, b"\r", b"SECONDHEAD")
            assert "REMOVEHEAD" not in screen(output), screen(output)
            h.send_and_wait(process, fd, output, b"\x1b", b"cond.ml")
            h.send_and_wait(process, fd, output, b"k", b"lib/a.ml")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description=f"Three recorded/tree diff readers pan NO_COLOR={no_color}",
                            interact=interact, http_fixtures=fixtures, terminal_cols=100,
                            terminal_rows=24, extra_env={"NO_COLOR": "1"} if no_color else {})


if __name__ == "__main__":
    for no_color in (False, True):
        run(os.path.abspath(sys.argv[1]), no_color)
    print("Recorded and repository diff horizontal viewports: PASS")
