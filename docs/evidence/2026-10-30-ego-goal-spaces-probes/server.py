import http.server
import os
import socketserver
import sys

os.chdir(os.path.dirname(os.path.abspath(__file__)))
port = int(sys.argv[1]) if len(sys.argv) > 1 else 54130
with socketserver.TCPServer(("127.0.0.1", port), http.server.SimpleHTTPRequestHandler) as httpd:
    print(f"serving fixture on 127.0.0.1:{port}", flush=True)
    httpd.serve_forever()
