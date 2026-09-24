"""The approval detail says when the ask runs past the frame it is drawn in."""

import os
import re
import sys

import test_tui_keyboard_input as h

# The regression this scenario stands over: the detail pane scrolls, but
# nothing on it said the ask was longer than the frame, so an operator could
# read the first screen, believe it whole, and press y. The footer now carries
# the window line the other reading panes carry when the field list outgrows
# the frame. See issue #38385.
SOURCE_MODULES = (
    "bin/masc_tui_render.ml",
)

# Long enough that the wrapped value alone is taller than the pane at the rows
# this scenario draws, so the tail exists only below the fold.
LONG_BODY = "deploy " + ("x" * 4000) + " TAIL-38385"
SHORT_BODY = "deploy now"

# [Masc_tui_scroll.window_text]: "1-34/55".
WINDOW_LINE = re.compile(rb"\[rows \d+-\d+/\d+\]")


def approval_with_body(body: str) -> h.HttpFixtures:
    fixtures = h.blocked_gate_detail_http_fixtures()
    row = fixtures["/api/v1/dashboard/gate"][1]["approval_queue"][0]
    row["tool_name"] = "connector_post"
    row["input"] = {"connector": "discord", "content": body}
    row["input_preview"] = '{"connector":"discord","content'
    return fixtures


def open_detail(process, master_fd, output, opening: bytes) -> None:
    h.resize_and_wait(
        process, master_fd, output, rows=40, columns=100, needle=b"MASC Overview"
    )
    h.tab_until(process, master_fd, output, b"MASC Approvals")
    # The row names the operation the producer sent, verbatim.
    h.wait_for_output(process, master_fd, output, b"connector_post", start=0, timeout=5.0)
    # The queue row's preview stops before the body, so these bytes can only
    # come from the detail pane this scenario is about.
    h.send_and_wait(process, master_fd, output, b"\r", opening)


def footer_row(output: bytearray) -> bytes:
    """The footer the pane drew, read off the reconstructed screen."""
    rows = h.screen_rows(bytes(output))
    carrying = [text for _, text in sorted(rows.items()) if b"j/k" in text]
    if not carrying:
        raise AssertionError(f"no footer row on screen: {rows!r}")
    return carrying[-1]


def run(executable: str) -> None:
    def overflow_says_so(process, master_fd, _slave_fd, output, _base_path):
        open_detail(process, master_fd, output, b"deploy")
        footer = footer_row(output)
        if not WINDOW_LINE.search(footer):
            raise AssertionError(
                "the ask ran past the frame but the footer did not say so: "
                f"{footer!r}"
            )
        os.write(master_fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="An approval detail longer than its frame says so",
        interact=overflow_says_so,
        http_fixtures=approval_with_body(LONG_BODY),
    )

    def short_stays_quiet(process, master_fd, _slave_fd, output, _base_path):
        open_detail(process, master_fd, output, b"deploy")
        footer = footer_row(output)
        if WINDOW_LINE.search(footer):
            raise AssertionError(
                "the ask fit the frame but the footer claimed a window: "
                f"{footer!r}"
            )
        os.write(master_fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="An approval detail that fits its frame carries no window line",
        interact=short_stays_quiet,
        http_fixtures=approval_with_body(SHORT_BODY),
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("approval detail scroll pty: PASS")
