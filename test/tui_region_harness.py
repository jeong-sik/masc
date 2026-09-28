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
  is a load failure standing in for the layout.
"""
import base64
import re
import time
import zlib

import test_tui_keyboard_input as h

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

# "1-22/38", "[lines 3-9/40]": a window onto a longer list. The heights the
# frame's readers compute show up here directly.
WINDOW_RE = re.compile(rb"\b\d+-\d+/\d+\b")

# The harness answers these itself (test_tui_keyboard_input.test_http_endpoint).
HARNESS_PATHS = frozenset(("/health", "/health?full=1"))
HARNESS_PATH_PREFIXES = frozenset((
    h.DASHBOARD_GOALS_PATH,
    h.RUNTIME_RESOLVED_PATH,
    h.ACCOUNT_EMAILS_PATH,
))

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


def is_rule(text: bytes) -> bool:
    plain = text.decode("utf-8", "replace")
    return any(glyph * RULE_RUN in plain for glyph in RULE_GLYPHS)


def measure(rows: dict[int, bytes], *, composer_rows: int) -> dict[str, object]:
    """Where the screen's rows sit, found by structure.

    Row 1 is the tab strip. The frame's title is the first row drawn below
    it. Rules are the rows holding a run of box glyphs. The body ends where
    the composer's rows begin -- [composer_rows] is the screen's, since a
    screen that draws its own input has none -- and the footer is the body's
    last drawn row."""
    last_body = TERMINAL_ROWS - composer_rows
    for row in range(last_body + 1, TERMINAL_ROWS + 1):
        if not rows[row].strip():
            raise AssertionError(f"composer row {row} is blank: {rows!r}")
    drawn = [row for row in range(2, last_body + 1) if rows[row].strip()]
    if not drawn:
        raise AssertionError(f"nothing is drawn below the strip: {rows!r}")
    title = min(drawn)
    footer = max(drawn)
    return {
        "title": title,
        "rules": tuple(row for row in drawn if is_rule(rows[row])),
        "footer": footer,
        "blank": sum(1 for row in range(title + 1, footer) if not rows[row].strip()),
        "windows": tuple(
            match.decode()
            for row in range(1, TERMINAL_ROWS + 1)
            for match in WINDOW_RE.findall(rows[row])
        ),
    }


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


def check_all(
    measured: dict[tuple[str, int], dict[str, object]],
    expected: dict[tuple[str, int], dict[str, object]],
) -> None:
    """Print every measurement, then fail on any that differs from [expected]."""
    print("measured = {")
    for key, value in measured.items():
        print(f"    {key!r}: {value!r},")
    print("}")
    moved = {
        key: (expected.get(key), value)
        for key, value in measured.items()
        if expected.get(key) != value
    }
    unmeasured = sorted(set(expected) - set(measured))
    if moved or unmeasured:
        raise AssertionError(
            "rows moved (expected, measured): "
            + ", ".join(f"{key}: {pair}" for key, pair in moved.items())
            + (f"; expected but not measured: {unmeasured}" if unmeasured else "")
        )
