#!/usr/bin/env python3
"""Controlled localhost fixture reconstructed from the capture host code.

/ready serves the exact captured HTML. /stall deliberately never sends HTTP
headers until the fixture exits. This helper does not open or control a browser.
"""
import datetime
import http.server
import json
from pathlib import Path
import threading
import sys

output = Path(sys.argv[1])
output.mkdir(parents=True, exist_ok=False)
release = threading.Event()
gate = threading.Lock()
ledger = []

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with gate:
            ledger.append({'at': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'path': self.path})
            (output / 'fixture-ledger.json').write_text(json.dumps(ledger, indent=2) + '\n')
        if self.path == '/stall':
            release.wait()
            try:
                self.send_response(200)
                self.end_headers()
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        body = b'<!doctype html><title>Owned recovery fixture</title><h1>Owned recovery fixture</h1><p id="value">Original ready document</p>'
        self.send_response(200)
        self.send_header('Content-Type', 'text/html')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
server.daemon_threads = True
print(f'http://127.0.0.1:{server.server_port}', flush=True)
try:
    server.serve_forever()
except KeyboardInterrupt:
    pass
finally:
    release.set()
    server.server_close()
