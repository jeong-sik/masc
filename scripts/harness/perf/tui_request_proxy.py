# pyright: strict
"""Relay HTTP/1.1 from local clients to one server and log what passed.

For each exchange the log keeps when the request started, its method, path
and query names, the final status, whether the answer is a stream, each
server-sent event by name, and how the exchange ended with its bytes each
way. It keeps no header values, no query values and no bodies.

Bytes pass unchanged in both directions except the request's Host, which
names the server's port instead of the relay's (see `with_authority`).

Each connection reads its client and its server at the same time, so the
relay sees a side close when it closes, whichever way bytes are flowing then.
A byte counts once the kernel has taken it for the side it is going to.

Message framing is in `tui_request_http.py`, event naming in
`tui_request_events.py` and the log entries in `tui_request_log.py`.
`tui_request_probe.py` runs the relay in front of one TUI child.
"""
import asyncio
import collections
from collections.abc import Callable, Generator, Mapping
import contextlib
from dataclasses import dataclass
import socket
import threading

from tui_request_http import (
    CONNECT, Chunked, Closed, FIRST_FINAL_STATUS, FIRST_REDIRECTION_STATUS, Fixed, Framing,
    HEAD_END, LINE_END, Malformed, Request, SWITCHING_PROTOCOLS, Side, Stop, UntilClose,
    chunk_size, parse_request, parse_response, response_framing, with_authority,
)
from tui_request_events import EventParser
from tui_request_log import Answered, Arrived, Ended, Ending, Failed, Fault, Log, Sent

LOOPBACK = '127.0.0.1'
MAX_LINE_BYTES = 65536
READ_BYTES = 65536
STOP_TIMEOUT_S = 10.0


class Endpoint:
    """One side of a relayed connection.

    A read or write error means this side has closed. Its write buffer limit
    is zero, so `send` returns only once the kernel has taken every byte."""

    __slots__ = ('side', '_reader', '_writer')

    def __init__(self, side: Side, reader: asyncio.StreamReader,
                 writer: asyncio.StreamWriter) -> None:
        self.side = side
        self._reader = reader
        self._writer = writer
        writer.transport.set_write_buffer_limits(high=0)

    async def some(self, size: int) -> bytes | Closed:
        try:
            piece = await self._reader.read(size)
        except OSError:
            return Closed(self.side)
        return piece if piece else Closed(self.side)

    async def exactly(self, size: int) -> bytes | Closed:
        try:
            return await self._reader.readexactly(size)
        except (asyncio.IncompleteReadError, OSError):
            return Closed(self.side)

    async def through(self, end: bytes) -> bytes | Stop:
        try:
            return await self._reader.readuntil(end)
        except (asyncio.IncompleteReadError, OSError):
            return Closed(self.side)
        except asyncio.LimitOverrunError:
            return Malformed(self.side, f'line longer than {MAX_LINE_BYTES} bytes')

    async def send(self, data: bytes) -> Closed | None:
        try:
            self._writer.write(data)
            await self._writer.drain()
        except OSError:
            return Closed(self.side)
        return None

    def close(self) -> None:
        self._writer.close()


@dataclass(frozen=True, slots=True)
class Pipe:
    """Message bytes from `source` to `sink`.

    `count` hears the size of each piece the sink took, and `content` hears
    each piece of body content it took, without chunk framing."""
    source: Endpoint
    sink: Endpoint
    count: Callable[[int], None]
    content: Callable[[bytes], None] | None = None

    async def frame(self, data: bytes) -> Closed | None:
        """Deliver framing: a head, a chunk size line, a chunk's CRLF or a trailer line."""
        if (closed := await self.sink.send(data)) is not None:
            return closed
        self.count(len(data))
        return None

    async def body(self, data: bytes) -> Closed | None:
        if (closed := await self.frame(data)) is not None:
            return closed
        if self.content is not None:
            self.content(data)
        return None


async def relay_fixed(pipe: Pipe, length: int) -> Stop | None:
    remaining = length
    while remaining:
        piece = await pipe.source.some(min(remaining, READ_BYTES))
        if isinstance(piece, Closed):
            return piece
        remaining -= len(piece)
        if (closed := await pipe.body(piece)) is not None:
            return closed
    return None


async def relay_trailers(pipe: Pipe) -> Stop | None:
    while True:
        line = await pipe.source.through(LINE_END)
        if not isinstance(line, bytes):
            return line
        if (closed := await pipe.frame(line)) is not None:
            return closed
        if line == LINE_END:
            return None


async def relay_chunked(pipe: Pipe) -> Stop | None:
    while True:
        line = await pipe.source.through(LINE_END)
        if not isinstance(line, bytes):
            return line
        size = chunk_size(line)
        if size is None:
            return Malformed(pipe.source.side, 'malformed chunk size line')
        if (closed := await pipe.frame(line)) is not None:
            return closed
        if size == 0:
            return await relay_trailers(pipe)
        if (stop := await relay_fixed(pipe, size)) is not None:
            return stop
        end = await pipe.source.exactly(len(LINE_END))
        if isinstance(end, Closed):
            return end
        if end != LINE_END:
            return Malformed(pipe.source.side, 'chunk data not followed by CRLF')
        if (closed := await pipe.frame(end)) is not None:
            return closed


async def relay_until_close(pipe: Pipe) -> Stop:
    """Relay until a side closes. A tunnel and a close-delimited body end this way."""
    while True:
        piece = await pipe.source.some(READ_BYTES)
        if isinstance(piece, Closed):
            return piece
        if (closed := await pipe.body(piece)) is not None:
            return closed


async def relay_body(pipe: Pipe, framing: Framing) -> Stop | None:
    """Relay one body; None once all of it was delivered."""
    match framing:
        case Fixed(length=length):
            return await relay_fixed(pipe, length)
        case Chunked():
            return await relay_chunked(pipe)
        case UntilClose():
            stop = await relay_until_close(pipe)
            return None if stop == Closed(pipe.source.side) else stop


@dataclass(slots=True)
class Exchange:
    """A request and its answer on one connection, as far as each was relayed.

    `decision` is set only for a request that asked to switch protocols, and
    its answer resolves it: True when the connection became a tunnel."""
    number: int
    method: str
    decision: asyncio.Future[bool] | None
    request_bytes: int = 0
    response_bytes: int = 0
    request_done: bool = False
    response_done: bool = False
    switched: bool = False

    def requested(self, size: int) -> None:
        self.request_bytes += size

    def answered(self, size: int) -> None:
        self.response_bytes += size

    def switches(self, status: int) -> bool:
        """Whether a final answer with `status` turns the connection into a tunnel."""
        if self.decision is None:
            return False
        if status == SWITCHING_PROTOCOLS:
            return True
        return self.method == CONNECT and FIRST_FINAL_STATUS <= status < FIRST_REDIRECTION_STATUS


@dataclass(frozen=True, slots=True)
class End:
    """Why and when one direction of a connection stopped."""
    stop: Stop
    t: float


def closed_ending(side: Side) -> Ending:
    match side:
        case Side.CLIENT:
            return Ending.CLIENT_CLOSED
        case Side.SERVER:
            return Ending.SERVER_CLOSED


def stop_ending(stop: Stop) -> tuple[Ending, str]:
    match stop:
        case Closed(side=side):
            return closed_ending(side), ''
        case Malformed(side=side, detail=detail):
            return Ending.MALFORMED, f'{side.value}: {detail}'


def describe(failure: BaseException) -> str:
    return f'{type(failure).__name__}: {failure}'


def failure_detail(context: Mapping[str, object]) -> str:
    """What the event loop reports as unhandled, for a `Failed` entry."""
    failure = context.get('exception')
    if isinstance(failure, BaseException):
        return describe(failure)
    return str(context.get('message'))


class Connection:
    """One client connection relayed over its own connection to the server.

    One task reads requests from the client while another reads answers from
    the server, so either side closing is seen at once. The connection ends
    when either side closes or sends bytes the relay cannot frame, and every
    exchange still open ends for that reason. The client closing counts as
    the client leaving: the TUI's HTTP client closes whole sockets and never
    half-closes one (lib/masc_http_client/pool.ml)."""

    __slots__ = ('_log', '_authority', '_client', '_server', '_unanswered', '_open', '_pumps')

    def __init__(self, log: Log, authority: bytes, client: Endpoint, server: Endpoint) -> None:
        self._log = log
        self._authority = authority
        self._client = client
        self._server = server
        self._unanswered: collections.deque[Exchange] = collections.deque()
        self._open: dict[int, Exchange] = {}
        self._pumps: tuple[asyncio.Task[End], ...] = ()

    async def run(self) -> None:
        pumps = (asyncio.create_task(self._requests()), asyncio.create_task(self._answers()))
        self._pumps = pumps
        try:
            await asyncio.wait(pumps, return_when=asyncio.FIRST_COMPLETED)
        except asyncio.CancelledError:
            self._end_open(self._log.now(), Ending.STOPPED, '')
            raise
        finally:
            # No await from here on: the relay stopping cancels this task at
            # its next await, and the ending must be logged before that.
            for pump in pumps:
                pump.cancel()
            self._client.close()
            self._server.close()
        self._settle(pumps)
        # The ending is logged; now let the cancelled pump finish before this task does.
        await asyncio.wait(pumps)

    def _settle(self, pumps: tuple[asyncio.Task[End], ...]) -> None:
        returned = [pump for pump in pumps if pump.done() and not pump.cancelled()]
        failures = [failure for pump in returned if (failure := pump.exception()) is not None]
        if failures:
            now = self._log.now()
            for failure in failures:
                self._log.add(Failed(now, describe(failure)))
            self._end_open(now, Ending.STOPPED, 'relay failed')
            return
        # The first pump to stop cancels the other, so one End is left.
        (end,) = (pump.result() for pump in returned)
        ending, detail = stop_ending(end.stop)
        if isinstance(end.stop, Malformed):
            self._log.add(Fault(end.t, end.stop.side, end.stop.detail))
        self._end_open(end.t, ending, detail)

    def _end_open(self, t: float, ending: Ending, detail: str) -> None:
        for exchange in self._open.values():
            if exchange.switched:
                ended = Ended(exchange.number, t, Ending.SWITCHED, exchange.request_bytes,
                              exchange.response_bytes, ending.value)
            else:
                ended = Ended(exchange.number, t, ending, exchange.request_bytes,
                              exchange.response_bytes, detail)
            self._log.add(ended)
        self._open.clear()

    def _stop(self, stop: Stop) -> End:
        """End the connection now. The other pump is cancelled before it relays or logs more."""
        current = asyncio.current_task()
        for pump in self._pumps:
            if pump is not current:
                pump.cancel()
        return End(stop, self._log.now())

    def _start(self, request: Request) -> Exchange:
        number = self._log.next_exchange()
        self._log.add(Sent(number, self._log.now(), request.method, request.path, request.query))
        decision: asyncio.Future[bool] | None = (
            asyncio.get_running_loop().create_future() if request.switching else None)
        exchange = Exchange(number, request.method, decision)
        self._open[number] = exchange
        self._unanswered.append(exchange)
        return exchange

    def _complete(self, exchange: Exchange) -> None:
        if exchange.request_done and exchange.response_done:
            del self._open[exchange.number]
            self._log.add(Ended(exchange.number, self._log.now(), Ending.COMPLETE,
                                exchange.request_bytes, exchange.response_bytes, ''))

    def _arrival(self, number: int) -> Callable[[str, int], None]:
        def arrived(name: str, size: int) -> None:
            self._log.add(Arrived(number, self._log.now(), name, size))
        return arrived

    async def _requests(self) -> End:
        while True:
            raw = await self._client.through(HEAD_END)
            if not isinstance(raw, bytes):
                return self._stop(raw)
            request = parse_request(raw)
            if isinstance(request, Malformed):
                return self._stop(request)
            exchange = self._start(request)
            pipe = Pipe(self._client, self._server, exchange.requested)
            if (closed := await pipe.frame(with_authority(raw, self._authority))) is not None:
                return self._stop(closed)
            if (stop := await relay_body(pipe, request.framing)) is not None:
                return self._stop(stop)
            exchange.request_done = True
            self._complete(exchange)
            if exchange.decision is not None and await exchange.decision:
                return self._stop(await relay_until_close(pipe))

    async def _answers(self) -> End:
        while True:
            raw = await self._server.through(HEAD_END)
            if not isinstance(raw, bytes):
                return self._stop(raw)
            if not self._unanswered:
                return self._stop(Malformed(Side.SERVER, 'answer without a request'))
            exchange = self._unanswered[0]
            response = parse_response(raw)
            if isinstance(response, Malformed):
                return self._stop(response)
            switches = exchange.switches(response.status)
            if response.status == SWITCHING_PROTOCOLS and not switches:
                return self._stop(Malformed(Side.SERVER, 'switched protocols unasked'))
            pipe = Pipe(self._server, self._client, exchange.answered)
            if (closed := await pipe.frame(raw)) is not None:
                return self._stop(closed)
            if not response.final:
                continue
            self._log.add(Answered(exchange.number, self._log.now(), response.status,
                                   switches or response.events))
            self._unanswered.popleft()
            if exchange.decision is not None:
                exchange.decision.set_result(switches)
            if switches:
                exchange.switched = True
                return self._stop(await relay_until_close(pipe))
            framing = response_framing(response.head, method=exchange.method,
                                       status=response.status)
            if isinstance(framing, Malformed):
                return self._stop(framing)
            if response.events:
                parser = EventParser(self._arrival(exchange.number))
                pipe = Pipe(self._server, self._client, exchange.answered, parser.feed)
            if (stop := await relay_body(pipe, framing)) is not None:
                return self._stop(stop)
            exchange.response_done = True
            self._complete(exchange)
            if isinstance(framing, UntilClose):
                return self._stop(Closed(Side.SERVER))


class Relay:
    """Relay each accepted connection over its own connection to the server."""

    def __init__(self, upstream_port: int, log: Log) -> None:
        self._upstream_port = upstream_port
        self._authority = f'{LOOPBACK}:{upstream_port}'.encode('ascii')
        self._log = log
        self._connections: set[asyncio.Task[None]] = set()

    async def listen(self, listener: socket.socket) -> asyncio.Server:
        return await asyncio.start_server(self._accept, sock=listener, limit=MAX_LINE_BYTES)

    async def close(self, server: asyncio.Server) -> None:
        server.close()
        connections = tuple(self._connections)
        for task in connections:
            task.cancel()
        await asyncio.gather(*connections, return_exceptions=True)
        await server.wait_closed()

    async def _accept(self, client_reader: asyncio.StreamReader,
                      client_writer: asyncio.StreamWriter) -> None:
        task = asyncio.current_task()
        if task is not None:
            self._connections.add(task)
        try:
            await self._relay(client_reader, client_writer)
        finally:
            if task is not None:
                self._connections.discard(task)
            client_writer.close()

    async def _relay(self, client_reader: asyncio.StreamReader,
                     client_writer: asyncio.StreamWriter) -> None:
        try:
            server_reader, server_writer = await asyncio.open_connection(
                LOOPBACK, self._upstream_port, limit=MAX_LINE_BYTES)
        except OSError as exc:
            self._log.add(Fault(self._log.now(), Side.SERVER, f'cannot connect: {exc}'))
            return
        await Connection(self._log, self._authority,
                         Endpoint(Side.CLIENT, client_reader, client_writer),
                         Endpoint(Side.SERVER, server_reader, server_writer)).run()


def listen_socket() -> socket.socket:
    """A listening loopback socket on a free port. Bind it before forking a child."""
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.bind((LOOPBACK, 0))
    listener.listen()
    return listener


def bound_port(listener: socket.socket) -> int:
    address: tuple[object, ...] = listener.getsockname()
    port = address[1]
    if not isinstance(port, int):
        raise TypeError(f'listening socket address has no port: {address!r}')
    return port


@contextlib.contextmanager
def serve(listener: socket.socket, upstream_port: int, log: Log) -> Generator[None]:
    """Relay connections accepted on `listener` while the `with` body runs.

    The relay runs its own event loop on its own thread. Whatever that loop
    reports as unhandled is logged as `Failed`."""
    loop = asyncio.new_event_loop()
    loop.set_exception_handler(
        lambda _loop, context: log.add(Failed(log.now(), failure_detail(context))))
    thread = threading.Thread(target=loop.run_forever, name='tui-request-proxy', daemon=True)
    thread.start()
    relay = Relay(upstream_port, log)
    try:
        server = asyncio.run_coroutine_threadsafe(relay.listen(listener), loop).result(STOP_TIMEOUT_S)
        try:
            yield
        finally:
            asyncio.run_coroutine_threadsafe(relay.close(server), loop).result(STOP_TIMEOUT_S)
    finally:
        loop.call_soon_threadsafe(loop.stop)
        thread.join(STOP_TIMEOUT_S)
        if not thread.is_alive():
            loop.close()
