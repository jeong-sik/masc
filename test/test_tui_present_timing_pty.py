"""A real TUI session attaches output accounting to its slow Present samples."""
import math
import os
from pathlib import Path
import re
import sys
import tempfile

import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui.ml",
    "bin/masc_tui_frame_timing.ml",
    "bin/masc_tui_frame_timing.mli",
    "bin/masc_tui_frame_presenter.ml",
)


def run(executable: str) -> None:
    def interact(process, master_fd, _slave_fd, output, _base_path):
        h.send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
        h.select_keeper_row(process, master_fd, output, b"beta")
        h.select_keeper_row(process, master_fd, output, b"alpha")
        os.write(master_fd, b"q")

    with tempfile.TemporaryDirectory(prefix="masc-present-timing-") as directory:
        report = Path(directory) / "timing.txt"
        h.run_terminal_scenario(
            executable,
            description="Present timing retains frame output accounting",
            interact=interact,
            http_fixtures=h.keeper_runtime_http_fixtures(),
            extra_env={"MASC_TUI_FRAME_TIMING": str(report)},
        )
        lines = report.read_text().splitlines()
        start = next(i for i, line in enumerate(lines)
                     if line.startswith("present frames="))
        worst = [line.strip() for line in lines[start:] if "worst[" in line]
        if not worst:
            raise AssertionError("no slow Present samples in real TUI report")
        emitted = False
        for line in worst:
            match = re.fullmatch(
                r"worst\[\d+\] frame=(\d+) ([\d.]+)ms tag=(\S+) "
                r"write=([\d.]+)ms flush=([\d.]+)ms other=([\d.]+)ms "
                r"bytes=(\d+) writes=(\d+) flushes=(\d+)", line)
            if match is None:
                raise AssertionError(f"missing Present output breakdown: {line}")
            frame, total, _tag, write, flush, other, size, writes, flushes = match.groups()
            values = [float(value) for value in (total, write, flush, other)]
            if int(frame) <= 0 or not all(math.isfinite(v) and v >= 0 for v in values):
                raise AssertionError(f"invalid Present sample: {line}")
            # Total prints two decimal places, components three. This bound
            # only accounts for decimal rounding; it is not a latency target.
            if abs(values[0] - sum(values[1:])) > 0.0066:
                raise AssertionError(f"components do not account for total: {line}")
            if int(writes) == 0:
                if int(size) != 0 or int(flushes) != 0:
                    raise AssertionError(f"unchanged presentation claims output: {line}")
            elif int(writes) != 1 or int(flushes) != 1 or int(size) <= 0:
                raise AssertionError(f"frame was not written and flushed once: {line}")
            else:
                emitted = True
        if not emitted:
            raise AssertionError("no emitted frame represented in Present samples")
        print("\n".join(lines))


if __name__ == "__main__":
    run(sys.argv[1])
    print("tui present timing: PASS")
