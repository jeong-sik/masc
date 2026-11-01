#!/usr/bin/env python3
"""Observe an existing local TUI through a PTY, without editing chat drafts.

Records key writes to the next observed PTY output chunk. That output may be
background work, and one chunk may follow several keys: these are not causal
key responses, completed renders or physical input-to-display measurements.
The TUI's independent frame clock supplies Build/Present records and actual
surface tags. No starvation, empty-content or performance verdict is inferred.

Requires an already healthy server with the requested effective base path.
The child uses an owned client config with Overview opening, so saved Last or
Keeper preferences cannot turn navigation keys into draft text. User client
preferences and config-only Keeper declarations are not copied into this run.
Normal TUI startup/auth behavior remains active; if it starts or reconnects to
a different server during the observation, the before/after identity differs.

Example:
  scripts/tui-frame-latency.py --exe /path/to/masc-tui --base-path /srv/masc \
    --port 8935 --scenario chat --output-dir artifacts/tui-chat-observation
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import errno
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
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
from urllib.request import urlopen

sys.path.insert(0, os.path.join(os.path.dirname(os.path.realpath(__file__)), "lib"))
import masc_base_path  # noqa: E402

FRAME_END = b"\x1b[?7h"  # terminal-protocol marker, not a screen-text assertion
KEY_UP, KEY_DOWN = b"\x1b[A", b"\x1b[B"
PAGE_UP, PAGE_DOWN = b"\x1b[5~", b"\x1b[6~"
SURFACE = {"overview": "overview", "keepers": "keeper-list", "chat": "keeper-message"}


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def health(port: int) -> dict:
    with urlopen(f"http://127.0.0.1:{port}/health?full=1", timeout=10) as response:
        value = json.load(response)
    return {key: value.get(key) for key in ("status", "build", "paths", "scheduler", "gc")}


def runtime_id(value: dict) -> str | None:
    build = value.get("build")
    return build.get("runtime_instance_id") if isinstance(build, dict) else None


def reports_base(value: dict, base_path: str) -> bool:
    paths = value.get("paths")
    reported = paths.get("effective_base_path") if isinstance(paths, dict) else None
    return (isinstance(reported, str) and bool(reported.strip())
            and Path(reported).resolve() == Path(base_path))


@dataclass
class Phase:
    name: str
    started: float
    ended: float | None = None
    sends: list[dict] = field(default_factory=list)


class Session:
    def __init__(self, exe: Path, base_path: str, port: int, rows: int, cols: int,
                 timing_path: Path, capture_screen: bool) -> None:
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        self.config_dir = timing_path.parent / "client-config"
        self.config_dir.mkdir(mode=0o700)
        (self.config_dir / "runtime.toml").write_text('[tui]\nopening = "overview"\n')
        env = dict(os.environ, TERM="xterm-256color",
                   MASC_BASE_PATH=base_path, MASC_HOST="127.0.0.1",
                   MASC_CONFIG_DIR=str(self.config_dir),
                   MASC_TUI_FRAME_TIMING=str(timing_path))
        self.argv = [str(exe), "--base-path", base_path, "--port", str(port)]
        self.profile = {name: env.get(name) for name in
                        ("TERM", "TERM_PROGRAM", "MASC_CONFIG_DIR", "MASC_TUI_SYNC",
                         "MASC_TUI_KITTY_KEYBOARD", "MASC_TUI_TITLE")}
        try:
            self.process = subprocess.Popen(self.argv, stdin=slave, stdout=slave,
                                            stderr=slave, env=env, start_new_session=True)
        except BaseException:
            os.close(self.master)
            raise
        finally:
            os.close(slave)
        self.chunks: list[tuple[float, int]] = []
        self.inputs: list[dict] = []
        self.phases: list[Phase] = []
        self.raw = bytearray() if capture_screen else None
        self.ready = threading.Event()
        self.reader_error: str | None = None
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self) -> None:
        suffix = b""
        while True:
            try:
                data = os.read(self.master, 1 << 16)
            except OSError as error:
                # Closing the last slave normally ends a PTY master with EIO.
                if error.errno != errno.EIO:
                    self.reader_error = str(error)
                return
            if not data:
                return
            self.chunks.append((time.monotonic(), len(data)))
            if self.raw is not None:
                self.raw.extend(data)
            if FRAME_END in suffix + data:
                self.ready.set()
            suffix = data[-(len(FRAME_END) - 1):]

    def send(self, name: str, data: bytes) -> dict:
        sample = {"name": name, "started": time.monotonic(), "returned": None,
                  "bytes_written": None}
        self.inputs.append(sample)
        sample["bytes_written"] = os.write(self.master, data)
        sample["returned"] = time.monotonic()
        if sample["bytes_written"] != len(data):
            raise OSError("short PTY input write")
        return sample

    def burst(self, name: str, key: bytes, count: int, gap: float, settle: float) -> None:
        phase = Phase(name, time.monotonic())
        self.phases.append(phase)
        for _ in range(count):
            phase.sends.append(self.send(name, key))
            time.sleep(gap)
        time.sleep(settle)
        phase.ended = time.monotonic()

    def quit(self) -> tuple[int, bool]:
        # Signal only this probe's child; Ctrl-C input can interrupt a Keeper.
        forced = False
        if self.process.poll() is None:
            self.process.send_signal(signal.SIGTERM)
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            forced = True
            self.process.kill()
            self.process.wait()
        self.reader.join(timeout=1)
        if self.reader.is_alive():
            self.reader_error = "PTY reader did not finish after child exit"
        os.close(self.master)
        return self.process.returncode, forced

    def measure(self, phase: Phase) -> dict:
        finished = phase.ended if phase.ended is not None else time.monotonic()
        chunks = list(self.chunks)
        window = [chunk for chunk in chunks if phase.started <= chunk[0] <= finished]
        delays = []
        for sent in phase.sends:
            if sent["returned"] is not None:
                following = next((at for at, _ in chunks
                                  if sent["returned"] < at <= finished), None)
                if following is not None:
                    delays.append((following - sent["returned"]) * 1000)
        delays.sort()

        def percentile(fraction: float) -> float | None:
            return delays[round(fraction * (len(delays) - 1))] if delays else None

        return {"name": phase.name, "completed": phase.ended is not None,
                "key_writes": len(phase.sends), "next_output_samples": len(delays),
                "keys_without_later_output": len(phase.sends) - len(delays),
                "output_chunks": len(window), "output_bytes": sum(n for _, n in window),
                "next_pty_output_ms": {"p50": percentile(.5), "p95": percentile(.95),
                                       "max": delays[-1] if delays else None},
                "write_samples": phase.sends}


def observe(session: Session, args: argparse.Namespace) -> None:
    deadline = time.monotonic() + args.ready_timeout
    while not session.ready.is_set() and session.process.poll() is None:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        session.ready.wait(min(.05, remaining))
    if not session.ready.is_set() or session.process.poll() is not None:
        raise RuntimeError("no live child with a completed terminal output frame")
    time.sleep(args.boot_wait)
    if args.scenario in ("keepers", "chat"):
        session.send("open Keepers", b"3")
        time.sleep(args.settle)
    if args.scenario == "chat":
        session.send("open selected Keeper chat", b"c")
        time.sleep(args.chat_wait)
        motions = [("chat pageup", PAGE_UP), ("chat pagedown", PAGE_DOWN)]
    else:
        motions = [(args.scenario + " down", KEY_DOWN), (args.scenario + " up", KEY_UP)]
    for name, key in motions:
        session.burst(name, key, args.keys, args.gap, args.settle)


def frame_records(text: str) -> list[dict]:
    records = []
    for line in text.splitlines():
        if line.startswith("{"):
            row = json.loads(line)
            if row.get("schema") == "masc.tui.frame.v2":
                records.append(row)
    return records


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--exe", type=Path, help="required existing TUI executable; no build")
    parser.add_argument("--base-path", default=None, help="effective base path, or MASC_BASE_PATH")
    parser.add_argument("--port", type=int, help="required already running localhost server")
    parser.add_argument("--output-dir", type=Path, help="required new observation directory")
    parser.add_argument("--rows", type=int, default=45)
    parser.add_argument("--cols", type=int, default=150)
    parser.add_argument("--scenario", choices=list(SURFACE), default="keepers")
    parser.add_argument("--keys", type=int, default=8, help="writes in each navigation direction")
    parser.add_argument("--gap", type=float, default=.1)
    parser.add_argument("--settle", type=float, default=.4)
    parser.add_argument("--boot-wait", type=float, default=2)
    parser.add_argument("--chat-wait", type=float, default=3)
    parser.add_argument("--ready-timeout", type=float, default=15)
    parser.add_argument("--capture-screen", action="store_true",
                        help="retain raw PTY output; may include private live content")
    args = parser.parse_args()
    # Preserve the shared scripts' unnamed-base rejection before any runtime work.
    base_path = str(masc_base_path.require(parser, args.base_path, "--base-path").resolve(strict=True))
    missing = ["--" + name.replace("_", "-") for name in ("exe", "port", "output_dir")
               if getattr(args, name) is None]
    if missing:
        parser.error("the following arguments are required: " + ", ".join(missing))
    if not (1 <= args.port <= 65535 and 1 <= args.rows <= 65535
            and 1 <= args.cols <= 65535 and args.keys > 0
            and all(math.isfinite(v) and v > 0 for v in
                    (args.gap, args.settle, args.boot_wait, args.chat_wait, args.ready_timeout))):
        parser.error("invalid port, geometry, count or observation duration")
    exe = args.exe.expanduser().resolve(strict=True)
    args.output_dir.mkdir(parents=True, exist_ok=False)
    out = args.output_dir.resolve()
    result = {"schema": "masc.tui.pty_observation.v1", "binary": str(exe),
              "started_at": datetime.now(timezone.utc).isoformat(),
              "base_path": base_path, "port": args.port, "scenario": args.scenario,
              "rows": args.rows, "cols": args.cols, "phases": [], "error": None,
              "observation_options": {name: getattr(args, name) for name in
                                      ("keys", "gap", "settle", "boot_wait", "chat_wait",
                                       "ready_timeout", "capture_screen")},
              "observation_complete": False,
              "scope": "next observed PTY output and application frame timings; no causal key response or physical display latency"}
    session = None
    try:
        before = health(args.port)
        result["server_before"] = before
        if not (before.get("status") == "ok" and isinstance(runtime_id(before), str)
                and runtime_id(before)
                and reports_base(before, base_path)):
            raise RuntimeError("existing healthy server identity/base path not established; TUI not launched")
        result["binary_sha256_before"] = digest(exe)
        result["load_before"] = os.getloadavg()
        session = Session(exe, base_path, args.port, args.rows, args.cols,
                          out / "frame-timing.txt", args.capture_screen)
        result["pid"] = session.process.pid
        result["argv"] = session.argv
        result["terminal_profile"] = session.profile
        result["client_config"] = {"directory": str(session.config_dir),
                                   "opening": "overview",
                                   "scope": "owned client defaults; user preferences and config-only Keeper declarations not copied"}
        observe(session, args)
    except (Exception, KeyboardInterrupt) as error:
        result["error"] = f"{type(error).__name__}: {error}"
    finally:
        if session is not None:
            result["exit_code"], result["forced_kill"] = session.quit()
            result["reader_error"] = session.reader_error
            result["phases"] = [session.measure(phase) for phase in session.phases]
            result["input_writes"] = session.inputs
            result["total_output_chunks"] = len(session.chunks)
            result["total_output_bytes"] = sum(size for _, size in session.chunks)
            if session.raw is not None:
                (out / "screen.ansi").write_bytes(session.raw)
    try:
        after = health(args.port)
        result["server_after"] = after
        result["same_runtime"] = runtime_id(result.get("server_before", {})) == runtime_id(after) \
            and runtime_id(after) is not None
        result["same_effective_base"] = reports_base(after, base_path)
        result["binary_sha256_after"] = digest(exe)
        result["same_binary"] = result["binary_sha256_after"] == result.get("binary_sha256_before")
        result["load_after"] = os.getloadavg()
        timing_path = out / "frame-timing.txt"
        timing_text = timing_path.read_text() if timing_path.exists() else ""
        frames = frame_records(timing_text)
        result["observed_surfaces"] = sorted({row["surface"] for row in frames if row.get("surface")})
        result["frame_samples"] = len(frames)
        result["omitted_sample_lines"] = [line for line in timing_text.splitlines()
                                          if re.search(r"\bomitted=[1-9]\d*", line)]
        result["requested_surface_recorded"] = SURFACE[args.scenario] in result["observed_surfaces"]
        result["observation_complete"] = bool(session and result["error"] is None
            and result["exit_code"] == 0 and not result["forced_kill"]
            and result["reader_error"] is None and result["same_runtime"]
            and result["same_effective_base"] and after.get("status") == "ok"
            and result["same_binary"] and result["requested_surface_recorded"]
            and not result["omitted_sample_lines"])
    except Exception as error:
        result["collection_error"] = f"{type(error).__name__}: {error}"
    (out / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"output_dir": str(out), "observation_complete": result["observation_complete"],
                      "error": result.get("error") or result.get("collection_error"),
                      "observed_surfaces": result.get("observed_surfaces", [])}))
    return 0 if result["observation_complete"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
