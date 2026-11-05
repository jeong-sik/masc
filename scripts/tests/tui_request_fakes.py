"""A fake server for the TUI request relay and probe tests. It is not MASC."""
import http.server
import json
import sys
import threading
import time

LOOPBACK = '127.0.0.1'
TICK = b': tick\n\n'
TICK_INTERVAL_S = 0.02
SLOW_S = 0.2
LINGER_S = 0.05
UNASKED = b'HTTP/1.1 408 Request Timeout\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'


class Server(http.server.ThreadingHTTPServer):
    def handle_error(self, request, client_address):
        """A relay closing a connection with bytes unread resets it; only other errors print."""
        if not isinstance(sys.exc_info()[1], OSError):
            super().handle_error(request, client_address)


class Upstream:
    """A fake server on its own thread. `runtimes` answer /health in order; the last repeats.

    Like MASC (`configured_bind_matches`), it answers 400 to a request whose
    Host does not name its own port."""

    def __init__(self):
        self.base_path = ''
        self.runtimes = ['runtime-a']
        self.idle_closed = threading.Event()
        self.server = Server((LOOPBACK, 0), self._handler())
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()

    def _runtime(self):
        return self.runtimes.pop(0) if len(self.runtimes) > 1 else self.runtimes[0]

    def _handler(self):
        upstream = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'

            def log_message(self, format, *args):
                pass

            def admitted(self):
                if self.headers.get('Host') == f'{LOOPBACK}:{upstream.port}':
                    return True
                self.send_error(400, 'request_authority_untrusted')
                return False

            def answer_json(self, value):
                body = json.dumps(value).encode()
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def start_events(self, *, chunked):
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                if chunked:
                    self.send_header('Transfer-Encoding', 'chunked')
                else:
                    self.send_header('Connection', 'close')
                    self.close_connection = True
                self.end_headers()

            def chunk(self, piece):
                self.wfile.write(b'%x\r\n%s\r\n' % (len(piece), piece))
                self.wfile.flush()

            def switch(self):
                self.send_response(101)
                self.send_header('Upgrade', 'echo')
                self.send_header('Connection', 'Upgrade')
                self.end_headers()
                self.close_connection = True

            def read_body(self):
                if 'chunked' not in self.headers.get('Transfer-Encoding', '').lower():
                    return self.rfile.read(int(self.headers['Content-Length']))
                body = bytearray()
                while size := int(self.rfile.readline().split(b';')[0], 16):
                    body.extend(self.rfile.read(size))
                    self.rfile.readline()
                while self.rfile.readline() not in (b'\r\n', b''):
                    pass
                return bytes(body)

            def do_GET(self):
                path = self.path.split('?', 1)[0]
                if not self.admitted():
                    return
                if path == '/health':
                    self.answer_json({'build': {'runtime_instance_id': upstream._runtime()},
                                      'paths': {'effective_base_path': upstream.base_path}})
                elif path == '/json':
                    self.answer_json({'ok': True})
                elif path == '/chunked-events':
                    self.start_events(chunked=True)
                    for piece in (b'event: snapshot\ndata: {}\n\n', b': keep-alive\n\n',
                                  b'data: {"type":"changed","dataset":"lanes"}\n', b'\n'):
                        self.chunk(piece)
                    self.wfile.write(b'0\r\n\r\n')
                elif path == '/until-close-events':
                    self.start_events(chunked=False)
                    self.wfile.write(b'data: {"method":"notifications/progress"}\n\n')
                elif path == '/hold':
                    self.start_events(chunked=True)
                    try:
                        while True:
                            self.chunk(TICK)
                            time.sleep(TICK_INTERVAL_S)
                    except OSError:
                        self.close_connection = True
                elif path == '/cut':
                    self.start_events(chunked=True)
                    self.chunk(b'event: first\ndata: {}\n\n')
                    self.close_connection = True
                elif path == '/idle':
                    self.start_events(chunked=True)
                    try:
                        self.rfile.read(1)
                    finally:
                        upstream.idle_closed.set()
                        self.close_connection = True
                elif path == '/slow':
                    time.sleep(SLOW_S)
                    try:
                        self.answer_json({'ok': True})
                    except OSError:
                        self.close_connection = True
                elif path == '/linger':
                    self.answer_json({'ok': True})
                    time.sleep(LINGER_S)
                    self.close_connection = True
                elif path == '/unasked':
                    self.answer_json({'ok': True})
                    time.sleep(LINGER_S)
                    try:
                        self.wfile.write(UNASKED)
                    except OSError:
                        pass
                    self.close_connection = True
                elif path == '/upgrade':
                    self.switch()
                    while piece := self.rfile.read1(65536):
                        self.wfile.write(piece)
                elif path == '/rogue-switch':
                    self.switch()
                elif path == '/trailers':
                    self.send_response(200)
                    self.send_header('Content-Type', 'text/plain')
                    self.send_header('Transfer-Encoding', 'chunked')
                    self.end_headers()
                    self.chunk(b'abc')
                    self.wfile.write(b'0\r\nX-Checksum: 1\r\n\r\n')
                elif path == '/empty':
                    self.send_response(204)
                    self.end_headers()
                else:
                    self.send_error(404)

            def do_HEAD(self):
                if not self.admitted():
                    return
                self.send_response(200)
                self.send_header('Content-Length', '12')
                self.end_headers()

            def do_POST(self):
                body = self.read_body()
                if self.admitted():
                    self.answer_json({'received': len(body)})

        return Handler


def read_all(connection):
    received = bytearray()
    while chunk := connection.recv(65536):
        received.extend(chunk)
    return bytes(received)


def read_head(connection):
    """Bytes through the first blank line, read one at a time so nothing after it is taken."""
    received = bytearray()
    while not received.endswith(b'\r\n\r\n'):
        byte = connection.recv(1)
        if not byte:
            raise ConnectionError(f'closed inside a head: {bytes(received)!r}')
        received.extend(byte)
    return bytes(received)


def of(kind, entries):
    return [entry for entry in entries if isinstance(entry, kind)]
