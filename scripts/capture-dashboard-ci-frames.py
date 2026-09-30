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
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def captures(log: str) -> list[dict]:
    result = []
    for line in log.splitlines():
        marker = "STUDIO_CAPTURE="
        if marker in line:
            result.append(json.loads(line.split(marker, 1)[1]))
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", type=Path)
    parser.add_argument("--run-info", type=Path)
    parser.add_argument("--expected-head")
    parser.add_argument("--out", type=Path)
    parser.add_argument("--replay", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.replay is not None:
        os.write(sys.stdout.fileno(), args.replay.read_bytes())
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
    binary_hashes = {
        line.split("STUDIO_BINARY_SHA256=", 1)[1].strip()
        for line in log.splitlines() if "STUDIO_BINARY_SHA256=" in line
    }
    args.out.mkdir(parents=True, exist_ok=True)
    evidence = {
        "provenance": "xterm replay of CI fixture PTY frames",
        "source_sha": run["headSha"], "run": run,
        "binary_sha256": sorted(binary_hashes),
        "suite_pass_seen": "tui dashboard studio PTY: PASS" in log,
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
                command = [ttyd, "-i", "127.0.0.1", "-p", str(port), "-t", "fontSize=16",
                           "-t", "disableResizeOverlay=true", sys.executable,
                           str(Path(__file__).resolve()), "--replay", str(frame_path.resolve())]
                process = subprocess.Popen(command, stdout=subprocess.DEVNULL,
                                           stderr=subprocess.PIPE)
                context = None
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
                    context = browser.new_context(viewport={
                        "width": columns * 10 + 24, "height": rows * 20 + 24})
                    page = context.new_page()
                    page.goto(f"http://127.0.0.1:{port}")
                    page.wait_for_function("window.term && window.term.buffer.active.getLine(0)")
                    page.evaluate("([cols, rows]) => window.term.resize(cols, rows)", [columns, rows])
                    page.wait_for_function("document.querySelector('.xterm-screen').innerText.includes('MASC Dashboard')")
                    page.locator(".xterm-screen").screenshot(path=str(args.out / f"{name}.png"))
                    evidence["frames"].append({
                        "name": name, "columns": columns, "rows": rows,
                        "frame_sha256": digest(raw),
                        "screenshot_sha256": digest((args.out / f"{name}.png").read_bytes()),
                        "screen": record["screen"],
                    })
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
