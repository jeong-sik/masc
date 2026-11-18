#!/usr/bin/env python3
# pyright: strict
"""Read-only HTTP relay between a TUI under measurement and a MASC server.

usage: readonly_proxy.py --upstream-port PORT --log PATH [--listen-port PORT] [--record DIR]

GET and HEAD pass to the server; an event stream is relayed as its bytes
arrive. POST /mcp passes only when every JSON-RPC message in it is a request
for a method in READ_METHODS or a tools/call of a tool in READ_TOOLS. The
relay answers 403 to every other request and never forwards it: other POSTs,
PUT, PATCH, DELETE, OPTIONS, TRACE, CONNECT, websocket upgrades, JSON-RPC
responses and request bodies without a Content-Length. A method the HTTP
library does not know is answered 501, also without reaching the server.

The relay listens on 127.0.0.1, prints `listening PORT` on stdout once it
accepts connections, and writes one JSON line per decision to --log:

  listening       the port it listens on and the upstream port
  refused         verb, target and why
  relayed         verb, target, what passed and the server's status
  progress        for an event stream, about once a second: bytes so far and,
                  per event name, events and bytes so far
  done            verb, target, status, bytes, how it ended, when the request
                  arrived; an event stream adds `stream` and its per-event counts
  upstream-error  the server could not be reached

`done` lines are the per-path byte log. Events are named as
scripts/harness/perf/tui_request_events.py names them. Targets keep their
query, so the log holds workspace names: keep it outside the repository.

With --record DIR the relay keeps each 200 or 404 answer to a GET or an allowed
POST /mcp, and the headers of each event stream, for frozen_server.py
(relay_files.py describes the format).
"""
import argparse
from collections.abc import Sequence
from dataclasses import dataclass
import enum
import http.client
import http.server
from http import HTTPStatus
import json
from pathlib import Path
import signal
import socketserver
import sys
import time
from types import FrameType
from typing import cast

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'perf'))
from relay_files import JsonLog, Kind, Recorder, json_object, mcp_key, path_of  # noqa: E402
from tui_request_events import EventParser  # noqa: E402

LOOPBACK = '127.0.0.1'
LISTENING = 'listening'
MCP_PATH = '/mcp'
TOOLS_CALL = 'tools/call'
EVENT_STREAM = 'text/event-stream'
READ_BYTES = 65536
PROGRESS_S = 1.0
LISTEN_BACKLOG = 256
RECORDED_STATUSES = frozenset({HTTPStatus.OK, HTTPStatus.NOT_FOUND})
BODYLESS_STATUSES = frozenset({HTTPStatus.NO_CONTENT, HTTPStatus.NOT_MODIFIED})
HOP_BY_HOP = frozenset({
    'connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization',
    'te', 'trailers', 'transfer-encoding', 'upgrade',
})
READ_METHODS = frozenset({
    'initialize', 'notifications/initialized', 'ping', 'tools/list',
    'resources/list', 'resources/read', 'resources/templates/list', 'prompts/list',
})
# Tools lib/tool/tool_catalog.ml registers as read_state_tool (readonly). A
# tool joins only after the catalog says it reads. masc_lane_observe,
# masc_lane_evidence and masc_lane_updates read like reads but the catalog
# registers them as mutating_tool, so they stay out.
READ_TOOLS = frozenset({
    'masc_status', 'masc_tasks', 'masc_messages', 'masc_tool_help',
    'masc_keeper_delegate_status', 'masc_keeper_status', 'masc_keeper_list',
    'masc_pause_status', 'masc_goal_list', 'masc_board_list', 'masc_board_post_get',
    'masc_board_search', 'masc_task_history', 'masc_agent_card', 'masc_agent_timeline',
    'masc_keeper_waiting_inventory', 'masc_schedule_list', 'masc_schedule_get',
    'masc_schedule_notes_list', 'masc_lane_inspect', 'masc_lane_declaration_read',
    'masc_lane_action_status', 'masc_board_curation_read',
})


@dataclass(frozen=True, slots=True)
class Allowed:
    detail: str


@dataclass(frozen=True, slots=True)
class Refused:
    why: str


type Decision = Allowed | Refused


class Ending(enum.Enum):
    COMPLETE = 'complete'
    CLIENT_LEFT = 'client_left'
    UPSTREAM_FAILED = 'upstream_failed'


def message_decision(message: object) -> Decision:
    fields = json_object(message)
    if fields is None:
        return Refused('non-object-message')
    method = fields.get('method')
    if method is None:
        # A client's answer to a server request can settle a question the
        # server asked, so it is not a read.
        return Refused('json-rpc-response')
    if not isinstance(method, str):
        return Refused('non-string-method')
    if method in READ_METHODS:
        return Allowed(method)
    if method != TOOLS_CALL:
        return Refused(method)
    name = (json_object(fields.get('params')) or {}).get('name')
    if isinstance(name, str) and name in READ_TOOLS:
        return Allowed(f'{TOOLS_CALL}:{name}')
    return Refused(f'{TOOLS_CALL}:{name}')


def mcp_decision(body: bytes) -> Decision:
    """Allowed only when every message of a JSON-RPC body (one or a batch) reads."""
    try:
        decoded: object = json.loads(body.decode('utf-8') or 'null')
    except (UnicodeDecodeError, ValueError, RecursionError):
        return Refused('unparsable-json')
    messages: Sequence[object] = cast(list[object], decoded) if isinstance(decoded, list) else (decoded,)
    if not messages:
        return Refused('empty-batch')
    details: list[str] = []
    for message in messages:
        match message_decision(message):
            case Allowed(detail):
                details.append(detail)
            case Refused() as refused:
                return refused
    return Allowed(','.join(details))


class StreamCounter:
    """Events and bytes per event name of one event stream, as its bytes arrive."""

    def __init__(self) -> None:
        self._counts: dict[str, tuple[int, int]] = {}
        self._parser = EventParser(self._on_event)

    def _on_event(self, name: str, size: int) -> None:
        events, total = self._counts.get(name, (0, 0))
        self._counts[name] = (events + 1, total + size)

    def feed(self, chunk: bytes) -> None:
        self._parser.feed(chunk)

    def report(self) -> dict[str, dict[str, int]]:
        ordered = sorted(self._counts.items(), key=lambda item: -item[1][1])
        return {name: {'events': events, 'bytes': total} for name, (events, total) in ordered}


class RelayServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = LISTEN_BACKLOG

    def __init__(self, port: int, upstream_port: int, log: JsonLog, recorder: Recorder | None) -> None:
        super().__init__((LOOPBACK, port), Relay)
        self.upstream_port = upstream_port
        self.log = log
        self.recorder = recorder

    def bound_port(self) -> int:
        return self.server_address[1]


class Relay(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, format: str, *args: object) -> None:  # noqa: A002 - base class name
        del format, args

    def relay_server(self) -> RelayServer:
        server = self.server
        if not isinstance(server, RelayServer):
            raise TypeError('Relay serves only under RelayServer')
        return server

    def refuse(self, why: str) -> None:
        self.relay_server().log.write({'decision': 'refused', 'verb': self.command, 'path': self.path, 'why': why})
        body = json.dumps({'error': 'the read-only relay refused this request', 'why': why}).encode()
        self.send_response(HTTPStatus.FORBIDDEN)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def read_body(self) -> bytes | Refused:
        if self.headers.get('Transfer-Encoding') is not None:
            return Refused('body-without-content-length')
        declared = self.headers.get('Content-Length')
        if declared is None:
            return b''
        try:
            length = int(declared)
        except ValueError:
            return Refused('bad-content-length')
        if length < 0:
            return Refused('bad-content-length')
        return self.rfile.read(length)

    def refuse_write(self) -> None:
        body = self.read_body()
        self.refuse(body.why if isinstance(body, Refused) else 'rest-write')

    def forward(self, body: bytes, detail: str) -> None:
        server = self.relay_server()
        arrived = round(time.time(), 3)
        target = self.path
        connection = http.client.HTTPConnection(LOOPBACK, server.upstream_port, timeout=None)
        headers = {name: value for name, value in self.headers.items()
                   if name.lower() not in HOP_BY_HOP and name.lower() != 'host'}
        # The server answers 400 when Host does not name its own bind port.
        headers['Host'] = f'{LOOPBACK}:{server.upstream_port}'
        try:
            connection.request(self.command, target, body=body or None, headers=headers)
            response = connection.getresponse()
        except (OSError, http.client.HTTPException) as exc:
            connection.close()
            server.log.write({'decision': 'upstream-error', 'verb': self.command, 'path': target, 'why': str(exc)})
            self.send_error(HTTPStatus.BAD_GATEWAY)
            return
        status = response.status
        stream = EVENT_STREAM in (response.getheader('Content-Type') or '')
        bodyless = self.command == 'HEAD' or status in BODYLESS_STATUSES or status < HTTPStatus.OK
        server.log.write({'decision': 'relayed', 'verb': self.command, 'path': target,
                          'detail': detail, 'status': status})
        self.send_response(status)
        for name, value in response.getheaders():
            if name.lower() not in HOP_BY_HOP and name.lower() != 'content-length':
                self.send_header(name, value)
        if not bodyless:
            self.send_header('Transfer-Encoding', 'chunked')
        self.send_header('Connection', 'close')
        self.end_headers()
        self.close_connection = True
        if server.recorder is not None and stream and self.command == 'GET':
            server.recorder.append(Kind.STREAM, target, status, response.getheaders(), b'')
        counter = StreamCounter() if stream else None
        kept = bytearray()
        sent = 0
        ending = Ending.COMPLETE
        next_progress = time.monotonic() + PROGRESS_S
        try:
            while not bodyless:
                try:
                    chunk = response.read1(READ_BYTES)
                except (OSError, http.client.HTTPException):
                    ending = Ending.UPSTREAM_FAILED
                    break
                try:
                    self.wfile.write(b'%x\r\n%s\r\n' % (len(chunk), chunk) if chunk else b'0\r\n\r\n')
                    self.wfile.flush()
                except OSError:
                    ending = Ending.CLIENT_LEFT
                    break
                if not chunk:
                    break
                sent += len(chunk)
                if counter is None:
                    kept.extend(chunk)
                    continue
                counter.feed(chunk)
                if time.monotonic() >= next_progress:
                    next_progress = time.monotonic() + PROGRESS_S
                    server.log.write({'decision': 'progress', 'verb': self.command, 'path': target,
                                      'started': arrived, 'bytes': sent, 'events': counter.report()})
        finally:
            connection.close()
        done: dict[str, object] = {'decision': 'done', 'verb': self.command, 'path': target, 'detail': detail,
                                   'status': status, 'bytes': sent, 'ending': ending.value, 'started': arrived}
        if counter is not None:
            done |= {'stream': True, 'events': counter.report()}
        server.log.write(done)
        if (server.recorder is None or counter is not None or ending is not Ending.COMPLETE
                or status not in RECORDED_STATUSES):
            return
        if self.command == 'GET':
            server.recorder.append(Kind.GET, target, status, response.getheaders(), bytes(kept))
        elif self.command == 'POST' and (key := mcp_key(body)) is not None:
            server.recorder.append(Kind.MCP, key, status, response.getheaders(), bytes(kept))

    def do_GET(self) -> None:
        if (self.headers.get('Upgrade') or '').lower() == 'websocket':
            self.refuse('websocket-upgrade')
            return
        self.forward(b'', 'get')

    def do_HEAD(self) -> None:
        self.forward(b'', 'head')

    def do_POST(self) -> None:
        body = self.read_body()
        if isinstance(body, Refused):
            self.refuse(body.why)
            return
        if path_of(self.path) != MCP_PATH:
            self.refuse('rest-write')
            return
        match mcp_decision(body):
            case Allowed(detail):
                self.forward(body, detail)
            case Refused(why):
                self.refuse(why)

    def do_PUT(self) -> None:
        self.refuse_write()

    def do_PATCH(self) -> None:
        self.refuse_write()

    def do_DELETE(self) -> None:
        self.refuse_write()

    def do_OPTIONS(self) -> None:
        self.refuse_write()

    def do_TRACE(self) -> None:
        self.refuse_write()

    def do_CONNECT(self) -> None:
        self.refuse_write()


def stop_serving(signum: int, frame: FrameType | None) -> None:
    del frame
    raise SystemExit(128 + signum)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description='Read-only HTTP relay in front of a MASC server.')
    parser.add_argument('--upstream-port', type=int, required=True,
                        help='port of the MASC server (or frozen_server.py) the relay forwards reads to')
    parser.add_argument('--listen-port', type=int, default=0,
                        help='loopback port to listen on; 0, the default, takes a free one')
    parser.add_argument('--log', type=Path, required=True, help='decision log, one JSON line per decision')
    parser.add_argument('--record', type=Path, default=None,
                        help='recording directory for frozen_server.py; holds workspace data')
    args = parser.parse_args(argv)
    upstream_port: int = args.upstream_port
    listen_port: int = args.listen_port
    log_path: Path = args.log
    record: Path | None = args.record
    log = JsonLog(log_path)
    server = RelayServer(listen_port, upstream_port, log, None if record is None else Recorder(record))
    signal.signal(signal.SIGTERM, stop_serving)
    try:
        log.write({'decision': 'listening', 'listen': server.bound_port(), 'upstream': upstream_port})
        print(f'{LISTENING} {server.bound_port()}', flush=True)
        server.serve_forever()
    finally:
        server.server_close()
        log.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
