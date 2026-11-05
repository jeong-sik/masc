# pyright: strict
"""What the TUI request relay logs.

The relay thread appends entries and the probe reads a copy. No entry keeps
a header value, a query value or a body.
"""
from collections.abc import Callable
from dataclasses import dataclass
import enum
import threading
import time

from tui_request_http import Side


class Ending(enum.Enum):
    COMPLETE = 'complete'
    CLIENT_CLOSED = 'client_closed'
    SERVER_CLOSED = 'server_closed'
    MALFORMED = 'malformed'
    SWITCHED = 'switched'
    STOPPED = 'stopped'


@dataclass(frozen=True, slots=True)
class Sent:
    """A request head arrived from the client."""
    exchange: int
    t: float
    method: str
    path: str
    query: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class Answered:
    """The final response head arrived from the server."""
    exchange: int
    t: float
    status: int
    stream: bool


@dataclass(frozen=True, slots=True)
class Arrived:
    """One server-sent event block reached the client; `size` counts its bytes since the last block."""
    exchange: int
    t: float
    name: str
    size: int


@dataclass(frozen=True, slots=True)
class Ended:
    exchange: int
    t: float
    ending: Ending
    request_bytes: int
    response_bytes: int
    detail: str


@dataclass(frozen=True, slots=True)
class Fault:
    """A server the relay could not reach, or bytes from `side` it could not frame."""
    t: float
    side: Side
    detail: str


@dataclass(frozen=True, slots=True)
class Failed:
    """The relay itself raised; what it logged for that connection may stop short."""
    t: float
    detail: str


type Entry = Sent | Answered | Arrived | Ended | Fault | Failed


class Log:
    """Entries in arrival order. The relay thread appends; `entries` copies."""

    __slots__ = ('_clock', '_lock', '_entries', '_last_exchange')

    def __init__(self, clock: Callable[[], float] = time.monotonic) -> None:
        self._clock = clock
        self._lock = threading.Lock()
        self._entries: list[Entry] = []
        self._last_exchange = 0

    def now(self) -> float:
        return self._clock()

    def next_exchange(self) -> int:
        with self._lock:
            self._last_exchange += 1
            return self._last_exchange

    def add(self, entry: Entry) -> None:
        with self._lock:
            self._entries.append(entry)

    def entries(self) -> tuple[Entry, ...]:
        with self._lock:
            return tuple(self._entries)
