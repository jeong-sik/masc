#!/usr/bin/env python3
from http.server import HTTPServer, SimpleHTTPRequestHandler
import os
import sys
import urllib.error
import urllib.request


class Handler(SimpleHTTPRequestHandler):
    BACKEND = "http://127.0.0.1:8935"

    def _cors_origin(self):
        origin = self.headers.get("Origin")
        return origin if origin else "*"

    def end_headers(self):
        self.send_header("Access-Control-Allow-Origin", self._cors_origin())
        self.send_header("Vary", "Origin")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Accept")
        super().end_headers()

    def _is_proxy_path(self):
        return (
            self.path.startswith("/api")
            or self.path.startswith("/sse")
            or self.path.startswith("/mcp")
        )

    def _read_request_body(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length <= 0:
            return None
        return self.rfile.read(length)

    def _copy_headers(self, response):
        skip = {
            "transfer-encoding",
            "connection",
            "server",
            "date",
            "content-encoding",
        }
        for key, value in response.headers.items():
            lowered = key.lower()
            if lowered in skip:
                continue
            if lowered.startswith("access-control-"):
                continue
            self.send_header(key, value)

    def _forward_headers(self):
        blocked = {"host", "connection", "accept-encoding", "origin", "content-length"}
        return {
            key: value
            for key, value in self.headers.items()
            if key.lower() not in blocked
        }

    def _proxy(self):
        req = urllib.request.Request(
            f"{self.BACKEND}{self.path}",
            data=self._read_request_body(),
            method=self.command,
            headers=self._forward_headers(),
        )
        try:
            with urllib.request.urlopen(req, timeout=45) as resp:
                self.send_response(resp.status)
                self._copy_headers(resp)
                self.end_headers()
                while True:
                    data = resp.read(65536)
                    if not data:
                        break
                    self.wfile.write(data)
                    self.wfile.flush()
        except urllib.error.HTTPError as err:
            self.send_response(err.code)
            self._copy_headers(err)
            self.end_headers()
            self.wfile.write(err.read() or b"")
        except Exception as err:
            self.send_error(502, f"Proxy error: {err}")

    def do_OPTIONS(self):
        self.send_response(200)
        self.end_headers()

    def do_GET(self):
        if self._is_proxy_path():
            self._proxy()
        else:
            super().do_GET()

    def do_POST(self):
        if self._is_proxy_path():
            self._proxy()
        else:
            self.send_error(405)


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    os.chdir(os.path.dirname(os.path.realpath(__file__)))
    HTTPServer(("", port), Handler).serve_forever()
