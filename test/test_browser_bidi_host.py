#!/usr/bin/env python3
"""Owned Firefox integration for the CI-built native BiDi host.

Usage: python3 test_browser_bidi_host.py HOST FIREFOX
No WebExtension, profile reuse, or production MASC. The HTTP peer is the
native poll/result contract; actual commands execute in Firefox.
"""
import base64
import http.server
import json
import os
from pathlib import Path
import queue
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid


def run(host, firefox):
    with tempfile.TemporaryDirectory(prefix="masc-bidi-native-") as directory:
        root = Path(directory)
        token = "owned-bidi-test-lane-token"
        (root / "token").write_text(token)
        commands, results = queue.Queue(), queue.Queue()
        ready = threading.Event()
        stopped = threading.Event()
        metadata = []

        class Peer(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_POST(self):
                if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
                    chunks = []
                    while True:
                        size = int(self.rfile.readline().split(b";", 1)[0], 16)
                        if not size:
                            self.rfile.readline()
                            break
                        chunks.append(self.rfile.read(size))
                        self.rfile.read(2)
                    body = json.loads(b"".join(chunks))
                else:
                    body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                assert self.headers["x-lane-token"] == token
                metadata.append((self.headers["x-browser-client-id"], self.headers["x-browser-version"]))
                if self.path.endswith("/poll"):
                    ready.set()
                    try:
                        reply = commands.get(timeout=1)
                    except queue.Empty:
                        reply = {"ok": True, "empty": True}
                elif self.path.endswith("/result"):
                    results.put(body)
                    reply = {"ok": True}
                elif self.path.endswith("/disconnect"):
                    stopped.set()
                    reply = {"ok": True}
                else:
                    raise AssertionError(self.path)
                data = json.dumps(reply).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Peer)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        # Two identical URL tabs are opened by the owned Firefox command line.
        fixture = root / "fixture.html"
        fixture.write_text('''<!doctype html><title>BiDi native fixture</title>
<style>body{margin:0}#pad{width:500px;height:300px;background:lightblue}</style>
<div id="pad">untouched</div><script>
const pad=document.querySelector('#pad'); let down=false;
pad.onpointerdown=e=>{down=e.isTrusted;pad.setPointerCapture(e.pointerId)};
pad.onpointerup=e=>{pad.textContent='drag:'+down+':'+e.isTrusted+':'+e.clientX};
</script>''')
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        (root / "profile").mkdir()
        ff = native = None
        log = (root / "firefox.log").open("wb")
        try:
            ff = subprocess.Popen([firefox, "--headless", "--no-remote", "--profile", str(root / "profile"),
                "--remote-debugging-port", str(port), fixture.as_uri(), fixture.as_uri()], stdout=log, stderr=log)
            deadline = time.monotonic() + 20
            while True:
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=.2):
                        break
                except OSError:
                    if time.monotonic() >= deadline:
                        raise AssertionError("owned Firefox did not start")
                    time.sleep(.05)
            native = subprocess.Popen([host, "--base-path", str(root), "--token-file", str(root / "token"),
                "--server", f"http://127.0.0.1:{server.server_port}", "--bidi-url", f"ws://127.0.0.1:{port}/session"],
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            assert ready.wait(20), "native peer did not register"

            def call(verb, args):
                ident = str(uuid.uuid4())
                commands.put({"id": ident, "verb": verb, "args": args})
                result = results.get(timeout=25)
                assert result["id"] == ident
                return result

            tabs = call("tabs.list", {})
            assert tabs["ok"], tabs
            matching = [tab for tab in tabs["data"] if tab["url"] == fixture.as_uri()]
            assert len(matching) == 2, matching
            first, second = (tab["id"] for tab in matching)
            before = call("page.read", {"tabId": second})
            shot = call("page.capture", {"tabId": first})
            assert shot["ok"] and base64.b64decode(shot["data"]["data"]).startswith(b"\x89PNG")
            args = {"tabId": first, "action": "drag", "expectedUrl": fixture.as_uri(),
                "viewport": shot["data"]["viewport"], "from": {"x": .05, "y": .05}, "to": {"x": .2, "y": .2}}
            stale = {**args, "viewport": {**args["viewport"], "documentId": "stale"}}
            rejected = call("page.interact", stale)
            assert rejected["ok"] is False and rejected["effectPhase"] == "not_started", rejected
            untouched = call("page.read", {"tabId": first})
            assert "untouched" in untouched["data"]["text"]
            moved = call("page.interact", args)
            assert moved["ok"] is True, moved
            after = call("page.read", {"tabId": first})
            assert "drag:true:true:" in after["data"]["text"], after
            other = call("page.read", {"tabId": second})
            assert other["ok"] and other["data"] == before["data"]
            unsupported = call("page.elements", {"tabId": first})
            assert not unsupported["ok"] and unsupported["effectPhase"] == "not_started"
            assert len({row[0] for row in metadata}) == 1 and all(row[1] for row in metadata)
            print(json.dumps({"passed": True, "tabs": matching, "version": metadata[0][1]}))
        finally:
            for process in (native, ff):
                if process is not None and process.poll() is None:
                    process.terminate()
                    try:
                        process.communicate(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.communicate(timeout=5)
            log.close()
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)


if __name__ == "__main__":
    run(*sys.argv[1:])
