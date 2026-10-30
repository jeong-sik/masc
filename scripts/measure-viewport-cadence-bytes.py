#!/usr/bin/env python3
"""Measure PTY bytes for constant browser viewport screenshots.

The loopback fixture gates each screenshot response. A sample starts when a
response is released and ends just before the next screenshot response is
released. The manually requested first screenshot is warmup; the 15-second
session starts at the next cadence request. It includes one settling window,
five constant samples and a changed-title control window. PTY bytes can include unrelated
TUI output, including asynchronous frames from other events. Title and image
co-occurrence in a window does not establish which event caused either. The
two pins must run in the same environment. This is a bounded experiment, not a
measurement of CPU, latency, real-browser traffic, or exclusive causation.
"""
from __future__ import annotations

import argparse
import base64
import fcntl
import hashlib
import json
import os
import pty
import queue
import secrets
import select
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
import zlib
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Iterator

CONSTANT_SAMPLES = 5
EXPECTED_POLLS = CONSTANT_SAMPLES + 4  # manual warmup, settle, constant, control, boundary
CADENCE_SEC = 2
SESSION_SEC = 15.0
SESSIONS = 3
STARTUP_SEC = 3.0
READY_TIMEOUT_SEC = 20.0
POLL_TIMEOUT_SEC = 12.0
CLIENT = "fixture-client-0001"
URL = "https://example.org/specimen"
TITLE = "Constant viewport"


def make_png() -> bytes:
    """Produce stable, valid image bytes with enough detail for a byte probe."""
    def chunk(tag: bytes, body: bytes) -> bytes:
        return (struct.pack(">I", len(body)) + tag + body
                + struct.pack(">I", zlib.crc32(tag + body) & 0xFFFFFFFF))

    width, height = 80, 60
    raw = b"".join(
        b"\0" + b"".join(hashlib.sha256(f"{x},{y}".encode()).digest()[:3]
                         for x in range(width))
        for y in range(height)
    )
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


PNG_B64 = base64.b64encode(make_png()).decode("ascii")


class Fixture:
    def __init__(self, base: Path, control_title: str) -> None:
        self.base = base
        self.control_title = control_title
        self.lock = threading.Lock()
        self.poll_count = 0
        self.requests: queue.Queue[dict[str, Any]] = queue.Queue()
        self.read_complete = threading.Event()
        self.responses_complete = 0
        self.errors: list[str] = []
        self.exchanges: list[dict[str, Any]] = []
        self.setup_exchanges: list[dict[str, Any]] = []

    def record_setup(self, method: str, path: str, request: Any,
                     response: dict[str, Any], written: bool) -> None:
        with self.lock:
            self.setup_exchanges.append({"method": method, "path": path, "request": request,
                                         "response": response, "reply_written": written})

    def screenshot(self, request: dict[str, Any]) -> tuple[int, dict[str, Any], dict[str, Any] | None]:
        if any(request.get(k) != v for k, v in
               (("lane", "live"), ("clientId", CLIENT), ("tabId", 7))):
            with self.lock:
                self.errors.append("unexpected screenshot request: " + repr(request))
            return 400, {"ok": False, "error": {"message": "unexpected request"}}, None
        gate = threading.Event()
        with self.lock:
            self.poll_count += 1
            n = self.poll_count
        event = {"number": n, "gate": gate, "received_at": time.monotonic()}
        self.requests.put(event)
        if not gate.wait(POLL_TIMEOUT_SEC * 2):
            with self.lock:
                self.errors.append(f"poll {n} was not released")
            return 504, {"ok": False, "error": {"message": "fixture gate timeout"}}, event
        title = self.control_title if n == CONSTANT_SAMPLES + 3 else TITLE
        return 200, {"ok": True, "data": {
            "source": "live", "clientId": CLIENT, "tabId": 7,
            "title": title, "url": URL, "mimeType": "image/png", "data": PNG_B64,
            "viewport": {"documentId": "fixture-doc-1", "width": 80, "height": 24,
                         "scrollX": 0, "scrollY": 0}, "elapsed_ms": 250,
        }}, event


@contextmanager
def fixture_server(fixture: Fixture) -> Iterator[int]:
    class Handler(BaseHTTPRequestHandler):
        def reply(self, payload: dict[str, Any], status: int = 200) -> bool:
            raw = json.dumps(payload).encode()
            try:
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)
                return True
            except (BrokenPipeError, ConnectionResetError):
                with fixture.lock:
                    fixture.errors.append("client disconnected before fixture reply")
                return False

        def do_GET(self) -> None:  # noqa: N802
            path = self.path.split("?")[0]
            if path == "/health":
                payload = {"version": "fixture", "build": {"binary_commit": "fixture"},
                           "paths": {"effective_base_path": str(fixture.base),
                                     "effective_masc_root": str(fixture.base / ".masc")},
                           "startup": {"state_ready": True}}
                fixture.record_setup("GET", path, None, payload, self.reply(payload))
            elif path == "/api/v1/dashboard/browser-lane/clients":
                client = {"clientId": CLIENT, "browser": "firefox", "transport": "web_extension",
                          "space": None, "spaceObservation": None, "interactions": [],
                          "lastActivities": []}
                browse = {"ok": True, "data": {"lane": "live", "clientId": CLIENT,
                                                "reason": "existing_login"}}
                work = {"ok": False, "error": {"code": "no_available_browser",
                                               "message": "no work browser"}}
                payload = {"ok": True, "data": {"clients": [client],
                                                   "automatic": {"browse": browse, "work": work}}}
                fixture.record_setup("GET", path, None, payload, self.reply(payload))
            else:
                self.reply({"ok": True, "posts": [], "keepers": [], "snapshots": [],
                            "asks": [], "pending": []})

        def do_POST(self) -> None:  # noqa: N802
            try:
                length = int(self.headers.get("Content-Length") or 0)
                request = json.loads(self.rfile.read(length) or b"{}")
            except (ValueError, json.JSONDecodeError):
                self.reply({"ok": False}, 400)
                return
            path = self.path.split("?")[0]
            if path == "/api/v1/dashboard/browser-lane/read":
                payload = {"ok": True, "data": {
                    "tabs": [{"id": 7, "title": TITLE, "url": URL, "active": True}],
                    "page": {"tabId": 7, "title": TITLE, "url": URL, "text": "fixture",
                             "chars": 7, "truncated": False}, "source": "live",
                    "clientId": CLIENT, "elapsed_ms": 250}}
                fixture.record_setup("POST", path, request, payload, self.reply(payload))
                fixture.read_complete.set()
            elif path == "/api/v1/dashboard/browser-lane/screenshot":
                status, payload, event = fixture.screenshot(request)
                delivered = self.reply(payload, status)
                if event is not None:
                    event["completed_at"] = time.monotonic()
                with fixture.lock:
                    fixture.exchanges.append({"request": request, "status": status,
                                              "response": payload, "reply_written": delivered,
                                              "poll": None if event is None else event["number"]})
                    fixture.responses_complete += 1
            else:
                self.reply({"ok": True})

        def log_message(self, *args: Any) -> None:
            return

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield int(server.server_address[1])
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


@contextmanager
def tui_pty(executable: Path, base: Path, api_port: int) -> Iterator[tuple[int, subprocess.Popen[bytes]]]:
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(base),
           "TERM": "xterm-256color", "TERM_PROGRAM": "iTerm.app",
           "MASC_BASE_PATH": str(base), "MASC_HOST": "127.0.0.1", "MASC_TUI_SYNC": "off",
           "NO_PROXY": "127.0.0.1,localhost", "no_proxy": "127.0.0.1,localhost"}
    try:
        proc = subprocess.Popen([str(executable), "--base-path", str(base), "--workspace",
                                 "viewport-bytes", "--port", str(api_port), "--refresh",
                                 str(CADENCE_SEC)], stdin=slave, stdout=slave, stderr=slave,
                                env=env, cwd=str(base), start_new_session=True)
    except BaseException:
        os.close(master)
        os.close(slave)
        raise
    os.close(slave)
    try:
        yield master, proc
    finally:
        if proc.poll() is None:
            proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        os.close(master)


def response_boundary_ordered(current: dict[str, Any], following: dict[str, Any]) -> bool:
    """Require response release and completion before the next request arrived."""
    complete = current.get("completed_at")
    return complete is not None and current["released_at"] <= complete <= following["received_at"]


def measure(executable: Path, base: Path, capture: Path, control_title: str,
            *, startup_marker: bytes | None = None) -> dict[str, Any]:
    fixture = Fixture(base, control_title)
    output = bytearray()
    windows: list[dict[str, Any]] = []
    errors: list[str] = []
    current: dict[str, Any] | None = None
    cursor = 0
    session_started: float | None = None
    session_cursor = 0
    session_duration = 0.0
    result: dict[str, Any] = {"executable": str(executable), "windows": windows,
                              "errors": errors}

    def read(master: int, timeout: float) -> None:
        ready, _, _ = select.select([master], [], [], timeout)
        if ready:
            try:
                data = os.read(master, 65536)
            except OSError:
                return
            output.extend(data)

    def wait_for(master: int, proc: subprocess.Popen[bytes], predicate: Any,
                 timeout: float, description: str) -> bool:
        deadline = time.monotonic() + timeout
        while not predicate():
            if proc.poll() is not None:
                errors.append(f"TUI exited {proc.returncode} while waiting for {description}")
                return False
            if time.monotonic() >= deadline:
                errors.append(f"timed out waiting for {description}")
                return False
            read(master, 0.05)
        return True

    def has_title_and_image(data: bytes, title: str) -> bool:
        return (title.encode() in data and b"\x1b]1337;File=" in data
                and PNG_B64.encode() in data)

    try:
        with fixture_server(fixture) as port, tui_pty(executable, base, port) as (master, proc):
            # The terminal capability probe completes before the lane key is sent.
            if startup_marker is None:
                until = time.monotonic() + STARTUP_SEC
                while time.monotonic() < until and proc.poll() is None:
                    read(master, 0.05)
                started = proc.poll() is None
            else:
                # The fake used by the contract test announces that it set raw mode.
                started = wait_for(master, proc, lambda: startup_marker in output,
                                   READY_TIMEOUT_SEC, "test terminal readiness")
            ready = False
            if started:
                os.write(master, b"\x1e")  # Ctrl-^: open the browser lane
                ready = wait_for(master, proc,
                                 lambda: fixture.read_complete.is_set() and b"Read 250.0 ms" in output,
                                 READY_TIMEOUT_SEC, "browser lane read")
            if ready:
                os.write(master, b"\x0f")  # Ctrl-O: open the selected screenshot
                for expected in range(1, EXPECTED_POLLS + 1):
                    available = wait_for(master, proc, lambda: not fixture.requests.empty(),
                                         POLL_TIMEOUT_SEC, f"screenshot poll {expected}")
                    if not available:
                        break
                    event = fixture.requests.get_nowait()
                    # Include all currently readable bytes before crossing the response boundary.
                    while select.select([master], [], [], 0)[0]:
                        before = len(output)
                        read(master, 0)
                        if len(output) == before:
                            break
                    if current is not None:
                        data = bytes(output[cursor:])
                        number = current["number"]
                        ordered = response_boundary_ordered(current, event)
                        if not ordered:
                            errors.append(f"response {number} overlapped the next request")
                        completed_at = current.get("completed_at")
                        windows.append({"poll": number, "bytes": len(data),
                                        "duration_sec": time.monotonic() - current["released_at"],
                                        "next_request_after_release_sec": event["received_at"] - current["released_at"],
                                        "completion_after_release_sec": (None if completed_at is None else
                                            completed_at - current["released_at"]),
                                        "response_completed_before_next_request": ordered,
                                        "title_and_image_observed": has_title_and_image(data, control_title if
                                            number == CONSTANT_SAMPLES + 3 else TITLE)})
                    if event["number"] != expected:
                        errors.append(f"expected poll {expected}, received {event['number']}")
                    cursor = len(output)
                    event["released_at"] = time.monotonic()
                    if event["number"] == 2:
                        session_started = event["released_at"]
                        session_cursor = cursor
                    current = event
                    event["gate"].set()
                    if expected == EXPECTED_POLLS:
                        wait_for(master, proc,
                                 lambda: fixture.responses_complete >= EXPECTED_POLLS,
                                 POLL_TIMEOUT_SEC, "final fixture reply")
                if session_started is not None:
                    deadline = session_started + SESSION_SEC
                    if len(windows) == EXPECTED_POLLS - 1:
                        if time.monotonic() > deadline:
                            errors.append("expected polls exceeded the session duration")
                        while time.monotonic() < deadline and proc.poll() is None:
                            read(master, max(0.0, min(0.05, deadline - time.monotonic())))
                        if proc.poll() is not None:
                            errors.append("TUI exited before the session ended")
                    session_duration = time.monotonic() - session_started
    except (OSError, ValueError) as exc:
        errors.append(f"harness error: {exc}")
    finally:
        capture.parent.mkdir(parents=True, exist_ok=True)
        capture.write_bytes(output)

    with fixture.lock:
        errors.extend(fixture.errors)
        poll_count = fixture.poll_count
        exchanges = list(fixture.exchanges)
        setup_exchanges = list(fixture.setup_exchanges)
    fixture_capture = capture.with_suffix(".fixture.json")
    fixture_capture.write_text(json.dumps({"schema": "masc.viewport_fixture.v1",
                                           "control_title": control_title,
                                           "setup_exchanges": setup_exchanges,
                                           "screenshot_exchanges": exchanges}, indent=2) + "\n")
    by_poll = {w["poll"]: w for w in windows}
    constants = [by_poll[n] for n in range(3, CONSTANT_SAMPLES + 3) if n in by_poll]
    initial = by_poll.get(1, {}).get("title_and_image_observed", False)
    control = by_poll.get(CONSTANT_SAMPLES + 3, {}).get("title_and_image_observed", False)
    if not initial:
        errors.append("initial title and image were not observed in the window")
    if not control:
        errors.append("control title and image were not observed in the window")
    if poll_count != EXPECTED_POLLS or len(constants) != CONSTANT_SAMPLES:
        errors.append("unexpected number of screenshot polls or constant samples")
    result.update({"poll_count": poll_count, "constant_samples": len(constants),
                   "session_poll_count": max(0, poll_count - 1),
                   "session_duration_sec": session_duration,
                   "session_total_bytes": max(0, len(output) - session_cursor) if session_started else 0,
                   "fixture_capture": fixture_capture.name,
                   "constant_ticks_bytes": sum(w["bytes"] for w in constants),
                   "constant_windows_with_title_and_image": sum(
                       w["title_and_image_observed"] for w in constants),
                   "control_tick_bytes": by_poll.get(CONSTANT_SAMPLES + 3, {}).get("bytes", 0),
                   "initial_window_observed": initial, "control_window_observed": control,
                   "valid": not errors})
    return result


def judge(before: dict[str, Any], after: dict[str, Any]) -> dict[str, Any]:
    poll_counts_match = (before["poll_count"] == after["poll_count"] == EXPECTED_POLLS
                         and before["constant_samples"] == after["constant_samples"] == CONSTANT_SAMPLES)
    control = before["control_window_observed"] and after["control_window_observed"]
    delta = before["constant_ticks_bytes"] - after["constant_ticks_bytes"]
    baseline_images = before["constant_windows_with_title_and_image"] == CONSTANT_SAMPLES
    images_reduced = (after["constant_windows_with_title_and_image"]
                      < before["constant_windows_with_title_and_image"])
    valid = before["valid"] and after["valid"] and poll_counts_match and control and baseline_images
    return {"valid": valid,
            "poll_counts_match": poll_counts_match, "control_windows_observed": control,
            "baseline_windows_observed": baseline_images, "observed_windows_reduced": images_reduced,
            "delta_constant": delta, "comparison_passed": valid and delta > 0 and images_reduced}


def judge_sessions(before: list[dict[str, Any]], after: list[dict[str, Any]]) -> dict[str, Any]:
    if len(before) != SESSIONS or len(after) != SESSIONS:
        raise ValueError("the comparison requires the expected number of sessions on each side")
    pairs = [judge(b, a) for b, a in zip(before, after)]
    for index, pair in enumerate(pairs, 1):
        pair["session"] = index
    valid = all(pair["valid"] for pair in pairs)
    before_bytes = sum(s["constant_ticks_bytes"] for s in before)
    after_bytes = sum(s["constant_ticks_bytes"] for s in after)
    before_windows = sum(s["constant_windows_with_title_and_image"] for s in before)
    after_windows = sum(s["constant_windows_with_title_and_image"] for s in after)
    samples = SESSIONS * CONSTANT_SAMPLES
    return {"valid": valid, "session_comparisons": pairs,
            "constant_samples_per_side": samples,
            "before_constant_bytes": before_bytes, "after_constant_bytes": after_bytes,
            "before_constant_mean_bytes": before_bytes / samples,
            "after_constant_mean_bytes": after_bytes / samples,
            "before_windows_observed": before_windows, "after_windows_observed": after_windows,
            "delta_constant": before_bytes - after_bytes,
            "comparison_passed": valid and after_bytes < before_bytes and after_windows < before_windows}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--before", required=True, type=Path)
    parser.add_argument("--after", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    args.out.parent.mkdir(parents=True, exist_ok=True)
    control_title = "Control-" + secrets.token_hex(12)
    report: dict[str, Any] = {"schema": "masc.viewport_cadence_bytes.v2",
                              "definition": "raw PTY bytes per screenshot response window",
                              "limitation": "A window can contain unrelated or delayed asynchronous frames; "
                                            "co-occurring title and image bytes do not establish causation.",
                              "control_title": control_title,
                              "conditions": {"constant_samples": CONSTANT_SAMPLES,
                                             "sessions_per_binary": SESSIONS,
                                             "session_seconds": SESSION_SEC,
                                             "expected_polls": EXPECTED_POLLS,
                                             "warmup_polls": 1,
                                             "expected_session_polls": EXPECTED_POLLS - 1,
                                             "cadence_sec": CADENCE_SEC,
                                             "same_image": True,
                                             "terminal": "emulated iTerm graphics"}}
    measured: dict[str, list[dict[str, Any]]] = {"before": [], "after": []}
    for index in range(1, SESSIONS + 1):
        for label, executable in (("before", args.before), ("after", args.after)):
            with tempfile.TemporaryDirectory(prefix="masc-viewport-bytes-") as tmp:
                base = Path(tmp).resolve()
                (base / ".masc").mkdir()
                measured[label].append(measure(executable.resolve(), base,
                    args.out.parent / f"capture-{label}-{index}.bin", control_title))
    report.update(measured)
    report.update(judge_sessions(measured["before"], measured["after"]))
    args.out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({k: report[k] for k in
                      ("valid", "constant_samples_per_side", "before_constant_mean_bytes",
                       "after_constant_mean_bytes", "before_windows_observed",
                       "after_windows_observed", "comparison_passed", "delta_constant")}, indent=2))
    return 0 if report["valid"] and report["comparison_passed"] else 3


if __name__ == "__main__":
    raise SystemExit(main())
