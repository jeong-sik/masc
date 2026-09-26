"""Observe complete, acknowledged cursor/scroll frames after terminal input.

Timings include the PTY and Python observer, not physical display latency.
The deterministic scheduling suite checks the absence of a frame-interval
delay; this scenario checks the resulting frames and prints observations.
"""
import hashlib
import json
import os
import select
import sys
import time

import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui.ml",
    "bin/masc_tui_render_schedule.ml",
)


def run(executable: str) -> None:
    samples = []
    with open(executable, "rb") as stream:
        binary_sha256 = hashlib.file_digest(stream, "sha256").hexdigest()
    with open(__file__, "rb") as stream:
        script_sha256 = hashlib.file_digest(stream, "sha256").hexdigest()

    def interact(process, master_fd, _slave_fd, output, _base_path):
        def transition(label, data, needle):
            # The needle must name a state different from the completed
            # screen before the input. Unrelated background frames cannot
            # acknowledge this transition.
            # Read without a settling sleep: the preceding acknowledged
            # frame makes the next key exercise the recent-frame deadline.
            h.read_available(master_fd, output)
            completed = output.rfind(h.FRAME_END) + len(h.FRAME_END)
            rows = h.screen_rows(bytes(output[:completed]), preserve_styles=True)
            if any(h.find_needle(row, needle) >= 0 for row in rows.values()):
                raise AssertionError(f"{label}: target was already visible")
            start = len(output)
            started = time.perf_counter_ns()
            h.write_all(master_fd, output, data)
            deadline = time.monotonic() + 3.0
            while True:
                found = h.find_needle(output, needle, start)
                if found >= 0:
                    needle_end = h.end_of_needle(output, needle, start)
                    if output.find(h.FRAME_END, needle_end) >= 0:
                        break
                if process.poll() is not None:
                    raise AssertionError(f"{label}: TUI exited before expected frame")
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise AssertionError(f"{label}: expected frame did not arrive")
                # Check the completed frame BEFORE waiting for another byte.
                # The general polling helper sleeps after reading a match,
                # which adds its polling interval to a latency observation.
                select.select([master_fd], [], [], remaining)
                h.read_available(master_fd, output)
            elapsed = (time.perf_counter_ns() - started) / 1e6
            samples.append({"action": label, "input_hex": data.hex(),
                            "complete_frame_ms": elapsed})

        h.wait_for_output(process, master_fd, output, b"Health: ", start=0, timeout=10.0)
        h.send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
        h.select_keeper_row(process, master_fd, output, b"alpha")
        for label, down, up in (
            ("arrow", b"\x1b[B", b"\x1b[A"),
            ("wheel", b"\x1b[<65;5;5M", b"\x1b[<64;5;5M"),
            ("page", b"\x1b[6~", b"\x1b[5~"),
        ):
            transition(label + " down", down, h.keeper_row_selected(b"beta"))
            transition(label + " up", up, h.keeper_row_selected(b"alpha"))

        # Every byte contributes to the final draft. An alternating cursor
        # burst could lose pairs of keys while keeping the same final row.
        draft = b"frame-burst-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        title = b"Keepers \xe2\x96\xb8 \x1b[1malpha"
        h.send_and_wait(process, master_fd, output, b"\r", title)
        h.send_and_wait(process, master_fd, output, b"m",
                        b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")
        h.send_and_wait(process, master_fd, output, draft, draft)
        h.drain_until_quiet(process, master_fd, output)
        if draft not in h.screen_text(bytes(output)):
            raise AssertionError("buffered input lost part of the draft")
        # Chat opened from detail, so acknowledge that return destination
        # after discarding the draft. A quiet PTY does not prove its view.
        h.send_and_wait(process, master_fd, output, b"\x15\x1b", title)
        frame = h.resize_and_wait(process, master_fd, output, rows=16, columns=100,
                                  needle=title, controls=(h.FULL_REDRAW,),
                                  final_cursor=b"\x1b[?25l")
        windows = h.WINDOW_TEXT_RE.findall(h.CSI_RE.sub(b"", frame))
        if not windows:
            raise AssertionError("detail has no scroll window")
        first, last, total = map(int, windows[-1])
        if first != 1 or total <= last:
            raise AssertionError("detail fixture does not start at an overflowing window")
        top = f"1-{last}/{total}".encode()
        next_row = f"2-{last + 1}/{total}".encode()
        for label, down, up in (
            ("detail key", b"j", b"k"),
            ("detail wheel", b"\x1b[<65;5;5M", b"\x1b[<64;5;5M"),
        ):
            transition(label + " down", down, next_row)
            transition(label + " up", up, top)
        os.write(master_fd, b"q")

    h.run_terminal_scenario(executable,
        description="Input bursts and scroll keys present their resulting frame",
        interact=interact, http_fixtures=h.keeper_runtime_http_fixtures())
    print(json.dumps({"binary_sha256": binary_sha256, "script_sha256": script_sha256,
                      "samples": samples,
                      "scope": "fixture input to completed expected PTY frame; no latency threshold"}))
    print("input and scroll frames: PASS")


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
