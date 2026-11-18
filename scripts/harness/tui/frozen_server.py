#!/usr/bin/env python3
# pyright: strict
"""Replay what readonly_proxy.py recorded, with no new data.

usage: frozen_server.py --recording DIR --log PATH [--port PORT] [--keepalive SECONDS]

A TUI pointed at this server sees the screens a live server drew while it was
recorded, and then nothing changes: the only reason left to redraw is the
passing of time. That isolates time-only redraws (RFC-tui-one-screen-grammar §8).

GET   The last answer recorded for the same path and query, else the last one
      for the same path, else 404. An If-None-Match equal to the recorded ETag
      answers 304 with the recorded ETag and x-masc-* headers: the TUI refuses
      a read the server did not attest, a 304 included. A path recorded as an
      event stream answers its headers and then only an SSE comment every
      --keepalive seconds until the client leaves. It sends no event.
POST  /mcp answers the recorded answer for the same JSON-RPC method, tool name
      and resource URI, with the request's id in place of the recorded one.
      A notification (no id) answers 202. Arguments other than the tool name
      and URI are not part of the key.
Other POSTs, PUT, PATCH and DELETE answer 405. Every request is logged as one
JSON line. The server listens on 127.0.0.1 and prints `listening PORT` on
stdout once it accepts connections.
"""
import argparse
from collections.abc import Mapping, Sequence
import http.server
from http import HTTPStatus
import json
from pathlib import Path
import signal
import socketserver
import sys
import threading
from types import FrameType
import zlib

from relay_files import Answer, JsonLog, Recording, json_object, load, mcp_key, path_of

LOOPBACK = '127.0.0.1'
LISTENING = 'listening'
MCP_PATH = '/mcp'
EVENT_STREAM = 'text/event-stream'
DATA_PREFIX = 'data: '
KEEPALIVE_S = 15.0
KEEPALIVE_COMMENT = b': frozen\n\n'
LISTEN_BACKLOG = 256
GZIP_WINDOW = 16 + zlib.MAX_WBITS
NOT_RECORDED = -32601


def decode_body(raw: bytes, encoding: str) -> bytes | str:
    """The body without its content encoding, or why it cannot be decoded."""
    match encoding:
        case '' | 'identity':
            return raw
        case 'gzip':
            try:
                return zlib.decompress(raw, GZIP_WINDOW)
            except zlib.error as exc:
                return f'gzip: {exc}'
        case 'zstd':
            try:
                from compression import zstd
            except ImportError:
                return 'zstd needs Python 3.14 or later'
            try:
                return zstd.decompress(raw)
            except zstd.ZstdError as exc:
                return f'zstd: {exc}'
        case _:
            return f'unknown content-encoding {encoding}'


def with_id(payload: object, request_id: object) -> object:
    fields = json_object(payload)
    if fields is None or 'id' not in fields:
        return payload
    return {**fields, 'id': request_id}


def answer_text(answer: Answer, request_id: object) -> str:
    """The recorded JSON-RPC answer carrying `request_id`: a JSON body, or the
    data lines of an event-stream body. Raises ValueError for a body that is
    neither."""
    raw = decode_body(answer.body, answer.headers.get('content-encoding', ''))
    if isinstance(raw, str):
        raise ValueError(raw)
    text = raw.decode('utf-8')
    if EVENT_STREAM not in answer.headers.get('content-type', ''):
        return json.dumps(with_id(json.loads(text), request_id))
    lines: list[str] = []
    for line in text.split('\n'):
        if line.startswith(DATA_PREFIX):
            line = DATA_PREFIX + json.dumps(with_id(json.loads(line[len(DATA_PREFIX):]), request_id))
        lines.append(line)
    return '\n'.join(lines)


class FrozenServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = LISTEN_BACKLOG

    def __init__(self, port: int, recording: Recording, log: JsonLog, keepalive_s: float) -> None:
        super().__init__((LOOPBACK, port), Frozen)
        self.recording = recording
        self.log = log
        self.keepalive_s = keepalive_s
        self.stopping = threading.Event()

    def bound_port(self) -> int:
        return self.server_address[1]


class Frozen(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, format: str, *args: object) -> None:  # noqa: A002 - base class name
        del format, args

    def frozen_server(self) -> FrozenServer:
        server = self.server
        if not isinstance(server, FrozenServer):
            raise TypeError('Frozen serves only under FrozenServer')
        return server

    def note(self, status: int, size: int, extra: Mapping[str, object] | None = None) -> None:
        self.frozen_server().log.write({'verb': self.command, 'path': self.path, 'status': status,
                                        'bytes': size, **(extra or {})})

    def send_json(self, status: int, payload: object) -> None:
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        self.note(status, len(data))

    def send_answer(self, status: int, headers: Mapping[str, str], body: bytes) -> None:
        self.send_response(status)
        for name, value in headers.items():
            self.send_header(name, value)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        self.note(status, len(body))

    def hold_stream(self, headers: Mapping[str, str]) -> None:
        server = self.frozen_server()
        self.send_response(HTTPStatus.OK)
        for name, value in headers.items():
            if name != 'content-encoding':
                self.send_header(name, value)
        self.send_header('Cache-Control', 'no-cache')
        self.send_header('Connection', 'close')
        self.end_headers()
        self.close_connection = True
        try:
            self.wfile.flush()
            self.note(HTTPStatus.OK, 0, {'stream': 'opened'})
            while not server.stopping.wait(server.keepalive_s):
                self.wfile.write(KEEPALIVE_COMMENT)
                self.wfile.flush()
        except OSError:
            self.note(HTTPStatus.OK, 0, {'stream': 'closed'})

    def do_GET(self) -> None:
        recording = self.frozen_server().recording
        stream = recording.streams.get(path_of(self.path))
        if stream is not None:
            self.hold_stream(stream)
            return
        answer = recording.exact.get(self.path) or recording.by_path.get(path_of(self.path))
        if answer is None:
            self.send_json(HTTPStatus.NOT_FOUND, {'error': 'not recorded'})
            return
        etag = answer.headers.get('etag')
        if etag is not None and self.headers.get('If-None-Match') == etag:
            self.send_response(HTTPStatus.NOT_MODIFIED)
            for name, value in answer.headers.items():
                if name == 'etag' or name.startswith('x-masc-'):
                    self.send_header(name, value)
            self.end_headers()
            self.note(HTTPStatus.NOT_MODIFIED, 0)
            return
        self.send_answer(answer.status, answer.headers, answer.body)

    def do_POST(self) -> None:
        declared = self.headers.get_all('Content-Length') or ['0']
        if len(declared) > 1 or not (declared[0].isascii() and declared[0].isdigit()):
            # The body's end is unknown, so the connection cannot be read on.
            self.close_connection = True
            self.send_json(HTTPStatus.BAD_REQUEST, {'error': 'one plain Content-Length expected'})
            return
        body = self.rfile.read(int(declared[0]))
        if path_of(self.path) != MCP_PATH:
            self.send_json(HTTPStatus.METHOD_NOT_ALLOWED, {'error': 'the frozen server takes no writes'})
            return
        try:
            message: object = json.loads(body.decode('utf-8') or 'null')
        except (UnicodeDecodeError, ValueError, RecursionError):
            self.send_json(HTTPStatus.BAD_REQUEST, {'error': 'unparsable JSON'})
            return
        fields = json_object(message)
        key = mcp_key(body)
        if fields is None or key is None:
            self.send_json(HTTPStatus.BAD_REQUEST, {'error': 'one JSON-RPC request expected'})
            return
        if 'id' not in fields:
            self.send_response(HTTPStatus.ACCEPTED)
            self.send_header('Content-Length', '0')
            self.end_headers()
            self.note(HTTPStatus.ACCEPTED, 0, {'key': key})
            return
        request_id = fields['id']
        answer = self.frozen_server().recording.mcp.get(key)
        if answer is None:
            self.send_json(HTTPStatus.NOT_FOUND, {'jsonrpc': '2.0', 'id': request_id,
                                                 'error': {'code': NOT_RECORDED, 'message': f'not recorded: {key}'}})
            return
        try:
            text = answer_text(answer, request_id)
        except (UnicodeDecodeError, ValueError, RecursionError) as exc:
            self.send_json(HTTPStatus.INTERNAL_SERVER_ERROR, {'error': f'recorded answer for {key}: {exc}'})
            return
        headers = {name: value for name, value in answer.headers.items() if name != 'content-encoding'}
        self.send_answer(answer.status, headers, text.encode())

    def refuse_write(self) -> None:
        self.send_json(HTTPStatus.METHOD_NOT_ALLOWED, {'error': 'the frozen server takes no writes'})

    def do_PUT(self) -> None:
        self.refuse_write()

    def do_PATCH(self) -> None:
        self.refuse_write()

    def do_DELETE(self) -> None:
        self.refuse_write()


def stop_serving(signum: int, frame: FrameType | None) -> None:
    del frame
    raise SystemExit(128 + signum)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description='Replay a relay recording with no new data.')
    parser.add_argument('--recording', type=Path, required=True, help='directory readonly_proxy.py --record wrote')
    parser.add_argument('--log', type=Path, required=True, help='request log, one JSON line per request')
    parser.add_argument('--port', type=int, default=0, help='loopback port; 0, the default, takes a free one')
    parser.add_argument('--keepalive', type=float, default=KEEPALIVE_S,
                        help=f'seconds between SSE comments on a held event stream (default {KEEPALIVE_S:g})')
    args = parser.parse_args(argv)
    recording_dir: Path = args.recording
    log_path: Path = args.log
    port: int = args.port
    keepalive_s: float = args.keepalive
    recording = load(recording_dir)
    if isinstance(recording, str):
        print(f'frozen_server: {recording}', file=sys.stderr)
        return 2
    log = JsonLog(log_path)
    server = FrozenServer(port, recording, log, keepalive_s)
    signal.signal(signal.SIGTERM, stop_serving)
    try:
        log.write({'decision': 'listening', 'port': server.bound_port(), 'get': len(recording.exact),
                   'sse': len(recording.streams), 'mcp': len(recording.mcp)})
        print(f'{LISTENING} {server.bound_port()}', flush=True)
        server.serve_forever()
    finally:
        server.stopping.set()
        server.server_close()
        log.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
