#!/usr/bin/env python3
"""Render recorded CI fixture PTY frames using ttyd's xterm frontend.

This replays original ANSI bytes; it does not run or build MASC. The manifest
keeps the producing run, source SHA, binary hash and frame hashes separate
from screenshot hashes. A screenshot is a replay of CI fixture PTY evidence,
never a claim about the installed or production terminal.
"""
from __future__ import annotations

import argparse
import base64
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import string
import subprocess
import sys
import tempfile
import time
import traceback


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def record_payload(line: str) -> str | None:
    # gh run --log prefixes stdout with job, step and an ISO timestamp.
    # Only unwrap that transport envelope; echoed workflow commands containing
    # a record marker remain commands, not records emitted by the PTY suite.
    envelope = line.split("\t", 2)
    if len(envelope) == 1:
        return line
    if len(envelope) != 3:
        return None
    timestamp, separator, payload = envelope[2].partition(" ")
    if not separator:
        return None
    try:
        datetime.fromisoformat(timestamp)
    except ValueError:
        return None
    return payload


def captures(log: str) -> list[dict]:
    result = []
    marker = "STUDIO_CAPTURE="
    for line in log.splitlines():
        payload = record_payload(line)
        if payload is None:
            continue
        if payload.startswith(marker):
            result.append(json.loads(payload[len(marker):]))
    return result


def binary_hashes(log: str) -> set[str]:
    result = set()
    marker = "STUDIO_BINARY_SHA256="
    for line in log.splitlines():
        payload = record_payload(line)
        if payload is None or not payload.startswith(marker):
            continue
        value = payload[len(marker):]
        if len(value) != 64 or any(char not in string.hexdigits for char in value):
            raise ValueError("malformed STUDIO_BINARY_SHA256 record")
        result.add(value.lower())
    return result


def expected_rows(record: dict) -> list[str]:
    lines = record["screen"].split("\n")
    if len(lines) != record["rows"]:
        raise ValueError("PTY screen row count differs from recorded terminal geometry")
    return [line.rstrip(" ") for line in lines]


def terminal_layout(page) -> dict:
    """Measure the actual terminal pixels and any clipping ancestors."""
    return page.evaluate("""() => {
        const screen = document.querySelector('.xterm-screen');
        if (!screen) return {screen: null, viewport: {width: innerWidth, height: innerHeight}};
        const rect = screen.getBoundingClientRect();
        const viewport = screen.parentElement.querySelector('.xterm-viewport');
        const scrollbarWidth = viewport ? Math.max(0, viewport.offsetWidth - viewport.clientWidth) : 0;
        const clippedBy = [];
        for (let ancestor = screen.parentElement; ancestor; ancestor = ancestor.parentElement) {
            const style = getComputedStyle(ancestor);
            const bounds = ancestor.getBoundingClientRect();
            const clips = value => ['hidden', 'clip', 'auto', 'scroll'].includes(value);
            if ((clips(style.overflowX) && (rect.left < bounds.left || rect.right > bounds.right))
                || (clips(style.overflowY) && (rect.top < bounds.top || rect.bottom > bounds.bottom))) {
                clippedBy.push({tag: ancestor.tagName, className: ancestor.className,
                    overflowX: style.overflowX, overflowY: style.overflowY});
            }
        }
        return {
            viewport: {width: innerWidth, height: innerHeight},
            native_scrollbar_width: scrollbarWidth,
            screen: {left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom,
                width: rect.width, height: rect.height, scrollWidth: screen.scrollWidth,
                scrollHeight: screen.scrollHeight, clientWidth: screen.clientWidth,
                clientHeight: screen.clientHeight},
            font: {family: window.term?.options.fontFamily,
                size: window.term?.options.fontSize, status: document.fonts.status},
            clippedBy
        };
    }""")


def preserve_failure(out: Path, name: str, record: dict, run: dict,
                     page, console: list[dict], error: Exception) -> None:
    """Save diagnostic artifacts; none of them constitute a verified frame."""
    report = {
        "capture_status": "failed",
        "provenance": "unverified xterm replay diagnostics",
        "run": run, "name": name,
        "expected_columns": record["columns"], "expected_rows": record["rows"],
        "expected_pty_screen": record["screen"],
        "error_type": type(error).__name__, "error": str(error),
        "traceback": "".join(traceback.format_exception(error)),
        "browser_events": console, "diagnostic_errors": [],
    }
    report_path = out / f"{name}-failure.json"
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    if page is not None:
        diagnostics = [
            ("terminal_layout", lambda: terminal_layout(page)),
            ("observed_xterm", lambda: page.evaluate("""() => {
                const term = window.term;
                return {
                    url: location.href,
                    viewport: {width: innerWidth, height: innerHeight},
                    terminal: term ? {
                        columns: term.cols, rows: term.rows,
                        lines: Array.from({length: term.rows}, (_, i) =>
                            term.buffer.active.getLine(i)?.translateToString(true) ?? '')
                    } : null
                };
            }""")),
            ("page_html", lambda: (out / f"{name}-failure.html").write_text(page.content())),
            ("page_screenshot", lambda: page.screenshot(
                path=str(out / f"{name}-failure.png"), timeout=5000)),
        ]
        for label, collect in diagnostics:
            try:
                result = collect()
                if label in ("observed_xterm", "terminal_layout"):
                    report[label] = result
            except Exception as diagnostic_error:
                report["diagnostic_errors"].append({
                    "diagnostic": label, "error": str(diagnostic_error)})
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", type=Path)
    parser.add_argument("--run-info", type=Path)
    parser.add_argument("--expected-head")
    parser.add_argument("--out", type=Path)
    parser.add_argument("--suite-pass-marker")
    parser.add_argument("--replay", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.replay is not None:
        # A visible ready record proves the websocket and replay process are
        # connected before the browser fixes geometry and sends Enter.
        sys.stdout.buffer.write(b"STUDIO_REPLAY_READY\r\n")
        sys.stdout.buffer.flush()
        sys.stdin.buffer.readline()
        sys.stdout.buffer.write(args.replay.read_bytes())
        sys.stdout.buffer.flush()
        signal.pause()
        return
    if None in (args.log, args.run_info, args.expected_head, args.out):
        parser.error("--log, --run-info, --expected-head and --out are required")
    from playwright.sync_api import sync_playwright

    ttyd = shutil.which("ttyd")
    if ttyd is None:
        raise SystemExit("ttyd is required to replay the recorded terminal frames")
    run = json.loads(args.run_info.read_text())
    if run["headSha"] != args.expected_head:
        raise SystemExit("run source SHA differs from --expected-head")
    log = args.log.read_text()
    frames = captures(log)
    if not frames:
        raise SystemExit("log contains no STUDIO_CAPTURE records")
    binaries = binary_hashes(log)
    args.out.mkdir(parents=True, exist_ok=True)
    evidence = {
        "provenance": "xterm replay of CI fixture PTY frames",
        "source_sha": run["headSha"], "run": run,
        "binary_sha256": sorted(binaries),
        "suite_pass_seen": any(
            args.suite_pass_marker is not None and record_payload(line) == args.suite_pass_marker
            for line in log.splitlines()
        ),
        "log_sha256": digest(args.log.read_bytes()), "frames": [],
    }
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch()
        try:
            for index, record in enumerate(frames):
                name = f"{index + 1:02d}-{record['name']}"
                raw = base64.b64decode(record["frame_b64"], validate=True)
                frame_path = args.out / f"{name}.ansi"
                frame_path.write_bytes(raw)
                with socket.socket() as sock:
                    sock.bind(("127.0.0.1", 0))
                    port = sock.getsockname()[1]
                command = [ttyd, "-i", "127.0.0.1", "-p", str(port), "-W",
                           "-t", "rendererType=dom", "-t", "fontSize=16",
                           "-t", "fontFamily=DejaVu Sans Mono, Liberation Mono, monospace",
                           "-t", "disableResizeOverlay=true",
                           "-T", "xterm-256color", sys.executable,
                           str(Path(__file__).resolve()), "--replay", str(frame_path.resolve())]
                process = subprocess.Popen(command, stdout=subprocess.DEVNULL,
                                           stderr=subprocess.PIPE)
                context = None
                page = None
                console = []
                try:
                    deadline = time.monotonic() + 10
                    while True:
                        if process.poll() is not None:
                            raise RuntimeError(process.stderr.read().decode())
                        try:
                            with socket.create_connection(("127.0.0.1", port), timeout=.2):
                                break
                        except OSError:
                            if time.monotonic() >= deadline:
                                raise RuntimeError("ttyd did not open its replay port")
                            time.sleep(.05)
                    columns, rows = record["columns"], record["rows"]
                    context = browser.new_context()
                    page = context.new_page()
                    page.on("console", lambda message: console.append({
                        "event": "console", "type": message.type, "text": message.text}))
                    page.on("pageerror", lambda error: console.append({
                        "event": "pageerror", "text": str(error)}))
                    page.goto(f"http://127.0.0.1:{port}")
                    page.wait_for_selector(".xterm-helper-textarea", state="attached")
                    page.wait_for_function("window.term && window.term.buffer.active.getLine(0)")
                    page.wait_for_function("""() => {
                        const term = window.term;
                        return Array.from({length: term.rows}, (_, i) =>
                            term.buffer.active.getLine(i)?.translateToString(true) ?? '')
                            .some(line => line === 'STUDIO_REPLAY_READY');
                    }""")
                    page.evaluate("document.fonts.ready")
                    page.evaluate("([cols, rows]) => window.term.resize(cols, rows)", [columns, rows])
                    layout = terminal_layout(page)
                    bounds = layout["screen"]
                    # The initial viewport is only for connection startup.
                    # Use measured pixels, retaining the terminal's margins.
                    viewport_size = {
                        "width": int(bounds["right"] + max(1, bounds["left"])
                                     + layout["native_scrollbar_width"] + 1),
                        "height": int(bounds["bottom"] + max(1, bounds["top"]) + 1),
                    }
                    if viewport_size != page.viewport_size:
                        # ttyd registers a synchronous window resize handler
                        # that calls FitAddon.fit(). Our listener is registered
                        # after READY, so its event follows that handler.
                        page.evaluate("""() => {
                            window.studioViewportResize = new Promise(resolve => {
                                window.addEventListener('resize', () => resolve(), {once: true});
                            });
                        }""")
                        page.set_viewport_size(viewport_size)
                        page.evaluate("window.studioViewportResize")
                    # Restore exact recorded cells only after ttyd's resize
                    # handler has finished, before releasing replay bytes.
                    page.evaluate("([cols, rows]) => window.term.resize(cols, rows)", [columns, rows])
                    page.wait_for_function(
                        "([cols, rows]) => window.term.cols === cols && window.term.rows === rows",
                        arg=[columns, rows],
                    )
                    page.evaluate("window.term.focus()")
                    page.keyboard.press("Enter")
                    # Both records contain terminal padding. Ignore only
                    # trailing ASCII spaces; retain all other content/cells.
                    expected = expected_rows(record)
                    page.wait_for_function(
                        """expected => {
                          const buffer = window.term.buffer.active;
                          const lines = Array.from({length: window.term.rows}, (_, i) =>
                            buffer.getLine(i)?.translateToString(true) ?? '')
                            .map(line => line.replace(/ +$/, ''));
                          return JSON.stringify(lines) === JSON.stringify(expected);
                        }""",
                        arg=expected,
                    )
                    page.evaluate("document.fonts.ready")
                    observed = page.evaluate("""() => ({
                      columns: window.term.cols, rows: window.term.rows,
                      screen: Array.from({length: window.term.rows}, (_, i) =>
                        window.term.buffer.active.getLine(i)?.translateToString(true) ?? '').join('\\n')
                    })""")
                    if (observed["columns"], observed["rows"]) != (columns, rows):
                        raise RuntimeError("xterm geometry changed before screenshot capture")
                    layout = terminal_layout(page)
                    bounds, viewport = layout["screen"], layout["viewport"]
                    if (bounds["left"] < 0 or bounds["top"] < 0
                        or bounds["right"] > viewport["width"]
                        or bounds["bottom"] > viewport["height"]
                        or bounds["scrollWidth"] > bounds["clientWidth"]
                        or bounds["scrollHeight"] > bounds["clientHeight"]
                        or layout["clippedBy"]):
                        raise RuntimeError("terminal pixels are clipped: " + json.dumps(layout))
                    page.locator(".xterm-screen").screenshot(path=str(args.out / f"{name}.png"))
                    evidence["frames"].append({
                        "name": name, "columns": columns, "rows": rows,
                        "frame_sha256": digest(raw),
                        "screenshot_sha256": digest((args.out / f"{name}.png").read_bytes()),
                        "pty_screen": record["screen"],
                        "observed_xterm_screen": observed["screen"],
                        "actual_columns": observed["columns"], "actual_rows": observed["rows"],
                        "terminal_layout": layout,
                    })
                except Exception as error:
                    try:
                        preserve_failure(args.out, name, record, run, page, console, error)
                    except Exception as diagnostic_error:
                        print(f"Replay failure diagnostics could not be saved: {diagnostic_error}",
                              file=sys.stderr)
                    raise
                finally:
                    if context is not None:
                        context.close()
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)
        finally:
            browser.close()
    (args.out / "manifest.json").write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"output": str(args.out), "frames": len(evidence["frames"]),
                      "source_sha": run["headSha"], "suite_pass_seen": evidence["suite_pass_seen"]}))


if __name__ == "__main__":
    main()
