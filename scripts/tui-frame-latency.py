#!/usr/bin/env python3
"""Drive the TUI through a PTY and measure what an operator feels.

Two numbers per scenario, from two clocks:

* input-to-first-output latency, per key, from this process's clock: the time
  between writing a key to the PTY and the first byte the TUI writes back.
  This is the delay a person sees between a keypress and the screen moving.
* frame cost, per surface, from the TUI's own clock: the build/present
  histogram MASC_TUI_FRAME_TIMING appends at exit, tagged by surface.

The scenarios drive the live server at the base path (the roster, the first
keeper's chat), so the numbers are for real state, not a fixture. Bytes and
frame counts come with each line so a scenario that moved nothing (a list
shorter than its pane) is not read as fast.

Two clocks are what tells a slow program from a starved one. If the TUI's own
build time is small while the keypress latency is large, the process was not
being scheduled and the run says nothing about the code; the report marks such
a run STARVED and prints the load average it ran under. A run whose chat never
loaded is marked EMPTY. Neither is a measurement to compare against another.

Usage:
  scripts/tui-frame-latency.py --rows 80 --cols 240 --scenario chat
  scripts/tui-frame-latency.py --scenario all --exe _build/default/bin/masc_tui.exe
"""

from __future__ import annotations

import argparse
import fcntl
import os
import pty
import re
import signal
import struct
import subprocess
import sys
import termios
import threading
import time
from dataclasses import dataclass, field

FRAME_MARK = b"\x1b[?7l"  # disable_autowrap, written once per presented frame
TAIL_BYTES = 1 << 20
# What the chat pane draws instead of a transcript. Every run passes through
# it: the pane opens before its history arrives. What separates a fast pane
# from an empty one is whether the notice is still on screen at the end, so
# only the last of the stream is asked.
EMPTY_CHAT_NOTICE = b"no messages yet"
CLOSING_BYTES = 128 << 10
KEY_UP, KEY_DOWN = b"\x1b[A", b"\x1b[B"
PAGE_UP, PAGE_DOWN = b"\x1b[5~", b"\x1b[6~"
WHEEL_UP, WHEEL_DOWN = b"\x1b[<64;10;10M", b"\x1b[<65;10;10M"
INTERRUPT = b"\x03"


@dataclass
class Phase:
    name: str
    started: float
    ended: float
    sends: list[float] = field(default_factory=list)


class Session:
    def __init__(self, exe: str, base_path: str, rows: int, cols: int, timing_path: str) -> None:
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        env = dict(
            os.environ,
            TERM="xterm-256color",
            MASC_BASE_PATH=base_path,
            MASC_HOST="127.0.0.1",
            MASC_TUI_FRAME_TIMING=timing_path,
            MASC_TUI_SYNC="off",
        )
        self.process = subprocess.Popen(
            [exe, "--base-path", base_path],
            stdin=slave, stdout=slave, stderr=slave, env=env,
            preexec_fn=os.setsid, close_fds=True,
        )
        os.close(slave)
        self.chunks: list[tuple[float, int, int]] = []
        # A bounded tail of what the TUI drew. The verdict asks it one
        # question -- did the chat have anything in it -- and a frame count
        # cannot answer that: an empty pane still redraws.
        self.tail = bytearray()
        self.stopped = False
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self) -> None:
        while not self.stopped:
            try:
                data = os.read(self.master, 1 << 16)
            except OSError:
                return
            if not data:
                return
            self.chunks.append((time.monotonic(), len(data), data.count(FRAME_MARK)))
            self.tail.extend(data)
            if len(self.tail) > TAIL_BYTES:
                del self.tail[: len(self.tail) - TAIL_BYTES]

    def send(self, data: bytes) -> None:
        os.write(self.master, data)

    def burst(self, name: str, key: bytes, count: int, gap: float, settle: float = 0.6) -> Phase:
        phase = Phase(name, time.monotonic(), 0.0)
        for _ in range(count):
            phase.sends.append(time.monotonic())
            self.send(key)
            time.sleep(gap)
        time.sleep(settle)
        phase.ended = time.monotonic()
        return phase

    def quit(self) -> int:
        # Two Ctrl-C presses end the session through exit 0, which is what
        # runs the at_exit timing report; a signal would skip it.
        self.send(INTERRUPT)
        time.sleep(0.3)
        self.send(INTERRUPT)
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(self.process.pid, signal.SIGTERM)
            self.process.wait(timeout=5)
        self.stopped = True
        return self.process.returncode or 0

    def measure(self, phase: Phase) -> dict[str, float]:
        window = [c for c in self.chunks if phase.started <= c[0] <= phase.ended]
        latencies = sorted(
            (nxt - sent) * 1000.0
            for sent in phase.sends
            for nxt in [next((c[0] for c in self.chunks if c[0] > sent), None)]
            if nxt is not None
        )

        def pct(p: float) -> float:
            if not latencies:
                return float("nan")
            return latencies[min(len(latencies) - 1, int(round(p * (len(latencies) - 1))))]

        return {
            "keys": len(phase.sends),
            "frames": sum(c[2] for c in window),
            "bytes": sum(c[1] for c in window),
            "p50": pct(0.5),
            "p95": pct(0.95),
            "p99": pct(0.99),
            "max": latencies[-1] if latencies else 0.0,
        }

    def report(self, phase: Phase) -> str:
        m = self.measure(phase)
        return (
            f"{phase.name:16s} keys={m['keys']:4.0f} frames={m['frames']:4.0f} "
            f"bytes={m['bytes']:9.0f} lat_ms p50={m['p50']:6.1f} "
            f"p95={m['p95']:6.1f} p99={m['p99']:6.1f} max={m['max']:6.1f}"
        )


def scenario_overview(s: Session) -> list[Phase]:
    return [s.burst("overview j", b"j", 120, 0.025), s.burst("overview k", b"k", 120, 0.025)]


def scenario_keepers(s: Session) -> list[Phase]:
    s.send(b"2")
    time.sleep(2.0)
    return [s.burst("keepers j", b"j", 60, 0.025), s.burst("keepers k", b"k", 60, 0.025)]


# The surface ring, in the order Tab walks it. Ten stops, and every one of
# them is a screen an operator scrolls.
SURFACE_RING = [
    "Overview", "Activity", "Keepers", "Memory", "Approvals",
    "Board", "Planning", "Workspace", "Runtime", "Config",
]


def scenario_surfaces(s: Session, settle: float) -> list[Phase]:
    """Walk the ring, scrolling each stop, so every surface reports its own
    frame cost. The frame histogram is tagged by surface, so one run answers
    for all of them."""
    phases: list[Phase] = []
    for name in SURFACE_RING:
        s.send(b"\t")
        time.sleep(settle)
        phases.append(s.burst(f"{name} j", b"j", 40, 0.03))
        phases.append(s.burst(f"{name} k", b"k", 40, 0.03))
    return phases


def scenario_chat(s: Session, chat_wait: float) -> list[Phase]:
    s.send(b"2")
    time.sleep(2.0)
    s.send(b"c")
    time.sleep(chat_wait)
    paste_body = "\n".join(f"line {i} " + "word " * 12 for i in range(300))
    paste = ("\x1b[200~" + paste_body + "\x1b[201~").encode()
    return [
        s.burst("chat pageup", PAGE_UP, 120, 0.04),
        s.burst("chat pagedown", PAGE_DOWN, 120, 0.04),
        s.burst("chat wheelup", WHEEL_UP, 150, 0.025),
        s.burst("chat wheeldown", WHEEL_DOWN, 150, 0.025),
        s.burst("chat typing", b"x", 120, 0.03),
        s.burst("chat paste", paste, 3, 0.8),
    ]


# A frame the TUI never built cannot be slow, and a frame it built quickly
# cannot arrive late unless something outside the program held it back.
#
# A keypress waits for the frame already being built and then for its own, so
# what the program owes is about two builds plus the loop's own interval. Past
# several times that, the extra is the machine: other work on it, or a run
# whose process was simply not scheduled. Both clocks decide together, because
# either one alone reads a starved run and slow code the same way.
FRAME_INTERVAL_MS = 16.0
BUILDS_A_KEYPRESS_WAITS_FOR = 2
STARVATION_MULTIPLE = 4.0
STARVED_LATENCY_FLOOR_MS = 250.0
MIN_FRAMES_FOR_A_MEASUREMENT = 100


def build_p50_ms(timing_text: str) -> float | None:
    match = re.search(r"^build frames=\d+ mean=[\d.]+ms p50=([\d.]+)", timing_text, re.M)
    return float(match.group(1)) if match else None


def judge(
    phases: list[Phase], session: Session, timing_text: str, drew_empty_chat: bool = False
) -> tuple[str, str]:
    if drew_empty_chat:
        return (
            "EMPTY",
            "the chat pane drew its no-messages notice: the transcript never loaded, "
            "and a pane with nothing in it is quick for the wrong reason",
        )
    frames = sum(session.measure(p)["frames"] for p in phases)
    if frames < MIN_FRAMES_FOR_A_MEASUREMENT:
        return "EMPTY", f"{frames:.0f} frames drawn across the scenarios; the surface had nothing to move"
    latency_p50 = sorted(session.measure(p)["p50"] for p in phases)[len(phases) // 2]
    build = build_p50_ms(timing_text)
    if build is None:
        return "NO_TIMING", "the TUI wrote no frame histogram, so the two clocks cannot be compared"
    owed = BUILDS_A_KEYPRESS_WAITS_FOR * build + FRAME_INTERVAL_MS
    ceiling = max(STARVED_LATENCY_FLOOR_MS, STARVATION_MULTIPLE * owed)
    if latency_p50 > ceiling:
        return (
            "STARVED",
            f"keypresses answered in {latency_p50:.0f} ms while frames built in {build:.1f} ms, "
            f"which owes about {owed:.0f} ms: the process was waiting for the machine, not for itself",
        )
    return "OK", f"median keypress {latency_p50:.0f} ms, median frame build {build:.1f} ms"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--exe", default="_build/default/bin/masc_tui.exe")
    parser.add_argument("--base-path", default=os.environ.get("MASC_BASE_PATH", os.path.expanduser("~/me/.masc")))
    parser.add_argument("--rows", type=int, default=80)
    parser.add_argument("--cols", type=int, default=240)
    parser.add_argument(
        "--scenario",
        choices=["overview", "keepers", "chat", "surfaces", "all"],
        default="all",
    )
    parser.add_argument("--boot-wait", type=float, default=7.0, help="seconds for first paint and loads")
    parser.add_argument("--chat-wait", type=float, default=6.0, help="seconds for the chat history to load")
    parser.add_argument("--timing-file", default=None, help="where the TUI appends its frame histogram")
    args = parser.parse_args()

    timing = args.timing_file or os.path.join(os.getcwd(), ".tmp", "tui-frame-timing.txt")
    os.makedirs(os.path.dirname(timing), exist_ok=True)
    if os.path.exists(timing):
        os.remove(timing)

    load_before = os.getloadavg()
    session = Session(args.exe, args.base_path, args.rows, args.cols, timing)
    time.sleep(args.boot_wait)
    phases: list[Phase] = []
    if args.scenario in ("overview", "all"):
        phases += scenario_overview(session)
    if args.scenario in ("keepers", "all"):
        phases += scenario_keepers(session)
    if args.scenario in ("surfaces", "all"):
        phases += scenario_surfaces(session, settle=1.5)
    if args.scenario in ("chat", "all"):
        phases += scenario_chat(session, args.chat_wait)
    code = session.quit()

    load_after = os.getloadavg()
    print(f"exe={args.exe} size={args.rows}x{args.cols} exit={code} "
          f"chunks={len(session.chunks)} bytes={sum(c[1] for c in session.chunks)} "
          f"frames={sum(c[2] for c in session.chunks)} "
          f"load={load_before[0]:.0f}->{load_after[0]:.0f}")
    for phase in phases:
        print(session.report(phase))
    print("--- frame timing (TUI clock, per surface):")
    timing_text = open(timing).read() if os.path.exists(timing) else ""
    if timing_text:
        sys.stdout.write(timing_text)
    else:
        print("(no timing file: the TUI did not exit through at_exit)")
    drew_empty_chat = (
        args.scenario in ("chat", "all")
        and EMPTY_CHAT_NOTICE in bytes(session.tail[-CLOSING_BYTES:])
    )
    verdict, why = judge(phases, session, timing_text, drew_empty_chat=drew_empty_chat)
    print(f"verdict={verdict} ({why})")
    return 0 if verdict == "OK" else 2

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
