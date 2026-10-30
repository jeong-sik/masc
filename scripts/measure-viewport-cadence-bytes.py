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
same PNG payload) during the constant window, then holds a changed title
throughout the positive-control window. The TUI's own 2s viewport cadence
drives polling. Every window records its actual screenshot polls; missing
or unequal coverage invalidates the comparison.
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
TICKS_CONTROL = 2           # hold the changed title across two cadence periods
TICKS_TAIL_CONSTANT = 2     # settle back, not measured
CADENCE_SEC = 2.0           # the TUI's own viewport cadence
WARMUP_SEC = 14.0           # boot, first fetch, settle of the viewport


class Fixture:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.poll_count = 0
        self.read_count = 0
        self.phase = "warmup"
        self.polls: list[dict[str, Any]] = []

    def set_phase(self, phase: str) -> None:
        with self.lock:
            self.phase = phase

    def snapshot(self) -> list[dict[str, Any]]:
        with self.lock:
            return list(self.polls)

    def reading_payload(self) -> dict[str, Any]:
        with self.lock:
            self.read_count += 1
        title = "Example Domain — constant"
        url = "https://example.org/specimen"
        return {"ok": True, "data": {
            "source": "live", "clientId": "fixture-client-0001",
            "tabs": [{"id": 7, "title": title, "url": url, "active": True}],
            "page": {"tabId": 7, "title": title, "url": url,
                     "text": "Example Domain", "chars": 14, "truncated": False},
            "elapsed_ms": 250,
        }}

    def discovery_payload(self) -> dict[str, Any]:
        selected = {"ok": True, "data": {
            "lane": "live", "clientId": "fixture-client-0001",
            "reason": "available_connected_browser",
        }}
        return {"ok": True, "data": {
            "clients": [{"clientId": "fixture-client-0001", "browser": "firefox",
                         "transport": "web_extension", "space": None,
                         "spaceObservation": None, "interactions": [],
                         "lastActivities": []}],
            "automatic": {"browse": selected, "work": {
                "ok": False, "error": {"code": "no_available_browser",
                                        "message": "This fixture has no work browser"}}},
        }}

    def screenshot_payload(self) -> dict[str, Any]:
        with self.lock:
            self.poll_count += 1
            phase = self.phase
            self.polls.append({"poll": self.poll_count, "phase": phase,
                               "at": time.monotonic()})
        title = "Example Domain — constant"
        # The title belongs to the measurement phase, independent of boot polls.
        if phase == "control":
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


@contextmanager
def fixture_server(fixture: Fixture, base: Path) -> Iterator[int]:
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
            if path in ("/health", "/api/v1/health"):
                self._reply(json.dumps({"ok": True, "version": "fixture",
                    "build": {"commit": "fixture"},
                    "paths": {"effective_base_path": str(base),
                              "effective_masc_root": str(base / ".masc")},
                    "startup": {"state_ready": True}}).encode())
            elif path == "/api/v1/dashboard/browser-lane/clients":
                self._reply(json.dumps(fixture.discovery_payload()).encode())
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
                self._reply(json.dumps(fixture.screenshot_payload()).encode())
            elif path == "/api/v1/dashboard/browser-lane/read":
                self._reply(json.dumps(fixture.reading_payload()).encode())
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
        server.server_close()
        thread.join()


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


def await_browser_read(master: int, fixture: Fixture) -> bool:
    deadline = time.monotonic() + WARMUP_SEC
    while fixture.read_count == 0 and time.monotonic() < deadline:
        drain(master, min(0.1, max(0.0, deadline - time.monotonic())))
    return fixture.read_count > 0


@contextmanager
def tui_pty(executable: Path, base: Path, api_port: int) -> Iterator[int]:
    master, slave = pty.openpty()
    # A real terminal size so the TUI renders a full frame.
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    env = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": str(base),
        "TERM": "xterm-256color",
        # Advertise an image protocol so the unmodified TUI opens its viewport.
        "TERM_PROGRAM": "iTerm.app",
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
            proc.wait()
        os.close(master)


def measure(executable: Path, base: Path, api_port: int,
            fixture: Fixture) -> dict[str, Any]:
    result: dict[str, Any] = {"executable": str(executable)}
    with tui_pty(executable, base, api_port) as master:
        # Warm-up: boot, first screenshot, viewport settle.
        boot_bytes, _ = drain(master, WARMUP_SEC)
        result["warmup_bytes"] = boot_bytes

        # These are the pinned TUI's browser toggle and viewport commands.
        os.write(master, b"\x1e")  # Ctrl-^
        result["browser_read_observed"] = await_browser_read(master, fixture)
        drain(master, CADENCE_SEC)
        os.write(master, b"\x0f")  # Ctrl-O
        drain(master, 2.0 * CADENCE_SEC)

        windows = []
        phase_polls: dict[str, int] = {}
        for phase, ticks in (("constant", TICKS_CONSTANT),
                             ("control", TICKS_CONTROL),
                             ("tail", TICKS_TAIL_CONSTANT)):
            fixture.set_phase(phase)
            for tick in range(ticks):
                before = len(fixture.snapshot())
                b, c = drain(master, CADENCE_SEC)
                windows.append({"phase": phase, "tick": tick + 1,
                                "bytes": b, "chunks": c,
                                "polls": len(fixture.snapshot()) - before})
            phase_polls[phase] = sum(poll["phase"] == phase
                                     for poll in fixture.snapshot())
        result["windows"] = windows
        const = sum(w["bytes"] for w in windows if w["phase"] == "constant")
        control = sum(w["bytes"] for w in windows if w["phase"] == "control")
        result["constant_ticks_bytes"] = const
        result["control_tick_bytes"] = control
        result["phase_polls"] = phase_polls
        result["polls"] = fixture.snapshot()
        result["poll_count"] = len(result["polls"])
        result["read_count"] = fixture.read_count
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
            "control_ticks": TICKS_CONTROL,
            "cadence_sec": CADENCE_SEC,
            "warmup_sec": WARMUP_SEC,
            "same_image": True,
        },
    }
    for label, exe in (("before", args.before), ("after", args.after)):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            (base / ".masc").mkdir(parents=True, exist_ok=True)
            fixture = Fixture()
            with fixture_server(fixture, base) as port:
                report[label] = measure(exe, base, port, fixture)

    before_const = report["before"]["constant_ticks_bytes"]
    after_const = report["after"]["constant_ticks_bytes"]
    before_ctrl = report["before"]["control_tick_bytes"]
    after_ctrl = report["after"]["control_tick_bytes"]
    report["delta_constant"] = before_const - after_const
    expected = {"constant": TICKS_CONSTANT, "control": TICKS_CONTROL,
                "tail": TICKS_TAIL_CONSTANT}
    report["poll_coverage_matches"] = all(
        report[label]["phase_polls"] == expected
        and report[label]["read_count"] > 0
        for label in ("before", "after")
    )
    report["control_flows_both"] = before_ctrl > 0 and after_ctrl > 0
    report["measurement_valid"] = (report["poll_coverage_matches"]
                                   and report["control_flows_both"])
    report["skip_effective"] = (report["measurement_valid"]
                                and after_const < before_const)

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({
        "before_constant": before_const,
        "after_constant": after_const,
        "delta": report["delta_constant"],
        "skip_effective": report["skip_effective"],
        "control_flows_both": report["control_flows_both"],
        "measurement_valid": report["measurement_valid"],
    }, indent=2))
    return 0 if report["measurement_valid"] else 3


if __name__ == "__main__":
    raise SystemExit(main())
