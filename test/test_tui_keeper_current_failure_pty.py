"""Render and clear a Keeper's current failure through the actual TUI.

The HTTP fixture supplies a synthetic summary. This scenario verifies display
and refresh; the native producer-to-decoder test owns registry provenance.
"""

import os
import subprocess
import sys
from typing import cast

import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui_render.ml",
    "lib/tui_decode.ml",
)

ROSTER_PATH = "/api/v1/gate/keepers?detailed=true"
# Longer than the whole terminal width, with short words so wrapping cannot
# split a token. The final token exposes truncation at the end of the cause.
SUMMARY = " ".join(f"failure-detail-{index:02d}" for index in range(20))


def screen_lines(output: bytearray) -> list[str]:
    end = output.rfind(h.FRAME_END)
    if end < 0:
        return []
    rows = h.screen_rows(bytes(output[: end + len(h.FRAME_END)]))
    return [rows[number].decode("utf-8").strip(" │") for number in sorted(rows)]


def failure_cleared(output: bytearray) -> bool:
    lines = screen_lines(output)
    heading = next(
        (index for index, line in enumerate(lines) if "Current failure" in line),
        None,
    )
    if heading is None:
        return False
    content = next((line for line in lines[heading + 1 :] if line), None)
    return content == "none" and not any("failure-detail-" in line for line in lines)


def run(executable: str) -> None:
    fixtures = h.keeper_runtime_http_fixtures()
    response = cast(h.HttpResponse, fixtures[ROSTER_PATH])
    payload = cast(dict[str, object], response[1])
    keepers = cast(list[dict[str, object]], payload["keepers"])
    alpha = next(row for row in keepers if row["name"] == "alpha")
    alpha["runtime_blocker_summary"] = SUMMARY

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        h.resize_and_wait(
            process, master_fd, output, rows=38, columns=100, needle=b"MASC Overview"
        )
        h.send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
        h.select_keeper_row(process, master_fd, output, b"alpha")
        h.send_and_wait(process, master_fd, output, b"\r", b"Current failure")
        h.drain_until_quiet(process, master_fd, output)
        lines = screen_lines(output)
        visible = "\n".join(lines)
        for word in SUMMARY.split():
            if word not in visible:
                raise AssertionError(f"current failure lost {word!r}: {visible}")
        carrying = [line for line in lines if "failure-detail-" in line]
        if len(carrying) < 2:
            raise AssertionError(f"the long failure was not wrapped: {visible}")

        # The fixture server reads this same body on the explicit refresh.
        # Judge the reconstructed screen: the output stream retains old frames.
        alpha["runtime_blocker_summary"] = None
        os.write(master_fd, b"r")
        if not h.wait_for_fixture_state(
            process,
            master_fd,
            output,
            lambda: failure_cleared(output),
            timeout=5.0,
        ):
            raise AssertionError(
                f"refresh did not clear the current failure: {screen_lines(output)}"
            )
        os.write(master_fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="Keeper current failure wraps and clears after refresh",
        interact=interact,
        http_fixtures=fixtures,
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("keeper current failure: PASS")
