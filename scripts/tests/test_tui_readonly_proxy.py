# pyright: strict
"""The read-only relay answers 403 to writes and never forwards them.

    python3 -m unittest scripts.tests.test_tui_readonly_proxy

No MASC server is involved. The test starts a stand-in upstream on a free
loopback port that records every request it receives, starts
scripts/harness/tui/readonly_proxy.py in front of it, and sends writes the
relay must refuse: REST verbs, POST outside /mcp, a tools/call of a mutating
tool, a batch with one, a JSON-RPC response, a body that names `method` or the
tool name twice, a chunked body, a websocket upgrade, and requests whose body
framing a server could read differently from the relay (Content-Length twice,
not plain digits, or on a GET). None of them may reach the upstream. A
Content-Length too long for int() is refused too, with a line in the log. A
GET and a tools/call of a read tool must reach it.
"""
from collections.abc import Mapping
from dataclasses import dataclass
import http.client
import http.server
import json
from pathlib import Path
import select
import socket
import subprocess
import sys
import tempfile
import threading
from typing import cast
import unittest

RELAY = Path(__file__).resolve().parent.parent / 'harness' / 'tui' / 'readonly_proxy.py'
LOOPBACK = '127.0.0.1'
START_TIMEOUT_S = 10.0
REQUEST_TIMEOUT_S = 5.0
FORBIDDEN = 403
OK = 200
READ_TOOL = 'masc_status'
WRITE_TOOL = 'masc_add_task'


@dataclass(frozen=True, slots=True)
class Received:
    verb: str
    path: str
    body: bytes


class Upstream(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self) -> None:
        super().__init__((LOOPBACK, 0), Recording)
        self.received: list[Received] = []
        self.lock = threading.Lock()


class Recording(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, format: str, *args: object) -> None:  # noqa: A002 - base class name
        del format, args

    def answer(self) -> None:
        server = self.server
        if not isinstance(server, Upstream):
            raise TypeError('Recording serves only under Upstream')
        length = int(self.headers.get('Content-Length') or 0)
        body = self.rfile.read(length) if length else b''
        with server.lock:
            server.received.append(Received(self.command, self.path, body))
        data = b'{"jsonrpc":"2.0","id":1,"result":{}}'
        self.send_response(OK)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(data)

    do_GET = do_HEAD = do_POST = do_PUT = do_PATCH = do_DELETE = do_OPTIONS = answer


def rpc(method: str, params: Mapping[str, object] | None = None, request_id: int = 1) -> dict[str, object]:
    message: dict[str, object] = {'jsonrpc': '2.0', 'id': request_id, 'method': method}
    if params is not None:
        message['params'] = dict(params)
    return message


def tool_call(name: str) -> dict[str, object]:
    return rpc('tools/call', {'name': name, 'arguments': {}})


def encoded(value: object) -> bytes:
    return json.dumps(value).encode()


@dataclass(frozen=True, slots=True)
class Case:
    name: str
    verb: str
    path: str
    body: bytes
    headers: Mapping[str, str]
    chunked: bool = False


JSON = {'Content-Type': 'application/json'}
REFUSED: tuple[Case, ...] = (
    Case('PUT', 'PUT', '/api/v1/tasks/1', b'{"status":"done"}', JSON),
    Case('PATCH', 'PATCH', '/api/v1/tasks/1', b'{"status":"done"}', JSON),
    Case('DELETE', 'DELETE', '/api/v1/tasks/1', b'', {}),
    Case('OPTIONS', 'OPTIONS', '/mcp', b'', {}),
    Case('REST POST', 'POST', '/api/v1/tui/preferences', b'{"view":"plain"}', JSON),
    Case('mutating tool', 'POST', '/mcp', encoded(tool_call(WRITE_TOOL)), JSON),
    Case('batch with a mutating tool', 'POST', '/mcp',
         encoded([tool_call(READ_TOOL), tool_call(WRITE_TOOL)]), JSON),
    Case('JSON-RPC response', 'POST', '/mcp', encoded({'jsonrpc': '2.0', 'id': 9, 'result': {}}), JSON),
    # json.loads keeps the last of two equal names; a server may read the first.
    Case('method named twice', 'POST', '/mcp',
         b'{"jsonrpc":"2.0","id":1,"method":"tools/call",'
         b'"params":{"name":"' + WRITE_TOOL.encode() + b'","arguments":{}},"method":"ping"}', JSON),
    Case('tool named twice', 'POST', '/mcp',
         b'{"jsonrpc":"2.0","id":1,"method":"tools/call",'
         b'"params":{"name":"' + WRITE_TOOL.encode() + b'","name":"' + READ_TOOL.encode() + b'","arguments":{}}}',
         JSON),
    Case('unlisted method', 'POST', '/mcp', encoded(rpc('resources/subscribe', {'uri': 'masc://x'})), JSON),
    Case('chunked read', 'POST', '/mcp', encoded(tool_call(READ_TOOL)), JSON, chunked=True),
    Case('websocket upgrade', 'GET', '/mcp', b'',
         {'Upgrade': 'websocket', 'Connection': 'Upgrade', 'Sec-WebSocket-Version': '13',
          'Sec-WebSocket-Key': 'dGhlIHNhbXBsZSBub25jZQ=='}),
)
PING = encoded(rpc('ping'))
PAST_DIGIT_CAP = 'Content-Length past the digit cap'


def raw_request(head: str, body: bytes) -> bytes:
    return head.replace('\n', '\r\n').encode() + b'\r\n' + body


# Sent byte for byte: http.client cannot send a header twice.
RAW_REFUSED: tuple[tuple[str, bytes], ...] = (
    ('Content-Length twice', raw_request(
        f'POST /mcp HTTP/1.1\nHost: relay\nContent-Type: application/json\n'
        f'Content-Length: {len(PING)}\nContent-Length: 5\n', PING)),
    ('Content-Length with an underscore', raw_request(
        f'POST /mcp HTTP/1.1\nHost: relay\nContent-Type: application/json\n'
        f'Content-Length: {str(len(PING))[0]}_{str(len(PING))[1:]}\n', PING)),
    ('Content-Length with a sign', raw_request(
        f'POST /mcp HTTP/1.1\nHost: relay\nContent-Type: application/json\nContent-Length: +{len(PING)}\n',
        PING)),
    # int() refuses a string past 4300 digits with ValueError, which would end
    # the handler with no answer and no refused line in the log.
    (PAST_DIGIT_CAP, raw_request(
        f'POST /mcp HTTP/1.1\nHost: relay\nContent-Type: application/json\nContent-Length: {"9" * 4301}\n',
        PING)),
    ('GET with a body', raw_request('GET /health HTTP/1.1\nHost: relay\nContent-Length: 5\n', b'hello')),
    ('HEAD with a chunked body', raw_request(
        'HEAD /health HTTP/1.1\nHost: relay\nTransfer-Encoding: chunked\n', b'5\r\nhello\r\n0\r\n\r\n')),
)
ALLOWED: tuple[Case, ...] = (
    Case('GET', 'GET', '/health', b'', {}),
    Case('read tool', 'POST', '/mcp', encoded(tool_call(READ_TOOL)), JSON),
)


def refusal_reasons(log: Path) -> list[object]:
    reasons: list[object] = []
    for line in log.read_text(encoding='utf-8').splitlines():
        entry: object = json.loads(line)
        if isinstance(entry, dict):
            fields = cast(dict[str, object], entry)
            if fields.get('decision') == 'refused':
                reasons.append(fields.get('why'))
    return reasons


def listening_port(process: subprocess.Popen[bytes]) -> int:
    stdout = process.stdout
    if stdout is None:
        raise AssertionError('relay stdout is not a pipe')
    ready, _, _ = select.select([stdout], [], [], START_TIMEOUT_S)
    if not ready:
        raise AssertionError('the relay did not say where it listens')
    word, _, port = stdout.readline().decode().partition(' ')
    if word != 'listening':
        raise AssertionError(f'unexpected first line from the relay: {word!r}')
    return int(port)


class ReadonlyProxyTest(unittest.TestCase):
    upstream: Upstream
    relay_port = 0
    log_path: Path

    @classmethod
    def setUpClass(cls) -> None:
        scratch = tempfile.TemporaryDirectory()
        cls.addClassCleanup(scratch.cleanup)
        cls.upstream = Upstream()
        thread = threading.Thread(target=cls.upstream.serve_forever, daemon=True)
        thread.start()
        cls.addClassCleanup(cls.upstream.server_close)
        cls.addClassCleanup(cls.upstream.shutdown)
        cls.log_path = Path(scratch.name) / 'relay.jsonl'
        process = subprocess.Popen(
            [sys.executable, str(RELAY), '--upstream-port', str(cls.upstream.server_address[1]),
             '--log', str(cls.log_path)],
            stdout=subprocess.PIPE)
        cls.addClassCleanup(process.wait)
        cls.addClassCleanup(process.terminate)
        cls.addClassCleanup(lambda: process.stdout.close() if process.stdout else None)
        cls.relay_port = listening_port(process)

    def send(self, case: Case) -> int:
        connection = http.client.HTTPConnection(LOOPBACK, self.relay_port, timeout=REQUEST_TIMEOUT_S)
        try:
            if case.chunked:
                connection.request(case.verb, case.path, body=iter((case.body,)), headers=dict(case.headers),
                                   encode_chunked=True)
            else:
                connection.request(case.verb, case.path, body=case.body or None, headers=dict(case.headers))
            response = connection.getresponse()
            response.read()
            return response.status
        finally:
            connection.close()

    def send_raw(self, request: bytes) -> int:
        with socket.create_connection((LOOPBACK, self.relay_port), timeout=REQUEST_TIMEOUT_S) as connection:
            connection.sendall(request)
            status_line = connection.makefile('rb').readline().decode()
        return int(status_line.split()[1])

    def received(self) -> list[Received]:
        with self.upstream.lock:
            return list(self.upstream.received)

    def test_writes_are_refused_and_never_reach_the_upstream(self) -> None:
        for case in REFUSED:
            with self.subTest(case.name):
                before = len(self.received())
                self.assertEqual(self.send(case), FORBIDDEN)
                self.assertEqual(self.received()[before:], [])

    def test_ambiguous_body_framing_is_refused_and_never_reaches_the_upstream(self) -> None:
        for name, request in RAW_REFUSED:
            with self.subTest(name):
                before = len(self.received())
                self.assertEqual(self.send_raw(request), FORBIDDEN)
                self.assertEqual(self.received()[before:], [])

    def test_a_content_length_past_the_digit_cap_is_logged_as_refused(self) -> None:
        request = dict(RAW_REFUSED)[PAST_DIGIT_CAP]
        self.assertEqual(self.send_raw(request), FORBIDDEN)
        # The relay logs a refusal before it answers, so the line is there now.
        self.assertIn('bad-content-length', refusal_reasons(self.log_path))

    def test_a_get_declaring_no_body_reaches_the_upstream(self) -> None:
        # The TUI sends Content-Length: 0 on its GETs.
        before = len(self.received())
        request = raw_request('GET /health HTTP/1.1\nHost: relay\nContent-Length: 0\nConnection: close\n', b'')
        self.assertEqual(self.send_raw(request), OK)
        self.assertEqual(self.received()[before:], [Received('GET', '/health', b'')])

    def test_reads_reach_the_upstream(self) -> None:
        for case in ALLOWED:
            with self.subTest(case.name):
                before = len(self.received())
                self.assertEqual(self.send(case), OK)
                self.assertEqual(self.received()[before:], [Received(case.verb, case.path, case.body)])


if __name__ == '__main__':
    unittest.main()
