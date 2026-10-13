import contextlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import sys
import threading
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "figma-studio/host"))
from mcp_client import McpClient, TransportError, encode

@contextlib.contextmanager
def running(server):
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    try:
        yield server
    finally:
        server.shutdown()
        server.server_close()
        worker.join()

class McpHandler(BaseHTTPRequestHandler):
    messages = []

    def log_message(self, format, *args):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        self.messages.append((request, dict(self.headers)))
        if 'id' not in request:
            self.send_response(202)
            self.end_headers()
            return
        result = {'protocolVersion': '2025-06-18'} if request['method'] == 'initialize' else {'content': [{'type': 'text', 'text': json.dumps({'worker_boot_id': 'boot'})}]}
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Mcp-Session-Id', 'test-session')
        self.end_headers()
        self.wfile.write(b'data: {"jsonrpc":"2.0","method":"notifications/tools/list_changed"}\n\n')
        self.wfile.write(('data: ' + json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'result': result}) + '\n\n').encode())

class TransportTests(unittest.TestCase):

    def test_silent_mcp_header_json_and_sse_reads_timeout_then_release_client(self):
        for stalled_at in ('headers', 'json', 'sse'):
            with self.subTest(stalled_at=stalled_at):
                release = threading.Event()
                received = []

                class Handler(BaseHTTPRequestHandler):

                    def log_message(self, *_):
                        pass

                    def do_POST(self):
                        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                        args = request['params']['arguments']
                        received.append(args)
                        if args['kind'] == 'result':
                            if stalled_at != 'headers':
                                self.send_response(200)
                                self.send_header('Content-Type', 'text/event-stream' if stalled_at == 'sse' else 'application/json')
                                self.end_headers()
                                self.wfile.flush()
                            release.wait()
                            return
                        value = {'worker_boot_id': 'boot', 'max_request_bytes': 10000} if args['kind'] == 'status' else {'command': None} if args['kind'] == 'poll' else {'status': 'reported'}
                        body = encode({'jsonrpc': '2.0', 'id': request['id'], 'result': {'structuredContent': value}})
                        self.send_response(200)
                        self.send_header('Content-Type', 'application/json')
                        self.send_header('Content-Length', str(len(body)))
                        self.end_headers()
                        self.wfile.write(body)
                try:
                    with running(ThreadingHTTPServer(('127.0.0.1', 0), Handler)) as upstream:
                        client = McpClient(f'http://127.0.0.1:{upstream.server_port}/mcp', 'fixture-token', request_timeout_seconds=0.1)
                        start = time.monotonic()
                        with self.assertRaises(TransportError):
                            client.call('masc_figma_relay', {'kind': 'result', 'payload': {}})
                        self.assertLess(time.monotonic() - start, 2)
                        self.assertIsNone(client.call('masc_figma_relay', {'kind': 'poll'})['command'])
                        self.assertEqual(sum(item['kind'] == 'result' for item in received), 1)
                finally:
                    release.set()

    def test_expired_session_rehandshakes_before_next_call_without_replaying_failed_rpc(self):
        requests = []
        expired = False
        generation = 0

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_POST(self):
                nonlocal expired, generation
                body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                requests.append(body)
                if body['method'] == 'initialize':
                    generation += 1
                    value = {'protocolVersion': '2025-06-18'}
                elif body['method'] == 'notifications/initialized':
                    self.send_response(202)
                    self.end_headers()
                    return
                elif expired:
                    expired = False
                    self.send_response(404)
                    self.end_headers()
                    return
                else:
                    self.assert_session = self.headers.get('Mcp-Session-Id')
                    if self.assert_session != f'session-{generation}':
                        self.send_response(400)
                        self.end_headers()
                        return
                    value = {'structuredContent': {'ready': True}}
                wire = encode({'jsonrpc': '2.0', 'id': body['id'], 'result': value})
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Mcp-Session-Id', f'session-{generation}')
                self.send_header('Content-Length', str(len(wire)))
                self.end_headers()
                self.wfile.write(wire)

        with running(ThreadingHTTPServer(('127.0.0.1', 0), Handler)) as server:
            client = McpClient(f'http://127.0.0.1:{server.server_port}/mcp', 'token')
            client.initialize()
            expired = True
            with self.assertRaises(TransportError):
                client.call('masc_figma_relay', {'kind': 'result', 'operation_id': 'once'})
            self.assertEqual(client.call('masc_figma_relay', {'kind': 'status'}), {'ready': True})
        self.assertEqual(generation, 2)
        self.assertEqual(sum(r.get('params', {}).get('arguments', {}).get('operation_id') == 'once' for r in requests), 1)

    def test_real_mcp_http_sse_session_and_model_text_result(self):
        McpHandler.messages = []
        with running(ThreadingHTTPServer(('127.0.0.1', 0), McpHandler)) as server:
            client = McpClient(f'http://127.0.0.1:{server.server_port}/mcp', 'fixture-token')
            client.initialize()
            self.assertEqual(client.call('masc_figma_relay', {'kind': 'status'}), {'worker_boot_id': 'boot'})
        self.assertEqual(len(McpHandler.messages), 3)
        self.assertEqual(McpHandler.messages[-1][1]['Mcp-Session-Id'], 'test-session')
        self.assertEqual(McpHandler.messages[-1][1]['Mcp-Protocol-Version'], '2025-06-18')
        self.assertEqual(McpHandler.messages[-1][1]['Authorization'], 'Bearer fixture-token')
