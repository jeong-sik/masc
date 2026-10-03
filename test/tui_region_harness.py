"""What the region baseline suites share: settling a screen, reading its rows
by structure, proving every request was answered, and printing the screen.

The workbench RFC's region steps (section 5.9, G0 to G5) move rows. Each
baseline suite opens the screens one step's readers draw and pins where their
rows sit, so the step changes those numbers on purpose. A number is only worth
pinning when the screen it came from is whole, loaded and still, so the
helpers here refuse a screen that is not:

- a screen is read only after the terminal has gone quiet and the last bytes
  close a frame, never at a timeout;
- every one of the terminal's rows must have been written since the last
  full redraw -- a row nobody drew is not read as blank;
- every request the TUI made must have been answered by a fixture, so no row
  is a load failure standing in for the layout;
- the frame has cut nothing: a body taller than its budget ends in the
  frame's own "+N rows not shown" note, which moves no row this measures.
"""
import base64
import re
import time
import unicodedata
import zlib

import tui_keyboard_harness as h

TERMINAL_ROWS = 30

# How long the terminal must stay silent before a screen is read, and the most
# a scenario waits for that. The header clock redraws once a second, so a
# quarter second of silence falls between two ticks; ten seconds without one
# means the TUI never stopped drawing, which is a failure, not a screen.
QUIET_SECONDS = 0.25
QUIET_LIMIT_SECONDS = 10.0

# A rule is drawn as a run of box glyphs; a side pane beside it leaves the run
# intact. Eight is shorter than any rule and longer than any glyph run in text.
RULE_GLYPHS = ("─", "━")
RULE_RUN = 8
BOX_TOP_LEFT = "┌"
BOX_BOTTOM_LEFT = "└"
# A side pane's edge on the title row: its own border, or the corner of a
# framed body next to it.
BORDER_GLYPHS = frozenset(
    ("│", "┃", "┌", "┐", "└", "┘"))
# Every box-drawing glyph. The footer is the frame's key hints, and a footer
# row holding one of these is a pane's border the frame pushed down onto it.
BOX_DRAWING = range(0x2500, 0x2580)

# "1-22/38", "[lines 3-9/40]": a window onto a longer list. The heights the
# frame's readers compute show up here directly.
WINDOW_RE = re.compile(rb"\b\d+-\d+/\d+\b")

# The note the frame draws in place of the rows it cut
# (Masc_tui_render_prim, "  +%d %s not shown").
FRAME_CUT_RE = re.compile(rb"\+\d+ \S+ not shown")

# The harness answers these itself (test_tui_keyboard_input.test_http_endpoint).
HARNESS_PATHS = frozenset(("/health", "/health?full=1"))
HARNESS_PATH_PREFIXES = frozenset((
    h.DASHBOARD_GOALS_PATH,
    h.RUNTIME_RESOLVED_PATH,
    h.ACCOUNT_EMAILS_PATH,
))

# The harness's 503 sentinel, as the TUI repeats it in a row.
UNANSWERED_TEXT = b"fixture endpoint unavailable"

# Frames are printed zlib-compressed and base64-encoded, in lines this long:
# dune cuts the middle out of an action's output past a size, and raw
# redraws ran past it.
PRINT_LINE_CHARS = 4096


class ServedFixtures(dict):
    """Fixtures that remember every path the TUI asked for.

    The harness looks each request up with `in` before answering, so the
    lookups are the requests. A request no fixture and no harness default
    answers got the 503 sentinel, and whatever row showed that failure would
    be measured as layout."""

    def __init__(self, fixtures: h.HttpFixtures) -> None:
        super().__init__(fixtures)
        self.asked: set[str] = set()

    def __contains__(self, key: object) -> bool:
        if isinstance(key, str):
            self.asked.add(key)
        return super().__contains__(key)

    def answered(self, path: str) -> bool:
        path_only = path.split("?", 1)[0]
        return (
            dict.__contains__(self, path)
            or dict.__contains__(self, path_only)
            or path in HARNESS_PATHS
            or path_only in HARNESS_PATH_PREFIXES
        )

    def unanswered(self) -> list[str]:
        return sorted(path for path in set(self.asked) if not self.answered(path))


def settle(process, fd, output: bytearray) -> None:
    """Wait until the terminal is silent and its last bytes close a frame."""
    deadline = time.monotonic() + QUIET_LIMIT_SECONDS
    while True:
        before = len(output)
        time.sleep(QUIET_SECONDS)
        h.read_available(fd, output)
        if len(output) == before and bytes(output).rstrip().endswith(h.FRAME_END):
            return
        if process.poll() is not None:
            raise AssertionError(f"the TUI exited while settling: {process.returncode}")
        if time.monotonic() > deadline:
            raise AssertionError(
                f"the terminal did not go quiet on a whole frame within "
                f"{QUIET_LIMIT_SECONDS}s: {h.screen_text(bytes(output))!r}"
            )


def whole_screen(output: bytearray) -> dict[int, bytes]:
    """The screen's rows, each one written since the last full redraw."""
    rows = h.screen_rows(bytes(output))
    missing = [row for row in range(1, TERMINAL_ROWS + 1) if row not in rows]
    if missing:
        raise AssertionError(f"rows {missing} were not drawn since the clear: {rows!r}")
    return rows


def assert_answered(fixtures: ServedFixtures, where: str) -> None:
    unanswered = fixtures.unanswered()
    if unanswered:
        raise AssertionError(f"{where}: requests no fixture answered: {unanswered}")


def assert_whole(rows: dict[int, bytes], where: str) -> None:
    """No row reports a read the fixtures left unanswered, and the frame cut
    none of the body."""
    for row, text in rows.items():
        if UNANSWERED_TEXT in text:
            raise AssertionError(f"{where}: row {row} reports a failed read: {text!r}")
        if FRAME_CUT_RE.search(text):
            raise AssertionError(f"{where}: row {row} is the frame's cut note: {text!r}")


def is_rule(text: str) -> bool:
    return any(glyph * RULE_RUN in text for glyph in RULE_GLYPHS)


def holds_box_drawing(text: str) -> bool:
    return any(ord(character) in BOX_DRAWING for character in text)


def cell_width(character: str) -> int:
    if unicodedata.combining(character):
        return 0
    return 2 if unicodedata.east_asian_width(character) in ("W", "F") else 1


def cells(text: bytes, left: int, right: int) -> str:
    """The display cells [left, right) of a plain row. A wide glyph that
    straddles an edge is left out: it belongs to neither side whole."""
    out, column = [], 0
    for character in text.decode("utf-8", "replace"):
        width = cell_width(character)
        if column >= left and column + width <= right:
            out.append(character)
        column += width
    return "".join(out)


def measure(
    rows: dict[int, bytes],
    *,
    columns: int,
    composer_rows: int,
    left: int = 0,
    right: int | None = None,
) -> dict[str, object]:
    """Where the body's rows sit, found by structure.

    Row 1 is the tab strip and row 2 the body's top: blank on a full-screen
    surface, a box's top border on a framed pane. The footer -- the frame's key
    hints -- is the body's last row, the one right above the composer's
    [composer_rows] (none on a screen that draws its own input); it must hold
    text and no box glyph, since a pane that outgrew its rows pushes its
    border down onto it. The body sits between [left] and [right], the roster
    to its left and the Activity pane to its right taking the rest. Within
    it: the title is the first drawn row below the top, rules are rows
    holding a run of box glyphs, a framed pane's bottom border holds its
    bottom corner, and [last] is the last drawn row above the footer."""
    right = columns if right is None else right
    body = {row: cells(rows[row], left, right) for row in range(1, TERMINAL_ROWS + 1)}
    footer = TERMINAL_ROWS - composer_rows
    for row in range(footer + 1, TERMINAL_ROWS + 1):
        if not rows[row].strip():
            raise AssertionError(f"composer row {row} is blank: {rows!r}")
    hints = rows[footer].decode("utf-8", "replace")
    if not hints.strip() or holds_box_drawing(hints):
        raise AssertionError(f"row {footer} is not the key hints: {hints!r}")
    top = body[2].strip()
    if top and not top.startswith(BOX_TOP_LEFT):
        raise AssertionError(f"row 2 is neither blank nor a box top: {top!r}")
    drawn = [row for row in range(3, footer) if body[row].strip()]
    if not drawn:
        raise AssertionError(f"nothing is drawn in the body: {rows!r}")
    title, last = min(drawn), max(drawn)
    bottoms = [row for row in drawn if body[row].strip().startswith(BOX_BOTTOM_LEFT)]
    return {
        "top": "border" if top else "blank",
        "title": title,
        "rules": tuple(row for row in drawn if is_rule(body[row])),
        "bottom": max(bottoms) if bottoms else None,
        "last": last,
        "blank": sum(1 for row in range(title + 1, footer) if not body[row].strip()),
        "windows": tuple(
            match.decode()
            for row in range(3, footer)
            for match in WINDOW_RE.findall(body[row].encode())
        ),
    }


def body_row(rows: dict[int, bytes], row: int, *, left: int, right: int) -> str:
    """One body row's text, whitespace collapsed."""
    return " ".join(cells(rows[row], left, right).split())


def measure_pane(rows: dict[int, bytes], *, left: int, right: int) -> dict[str, int]:
    """A framed side pane's top and bottom border rows, in cells [left, right)."""
    pane = {row: cells(rows[row], left, right).strip() for row in rows}
    tops = [row for row, text in pane.items() if text.startswith(BOX_TOP_LEFT)]
    bottoms = [row for row, text in pane.items() if text.startswith(BOX_BOTTOM_LEFT)]
    if len(tops) != 1 or len(bottoms) != 1:
        raise AssertionError(f"the pane in cells {left}-{right} has tops {tops} "
                             f"and bottoms {bottoms}: {rows!r}")
    for row, left_corner, right_corner in ((tops[0], BOX_TOP_LEFT, "┐"),
                                           (bottoms[0], BOX_BOTTOM_LEFT, "┘")):
        border = cells(rows[row], left, right)
        expected = left_corner + "─" * (right - left - 2) + right_corner
        if border != expected:
            raise AssertionError(f"the pane in cells {left}-{right} has an incomplete border: {border!r}")
    if bottoms[0] <= tops[0]:
        raise AssertionError(f"the pane in cells {left}-{right} closes before its top: "
                             f"top {tops[0]}, bottom {bottoms[0]}")
    return {"top": tops[0], "bottom": bottoms[0]}


def assert_pane_edge(rows: dict[int, bytes], column: int, where: str) -> None:
    """The column a side pane's border stands in holds a border glyph on the
    title row, so a body slice cut there is cut at the pane and not inside
    the body."""
    edge = cells(rows[3], column, column + 1)
    if edge not in BORDER_GLYPHS:
        raise AssertionError(f"{where}: no pane border at cell {column} "
                             f"({edge!r}): {rows[3]!r}")


def print_screen(name: str, columns: int, output: bytearray) -> None:
    """The bytes the screen was built from since its last full redraw, for a
    reader to rebuild it from the log (docs/evidence/tui-region-baseline-*)."""
    drawn = bytes(output)
    cleared = drawn.rfind(h.FULL_REDRAW)
    if cleared >= 0:
        drawn = drawn[cleared:]
    encoded = base64.b64encode(zlib.compress(drawn, 9)).decode("ascii")
    print(f"=== region-baseline {name} {columns}x{TERMINAL_ROWS} begin ===")
    for start in range(0, len(encoded), PRINT_LINE_CHARS):
        print(encoded[start : start + PRINT_LINE_CHARS])
    print(f"=== region-baseline {name} {columns}x{TERMINAL_ROWS} end ===")


def print_measured(measured: dict[tuple[str, int], dict[str, object]]) -> None:
    print("measured = {")
    for key, value in measured.items():
        print(f"    {key!r}: {value!r},")
    print("}")

# Exact helper inputs consumed by the PR test selector.
SOURCE_MODULES = (
    "test/tui_keyboard_harness.py",
)
