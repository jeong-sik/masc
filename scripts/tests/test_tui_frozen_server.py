# pyright: strict
"""Replay a synthetic recording with the frozen server and read it back with urllib.

    python3 -m unittest scripts.tests.test_tui_frozen_server

No MASC server is involved. The test writes a recording in the format
scripts/harness/tui/relay_files.py documents, starts
scripts/harness/tui/frozen_server.py on a free loopback port, and checks a
plain answer, the 304 that keeps the x-masc header, a held event stream that
sends only comments, and a POST /mcp answer that carries the request's id.
"""
import hashlib
import json
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import unittest
import urllib.error
import urllib.request

FROZEN = Path(__file__).resolve().parent.parent / 'harness' / 'tui' / 'frozen_server.py'
DIGEST_CHARS = 24
KEEPALIVE_S = 0.1
START_TIMEOUT_S = 10.0
READ_TIMEOUT_S = 5.0
COMMENTS_READ = 3
HEALTH = b'{"status":"ok"}'
THING_PATH = '/api/v1/thing'
THING = b'{"rows":[1,2,3]}'
ETAG = '"thing-1"'
ATTEST_HEADER = 'x-masc-read-epoch'
ATTEST_VALUE = '7'
STREAM_PATH = '/api/v1/events'
RECORDED_ID = 1
JSON_TOOL = 'masc_status'
SSE_TOOL = 'masc_tasks'


def answer_line(directory: Path, kind: str, key: str, headers: dict[str, str], body: bytes) -> str:
    digest = hashlib.sha256(body).hexdigest()[:DIGEST_CHARS]
    (directory / 'bodies' / digest).write_bytes(body)
    return json.dumps({'kind': kind, 'key': key, 'status': 200, 'headers': headers, 'body': digest})


def write_recording(directory: Path) -> None:
    (directory / 'bodies').mkdir(parents=True)
    rpc: dict[str, object] = {'jsonrpc': '2.0', 'id': RECORDED_ID, 'result': {'content': []}}
    lines = [
        answer_line(directory, 'get', '/health', {'content-type': 'application/json'}, HEALTH),
        answer_line(directory, 'get', THING_PATH + '?limit=3',
                    {'content-type': 'application/json', 'etag': ETAG, ATTEST_HEADER: ATTEST_VALUE}, THING),
        answer_line(directory, 'sse', STREAM_PATH + '?kind=observer', {'content-type': 'text/event-stream'}, b''),
        answer_line(directory, 'mcp', f'tools/call|{JSON_TOOL}|', {'content-type': 'application/json'},
                    json.dumps(rpc).encode()),
        answer_line(directory, 'mcp', f'tools/call|{SSE_TOOL}|', {'content-type': 'text/event-stream'},
                    f'event: message\ndata: {json.dumps(rpc)}\n\n'.encode()),
    ]
    (directory / 'index.jsonl').write_text('\n'.join(lines) + '\n', encoding='utf-8')


def listening_port(process: subprocess.Popen[bytes]) -> int:
    stdout = process.stdout
    if stdout is None:
        raise AssertionError('frozen server stdout is not a pipe')
    ready, _, _ = select.select([stdout], [], [], START_TIMEOUT_S)
    if not ready:
        raise AssertionError('frozen server did not say where it listens')
    word, _, port = stdout.readline().decode().partition(' ')
    if word != 'listening':
        raise AssertionError(f'unexpected first line from the frozen server: {word!r}')
    return int(port)


def tool_call(name: str, request_id: str) -> bytes:
    return json.dumps({'jsonrpc': '2.0', 'id': request_id, 'method': 'tools/call',
                       'params': {'name': name, 'arguments': {}}}).encode()


class FrozenServerTest(unittest.TestCase):
    base = ''

    @classmethod
    def setUpClass(cls) -> None:
        scratch = tempfile.TemporaryDirectory()
        cls.addClassCleanup(scratch.cleanup)
        root = Path(scratch.name)
        write_recording(root / 'recording')
        process = subprocess.Popen(
            [sys.executable, str(FROZEN), '--port', '0', '--recording', str(root / 'recording'),
             '--log', str(root / 'frozen.jsonl'), '--keepalive', str(KEEPALIVE_S)],
            stdout=subprocess.PIPE)
        cls.addClassCleanup(process.wait)
        cls.addClassCleanup(process.terminate)
        cls.addClassCleanup(lambda: process.stdout.close() if process.stdout else None)
        cls.base = f'http://127.0.0.1:{listening_port(process)}'

    def get(self, path: str, headers: dict[str, str] | None = None) -> urllib.request.Request:
        return urllib.request.Request(self.base + path, headers=headers or {})

    def post_mcp(self, body: bytes) -> tuple[int, str, bytes]:
        request = urllib.request.Request(self.base + '/mcp', data=body, method='POST',
                                         headers={'Content-Type': 'application/json'})
        with urllib.request.urlopen(request, timeout=READ_TIMEOUT_S) as response:
            return response.status, response.headers.get('Content-Type', ''), response.read()

    def test_health_answers_the_recorded_body(self) -> None:
        with urllib.request.urlopen(self.get('/health'), timeout=READ_TIMEOUT_S) as response:
            self.assertEqual(response.status, 200)
            self.assertEqual(response.read(), HEALTH)

    def test_matching_etag_answers_304_and_keeps_the_x_masc_header(self) -> None:
        with urllib.request.urlopen(self.get(THING_PATH + '?limit=3'), timeout=READ_TIMEOUT_S) as response:
            self.assertEqual(response.status, 200)
            self.assertEqual(response.headers.get('ETag'), ETAG)
            self.assertEqual(response.read(), THING)
        with self.assertRaises(urllib.error.HTTPError) as caught:
            urllib.request.urlopen(self.get(THING_PATH + '?limit=3', {'If-None-Match': ETAG}),
                                   timeout=READ_TIMEOUT_S)
        not_modified = caught.exception
        self.addCleanup(not_modified.close)
        self.assertEqual(not_modified.code, 304)
        self.assertEqual(not_modified.headers.get(ATTEST_HEADER), ATTEST_VALUE)
        self.assertEqual(not_modified.headers.get('ETag'), ETAG)

    def test_unrecorded_path_answers_404(self) -> None:
        with self.assertRaises(urllib.error.HTTPError) as caught:
            urllib.request.urlopen(self.get('/api/v1/never'), timeout=READ_TIMEOUT_S)
        self.addCleanup(caught.exception.close)
        self.assertEqual(caught.exception.code, 404)

    def test_event_stream_is_held_open_with_comments_only(self) -> None:
        with urllib.request.urlopen(self.get(STREAM_PATH + '?kind=observer&since=9'),
                                    timeout=READ_TIMEOUT_S) as response:
            self.assertEqual(response.status, 200)
            self.assertIn('text/event-stream', response.headers.get('Content-Type', ''))
            lines: list[bytes] = []
            while len(lines) < COMMENTS_READ:
                line = response.readline()
                self.assertTrue(line, 'the frozen server closed the event stream')
                if line.strip():
                    lines.append(line)
        self.assertTrue(all(line.startswith(b':') for line in lines), lines)

    def test_mcp_json_answer_carries_the_request_id(self) -> None:
        status, _, body = self.post_mcp(tool_call(JSON_TOOL, 'req-42'))
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)['id'], 'req-42')

    def test_mcp_event_stream_answer_carries_the_request_id(self) -> None:
        status, content_type, body = self.post_mcp(tool_call(SSE_TOOL, 'req-43'))
        self.assertEqual(status, 200)
        self.assertIn('text/event-stream', content_type)
        data = [line[len('data: '):] for line in body.decode().split('\n') if line.startswith('data: ')]
        self.assertEqual([json.loads(item)['id'] for item in data], ['req-43'])


if __name__ == '__main__':
    unittest.main()
