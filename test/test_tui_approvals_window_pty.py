"""A short frame says which approvals it draws.

The queue's window used to draw only the rows that fit and nothing said the
rest existed: three approvals on an 80x17 frame drew two, under a title that
read "(3 op)", and an operator could read the screen, believe it whole, and
decide against a queue they had not seen. The window now spends one of its
rows on a line that says which rows these are and how many lie each way, and
draws that line only where rows are hidden.
"""

import os
import re
import sys

import tui_keyboard_harness as h

# Which of the three fixture approvals a row names, by its action type.
ROW_ACTIONS = (b"namespace_pause", b"keeper_probe", b"keeper_message")
WINDOW_LINE = re.compile(rb"\[approvals (\d+)-(\d+)/(\d+)\]\s+(.*?)\s+-- j/k to reach")


def last_frame(output: bytearray) -> dict[int, bytes]:
    end = output.rfind(h.FRAME_END)
    assert end >= 0, "no frame was completed"
    return h.screen_rows(bytes(output[: end + len(h.FRAME_END)]))


def approval_rows(rows: dict[int, bytes]) -> list[bytes]:
    """The queue's rows as drawn: the actor, then the action type column."""
    found = []
    for line in rows.values():
        match = re.match(rb"^\s*>?\s+masc-tui\s+(\w+)\s", line)
        if match and match.group(1) in ROW_ACTIONS:
            found.append(match.group(1))
    return found


def positioned_rows(rows: dict[int, bytes]) -> list[tuple[bytes | None, bytes]]:
    """The queue's rows with the `[i/n]` position a one-row window prefixes, if any."""
    found = []
    for line in rows.values():
        match = re.match(
            rb"^\s*>?\s*(?:\[(\d+/\d+)\]\s+)?masc-tui\s+(\w+)\s", line)
        if match and match.group(2) in ROW_ACTIONS:
            found.append((match.group(1), match.group(2)))
    return found


def window_line(rows: dict[int, bytes]) -> re.Match[bytes] | None:
    for line in rows.values():
        match = WINDOW_LINE.search(line)
        if match:
            return match
    return None


def open_approvals(process, fd, output) -> None:
    h.palette_go(process, fd, output, b"go Approvals", h.approvals_header(3))
    h.drain_until_quiet(process, fd, output)


def run(executable: str) -> None:
    fixtures, _items, _new = h.approval_selection_http_fixtures()

    def short_frame(process, fd, _slave, output, _base):
        h.resize_and_wait(process, fd, output, rows=17, columns=80,
                          needle=b"MASC Dashboard", final_cursor=b"\x1b[?25l")
        h.drain_until_quiet(process, fd, output)
        open_approvals(process, fd, output)
        seen: set[bytes] = set()
        for step in range(3):
            if step:
                h.send_and_wait(process, fd, output, b"j", b"[approvals ")
                h.drain_until_quiet(process, fd, output)
            rows = last_frame(output)
            drawn = approval_rows(rows)
            marker = window_line(rows)
            if marker is None:
                raise AssertionError(
                    f"step {step}: {len(drawn)} of 3 approvals drawn and no "
                    f"window line says so: {rows!r}")
            first, last, total = (int(marker.group(i)) for i in (1, 2, 3))
            if total != 3 or len(drawn) != last - first + 1:
                raise AssertionError(
                    f"step {step}: the window line reads {first}-{last}/{total} "
                    f"but {len(drawn)} row(s) are drawn: {rows!r}")
            if not first <= step + 1 <= last:
                raise AssertionError(
                    f"step {step}: the selected row {step + 1} is outside the "
                    f"window {first}-{last}")
            reach = marker.group(4).decode()
            hidden_above, hidden_below = first - 1, total - last
            if bool(hidden_above) != ("above" in reach) or \
                    bool(hidden_below) != ("below" in reach):
                raise AssertionError(
                    f"step {step}: the window line says {reach!r} with "
                    f"{hidden_above} above and {hidden_below} below")
            seen.update(drawn)
        if seen != set(ROW_ACTIONS):
            raise AssertionError(
                f"moving the cursor never reached every approval: {seen!r}")
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="A short Approvals frame says which rows it draws",
        interact=short_frame,
        http_fixtures=fixtures,
        refresh=2.0,
    )

    def one_row_frame(process, fd, _slave, output, _base):
        # 16 rows is the shortest frame that still draws the queue with a
        # single row (15 is the TUI's floor): no row to spend on a window
        # line, so the selected row carries its own `[i/n]` position.
        h.resize_and_wait(process, fd, output, rows=16, columns=80,
                          needle=b"MASC Dashboard", final_cursor=b"\x1b[?25l")
        h.drain_until_quiet(process, fd, output)
        open_approvals(process, fd, output)
        seen: list[bytes] = []
        for step in range(3):
            if step:
                h.send_and_wait(process, fd, output, b"j", b"/3]")
                h.drain_until_quiet(process, fd, output)
            rows = last_frame(output)
            drawn = positioned_rows(rows)
            if len(drawn) != 1:
                raise AssertionError(
                    f"step {step}: a one-row window drew {len(drawn)} rows: {rows!r}")
            position, action = drawn[0]
            if position != f"{step + 1}/3".encode():
                raise AssertionError(
                    f"step {step}: the row says position {position!r}, "
                    f"expected {step + 1}/3: {rows!r}")
            if action != ROW_ACTIONS[step]:
                raise AssertionError(
                    f"step {step}: the row is {action!r}, expected {ROW_ACTIONS[step]!r}")
            if window_line(rows) is not None:
                raise AssertionError(
                    f"step {step}: a window line is drawn with no row to spend: {rows!r}")
            seen.append(action)
        if tuple(seen) != ROW_ACTIONS:
            raise AssertionError(f"the cursor never reached every approval: {seen!r}")
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="A one-row Approvals frame carries its own position",
        interact=one_row_frame,
        http_fixtures=fixtures,
        refresh=2.0,
    )

    def tall_frame(process, fd, _slave, output, _base):
        h.resize_and_wait(process, fd, output, rows=38, columns=150,
                          needle=b"MASC Dashboard", final_cursor=b"\x1b[?25l")
        h.drain_until_quiet(process, fd, output)
        open_approvals(process, fd, output)
        rows = last_frame(output)
        drawn = approval_rows(rows)
        if len(drawn) != 3:
            raise AssertionError(f"a tall frame drew {len(drawn)} of 3: {rows!r}")
        if any(b"[approvals " in line for line in rows.values()):
            raise AssertionError(
                f"every row fits and the window line is drawn anyway: {rows!r}")
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="A frame that holds the whole queue draws no window line",
        interact=tall_frame,
        http_fixtures=fixtures,
        refresh=2.0,
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("approvals window pty: PASS")
