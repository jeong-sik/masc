"""Observer changes, not a two-second timer, reread the visible Lane data."""

from __future__ import annotations

import fcntl
import http.server
import json
import os
import pathlib
import pty
import select
import socketserver
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
import unittest
import urllib.parse
from typing import cast


SESSION = "fixture-session"
INSTANCE = "fixture-instance"
WAIT = 12.0


def exact_lane(name: str, required: bool) -> dict:
    return {
        "lane_id": name,
        "label": name,
        "purpose": "fixture purpose",
        "required": required,
        "observation_only": True,
        "configured": True,
        "configuration_state": "ready",
        "admitted_slots": ["account.model"],
        "cli_slots": [],
        "declared_slots": ["account.model"],
        "declared_cli_slots": [],
        "dropped_slots": [],
        "admission_error": None,
        "status": "no_retained_observation",
        "retained_run_count": 0,
        "running_count": 0,
        "succeeded_count": 0,
        "failed_count": 0,
        "cancelled_count": 0,
        "last_started_at": None,
        "last_terminal_at": None,
        "last_outcome": None,
        "p50_elapsed_s": None,
        "selected_slots": [],
        "runs_without_slot": {"vendor_system_one": 0, "server_restarted": 0, "no_slot": 0},
        **({"jev": {"state": "off"}} if name == "board_attention" else {}),
    }


def lane_payload() -> dict:
    lanes = ["librarian", "hitl_auto_judge", "board_attention", "verifier", "browser_stagehand", "candle_appraiser"]
    configuration = {
        "kind": "configured",
        "admitted_slots": ["account.model"],
        "cli_slots": [],
        "declared_slots": ["account.model"],
        "declared_cli_slots": [],
        "dropped_slots": [],
        "admission_error": None,
    }
    rows = []
    for name in lanes:
        rows.append({
            "id": "exact/" + name,
            "label": name,
            "purpose": "fixture purpose",
            "selection": {"kind": "exact", "lane_id": name},
            "state": {"kind": "exact", "configuration": configuration},
        })
    for name, kind in [("live", "browser_clients"), ("automation", "browser_executor"), ("stagehand", "browser_executor")]:
        reading = {"kind": "observed", "connected_clients": 0} if kind == "browser_clients" else {"kind": "observed", "registered": True}
        rows.append({
            "id": "browser/" + name,
            "label": name,
            "purpose": "fixture purpose",
            "selection": {"kind": "browser", "lane": name},
            "state": {"kind": kind, "addon": reading},
        })
    for name in ["msx", "dos"]:
        rows.append({
            "id": "machine/" + name,
            "label": name,
            "purpose": "fixture purpose",
            "selection": {"kind": "machine", "machine": name},
            "state": {"kind": "machine", "activity": "on", "publication": "stable"},
        })
    return {
        "schema": "masc.lane-inventory/v1",
        "observed_at": 12.0,
        "rows": rows,
        "exact_snapshot": {
            "schema": "masc.standalone_llm_lanes.v2",
            "generated_at": "2026-10-04T00:00:00Z",
            "observed_at_unix": 12.0,
            "observation_only": True,
            "exact_run_projection_count": 0,
            "exact_run_source_total": 0,
            "exact_run_projection_truncated": False,
            "lanes": [exact_lane(name, name in {"hitl_auto_judge", "board_attention"}) for name in lanes],
        },
        "package_read": {"directory": "/config", "complete": True, "owner_present": True, "issues": []},
    }


def addon_payload() -> dict:
    return {
        "instances": [{
            "instance_id": "quiz-1",
            "run_id": "quiz",
            "addon_id": "operator-quiz",
            "title": "Operator quiz",
            "revision": "0.1.0",
            "phase": {"kind": "attached"},
            "runtime_presence": "live",
            "observation_seq": 1,
            "rows_count": 0,
            "incarnation": "quiz-1",
            "action_schema": None,
            "configuration": {"id": "operator-quiz", "source_path": "/c/operator-quiz.toml", "revision": "r1"},
            "binding": {"sources": []},
            "package": {"outputs": {"quiz": {"lanes": ["quiz/sessions"]}}, "skills_directory": None},
        }],
        "rows": [],
        "coverage": [],
        "configuration": {"directory": "/c", "complete": True, "declarations": [], "issues": []},
    }


class FeedServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    request_queue_size = 128

    def __init__(self, base: str) -> None:
        super().__init__(("127.0.0.1", 0), FeedHandler)
        self.base = os.path.realpath(base)
        self.condition = threading.Condition()
        self.events: list[dict] = []
        self.lane_reads = 0
        self.addon_reads = 0
        self.fail_next_lane = False

    def emit(self, dataset: str, instance_id: str | None = None) -> None:
        with self.condition:
            event = {"type": "workspace_dataset_changed", "dataset": dataset}
            if instance_id is not None:
                event["instance_id"] = instance_id
            self.events.append(event)
            self.condition.notify_all()

    def counts(self) -> tuple[int, int]:
        with self.condition:
            return self.lane_reads, self.addon_reads


class FeedHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format: str, *args: object) -> None:
        del format, args

    def respond(self, status: int, value: object) -> None:
        data = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("x-masc-workspace-read", "matched-v1")
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_POST(self) -> None:
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if urllib.parse.urlsplit(self.path).path != "/mcp":
            self.respond(503, {"error": "fixture write unavailable"})
            return
        try:
            message = json.loads(body)
        except (UnicodeDecodeError, json.JSONDecodeError):
            self.respond(400, {"error": "invalid request"})
            return
        if not isinstance(message, dict) or message.get("method") != "initialize":
            self.respond(503, {"error": "fixture method unavailable"})
            return
        payload = json.dumps({"jsonrpc": "2.0", "id": 1, "result": {}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Mcp-Session-Id", SESSION)
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self) -> None:
        server = cast(FeedServer, self.server)
        split = urllib.parse.urlsplit(self.path)
        if split.path == "/health":
            self.respond(200, {
                "status": "ok",
                "version": "fixture",
                "build": {"binary_commit": "fixture"},
                "paths": {"effective_base_path": server.base, "effective_masc_root": server.base + "/.masc"},
                "startup": {"state_ready": True},
            })
            return
        if split.path == "/api/v1/lanes":
            with server.condition:
                server.lane_reads += 1
                failed = server.fail_next_lane
                server.fail_next_lane = False
            if failed:
                self.respond(503, {"error": "retry the Lane read"})
            else:
                self.respond(200, lane_payload())
            return
        if split.path == "/api/v1/lane-addons":
            with server.condition:
                server.addon_reads += 1
            self.respond(200, addon_payload())
            return
        if split.path != "/mcp":
            self.respond(200, {})
            return
        query = urllib.parse.parse_qs(split.query)
        if query.get("expected_base_path") != [server.base] or query.get("expected_masc_root") != [server.base + "/.masc"]:
            self.respond(409, {"error": "workspace precondition failed"})
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("x-masc-workspace-read", "matched-v1")
        self.send_header("x-masc-sse-instance-id", INSTANCE)
        self.send_header("x-masc-sse-replay", "fresh")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(b": fixture open\n\n")
        self.wfile.flush()
        index = 0
        while index < 4:
            with server.condition:
                while index >= len(server.events):
                    server.condition.wait(1.0)
                event = server.events[index]
            data = ("data: " + json.dumps(event) + "\n\n").encode()
            try:
                self.wfile.write(data)
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                return
            index += 1
        self.close_connection = True


class LaneInventoryPushTest(unittest.TestCase):
    binary = ""

    def test_pushes_reread_only_the_visible_lane_and_open_instance(self) -> None:
        with tempfile.TemporaryDirectory(prefix="masc-lane-push-") as base:
            config = pathlib.Path(base, ".masc", "config")
            config.mkdir(parents=True)
            (config / "runtime.toml").write_text(
                '[tui]\nopening = "overview"\nhints_visible = false\nhelp_hint_shown = true\nreduce_motion = true\n',
                encoding="utf-8",
            )
            server = FeedServer(base)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            master, slave = pty.openpty()
            process: subprocess.Popen[bytes] | None = None
            try:
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 150, 0, 0))
                env = {"HOME": base, "TMPDIR": base, "PATH": os.defpath, "TERM": "xterm-256color", "LANG": "C.UTF-8"}
                process = subprocess.Popen(
                    [self.binary, "--base-path", base, "--port", str(server.server_port), "--refresh", "1000"],
                    stdin=slave, stdout=slave, stderr=slave, env=env, close_fds=True,
                )
                os.close(slave)
                slave = -1

                def drain_until(predicate, label: str) -> None:
                    assert process is not None
                    deadline = time.monotonic() + WAIT
                    while time.monotonic() < deadline:
                        if predicate():
                            return
                        if process.poll() is not None:
                            break
                        if select.select([master], [], [], 0.05)[0]:
                            try:
                                os.read(master, 65536)
                            except OSError:
                                break
                    self.fail(f"{label}; exit={process.poll()}, counts={server.counts()}")

                drain_until(lambda: server.counts()[0] >= 1 and server.counts()[1] >= 1, "initial Lane reads")
                os.write(master, b"9")
                os.write(master, b":addons\n")
                os.write(master, b"\r")
                server.emit("lanes")
                drain_until(lambda: server.counts()[0] >= 2, "lanes push did not reread the inventory")
                server.emit("lane_addons", "quiz-1")
                drain_until(lambda: server.counts()[1] >= 2, "Add-on push did not reread the open instance")
                other_before = server.counts()[1]
                server.emit("lane_addons", "someone-else")
                quiet = time.monotonic() + 1.0
                drain_until(lambda: time.monotonic() >= quiet, "TUI exited")
                self.assertEqual(other_before, server.counts()[1], "another instance was reread")
                with server.condition:
                    server.fail_next_lane = True
                server.emit("lanes")
                drain_until(lambda: server.counts()[0] >= 4, "failed Lane read was not retried")
            finally:
                if process is not None:
                    if process.poll() is None:
                        process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
                if slave >= 0:
                    os.close(slave)
                os.close(master)
                server.shutdown()
                server.server_close()
                thread.join(timeout=5)


if __name__ == "__main__":
    LaneInventoryPushTest.binary = os.path.abspath(sys.argv.pop(1))
    unittest.main()
