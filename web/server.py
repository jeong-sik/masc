#!/usr/bin/env python3
from http.server import HTTPServer, SimpleHTTPRequestHandler
import urllib.request
import os

class Handler(SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Headers', '*')
        super().end_headers()

    def do_GET(self):
        if self.path.startswith('/sse'):
            # SSE proxy
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Cache-Control', 'no-cache')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            
            import socket
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.connect(('127.0.0.1', 8935))
            s.send(f"GET {self.path} HTTP/1.1\r\nHost: 127.0.0.1:8935\r\n\r\n".encode())
            
            # Skip HTTP headers
            buf = b''
            while b'\r\n\r\n' not in buf:
                buf += s.recv(1)
            
            # Stream data
            try:
                while True:
                    data = s.recv(4096)
                    if not data:
                        break
                    self.wfile.write(data)
                    self.wfile.flush()
            except:
                pass
            s.close()
        else:
            super().do_GET()

HTTPServer(('', 8080), Handler).serve_forever()
