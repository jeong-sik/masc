#!/usr/bin/env python3
"""Before/After terminal byte measurement for the browser viewport cadence.

Mad-scientist conditions (board p-f704cbabf5d5ee8c9618db11f9827cc7):
  1. Both binaries built in this same run from pinned heads.
  2. Quiet-window baseline; the value reported is the Before/After delta of
     the constant-field ticks, not an absolute zero claim.
  3. Positive control: one mid-window field change must make bytes flow
     again on both binaries.

Measurement definition (masc-pro-builder, c-7810bb62): raw bytes written to
the PTY master by the TUI process. No instrumentation patch inside the TUI.

The fixture server answers the browser-lane screenshot poll with constant
fields (source, clientId, tabId, title, url, viewport, elapsed_ms and the
same PNG payload) for CONSTANT_TICKS, then changes the title for one tick
(positive control), then returns to constant fields. The TUI's own 2s
viewport cadence drives the polling; we just count master bytes per
cadence window.
"""

from __future__ import annotations

import argparse
import base64
import fcntl
import json
import os
import pty
import select
import struct
import subprocess
import sys
import termios
import threading
import time
import zlib
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Iterator

# A real 1x1 PNG (transparent), base64-decoded at serve time.
PNG_1PX = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk"
    "YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
)

TICKS_CONSTANT = 5          # condition 2 window: all fields constant
TICKS_CONTROL = 1           # condition 3: title changes once
TICKS_TAIL_CONSTANT = 2     # settle back, not measured
CADENCE_SEC = 2.0           # the TUI's own viewport cadence
WARMUP_SEC = 14.0           # boot, first fetch, settle of the viewport


def make_png(width: int, height: int, level: int) -> bytes:
    """Minimal truecolor PNG so distinct payloads decode differently."""

    def chunk(tag: bytes, body: bytes) -> bytes:
        return (
            struct.pack(">I", len(body))
            + tag
            + body
            + struct.pack(">I", zlib.crc32(tag + body) & 0xFFFFFFFF)
        )

    raw = b"".join(
        b"\x00" + bytes([(x * 3) % 256, (y * 7) % 256, level]) * width
        for y in range(height)
    )
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 6))
        + chunk(b"IEND", b"")
    )


class Fixture:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.poll_count = 0

    def screenshot_payload(self) -> dict[str, Any]:
        with self.lock:
            self.poll_count += 1
            n = self.poll_count
        title = "Example Domain — constant"
        # Positive control tick: change a compared field.
        if n == TICKS_CONSTANT + 1:
            title = "Example Domain — changed"
        return {
            "ok": True,
            "data": {
                "source": "live",
                "clientId": "fixture-client-0001",
                "tabId": 7,
                "title": title,
                "url": "https://example.org/specimen",
                "mimeType": "image/png",
                "data": base64.b64encode(PNG_1PX).decode("ascii"),
                "viewport": {
                    "width": 80, "height": 24, "scrollX": 0, "scrollY": 0,
                    "pageWidth": 960, "pageHeight": 2400, "zoom": 1.0,
                    "naturalWidth": 960, "naturalHeight": 2400,
                },
                "elapsed_ms": 250,
            },
        }


FIXTURE = Fixture()


@contextmanager
def fixture_server() -> Iterator[int]:
    class Handler(BaseHTTPRequestHandler):
        def _reply(self, payload: bytes, status: int = 200) -> None:
            try:
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def do_GET(self) -> None:  # noqa: N802 - http.server API
            path = self.path.split("?")[0]
            if path == "/api/v1/health":
                self._reply(json.dumps({"ok": True, "commit": "fixture"}).encode())
            elif path == "/api/v1/keepers/turns":
                self._reply(json.dumps({"schema": "masc.keeper_turns.v1", "keepers": []}).encode())
            elif path == "/api/v1/keepers/asks":
                self._reply(json.dumps({"keeper": None, "open_count": 0, "asks": []}).encode())
            elif path == "/api/v1/operator":
                self._reply(json.dumps({"operator": "fixture"}).encode())
            else:
                # Quiet defaults for every other surface so the boot loop is
                # not a wall of errors: board, gate, dashboard reads.
                self._reply(json.dumps({"ok": True, "posts": [], "keepers": [],
                                        "snapshots": [], "asks": [], "pending": []}).encode())

        def do_POST(self) -> None:  # noqa: N802 - http.server API
            length = int(self.headers.get("Content-Length") or 0)
            if length:
                self.rfile.read(length)
            path = self.path.split("?")[0]
            if path == "/api/v1/dashboard/browser-lane/screenshot":
                self._reply(json.dumps(FIXTURE.screenshot_payload()).encode())
            else:
                self._reply(json.dumps({"ok": True}).encode())

        def log_message(self, *args: Any) -> None:
            return

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield int(server.server_address[1])
    finally:
        server.shutdown()


def drain(master: int, budget_sec: float) -> tuple[int, int]:
    """Read whatever the TUI writes for budget_sec; return (bytes, chunks)."""
    total = 0
    chunks = 0
    deadline = time.monotonic() + budget_sec
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        ready, _, _ = select.select([master], [], [], min(remaining, 0.2))
        if master in ready:
            try:
                data = os.read(master, 65536)
            except OSError:
                break
            if not data:
                break
            total += len(data)
            chunks += 1
    return total, chunks


@contextmanager
def tui_pty(executable: Path, base: Path, api_port: int) -> Iterator[int]:
    master, slave = pty.openpty()
    # A real terminal size so the TUI renders a full frame.
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    env = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": str(base),
        "TERM": "xterm-256color",
        "MASC_BASE_PATH": str(base),
        "MASC_HOST": "127.0.0.1",
        "MASC_TUI_SYNC": "off",
        "NO_PROXY": "127.0.0.1,localhost",
        "no_proxy": "127.0.0.1,localhost",
    }
    proc = subprocess.Popen(  # noqa: S603 - fixed argv, no shell
        [
            str(executable),
            "--base-path", str(base),
            "--workspace", "viewport-bytes",
            "--port", str(api_port),
            "--refresh", "60",
        ],
        stdin=slave, stdout=slave, stderr=slave,
        env=env, cwd=str(base), start_new_session=True,
    )
    os.close(slave)
    try:
        yield master
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
        os.close(master)


def measure(executable: Path, base: Path, api_port: int) -> dict[str, Any]:
    FIXTURE.poll_count = 0
    result: dict[str, Any] = {"executable": str(executable)}
    with tui_pty(executable, base, api_port) as master:
        # Warm-up: boot, first screenshot, viewport settle.
        boot_bytes, _ = drain(master, WARMUP_SEC)
        result["warmup_bytes"] = boot_bytes

        # Open the browser lane (Ctrl+X = \x18 is the app's toggle; the
        # screenshot poll only runs with the lane on screen).
        os.write(master, b"\x18")
        time.sleep(2.0)
        drain(master, 2.0)

        windows = []
        total_ticks = TICKS_CONSTANT + TICKS_CONTROL + TICKS_TAIL_CONSTANT
        for i in range(total_ticks):
            b, c = drain(master, CADENCE_SEC)
            windows.append({"tick": i + 1, "bytes": b, "chunks": c})
        result["windows"] = windows
        const = sum(w["bytes"] for w in windows[:TICKS_CONSTANT])
        control = windows[TICKS_CONSTANT]["bytes"]
        result["constant_ticks_bytes"] = const
        result["control_tick_bytes"] = control
        result["poll_count"] = FIXTURE.poll_count
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--before", required=True, type=Path)
    parser.add_argument("--after", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()

    import tempfile

    for exe in (args.before, args.after):
        if not exe.exists():
            print(f"missing binary: {exe}", file=sys.stderr)
            return 2

    report: dict[str, Any] = {
        "schema": "masc.viewport_cadence_bytes.v1",
        "definition": "raw bytes written to the PTY master by the TUI",
        "conditions": {
            "constant_ticks": TICKS_CONSTANT,
            "control_tick": TICKS_CONSTANT + 1,
            "cadence_sec": CADENCE_SEC,
            "warmup_sec": WARMUP_SEC,
            "same_image": True,
        },
    }
    for label, exe in (("before", args.before), ("after", args.after)):
        with fixture_server() as port, tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            (base / ".masc").mkdir(parents=True, exist_ok=True)
            report[label] = measure(exe, base, port)

    before_const = report["before"]["constant_ticks_bytes"]
    after_const = report["after"]["constant_ticks_bytes"]
    before_ctrl = report["before"]["control_tick_bytes"]
    after_ctrl = report["after"]["control_tick_bytes"]
    report["delta_constant"] = before_const - after_const
    report["skip_effective"] = after_const < before_const
    report["control_flows_both"] = before_ctrl > 0 and after_ctrl > 0

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({
        "before_constant": before_const,
        "after_constant": after_const,
        "delta": report["delta_constant"],
        "skip_effective": report["skip_effective"],
        "control_flows_both": report["control_flows_both"],
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
