#!/usr/bin/env python3
"""Simple reverse proxy with CORS for MASC SSE"""
from http.server import HTTPServer, SimpleHTTPRequestHandler
import urllib.request
import sys

class ProxyHandler(SimpleHTTPRequestHandler):
    def send_cors_headers(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', '*')
    
    def do_OPTIONS(self):
        self.send_response(200)
        self.send_cors_headers()
        self.end_headers()
    
    def do_GET(self):
        # Proxy SSE requests to MASC server
        if self.path.startswith('/sse') or self.path.startswith('/api'):
            try:
                url = f"http://127.0.0.1:8935{self.path}"
                req = urllib.request.Request(url)
                with urllib.request.urlopen(req, timeout=30) as resp:
                    self.send_response(200)
                    self.send_header('Content-Type', resp.headers.get('Content-Type', 'text/event-stream'))
                    self.send_cors_headers()
                    self.end_headers()
                    # Stream response
                    while True:
                        chunk = resp.read(1024)
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                        self.wfile.flush()
            except Exception as e:
                self.send_error(502, f"Proxy error: {e}")
        else:
            # Serve static files
            super().do_GET()
    
    def end_headers(self):
        self.send_cors_headers()
        super().end_headers()

if __name__ == '__main__':
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    print(f"Proxy server on http://localhost:{port}")
    print(f"Proxying /sse and /api to http://127.0.0.1:8935")
    HTTPServer(('', port), ProxyHandler).serve_forever()
