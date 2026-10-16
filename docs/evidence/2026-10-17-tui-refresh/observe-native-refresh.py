#!/usr/bin/env python3
"""Manual native-TUI observation, with a real isolated backend and delayed reads.

Frames are collected for inspection, never matched against expected UI text.
The proxy changes only the paused reading of fixture Keeper rows during the
    warm refresh, and changes their health to a visible failing reading. This
    synthetic input and its native UI projection are recorded
separately from real fleet behavior and physical terminal paint latency.
"""
import argparse
import codecs
import fcntl
import hashlib
import http.client
import json
import os
from pathlib import Path
import pty
import select
import signal
import socket
import struct
import subprocess
import sys
import termios
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "pty-python-dependencies"))
import pyte
from PIL import Image, ImageDraw, ImageFont


def dump(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def free_port():
    with socket.socket() as handle:
        handle.bind(("127.0.0.1", 0))
        return handle.getsockname()[1]


def stop(process):
    if process is not None and process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()


def frame_image(screen, destination):
    cell_w, cell_h = 10, 21
    canvas = Image.new("RGB", (screen.columns * cell_w, screen.lines * cell_h), "#111418")
    draw = ImageDraw.Draw(canvas)
    latin = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 15)
    korean = ImageFont.truetype("/System/Library/Fonts/AppleSDGothicNeo.ttc", 16)
    colours = {"default": "#d8dde5", "black": "#111418", "red": "#e06c75",
               "green": "#98c379", "brown": "#e5c07b", "blue": "#61afef",
               "magenta": "#c678dd", "cyan": "#56b6c2", "white": "#d8dde5"}
    def colour(value, fallback):
        if value in colours:
            return colours[value]
        if len(value) == 6 and all(c in "0123456789abcdefABCDEF" for c in value):
            return "#" + value
        return fallback
    for row in range(screen.lines):
        for col in range(screen.columns):
            cell = screen.buffer[row][col]
            foreground = colour(cell.fg, "#d8dde5")
            background = "#111418" if cell.bg == "default" else colour(cell.bg, "#111418")
            if cell.reverse:
                foreground, background = background, foreground
            x, y = col * cell_w, row * cell_h
            draw.rectangle((x, y, x + cell_w, y + cell_h), fill=background)
            if cell.data and cell.data != " ":
                font = korean if any(ord(c) > 0x2fff for c in cell.data) else latin
                draw.text((x, y), cell.data, font=font, fill=foreground)
    canvas.save(destination)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--server", type=Path, required=True)
    parser.add_argument("--tui", type=Path, required=True)
    parser.add_argument("--arm", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--columns", type=int, default=120)
    parser.add_argument("--rows", type=int, default=36)
    parser.add_argument("--delay", type=float, default=2.0)
    parser.add_argument("--surface", choices=("dashboard", "keepers"), default="dashboard")
    args = parser.parse_args()
    args.output.mkdir(mode=0o700)
    base = args.output.resolve() / "workspace"
    base.mkdir(mode=0o700)
    env = {key: os.environ[key] for key in ("PATH", "HOME", "TMPDIR", "LANG") if key in os.environ}
    env.update({"MASC_BASE_PATH": str(base), "XDG_CONFIG_HOME": str(base / "xdg"),
                "TERM": "xterm-256color", "COLORTERM": "truecolor"})
    server_port = free_port()
    server = tui = proxy = None
    started = time.monotonic()
    observations = []
    receipt = {"arm": args.arm, "base": str(base), "viewport": [args.columns, args.rows],
               "delay_seconds": args.delay, "surface": args.surface, "status": "started", "physical_paint_measured": False,
               "input_scope": "Real isolated backend; proxy delays briefing/operator and changes fixture roster health offline to failing, paused false to true at warm refresh",
               "dependency_scope": "Both CI binaries use the same recorded local Homebrew dependencies",
               "frame_scope": "Captured native PTY output decoded with pyte; PNG is a rendering of that captured cell state",
               "inherited_environment_keys": sorted(env), "binary_identity": {},
               "observer_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
    dump(args.output / "observation.json", receipt)
    try:
        for role, binary, flag in (("server", args.server, "build-commit"), ("tui", args.tui, "--build-commit")):
            identity = subprocess.run([str(binary), flag], env=env, capture_output=True, text=True, timeout=15)
            receipt["binary_identity"][role] = {"path": str(binary.resolve()),
                "sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
                "source": identity.stdout.strip(), "returncode": identity.returncode, "stderr": identity.stderr}
            if identity.returncode:
                raise RuntimeError(role + " embedded identity failed")
        init = subprocess.run([str(args.server), "init", "--base-path", str(base)],
                              env=env, capture_output=True, text=True, timeout=30)
        dump(args.output / "init.json", {"returncode": init.returncode, "stdout": init.stdout, "stderr": init.stderr})
        if init.returncode:
            raise RuntimeError("isolated workspace initialization failed")
        profiles = base / ".masc/config/keepers"
        profiles.mkdir(parents=True, exist_ok=True)
        fixture = '[keeper]\nactivation_mode = "manual"\nsandbox_profile = "docker"\nsandbox_image = "base"\nnetwork_mode = "inherit"\ninstructions = "Private native refresh observation fixture. Remain manual."\n'
        for name in ("probe-one", "probe-two"):
            (profiles / (name + ".toml")).write_text(fixture)
        receipt["fixture_sha256"] = hashlib.sha256(fixture.encode()).hexdigest()
        meta_source = ROOT / "keeper-meta-fixture.json"
        template = json.loads(meta_source.read_text())
        receipt["meta_fixture_sha256"] = hashlib.sha256(meta_source.read_bytes()).hexdigest()
        metadata = base / ".masc/keepers"
        metadata.mkdir(parents=True, exist_ok=True)
        for name in ("probe-one", "probe-two"):
            meta = {**template, "name": name, "trace_id": "trace-native-" + name, "paused": False}
            dump(metadata / (name + ".json"), meta)
        runtime_file = base / ".masc/config/runtime.toml"
        with runtime_file.open("a") as config:
            config.write('\n[tui]\nopening = "overview"\n')
        log = (args.output / "server.log").open("wb")
        server = subprocess.Popen([str(args.server), "start", "--base-path", str(base),
                                   "--port", str(server_port), "--host", "127.0.0.1"],
                                  env=env, cwd=base, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        health = None
        for _ in range(600):
            if server.poll() is not None:
                raise RuntimeError("isolated backend exited during startup")
            try:
                connection = http.client.HTTPConnection("127.0.0.1", server_port, timeout=0.5)
                connection.request("GET", "/health?full=1")
                response = connection.getresponse()
                health = json.loads(response.read())
                connection.close()
                paths = health.get("paths", {})
                if paths.get("effective_base_path") != str(base) or paths.get("effective_masc_root") != str(base / ".masc"):
                    raise RuntimeError("isolated backend workspace identity differs")
                dump(args.output / "health.json", health)
                # The TUI's own readiness decoder remains authoritative. A short
                # startup settling interval belongs to this experiment, not runtime policy.
                time.sleep(1)
                break
            except (ConnectionError, OSError, http.client.HTTPException, json.JSONDecodeError):
                time.sleep(0.1)
        else:
            raise RuntimeError("backend observation window ended before a health reading")

        warm = threading.Event()
        class Proxy(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"
            def log_message(self, *unused):
                pass
            def exchange(self):
                request_start = time.monotonic()
                path = urlsplit(self.path).path
                is_warm = warm.is_set()
                delayed = is_warm and path in ("/api/v1/dashboard/briefing", "/api/v1/operator")
                if delayed:
                    time.sleep(args.delay)
                size = int(self.headers.get("Content-Length", 0))
                body = self.rfile.read(size) if size else None
                headers = {key: value for key, value in self.headers.items()
                           if key.lower() not in ("host", "connection", "content-length")}
                conn = http.client.HTTPConnection("127.0.0.1", server_port, timeout=15)
                rewritten = 0
                try:
                    conn.request(self.command, self.path, body=body, headers=headers)
                    response = conn.getresponse()
                    if "text/event-stream" in response.getheader("Content-Type", ""):
                        self.send_response(response.status)
                        self.send_header("Content-Type", "text/event-stream")
                        self.send_header("Connection", "close")
                        self.end_headers()
                        while True:
                            part = response.readline()
                            if not part:
                                break
                            self.wfile.write(part)
                            self.wfile.flush()
                        return
                    payload = response.read()
                    if path == "/api/v1/gate/keepers" and response.status == 200:
                        value = json.loads(payload)
                        def mark_rows(node):
                            nonlocal rewritten
                            if isinstance(node, dict):
                                if is_warm and "name" in node and isinstance(node.get("paused"), bool):
                                    node["paused"] = True
                                    node["health"] = "failing"
                                    rewritten += 1
                                for child in node.values():
                                    mark_rows(child)
                            elif isinstance(node, list):
                                for child in node:
                                    mark_rows(child)
                        mark_rows(value)
                        dump(args.output / ("roster-warm.json" if is_warm else "roster-cold.json"), value)
                        payload = json.dumps(value, ensure_ascii=False).encode()
                    self.send_response(response.status)
                    for key, value in response.getheaders():
                        if key.lower() not in ("content-length", "transfer-encoding", "connection"):
                            self.send_header(key, value)
                    self.send_header("Content-Length", str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)
                    self.wfile.flush()
                    observations.append({"path": path, "warm": is_warm, "delayed": delayed,
                        "started_ms": (request_start - started) * 1000,
                        "finished_ms": (time.monotonic() - started) * 1000,
                        "status": response.status, "rewritten_fixture_rows": rewritten})
                except (ConnectionError, OSError, http.client.HTTPException) as error:
                    observations.append({"path": path, "warm": is_warm, "error": type(error).__name__})
                    self.close_connection = True
                finally:
                    conn.close()
            do_GET = exchange
            do_POST = exchange
        proxy = ThreadingHTTPServer(("127.0.0.1", 0), Proxy)
        proxy.daemon_threads = True
        threading.Thread(target=proxy.serve_forever, daemon=True).start()
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", args.rows, args.columns, 0, 0))
        tui = subprocess.Popen([str(args.tui), "--base-path", str(base), "--port", str(proxy.server_port), "--refresh", "3600"],
                               env=env, cwd=base, stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
        os.close(slave)
        class ObservationScreen(pyte.Screen):
            def write_process_input(self, data):
                os.write(master, data.encode())

            def report_device_status(self, mode, **kwargs):
                # pyte 0.8.2 does not accept DEC-private status requests.
                # Unsupported private terminal reports receive no answer.
                if not kwargs.get("private"):
                    super().report_device_status(mode)

        screen = ObservationScreen(args.columns, args.rows)
        stream = pyte.Stream(screen)
        decoder = codecs.getincrementaldecoder("utf-8")("replace")
        tui_started = time.monotonic()
        snapshots = [(0.5, "cold-0.5"), (2, "cold-2"), (6, "cold-6"),
                     (8.1, "warm-0.1"), (8.5, "warm-0.5"), (9, "warm-1"),
                     (10.5, "warm-2.5"), (12, "warm-4")]
        refresh_sent = False
        navigation_steps = 0
        with (args.output / "native.ansi").open("wb") as raw, (args.output / "frames.jsonl").open("w") as frames:
            while time.monotonic() - tui_started < 12.5:
                elapsed = time.monotonic() - tui_started
                if tui.poll() is not None:
                    raise RuntimeError("native TUI exited before observation finished")
                if navigation_steps == 0 and elapsed >= 6.3:
                    os.write(master, b"\t" if args.surface == "keepers" else b"\x02")
                    navigation_steps = 1
                if args.surface == "keepers" and navigation_steps == 1 and elapsed >= 6.6:
                    os.write(master, b"\t")
                    navigation_steps = 2
                if not refresh_sent and elapsed >= 8:
                    warm.set()
                    receipt["warm_refresh_sent_ms"] = (time.monotonic() - started) * 1000
                    os.write(master, b"r")
                    refresh_sent = True
                if select.select([master], [], [], 0.02)[0]:
                    data = os.read(master, 1024 * 1024)
                    raw.write(data)
                    text = decoder.decode(data)
                    stream.feed(text)
                    frames.write(json.dumps({"elapsed_ms": (time.monotonic() - tui_started) * 1000,
                                             "rows": screen.display}, ensure_ascii=False) + "\n")
                while snapshots and elapsed >= snapshots[0][0]:
                    _, name = snapshots.pop(0)
                    (args.output / (name + ".txt")).write_text("\n".join(screen.display) + "\n")
                    frame_image(screen, args.output / (name + ".png"))
        receipt["status"] = "captured"
        receipt["warm_fixture_rows_changed"] = sum(row.get("rewritten_fixture_rows", 0) for row in observations)
        receipt["tui_exit_before_stop"] = tui.poll()
    except Exception as error:
        receipt["status"] = "failed"
        receipt["error_type"] = type(error).__name__
        receipt["error"] = str(error)
    finally:
        stop(tui)
        stop(server)
        if proxy is not None:
            proxy.shutdown()
            proxy.server_close()
        dump(args.output / "http-observations.json", observations)
        receipt["elapsed_seconds"] = time.monotonic() - started
        dump(args.output / "observation.json", receipt)
        print(json.dumps({"output": str(args.output), "status": receipt["status"], "error": receipt.get("error")}), flush=True)
    return 0 if receipt["status"] == "captured" else 1


if __name__ == "__main__":
    sys.exit(main())
