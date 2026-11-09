#!/usr/bin/env python3
"""Diagnostic: PTY key write to the same draft prefix emitted by native TUI.

Uses a synthetic loopback peer and no live credentials. Optional verify-submit
sends Enter only to that owned peer, which records and refuses model execution.
This is an observation, not a layout test or physical display measurement.
All keys, missing observations, process identity and captures are retained.
"""
import argparse
import errno
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import pty
import re
import resource
import secrets
import struct
import subprocess
import sys
import termios
import threading
import time
import urllib.parse

ROOT = Path(__file__).resolve().parents[2]
PROBE_BYTES = Path(__file__).read_bytes()
sys.path.insert(0, str(ROOT / "test"))
from test_tui_chat_owed_history import ChatHandler, ChatServer, HISTORY_PATH

ANSI = re.compile(rb"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b\[[0-?]*[ -/]*[@-~]|\x1b[ -/]*[@-Z\\-_]")
KEYS = {"typing": None, "pageup": b"\x1b[5~", "pagedown": b"\x1b[6~",
        "wheelup": b"\x1b[<64;100;12M", "wheeldown": b"\x1b[<65;100;12M"}


class PlainText:
    """Streaming diagnostic decoder; OSC/DCS contents never become text."""
    def __init__(self):
        self.state = "text"

    def feed(self, data):
        result = bytearray()
        for byte in data:
            if self.state == "text":
                if byte == 0x1b:
                    self.state = "escape"
                elif byte >= 0x20 or byte in (10, 13):
                    result.append(byte)
            elif self.state == "escape":
                if byte == ord("["):
                    self.state = "csi"
                elif byte == ord("]"):
                    self.state = "osc"
                elif byte in (ord("P"), ord("^"), ord("_")):
                    self.state = "string"
                elif 0x20 <= byte <= 0x2f:
                    self.state = "intermediate"
                else:
                    self.state = "text"
            elif self.state == "csi":
                if 0x40 <= byte <= 0x7e:
                    self.state = "text"
            elif self.state == "intermediate":
                if 0x30 <= byte <= 0x7e:
                    self.state = "text"
            elif self.state == "osc":
                if byte == 7:
                    self.state = "text"
                elif byte == 0x1b:
                    self.state = "osc_escape"
            elif self.state == "string":
                if byte == 0x1b:
                    self.state = "string_escape"
            elif self.state in ("osc_escape", "string_escape"):
                if byte == ord("\\") or (byte == 7 and self.state == "osc_escape"):
                    self.state = "text"
                elif byte != 0x1b:
                    self.state = "osc" if self.state == "osc_escape" else "string"
        return bytes(result)


class Handler(ChatHandler):
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        body = json.loads(raw or b"{}")
        path = urllib.parse.urlsplit(self.path).path
        with self.server.condition:
            self.server.posts.append({"at": time.monotonic(), "path": path, "body": body})
        if path == "/api/v1/keepers/chat/stream":
            # Observe the request bytes, then refuse it. No Keeper or model
            # runs in this synthetic peer, and no request can leave loopback.
            self.respond(503, {"error": "synthetic request observed; no model execution"})
        else:
            original = self.rfile
            self.rfile = io.BytesIO(raw)
            try:
                super().do_POST()
            finally:
                self.rfile = original

    def do_GET(self):
        path = urllib.parse.urlsplit(self.path).path
        if path == HISTORY_PATH or path == HISTORY_PATH + "/page":
            server = self.server
            phase = server.record(path)
            payload = server.history if path == HISTORY_PATH else {
                "schema": "masc.keeper_chat_history.page.v2", "messages": server.history,
                "has_more": False, "next_cursor": None}
            if self.respond(200, payload, workspace_receipt=True):
                server.responded(phase, path)
        else:
            super().do_GET()


def summary(values):
    if not values:
        return None
    ordered = sorted(values)
    return {"n": len(values), "p50_ms": ordered[int((len(ordered)-1)*.5)],
            "p95_ms": ordered[int((len(ordered)-1)*.95)],
            "max_ms": max(values), "mean_ms": sum(values)/len(values)}


def run(args, condition):
    out = args.output / condition
    out.mkdir(parents=True, exist_ok=False)
    (out / "probe.py").write_bytes(PROBE_BYTES)
    fixture_hashes = {}
    for source in ("test_tui_chat_owed_history.py", "test_tui_fusion_recovery.py"):
        content = (ROOT / "test" / source).read_bytes()
        (out / source).write_bytes(content)
        fixture_hashes[source] = hashlib.sha256(content).hexdigest()
    exe_hash_before = hashlib.sha256(args.exe.read_bytes()).hexdigest()
    base = out / "workspace"
    config = base / ".masc/config"
    (config / "keepers").mkdir(parents=True)
    (config / "runtime.toml").write_text('[tui]\nopening = "overview"\nhints_visible = false\nhelp_hint_shown = true\nreduce_motion = true\n')
    (config / "keepers/analyst.toml").write_text('[keeper]\ninstructions = "Synthetic latency fixture"\n')
    server = ChatServer(str(base.resolve()))
    server.posts = []
    server.RequestHandlerClass = Handler
    server.history = [{"id": f"fixture-{i}", "ts": 1780000000.0 + i,
                       "role": "user" if i % 2 == 0 else "assistant",
                       "speaker_authority": "owner", "content":
                       f"Record {i}\n\n" + "\n".join(
                           f"- synthetic row {j}: a **bold** phrase, `code`, and 한글 text for wrapping "
                           "across the chat pane without any real conversation data."
                           for j in range(args.lines))}
                      for i in range(args.messages)]
    history_raw = json.dumps(server.history, ensure_ascii=False).encode()
    (out / "history.json").write_bytes(history_raw)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 45, 150, 0, 0))
    timing = out / "frames.txt"
    env = {"HOME": str(base), "TMPDIR": str(base), "PATH": os.defpath,
           "TERM": "xterm-256color", "LANG": "C.UTF-8",
           "MASC_TUI_FRAME_TIMING": str(timing), "MASC_HOST": "127.0.0.1"}
    if args.alloc:
        env["MASC_TUI_ALLOC_PROFILE"] = str(out / "alloc.txt")
    argv = [str(args.exe), "--base-path", str(base), "--port", str(server.server_port)]
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    started = time.monotonic()
    load_before = os.getloadavg()
    proc = subprocess.Popen(argv, stdin=slave, stdout=slave, stderr=slave,
                            env=env, cwd=base, start_new_session=True)
    os.close(slave)
    lock = threading.Lock()
    ready = threading.Event()
    records = []
    sends = []
    raw = bytearray()
    chunks = []
    errors = []
    reader_stop = threading.Event()

    def read():
        marker_tail = b""
        while not reader_stop.is_set():
            try:
                data = os.read(master, 65536)
            except OSError as error:
                if error.errno != errno.EIO:
                    errors.append(str(error))
                return
            if not data:
                return
            at = time.monotonic()
            # Drain the PTY before doing any transcript decoding. Analyze the
            # timestamped chunks after the process exits, so the observer does
            # not stall the TUI's blocking terminal flush under scrolling.
            chunks.append((at, data))
            raw.extend(data)
            if b"\x1b[?7h" in marker_tail + data:
                ready.set()
            marker_tail = (marker_tail + data)[-4:]

    reader = threading.Thread(target=read, daemon=True)
    reader.start()

    def send(name, value):
        start = time.monotonic()
        n = os.write(master, value)
        sends.append({"name": name, "at": start, "returned": time.monotonic(), "bytes": value.hex(), "written": n})
        if n != len(value):
            raise RuntimeError("short write")

    def wait_for(predicate, timeout=20):
        deadline = time.monotonic()+timeout
        while not predicate():
            if proc.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError(f"observation incomplete, exit={proc.poll()}")
            time.sleep(.01)

    scroll_stop = threading.Event()
    scroll_thread = None
    profile = None
    observation = {}
    try:
        wait_for(ready.is_set)
        wait_for(server.observer_ready.is_set)
        time.sleep(.5)
        send("keepers", b"3")
        time.sleep(.4)
        send("chat", b"c")
        wait_for(lambda: server.response_count("setup", HISTORY_PATH) + server.response_count("setup", HISTORY_PATH+"/page") > 0)
        time.sleep(1.5)
        echo_off = not (termios.tcgetattr(master)[3] & termios.ECHO)
        if not echo_off:
            raise RuntimeError("PTY echo enabled: draft output would not be causal")
        # Keep the timed scroll away from the transcript boundaries. This version
        # uses 800 messages and audits actual write counts separately; the
        # original 800-message burst cohort could reach the tail.
        for _ in range({"pagedown": 200, "wheeldown": 50}.get(condition, 10)):
            send("position", KEYS["pageup"])
            time.sleep(.025)
        time.sleep(.25)
        send("clear-own-draft", b"\x15")
        time.sleep(.2)
        nonce = "M"+secrets.token_hex(5)+":"
        seed = {"prefix": nonce, "sent_at": time.monotonic(), "ack_at": None}
        with lock:
            records.append(seed)
            send("nonce", nonce.encode())
        wait_for(lambda: nonce.encode() in raw)
        if args.profile:
            profile = subprocess.Popen(["/usr/bin/sample", str(proc.pid), "3", "-file", str(out / "sample.txt")], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if KEYS[condition]:
            def scroll():
                while not scroll_stop.is_set():
                    send(condition, KEYS[condition])
                    scroll_stop.wait(args.scroll_gap)
            scroll_thread = threading.Thread(target=scroll, daemon=True)
            scroll_thread.start()
        text = args.text
        prefix = nonce
        observation["phase_start"] = time.monotonic()
        for char in text:
            prefix += char
            with lock:
                record = {"prefix": prefix, "sent_at": time.monotonic(), "ack_at": None}
                records.append(record)
                send("type", char.encode())
            time.sleep(args.type_gap)
        scroll_stop.set()
        if scroll_thread:
            scroll_thread.join(3)
        wait_for(lambda: prefix.encode() in raw, timeout=8)
        observation["phase_end"] = time.monotonic()
        observation["echo_off"] = echo_off
        observation["complete"] = True
        if args.verify_submit:
            send("verify-submit-synthetic-peer-only", b"\r")
            wait_for(lambda: any(p["path"] == "/api/v1/keepers/chat/stream" for p in server.posts))
            posted = [p for p in server.posts if p["path"] == "/api/v1/keepers/chat/stream"]
            observation["submitted_message_exact"] = len(posted) == 1 and posted[0]["body"].get("message") == prefix
            if not observation["submitted_message_exact"]:
                raise RuntimeError("submitted message does not match the typed Unicode draft")
    except Exception as error:
        errors.append(str(error))
        observation["complete"] = False
    finally:
        scroll_stop.set()
        if scroll_thread:
            scroll_thread.join(3)
        if profile:
            profile.wait(timeout=10)
        server.events.put(None)
        if proc.poll() is None:
            proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            errors.append("forced child kill")
            proc.kill()
            proc.wait()
        reader.join(2)
        reader_stop.set()
        os.close(master)
        server.shutdown()
        server.server_close()
        thread.join(2)
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    # Preserve protocol state across chunk boundaries, including OSC titles.
    decoder = PlainText()
    plain_tail = b""
    boundary_bytes = max((len(record["prefix"].encode()) for record in records), default=1) - 1
    for at, data in chunks:
        plain = plain_tail + decoder.feed(data)
        for record in records:
            if record["ack_at"] is None and record["sent_at"] <= at and record["prefix"].encode() in plain:
                record["ack_at"] = at
        plain_tail = plain[-boundary_bytes:] if boundary_bytes else b""
    observation["complete"] = observation.get("complete", False) and bool(records) and all(item["ack_at"] is not None for item in records)
    (out / "capture.ansi").write_bytes(raw)
    (out / "capture.txt").write_bytes(ANSI.sub(b"", bytes(raw)))
    samples = [(item["ack_at"]-item["sent_at"])*1000 for item in records[1:] if item["ack_at"] is not None]
    result = {"scope": "PTY input write to causally matching draft prefix output; not physical terminal paint",
              "exe": str(args.exe), "exe_sha256": hashlib.sha256(args.exe.read_bytes()).hexdigest(),
              "condition": condition, "pid": proc.pid, "argv": argv, "exit": proc.returncode,
              "messages": args.messages, "lines_per_message": args.lines,
              "history_sha256": hashlib.sha256(history_raw).hexdigest(),
              "probe_sha256": hashlib.sha256(PROBE_BYTES).hexdigest(),
              "fixture_modules_sha256": fixture_hashes,
              "exe_sha256_before": exe_hash_before,
              "load_before": load_before, "load_after": os.getloadavg(),
              "wall_seconds": time.monotonic()-started,
              "child_cpu_user_s": after.ru_utime-before.ru_utime,
              "child_cpu_system_s": after.ru_stime-before.ru_stime,
              "cpu_includes_sample_process": args.profile,
              "allocation_sampling_enabled": args.alloc,
              "latency": summary(samples), "unacknowledged": len(records)-sum(item["ack_at"] is not None for item in records),
              "records": records, "sends": sends, "observation": observation, "errors": errors,
              "chunks": [{"at": at, "bytes": len(data)} for at, data in chunks],
              "posts": server.posts,
              "requests": [{"phase": key[0], "path": key[1], "count": value} for key,value in server.requests.items()]}
    (out / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2))
    print(json.dumps({key: result[key] for key in ("condition", "latency", "unacknowledged", "errors", "observation")}), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--exe", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--conditions", nargs="+", choices=KEYS, default=list(KEYS))
    parser.add_argument("--messages", type=int, default=800)
    parser.add_argument("--lines", type=int, default=8)
    parser.add_argument("--type-gap", type=float, default=.05)
    parser.add_argument("--scroll-gap", type=float, default=.02)
    parser.add_argument("--profile", action="store_true")
    parser.add_argument("--alloc", action="store_true")
    parser.add_argument("--text", default="abcdefghijklmnopqrstuvwxyz012345")
    parser.add_argument("--verify-submit", action="store_true")
    args = parser.parse_args()
    args.exe = args.exe.resolve()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    for condition in args.conditions:
        run(args, condition)
