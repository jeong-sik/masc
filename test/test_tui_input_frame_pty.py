"""Observe complete, acknowledged cursor/scroll frames after terminal input.

Timings include the PTY and Python observer, not physical display latency.
Each input is acknowledged before the next is sent. Repeated cycles measure
closed-loop interaction, not a fixed-rate overload or physical display latency.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import select
import sys
import time

import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui.ml",
    "bin/masc_tui_render_schedule.ml",
)


def positive_int(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("cycles must be positive")
    return parsed


def workspace_metadata(path: Path | None) -> dict:
    metadata = ({name: h.keeper_metadata(name) for name in ("alpha", "beta")}
                if path is None else json.loads(path.read_text()))
    if (not isinstance(metadata, dict) or set(metadata) != {"alpha", "beta"}
            or any(not isinstance(value, dict) or value.get("name") != name
                   for name, value in metadata.items())):
        raise ValueError("metadata fixture must contain alpha and beta with matching names")
    return metadata


def run(executable: str, *, cycles: int = 1, metadata_path: Path | None = None) -> None:
    if cycles <= 0:
        raise ValueError("cycles must be positive")
    samples = []
    stage = "startup"
    metadata = workspace_metadata(metadata_path)
    metadata_sha256 = hashlib.sha256(
        json.dumps(metadata, sort_keys=True).encode()).hexdigest()
    preflight = {"metadata_sha256": metadata_sha256, "visible_keepers": []}

    def prepare_workspace(base_path):
        for name, value in metadata.items():
            (Path(base_path) / ".masc/keepers" / f"{name}.json").write_text(json.dumps(value))
    with open(executable, "rb") as stream:
        binary_sha256 = hashlib.file_digest(stream, "sha256").hexdigest()
    with open(__file__, "rb") as stream:
        script_sha256 = hashlib.file_digest(stream, "sha256").hexdigest()

    def interact(process, master_fd, _slave_fd, output, _base_path):
        nonlocal stage
        previous_ack_ns = None

        def transition(cycle, label, data, needle):
            nonlocal previous_ack_ns, stage
            stage = f"cycle {cycle}: {label}"
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
            acknowledged = time.perf_counter_ns()
            elapsed = (acknowledged - started) / 1e6
            gap_ms = None if previous_ack_ns is None else (started - previous_ack_ns) / 1e6
            samples.append({"cycle": cycle, "action": label, "input_hex": data.hex(),
                            "preceding_ack_to_input_ms": gap_ms,
                            "complete_frame_ms": elapsed})
            previous_ack_ns = acknowledged

        h.wait_for_output(process, master_fd, output, b"Health: ", start=0, timeout=10.0)
        stage = "prepare roster"
        h.send_and_wait(process, master_fd, output, b"2", b"MASC Keepers")
        # This benchmark measures input against a loaded snapshot. Request
        # that snapshot explicitly before measuring, equally for both binaries.
        # A previous run stalled here before its first sample; retain that
        # failure separately rather than counting a setup refresh as latency.
        # Differential redraw may omit an unchanged alpha row. The selector
        # below reconstructs the current completed screen instead of requiring
        # those bytes to be emitted again after refresh.
        h.write_all(master_fd, output, b"r")
        h.select_keeper_row(process, master_fd, output, b"beta")
        h.select_keeper_row(process, master_fd, output, b"alpha")
        preflight["visible_keepers"] = ["alpha", "beta"]
        for cycle in range(1, cycles + 1):
            for label, down, up in (
                ("arrow", b"\x1b[B", b"\x1b[A"),
                ("wheel", b"\x1b[<65;5;5M", b"\x1b[<64;5;5M"),
                ("page", b"\x1b[6~", b"\x1b[5~"),
            ):
                transition(cycle, label + " down", down, h.keeper_row_selected(b"beta"))
                transition(cycle, label + " up", up, h.keeper_row_selected(b"alpha"))

        # Every byte contributes to the final draft. An alternating cursor
        # burst could lose pairs of keys while keeping the same final row.
        draft = b"frame-burst-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        title = b"Keepers \xe2\x96\xb8 \x1b[1malpha"
        stage = "prepare draft"
        h.send_and_wait(process, master_fd, output, b"\r", title)
        h.send_and_wait(process, master_fd, output, b"m",
                        b"Keepers \xe2\x96\xb8 alpha \xe2\x96\xb8 chat")
        stage = "draft burst"
        h.send_and_wait(process, master_fd, output, draft, draft)
        h.drain_until_quiet(process, master_fd, output)
        if draft not in h.screen_text(bytes(output)):
            raise AssertionError("buffered input lost part of the draft")
        # Chat opened from detail, so Escape must acknowledge that return
        # destination. A quiet PTY does not prove which view owns the input.
        stage = "prepare detail"
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
        # This phase follows draft entry, navigation and a resize. Its first
        # timed input has no preceding timed acknowledgement in this phase.
        previous_ack_ns = None
        for cycle in range(1, cycles + 1):
            for label, down, up in (
                ("detail key", b"j", b"k"),
                ("detail wheel", b"\x1b[<65;5;5M", b"\x1b[<64;5;5M"),
            ):
                transition(cycle, label + " down", down, next_row)
                transition(cycle, label + " up", up, top)
        os.write(master_fd, b"q")
        stage = "shutdown"

    # The helper starts one launcher, which waits for the TUI. Read CPU only
    # after the helper has reaped it. This includes startup, navigation, draft
    # input and shutdown; it is not CPU spent solely in the timed transitions.
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    session_started = time.perf_counter_ns()
    try:
        h.run_terminal_scenario(executable,
            description="Input bursts and scroll keys present their resulting frame",
            interact=interact, http_fixtures=h.keeper_runtime_http_fixtures(),
            prepare_workspace=prepare_workspace)
    except BaseException:
        # Print only after the helper unwinds: per-input I/O would perturb the
        # timings. A failed run never emits PASS or a complete resource receipt.
        print(json.dumps({"status": "failed", "stage": stage, "cycles": cycles,
                          "binary_sha256": binary_sha256, "script_sha256": script_sha256,
                          "preflight": preflight, "samples": samples}), file=sys.stderr, flush=True)
        raise
    session_wall_seconds = (time.perf_counter_ns() - session_started) / 1e9
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    user_seconds = after.ru_utime - before.ru_utime
    system_seconds = after.ru_stime - before.ru_stime
    print(json.dumps({"binary_sha256": binary_sha256, "script_sha256": script_sha256,
                      "cycles": cycles, "samples": samples, "preflight": preflight,
                      "session_resources": {
                          "child_user_seconds": user_seconds,
                          "child_system_seconds": system_seconds,
                          "child_cpu_seconds": user_seconds + system_seconds,
                          "wall_seconds": session_wall_seconds,
                          "scope": "whole reaped launcher/TUI session and waited descendants; "
                                   "includes startup/navigation/draft/shutdown; excludes observer CPU",
                      },
                      "scope": "fixture input to completed expected PTY frame; no latency threshold"}))
    print("input and scroll frames: PASS")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable")
    parser.add_argument("--cycles", type=positive_int, default=1)
    parser.add_argument("--keeper-metadata", type=Path,
                        help="Explicit alpha/beta JSON fixture for a source-pinned comparison")
    args = parser.parse_args()
    run(os.path.abspath(args.executable), cycles=args.cycles, metadata_path=args.keeper_metadata)
