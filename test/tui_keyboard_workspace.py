from __future__ import annotations

import os
import re
import subprocess
from typing import Any, cast

from tui_keyboard_harness import (
    CSI_RE,
    LEXED_LET,
    LINES_WINDOW_RE,
    HttpFixtures,
    assert_pane_surface_title_over_gap,
    drain_until_quiet,
    keeper_runtime_http_fixtures,
    palette_go,
    run_terminal_scenario,
    screen_rows,
    screen_text,
    select_keeper_row,
    send_and_wait,
    tab_until,
    wait_for_output,
    wait_for_terminal_input_consumed,
)

FILE_CHANGES_ALPHA_PATH = "/api/v1/keepers/alpha/file-changes?window_hours=24"
FILE_CHANGES_BETA_PATH = "/api/v1/keepers/beta/file-changes?window_hours=24"


def file_changes_alpha_response() -> tuple[int, dict[str, object]]:
    return (
        200,
        {
            "keeper": "alpha",
            "window_hours": 24.0,
            "calls_in_window": 3,
            "changes": [
                {
                    "at": 1787600000.0,
                    "keeper": "alpha",
                    "turn": 7,
                    "task_id": "task-1",
                    "location": {
                        "kind": "repo",
                        "repo_id": "masc",
                        "path": "lib/example.ml",
                    },
                    "change": {
                        "kind": "edit",
                        "before": "let a = 1",
                        "after": "let a = 2",
                    },
                    "succeeded": True,
                },
                # A second row, so the arrow keys have somewhere to go. With
                # one row the marked row and the window's top row are the same
                # index whether or not the code keeps them apart.
                {
                    "at": 1787600100.0,
                    "keeper": "alpha",
                    "turn": 9,
                    "task_id": "task-9",
                    "location": {
                        "kind": "repo",
                        "repo_id": "masc",
                        "path": "lib/second.ml",
                    },
                    "change": {
                        "kind": "edit",
                        "before": "let b = 1",
                        "after": "let b = 2\nlet c = 3",
                    },
                    "succeeded": True,
                },
                {
                    "at": 1787600200.0,
                    "keeper": "alpha",
                    "turn": 11,
                    "task_id": "task-11",
                    "location": {
                        "kind": "repo",
                        "repo_id": "masc",
                        "path": "lib/long.ml",
                    },
                    "change": {
                        "kind": "edit",
                        "before": "let x = 0",
                        # Taller than the diff view, so the view has somewhere
                        # to scroll and says how far it scrolled.
                        "after": "\n".join(f"let x{n} = {n}" for n in range(40)),
                    },
                    "succeeded": True,
                },
            ],
            "over_budget": 0,
            "malformed": 0,
        },
    )


def file_changes_beta_response() -> tuple[int, dict[str, object]]:
    status, payload = file_changes_alpha_response()
    payload["keeper"] = "beta"
    change = cast(list[dict[str, Any]], payload["changes"])[0]
    change["keeper"] = "beta"
    change["turn"] = 8
    change["task_id"] = "task-2"
    cast(dict[str, Any], change["location"])["path"] = "lib/beta.ml"
    change["change"] = {
        "kind": "edit",
        "before": "let beta = false",
        "after": "let beta = true",
    }
    payload["changes"] = [change]
    return status, payload


def open_changes(
    process: subprocess.Popen[bytes],
    master_fd: int,
    output: bytearray,
) -> bytes:
    """Reach the Changes surface the way the key map says it is reached.

    Changes is not on the Tab ring -- test_tui_keys pins that with
    "Changes is not a top-level ring entry" -- it is a Keepers child opened
    with [f] ("files: file changes this keeper wrote"). These scenarios tabbed
    for it, which walks the ring past a surface that is not on it, so they
    could not arrive however many presses they were given.
    """
    tab_until(process, master_fd, output, b"MASC Keepers")
    # The header precedes the asynchronous roster. The fixture's alpha must
    # actually be selected before f captures the Keeper for this reading.
    select_keeper_row(process, master_fd, output, b"alpha")
    return send_and_wait(process, master_fd, output, b"f", b"masc:lib/example.ml")


def changes_keeper_and_arrow_detail_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    open_changes(process, master_fd, output)
    # The cursor row's diff previews under the list without Enter -- the
    # recorded before/after pair, rendered locally.
    wait_for_output(
        process, master_fd, output, b"preview masc:lib/example.ml",
        start=0, timeout=3.0,
    )
    preview_plain = CSI_RE.sub(b"", bytes(output)).decode("utf-8")
    for needle in ("EDIT", "APPLIED", "-1 +1", "let a = 1", "let a = 2"):
        if needle not in preview_plain:
            raise AssertionError(
                f"the preview missed {needle!r}: {preview_plain[-600:]!r}"
            )
    raw = bytes(output)
    for badge in (b"EDIT", b"APPLIED"):
        if re.search(rb"\x1b\[[0-9;]*m" + badge + rb"[^\x1b]*\x1b\[0m", raw) is None:
            raise AssertionError(f"Changes badge {badge!r} was not highlighted")
    # Down moves the marked row, not just the window. The mark used to be the
    # window's top row, so on a list that fits the screen it could not move at
    # all and Enter opened the first change whatever the operator pressed.
    second = send_and_wait(
        process, master_fd, output, b"\x1b[B", b"preview masc:lib/second.ml"
    )
    second_plain = CSI_RE.sub(b"", second).decode("utf-8")
    for needle in ("-1 +2", "let b = 1", "let c = 3"):
        if needle not in second_plain:
            raise AssertionError(
                f"down did not move the mark to the second change ({needle!r} "
                f"missing): {second_plain[-600:]!r}"
            )
    second_diff = send_and_wait(
        process, master_fd, output, b"\x1b[C", b"turn 9  task task-9  applied"
    )
    second_diff_plain = CSI_RE.sub(b"", second_diff).decode("utf-8")
    for needle in ("MASC Change", "masc:lib/second.ml", "let c = 3"):
        if needle not in second_diff_plain:
            raise AssertionError(
                f"right opened a diff that is not the marked row ({needle!r} "
                f"missing): {second_diff_plain!r}"
            )
    # The row that says how to leave. The screen tallied its own chrome one
    # row short, which put it a row over its budget, and a surface over budget
    # loses its last rows -- the footer being the last of them. Nothing else
    # on this screen names the key that closes it.
    if "open in editor" not in second_diff_plain:
        raise AssertionError(
            f"the diff drew no footer: {second_diff_plain[-800:]!r}"
        )
    send_and_wait(process, master_fd, output, b"\x1b[D", b"TURN")
    # An open diff scrolls to its end and stops there. The keypress steps
    # without a bound -- the rows are the drawing's -- so the frame reports
    # what it could use and the loop stores that. Without the report the
    # stored value kept climbing, and coming back up took one press per step
    # taken past the end.
    send_and_wait(
        process, master_fd, output, b"\x1b[B", b"preview masc:lib/long.ml"
    )
    tall = send_and_wait(
        process, master_fd, output, b"\x1b[C", b"turn 11  task task-11  applied"
    )
    # "[lines first-last/count]": the window the diff drew. At the top its
    # first row is 1; at the end its last row is the count.
    opened = LINES_WINDOW_RE.findall(CSI_RE.sub(b"", tall))
    if not opened or int(opened[-1][0]) != 1:
        raise AssertionError(
            f"the tall diff did not open at the top: {CSI_RE.sub(b'', tall)!r}"
        )
    mark = len(output)
    os.write(master_fd, b"j" * 60)
    wait_for_terminal_input_consumed(slave_fd)
    drain_until_quiet(process, master_fd, output)
    settled = CSI_RE.sub(b"", bytes(output[mark:]))
    at_end = LINES_WINDOW_RE.findall(settled)
    if not at_end:
        raise AssertionError(
            f"the tall diff drew no scroll indicator: {settled[-800:]!r}"
        )
    first, last, total = (int(value) for value in at_end[-1])
    if first == 1:
        raise AssertionError(
            f"the tall diff did not scroll at all: {settled[-800:]!r}"
        )
    if last != total:
        raise AssertionError(
            f"the tall diff stopped short of its end: {settled[-800:]!r}"
        )
    send_and_wait(
        process,
        master_fd,
        output,
        b"k",
        f"lines {first - 1}-{last - 1}/{total}]".encode("ascii"),
    )
    send_and_wait(process, master_fd, output, b"\x1b[D", b"TURN")
    send_and_wait(
        process, master_fd, output, b"\x1b[A", b"preview masc:lib/second.ml"
    )
    send_and_wait(
        process, master_fd, output, b"\x1b[A", b"preview masc:lib/example.ml"
    )
    beta = send_and_wait(process, master_fd, output, b"]", b"masc:lib/beta.ml")
    if b"MASC Changes beta" not in CSI_RE.sub(b"", beta):
        raise AssertionError(f"Changes did not switch to beta: {beta!r}")
    alpha = send_and_wait(process, master_fd, output, b"[", b"masc:lib/example.ml")
    if b"MASC Changes alpha" not in CSI_RE.sub(b"", alpha):
        raise AssertionError(f"Changes did not switch back to alpha: {alpha!r}")
    detail = send_and_wait(process, master_fd, output, b"\x1b[C", b"-1 +1")
    if b"MASC Change" not in CSI_RE.sub(b"", detail):
        raise AssertionError(f"Right did not open the selected diff: {detail!r}")
    listing = send_and_wait(process, master_fd, output, b"\x1b[D", b"TURN")
    if b"MASC Changes alpha" not in CSI_RE.sub(b"", listing):
        raise AssertionError(f"Left did not return to the Changes list: {listing!r}")
    # v opens the row's file on the Code surface, read through the keeper's
    # own workspace (?keeper=alpha), so the header names whose tree it is
    # and the bytes arrive lexed.
    code = send_and_wait(
        process, master_fd, output, b"v", LEXED_LET
    )
    code_plain = CSI_RE.sub(b"", code).decode("utf-8")
    if "alpha ▸ repos/masc/lib" not in code_plain:
        raise AssertionError(
            f"the Code header does not name the keeper workspace: {code_plain!r}"
        )
    if "example.ml" not in code_plain:
        raise AssertionError(f"the jumped file is not open: {code_plain!r}")
    os.write(master_fd, b"q")


def enter_outside_changes_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    """Enter pressed off the Changes surface must not arm its diff view.

    The widened Enter arm sent Acting/Approvals/Schedules/Verify/Harness into
    the Changes handler; with changes loaded, coming back to Changes then drew
    a diff nobody opened. Lanes now owns Enter, so this no-op guard uses Acting.
    """
    populated = open_changes(process, master_fd, output)
    populated_plain = CSI_RE.sub(b"", populated).decode("utf-8")
    if "MASC Changes" not in populated_plain:
        raise AssertionError(
            f"Changes did not draw the fixture row as a list: {populated_plain!r}"
        )
    tab_until(process, master_fd, output, b"MASC System")
    acting = send_and_wait(process, master_fd, output, b"A", b"MASC Activity")
    if b"MASC Activity" not in acting:
        raise AssertionError(f"did not reach Activity: {acting!r}")
    # System logs hang off Activity under [l]; Esc walks back to the parent.
    send_and_wait(process, master_fd, output, b"l", b"\xe2\x96\xb8Logs")
    events = send_and_wait(process, master_fd, output, b"e", b"\xe2\x96\xb8Events")
    # The same capitals, on the feed's own columns.
    if b"TIME" not in CSI_RE.sub(b"", events):
        raise AssertionError(
            f"the Activity feed did not name its columns in capitals: {events!r}"
        )
    send_and_wait(process, master_fd, output, b"l", b"\xe2\x96\xb8Logs")
    send_and_wait(process, master_fd, output, b"\x1b", b"\xe2\x96\xb8Events")
    os.write(master_fd, b"\r")
    back = open_changes(process, master_fd, output)
    back_plain = CSI_RE.sub(b"", back).decode("utf-8")
    if "TURN" not in back_plain:
        raise AssertionError(
            "returning to Changes did not draw the list columns; Enter on "
            f"Acting armed a view it does not own: {back_plain!r}"
        )
    # What says a diff is open is the diff view's own frame, not a pair of
    # counts: the marked row previews its diff under the list now, so "-1 +1"
    # is what an unopened list looks like.
    if "esc closes" in back_plain:
        raise AssertionError(
            "returning to Changes drew a diff nobody opened; Enter on Acting "
            f"reached the Changes handler: {back_plain!r}"
        )
    os.write(master_fd, b"q")




WORKSPACE_TREE_ROOT_PATH = "/api/v1/workspace/children?path=&limit=2000"
WORKSPACE_CHILDREN_LIB_PATH = "/api/v1/workspace/children?path=lib&limit=2000"
WORKSPACE_FILE_AML_PATH = "/api/v1/workspace/file?path=lib/a.ml"


def code_lane_fixtures() -> HttpFixtures:
    fixtures = keeper_runtime_http_fixtures()
    fixtures[WORKSPACE_TREE_ROOT_PATH] = (
        200,
        [
            {"path": "lib", "label": "lib", "depth": 0, "parent": "",
             "hasChildren": True, "diff": None, "keeperId": None,
             "hueIndex": None},
            {"path": "README.md", "label": "README.md", "depth": 0,
             "parent": "", "hasChildren": False, "diff": None,
             "keeperId": None, "hueIndex": None},
        ],
    )
    fixtures[WORKSPACE_CHILDREN_LIB_PATH] = (
        200,
        [
            {"path": "lib/a.ml", "label": "a.ml", "depth": 1, "parent": "lib",
             "hasChildren": False, "diff": None, "keeperId": None,
             "hueIndex": None},
        ],
    )
    file_response = (
        200, {"ok": True, "content": "let x = 1\n(* hi *)\nlet y = x\n"})
    fixtures[WORKSPACE_FILE_AML_PATH] = file_response
    # uri's Query_value encoding may or may not spell the slash; serve both.
    fixtures["/api/v1/workspace/file?path=lib%2Fa.ml"] = file_response
    history_response = (
        200,
        {
            "ok": True,
            "commits": [
                {"hash": "abc1234", "timestamp_ms": 1787000000000,
                 "author": "keeper-alpha", "subject": "feat: add x"},
                {"hash": "def5678", "timestamp_ms": 1786900000000,
                 "author": "vincent", "subject": "chore: seed the file"},
            ],
        },
    )
    fixtures["/api/v1/git/log?path=lib/a.ml&limit=50"] = history_response
    fixtures["/api/v1/git/log?path=lib%2Fa.ml&limit=50"] = history_response
    diff_response = (
        200,
        {
            "has_changes": True,
            "unified": [
                {"kind": "delete", "oldLine": 1, "newLine": None,
                 "text": "let a = 1"},
                # The added row is the working tree's line 1, so its text
                # agrees with the file fixture -- the renderer now resolves
                # it back to the lexed row by that number.
                {"kind": "add", "oldLine": None, "newLine": 1,
                 "text": "let x = 1"},
            ],
        },
    )
    for diff_path in (
        "/api/v1/git/diff?path=lib/a.ml&base_ref=HEAD",
        "/api/v1/git/diff?path=lib%2Fa.ml&base_ref=HEAD",
    ):
        fixtures[diff_path] = diff_response
    hover_response = (200, {"ok": True, "data": {"kind": "hover", "text": "int"}})
    definition_response = (
        200,
        {"ok": True, "data": {"kind": "locations", "locations": [
            {"path": "lib/a.ml", "inside_workspace": True, "line": 2,
             "character": 1},
        ]}},
    )
    y_definition_response = (
        200,
        {"ok": True, "data": {"kind": "locations", "locations": [
            {"path": "lib/a.ml", "inside_workspace": True, "line": 1,
             "character": 5},
        ]}},
    )
    for enc in ("lib/a.ml", "lib%2Fa.ml"):
        fixtures[
            f"/api/v1/lsp/question?question=hover&path={enc}&line=1&symbol=x"
        ] = hover_response
        fixtures[
            f"/api/v1/lsp/question?question=definition&path={enc}&line=1&symbol=x"
        ] = definition_response
        fixtures[
            f"/api/v1/lsp/question?question=definition&path={enc}&line=3&symbol=y"
        ] = y_definition_response
    return fixtures


CODE_MEMO_FILE_PATH = "/api/v1/workspace/file?path=init.lua"
# The gutter mark a memo row wears (RFC-0429 §3.1); a Keeper's own change
# wears a dimmer one, so the two are told apart by glyph.
MEMO_GUTTER_MARK = "\u25cf".encode()
# What the title says while the cursor sits on the memo's line. Truncated by
# the frame if the pane is narrow, so the needle stops well before the end of
# the memo's text.
MEMO_CURSOR_RIDER = b"memo alpha (decision) keep the coroutine"

CODE_MEMO_SOURCE = (
    "local lock = 1\n"
    "-- masc(alpha) decision: keep the coroutine, the pool is single threaded\n"
    "local function read() return lock end\n"
)


def code_memo_fixtures() -> HttpFixtures:
    """A Lua file with a memo in it. Lua has no lexer in the TUI, so this is
    the case the memo list used to miss: it read only rows the lexer had
    marked as a comment, and an unlexed file has none."""
    fixtures = keeper_runtime_http_fixtures()
    fixtures[WORKSPACE_TREE_ROOT_PATH] = (
        200,
        [
            {"path": "init.lua", "label": "init.lua", "depth": 0, "parent": "",
             "hasChildren": False, "diff": None, "keeperId": None,
             "hueIndex": None},
        ],
    )
    fixtures[CODE_MEMO_FILE_PATH] = (200, {"ok": True, "content": CODE_MEMO_SOURCE})
    return fixtures


def code_memo_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    """m on an open file lists the memos written in that file's own comment
    syntax. The file here is Lua, whose comments the TUI does not colour, so
    the list is the proof that the reader looks for the file's markers rather
    than for something the lexer marked."""
    palette_go(process, master_fd, output, b"go code", b"init.lua")
    send_and_wait(process, master_fd, output, b"\r", b"local lock = 1")
    # The wait needle has to be text only the overlay draws: the memo's own
    # words are line 2 of the file and are already on screen before m, so a
    # redraw arriving in the wait window would satisfy a needle taken from
    # the file pane and read the wrong frame back.
    listed = send_and_wait(process, master_fd, output, b"m", b"(decision)")
    plain = CSI_RE.sub(b"", listed).decode("utf-8")
    for needle in ("notes: init.lua", "L2", "alpha", "(decision)"):
        if needle not in plain:
            raise AssertionError(
                f"the memo list missed {needle!r}: {plain!r}"
            )
    if "no memo in this file" in plain:
        raise AssertionError(
            f"the memo list called a file with a memo empty: {plain!r}"
        )
    # The same key puts the list away and the file comes back.
    closed = send_and_wait(
        process, master_fd, output, b"m", b"local function read"
    )
    if "notes: init.lua" in CSI_RE.sub(b"", closed).decode("utf-8"):
        raise AssertionError(
            f"a second m left the memo list open: {closed!r}"
        )

    # RFC-0429 §3.1: the memo is a margin, not a replacement. With the body
    # back, the row that carries the memo wears a mark in the gutter, and
    # putting the cursor on that row says what the mark marks without opening
    # the list again. These run after the list is closed on purpose: the
    # rider repeats the memo's words in the title, and asserting them earlier
    # would let a title redraw satisfy a needle meant for the overlay.
    rows = screen_rows(bytes(output))
    memo_rows = [text for text in rows.values() if b"masc(alpha) decision" in text]
    if not memo_rows:
        raise AssertionError(f"the memo's own row is not on screen: {rows!r}")
    if not any(MEMO_GUTTER_MARK in text for text in memo_rows):
        raise AssertionError(
            f"the row carrying a memo wears no gutter mark: {memo_rows!r}"
        )

    # The memo sits on line 2 and the file opens on line 1. The needle is the
    # memo's own row: the cursor line carries its gutter in reverse video, so
    # landing there redraws that row whatever the title does. A needle taken
    # from the title would make this wait, not the assertion below, the thing
    # that notices a missing rider.
    on_the_memo = send_and_wait(process, master_fd, output, b"j", b"masc(alpha)")
    title = screen_text(bytes(output))
    if MEMO_CURSOR_RIDER not in title:
        raise AssertionError(
            "the cursor on a memo line did not say what the memo says: "
            f"{CSI_RE.sub(b'', on_the_memo)!r}"
        )
    os.write(master_fd, b"q")


def code_lane_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    """The Code surface: one directory level, Enter drills, a file opens
    lexed. The keyword's yellow span and the dim gutter are the claim that
    the file was lexed, not just printed."""
    listing = palette_go(process, master_fd, output, b"go code", b"README.md")
    plain = CSI_RE.sub(b"", listing).decode("utf-8")
    for needle in ("lib", "README.md"):
        if needle not in plain:
            raise AssertionError(f"Code did not list {needle!r}: {plain!r}")
    drain_until_quiet(process, master_fd, output)
    assert_pane_surface_title_over_gap(
        bytes(output), b"MASC Workspace / Code", b"\xe2\x96\xb8 / (2)"
    )
    send_and_wait(process, master_fd, output, b"\r", b"a.ml")
    # Which colour a keyword wears belongs to the theme, and the theme moves:
    # #30723 turned it bright magenta and this waited out its timeout on the
    # old yellow. What this scenario is about is that the file arrived lexed,
    # so it asks for a style around the span and not for a particular one.
    opened = send_and_wait(process, master_fd, output, b"\r", LEXED_LET)
    if re.search(rb"\x1b\[7m\s+1\x1b\[0m", opened) is None:
        raise AssertionError(
            f"the cursor line's gutter is not highlighted: {opened!r}"
        )
    if re.search(rb"\x1b\[[0-9;]*m" + re.escape(b"(* hi *)") + rb"\x1b\[0m", opened) is None:
        raise AssertionError(f"the comment did not colour: {opened!r}")
    # This scenario runs at 100 columns, under the split threshold, so the
    # frame draws one pane and the focus chooses which. h and l move that
    # focus, and with a file open they are the only way back to the tree:
    # Esc closes the file. The keys were refused under the threshold until
    # #39017, on a screen already drawing their answer.
    tree_focus = send_and_wait(
        process, master_fd, output, b"h", b"j/k:move  h/l:pane"
    )
    if "\u25c6 a.ml" not in CSI_RE.sub(b"", tree_focus).decode("utf-8"):
        raise AssertionError(
            f"h did not put the tree back under the focus: {tree_focus!r}"
        )
    send_and_wait(process, master_fd, output, b"l", b"j/k:scroll  h/l:pane")
    # Shift-Right pans the open file sideways by one cell: lowercase h/l now
    # choose the split pane. The keyword span is cut mid-word but its colour
    # still opens the remainder, and the title says the view is shifted.
    panned = send_and_wait(
        process, master_fd, output, b"\x1b[1;2C\x1b[1;2C", b"(col 3)"
    )
    cut_under_style = re.compile(
        rb"\x1b\[[0-9;]*m" + re.escape(b"t") + rb"\x1b\[0m x = "
        rb"\x1b\[[0-9;]*m" + re.escape(b"1") + rb"\x1b\[0m"
    )
    if cut_under_style.search(panned) is None:
        raise AssertionError(f"pan did not cut by cells under the style: {panned!r}")
    send_and_wait(
        process,
        master_fd,
        output,
        b"\x1b[1;2D\x1b[1;2D",
        LEXED_LET,
    )
    # With the file focused, "/" searches its lines: typing jumps the line
    # cursor (the reverse gutter) to the match, and Enter keeps the query.
    searched = send_and_wait(process, master_fd, output, b"/hi", b"/hi")
    if re.search(rb"\x1b\[7m\s+2\x1b\[0m", searched) is None:
        raise AssertionError(
            f"the file search did not move the cursor gutter: {searched!r}"
        )
    # Enter retains the query for n/N and removes its editing cursor.
    # The settled footer still starts with the retained search, not the
    # generic hints that were drawn before search began.
    settled = send_and_wait(
        process, master_fd, output, b"\r", b"/hi (1) n/N",
    )
    if "▌".encode() in screen_text(settled):
        raise AssertionError(f"Enter left the search prompt editing: {settled!r}")
    # d swaps the content for the working tree's diff against HEAD; Esc
    # swaps back to the lexed content.
    # The added row now arrives lexed, so the wait needle is the keyword
    # span rather than the plain text the styles split apart.
    diff_frame = send_and_wait(
        process, master_fd, output, b"d", LEXED_LET
    )
    diff_plain = CSI_RE.sub(b"", diff_frame).decode("utf-8")
    for needle in ("diff col 1 vs HEAD: lib/a.ml", "let a = 1", "let x = 1"):
        if needle not in diff_plain:
            raise AssertionError(
                f"the diff view missed {needle!r}: {diff_plain!r}"
            )
    # The added row is the working tree's own line, so it carries the
    # lexer's colours (the keyword span) inside the diff band.
    if LEXED_LET.search(diff_frame) is None:
        raise AssertionError(
            f"the added diff row lost the lexer's colours: {diff_frame!r}"
        )
    send_and_wait(process, master_fd, output, b"\x1b", LEXED_LET)
    # H swaps the content for the commits that touched the file; Esc swaps
    # back (the lexed keyword span is the proof the content returned).
    # The needle is a commit hash so the wait crosses the "(loading
    # history)" frame and lands on the fetched listing.
    history = send_and_wait(process, master_fd, output, b"H", b"abc1234")
    history_plain = CSI_RE.sub(b"", history).decode("utf-8")
    for needle in ("history: lib/a.ml", "feat: add x", "def5678", "vincent"):
        if needle not in history_plain:
            raise AssertionError(
                f"history missed {needle!r}: {history_plain!r}"
            )
    if "Left / Esc:back" not in history_plain:
        raise AssertionError(
            f"history footer does not offer the way back: {history_plain!r}"
        )
    send_and_wait(process, master_fd, output, b"\x1b", LEXED_LET)
    # The search above left the cursor on line 2; the lsp fixtures answer
    # about line 1, so put the cursor back where the question is.
    send_and_wait(process, master_fd, output, b"k", b"\x1b[7m   1\x1b[0m")
    # The cursor line holds one name (let is a keyword, 1 a number), so K
    # asks about it at once -- no palette between the keypress and the
    # answer beside the title.
    send_and_wait(process, master_fd, output, b"K", b"x: int")
    # D likewise jumps straight to the definition; the answer is inside the
    # same file, so the cursor (the reverse gutter) moves to its line.
    landed = send_and_wait(process, master_fd, output, b"D", b"x: lib/a.ml:2")
    if re.search(rb"\x1b\[7m\s+2\x1b\[0m", landed) is None:
        raise AssertionError(
            f"the definition jump did not move the cursor gutter: {landed!r}"
        )
    # B walks back to where the jump left from: the cursor gutter returns
    # to line 1.
    returned = send_and_wait(
        process, master_fd, output, b"B",
        re.compile(rb"\x1b\[7m\s+1\x1b\[0m"),
    )
    if re.search(rb"\x1b\[7m\s+2\x1b\[0m", returned) is not None:
        raise AssertionError(
            f"B left the cursor on the jumped-to line: {returned!r}"
        )
    # A line with several names (let y = x) opens the palette with each as
    # an entry instead of guessing one.
    send_and_wait(
        process, master_fd, output, b"jj",
        re.compile(rb"\x1b\[7m\s+3\x1b\[0m"),
    )
    # The palette footer is [key:label] items now, not a dotted row: #35585
    # rewrote it so Masc_tui_footer could shed whole keys and keep Esc at
    # narrow widths, and the action label came down to lower case with it
    # ("[Enter] Ask" -> "Enter:ask", masc_tui_render.ml). The old needle
    # matched no row, so this read as "D opened nothing".
    choices = send_and_wait(process, master_fd, output, b"D", b"Enter:ask")
    choices_plain = CSI_RE.sub(b"", choices).decode("utf-8")
    if ("definition" not in choices_plain or "2 names on line 3" not in choices_plain
            or "▸ y" not in choices_plain
            or re.search(r"│\s+x\s+│", choices_plain) is None):
        raise AssertionError(
            f"the candidate list missed the second name: {choices!r}"
        )
    # Enter alone runs the highlighted candidate (y): the answer names
    # the location and the cursor jumps to it.
    picked = send_and_wait(
        process, master_fd, output, b"\r", b"y: lib/a.ml:1"
    )
    if re.search(rb"\x1b\[7m\s+1\x1b\[0m", picked) is None:
        raise AssertionError(
            f"the candidate jump did not move the cursor gutter: {picked!r}"
        )
    os.write(master_fd, b"q")



# RFC-0429 §1.3 and §4. The second recorded change carries
# "let b = 2\nlet c = 3", and the Changes list has one line per row to say it
# in. Printing the newline writes the rest of the row wherever the terminal's
# cursor lands; Tui_decode.preview_line projects it to one cell instead.
#
# This is its own lane rather than an assertion inside the default keyboard
# regression: that lane stops before reaching the Changes surface, at the exit
# step of "A spilled paste is written where the keeper reads" (issue filed), so
# an assertion added there would never run and would read as green.
CHANGES_NEWLINE_PROJECTED = "let b = 2\u23celet c = 3".encode()


def changes_newline_projection_interaction(
    process: subprocess.Popen[bytes],
    master_fd: int,
    _slave_fd: int,
    output: bytearray,
    _base_path: str,
) -> None:
    open_changes(process, master_fd, output)
    send_and_wait(process, master_fd, output, b"\x1b[B", b"preview masc:lib/second.ml")

    rows = screen_rows(bytes(output))
    carrying_a_newline = sorted(row for row, text in rows.items() if b"\n" in text)
    if carrying_a_newline:
        raise AssertionError(
            "the Changes frame printed a raw newline on row(s) "
            f"{carrying_a_newline}: { {row: rows[row] for row in carrying_a_newline} !r}"
        )
    if CHANGES_NEWLINE_PROJECTED not in screen_text(bytes(output)):
        naming = [text for text in rows.values() if b"second.ml" in text]
        raise AssertionError(
            f"the WHAT column did not project the newline to one cell: {naming!r}"
        )
    os.write(master_fd, b"q")


def run_changes_newline_regression(executable: str) -> None:
    fixtures = keeper_runtime_http_fixtures()
    fixtures[FILE_CHANGES_ALPHA_PATH] = file_changes_alpha_response()
    run_terminal_scenario(
        executable,
        description="A recorded newline is one cell in the Changes list",
        interact=changes_newline_projection_interaction,
        http_fixtures=fixtures,
    )


def run_code_memo_regression(executable: str) -> None:
    run_terminal_scenario(
        executable,
        description="Code lane lists a memo in a language with no lexer",
        interact=code_memo_interaction,
        http_fixtures=code_memo_fixtures(),
    )
