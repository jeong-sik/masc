#!/usr/bin/env python3
"""Owned HTTP fixture for revision correction; never controls Browser or MSX.

Keep it running, navigate an existing browser by its normal owner, and bind the
actual browser document source separately. HTTP probes are not browser proof.
"""

from __future__ import annotations

import argparse
import hashlib
import html
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import tempfile
import threading
import time


def document(namespace: str, revision: str, feature_ok: bool) -> bytes:
    return ('<!doctype html><html><head><meta charset="utf-8">'
            f'<meta name="masc-revision" content="{html.escape(revision, quote=True)}">'
            f'<meta name="masc-revision-namespace" content="{html.escape(namespace, quote=True)}">'
            '<title>Lane revision fixture</title></head><body><h1>Existing browser document</h1>'
            f'<button id="fixture-action" data-ready="{str(feature_ok).lower()}"'
            f'{"" if feature_ok else " disabled"}>Check feature</button>'
            '<output id="fixture-result"></output><script>'
            'document.querySelector("#fixture-action").addEventListener("click",()=>{'
            'document.querySelector("#fixture-result").textContent="feature-complete";});'
            '</script></body></html>').encode()


class State:
    def __init__(self, root: Path, namespace: str, expected: str, initial: str):
        root.mkdir(parents=True, exist_ok=True)
        if any(root.iterdir()):
            raise ValueError("fixture output directory must be empty")
        root.chmod(0o700)
        self.root, self.namespace, self.expected = root, namespace, expected
        self.lock = threading.Lock()
        self.path = root / "state.json"
        self.page_path = root / "current.html"
        self.update(initial, False)
        expected_html = document(namespace, expected, True)
        self.manifest = {"namespace": namespace, "revision": expected,
                         "html_sha256": hashlib.sha256(expected_html).hexdigest(),
                         "feature": "click enabled fixture-action and observe feature-complete"}
        self.manifest_bytes = (json.dumps(self.manifest, sort_keys=True) + "\n").encode()
        (root / "manifest.json").write_bytes(self.manifest_bytes)
        (root / "expected.html").write_bytes(expected_html)

    def update(self, revision: str, feature_ok: bool):
        if not isinstance(revision, str) or not revision or not isinstance(feature_ok, bool):
            raise ValueError("state requires nonempty revision and boolean feature_ok")
        state = {"revision": revision, "feature_ok": feature_ok, "changed_at": time.time()}
        with self.lock:
            with tempfile.NamedTemporaryFile(dir=self.root, mode="w", delete=False, encoding="utf-8") as output:
                temporary = Path(output.name)
                json.dump(state, output)
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, self.path)
            with tempfile.NamedTemporaryFile(dir=self.root, mode="wb", delete=False) as output:
                temporary = Path(output.name)
                output.write(document(self.namespace, revision, feature_ok))
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, self.page_path)
        return state

    def read(self):
        with self.lock:
            return json.loads(self.path.read_text())

    def page(self):
        with self.lock:
            return self.page_path.read_bytes()

    def record(self, event: dict):
        with self.lock:
            with (self.root / "http-measurements.jsonl").open("a") as output:
                (self.root / "http-measurements.jsonl").chmod(0o600)
                output.write(json.dumps({"kind": "http_destination_observation", **event}) + "\n")


def make_server(state: State, host: str, port: int):
    class Handler(BaseHTTPRequestHandler):
        def respond(self, status: int, body: bytes, content_type: str):
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
            state.record({"method": self.command, "path": self.path, "status": status,
                          "observed_at": time.time(), "body_sha256": hashlib.sha256(body).hexdigest()})

        def do_GET(self):
            current = state.read()
            if self.path == "/":
                self.respond(200, state.page(),
                             "text/html; charset=utf-8")
            elif self.path == "/manifest.json":
                self.respond(200, state.manifest_bytes, "application/json")
            elif self.path in {"/state", "/probe"}:
                result = {"namespace": state.namespace, **current,
                          "evidence_scope": "HTTP server state; no browser document or interaction observed"}
                self.respond(200, json.dumps(result).encode(), "application/json")
            else:
                self.respond(404, b'{"error":"unknown fixture path"}', "application/json")

        def do_POST(self):
            if self.path != "/state":
                self.respond(404, b'{"error":"unknown fixture path"}', "application/json")
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                # Only a tiny owned-fixture command is accepted, not arbitrary
                # request buffering. This is not a Keeper execution budget.
                if not 0 < length <= 4096:
                    raise ValueError("fixture state command must fit 4096 bytes")
                value = json.loads(self.rfile.read(length))
                if not isinstance(value, dict) or set(value) != {"revision", "feature_ok"}:
                    raise ValueError("provide exactly revision and feature_ok")
                result = state.update(value["revision"], value["feature_ok"])
                self.respond(200, json.dumps(result).encode(), "application/json")
            except (ValueError, TypeError) as error:
                self.respond(400, json.dumps({"error": str(error)}).encode(), "application/json")

        def log_message(self, *args):
            pass

    return ThreadingHTTPServer((host, port), Handler)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--namespace", default="lane-fixture")
    parser.add_argument("--expected", default="A")
    parser.add_argument("--initial", default="B")
    args = parser.parse_args()
    state = State(args.output_dir, args.namespace, args.expected, args.initial)
    server = make_server(state, args.host, args.port)
    host, port = server.server_address
    origin = f"http://{host}:{port}"
    metadata = {"url": origin + "/", "state_url": origin + "/state", "probe_url": origin + "/probe",
                "served_html_path": str(state.page_path.resolve()),
                "expected": {"namespace": args.namespace, "revision": args.expected,
                             "observed_at": time.time(), "manifest": {
                                 "uri": (state.root / "manifest.json").resolve().as_uri(),
                                 "sha256": hashlib.sha256(state.manifest_bytes).hexdigest()}},
                "browser_source": "not acquired; use the existing Browser Lane and actual document identity",
                "keeper_action": "not performed; existing owner may choose to change this owned fixture"}
    (state.root / "fixture.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(json.dumps({"url": origin + "/", "metadata": str(state.root / "fixture.json")}), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
