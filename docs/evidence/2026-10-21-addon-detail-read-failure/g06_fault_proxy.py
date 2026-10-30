"""Manual transport fault: forward real HTTP bytes; close only selected reads.

No HTTP response is fabricated. Never log headers, credentials or request bodies.
Connection: close gives each non-streaming read a separately observable socket.
"""
import json
from pathlib import Path
import select
import socket
import socketserver
import threading
import time

config = json.loads(Path('/tmp/masc-addon-goal-resume-20261021/g06-runtime-session.json').read_text())
capture = Path(config['capture_directory'])
log_lock = threading.Lock()

def record(**event):
    with log_lock:
        with (capture / 'transport-events.jsonl').open('a') as channel:
            channel.write(json.dumps({'at': time.time(), **event}) + '\n')

class Forwarder(socketserver.BaseRequestHandler):
    def handle(self):
        client = self.request
        prefix = b''
        while b'\r\n\r\n' not in prefix:
            data = client.recv(65536)
            if not data:
                return
            prefix += data
        header, body = prefix.split(b'\r\n\r\n', 1)
        lines = header.split(b'\r\n')
        method, path, _ = lines[0].decode('ascii').split(' ', 2)
        if method == 'GET' and path.partition('?')[0] == '/api/v1/lane-addons/slice' and (capture / 'fail-slice').exists():
            record(method=method, path=path, decision='closed before forwarding; no response')
            return
        lines = [line for line in lines if not line.lower().startswith((b'connection:', b'host:'))]
        lines.append(f"Host: 127.0.0.1:{config['backend_port']}".encode('ascii'))
        lines.append(b'Connection: close')
        record(method=method, path=path, decision='forwarded to actual matching backend')
        with socket.create_connection(('127.0.0.1', config['backend_port'])) as backend:
            backend.sendall(b'\r\n'.join(lines) + b'\r\n\r\n' + body)
            sockets = [client, backend]
            while True:
                readable, _, _ = select.select(sockets, [], [])
                for source in readable:
                    data = source.recv(65536)
                    if not data:
                        return
                    target = backend if source is client else client
                    target.sendall(data)

class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True

with Server(('127.0.0.1', config['port']), Forwarder) as server:
    print(json.dumps({'proxy_port': config['port'], 'backend_port': config['backend_port'], 'capture_directory': str(capture)}), flush=True)
    server.serve_forever()
