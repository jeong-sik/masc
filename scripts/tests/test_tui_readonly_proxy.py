# pyright: strict
"""The read-only relay answers 403 to writes and never forwards them.

    python3 -m unittest scripts.tests.test_tui_readonly_proxy

No MASC server is involved. The test starts a stand-in upstream on a free
loopback port that records every request it receives, starts
scripts/harness/tui/readonly_proxy.py in front of it, and sends writes the
relay must refuse: REST verbs, POST outside /mcp, a tools/call of a mutating
tool, a batch with one, a JSON-RPC response, a chunked body and a websocket
upgrade. None of them may reach the upstream. A GET and a tools/call of a read
tool must reach it.
"""
from collections.abc import Mapping
from dataclasses import dataclass
import http.client
import http.server
import json
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import threading
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
    Case('unlisted method', 'POST', '/mcp', encoded(rpc('resources/subscribe', {'uri': 'masc://x'})), JSON),
    Case('chunked read', 'POST', '/mcp', encoded(tool_call(READ_TOOL)), JSON, chunked=True),
    Case('websocket upgrade', 'GET', '/mcp', b'',
         {'Upgrade': 'websocket', 'Connection': 'Upgrade', 'Sec-WebSocket-Version': '13',
          'Sec-WebSocket-Key': 'dGhlIHNhbXBsZSBub25jZQ=='}),
)
ALLOWED: tuple[Case, ...] = (
    Case('GET', 'GET', '/health', b'', {}),
    Case('read tool', 'POST', '/mcp', encoded(tool_call(READ_TOOL)), JSON),
)


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

    @classmethod
    def setUpClass(cls) -> None:
        scratch = tempfile.TemporaryDirectory()
        cls.addClassCleanup(scratch.cleanup)
        cls.upstream = Upstream()
        thread = threading.Thread(target=cls.upstream.serve_forever, daemon=True)
        thread.start()
        cls.addClassCleanup(cls.upstream.server_close)
        cls.addClassCleanup(cls.upstream.shutdown)
        process = subprocess.Popen(
            [sys.executable, str(RELAY), '--upstream-port', str(cls.upstream.server_address[1]),
             '--log', str(Path(scratch.name) / 'relay.jsonl')],
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

    def received(self) -> list[Received]:
        with self.upstream.lock:
            return list(self.upstream.received)

    def test_writes_are_refused_and_never_reach_the_upstream(self) -> None:
        for case in REFUSED:
            with self.subTest(case.name):
                before = len(self.received())
                self.assertEqual(self.send(case), FORBIDDEN)
                self.assertEqual(self.received()[before:], [])

    def test_reads_reach_the_upstream(self) -> None:
        for case in ALLOWED:
            with self.subTest(case.name):
                before = len(self.received())
                self.assertEqual(self.send(case), OK)
                self.assertEqual(self.received()[before:], [Received(case.verb, case.path, case.body)])


if __name__ == '__main__':
    unittest.main()
