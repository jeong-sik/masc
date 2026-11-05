# pyright: strict
"""Name the server-sent events of a text/event-stream body as its bytes arrive."""
from collections.abc import Callable
import json
from typing import cast

CR = ord('\r')
LF = ord('\n')
UTF8_BOM = b'\xef\xbb\xbf'
COMMENT_EVENT = ':comment'
NO_DATA_EVENT = ':no-data'
MESSAGE_EVENT = 'message'


def json_fields(value: object) -> dict[str, object]:
    """A decoded JSON object's fields; nothing for any other JSON value."""
    if isinstance(value, dict):
        return cast(dict[str, object], value)
    return {}


def json_event_name(data: bytes) -> str | None:
    try:
        payload: object = json.loads(data)
    except (ValueError, RecursionError):
        # The decoder raises RecursionError for nesting deeper than the
        # interpreter's recursion limit. Such data names no event either.
        return None
    fields = json_fields(payload)
    kind = fields.get('type')
    if isinstance(kind, str) and kind:
        dataset = fields.get('dataset')
        return f'{kind}:{dataset}' if isinstance(dataset, str) and dataset else kind
    method = fields.get('method')
    return f'rpc:{method}' if isinstance(method, str) and method else None


def line_break(data: bytes, start: int) -> int:
    """Where the first CR or LF at or after `start` is, or -1."""
    return min((at for at in (data.find(b'\r', start), data.find(b'\n', start)) if at >= 0),
               default=-1)


class EventParser:
    """Name the server-sent events of a text/event-stream body as its bytes arrive.

    It follows HTML, "Parsing an event stream": lines end in CRLF, LF or CR, a
    leading BOM is dropped, and a blank line ends a block. A block's `event`
    field names it. Without one, JSON data names it by its `type` (with its
    `dataset` when it has one) or by its JSON-RPC `method`. A block of comments
    only is a keep-alive, a block without data dispatches no event, and a blank
    line with nothing before it ends no block. An unfinished block at the end
    of the body is not counted.

    `on_event` hears each block's name and its bytes since the previous block.
    The LF of a CRLF that ends a block counts toward the next block, so the
    sizes do not depend on how the body was cut into pieces."""

    __slots__ = ('_on_event', '_line', '_after_cr', '_first_line', '_size',
                 '_name', '_data', '_fields', '_comments')

    def __init__(self, on_event: Callable[[str, int], None]) -> None:
        self._on_event = on_event
        self._line = bytearray()
        self._after_cr = False
        self._first_line = True
        self._size = 0
        self._name = b''
        self._data: list[bytes] = []
        self._fields = 0
        self._comments = 0

    def feed(self, data: bytes) -> None:
        at = 0
        while at < len(data):
            if self._after_cr:
                self._after_cr = False
                if data[at] == LF:
                    self._size += 1
                    at += 1
                    continue
            cut = line_break(data, at)
            if cut < 0:
                self._line.extend(data[at:])
                self._size += len(data) - at
                return
            self._line.extend(data[at:cut])
            self._size += cut + 1 - at
            self._after_cr = data[cut] == CR
            at = cut + 1
            line = bytes(self._line)
            self._line.clear()
            self._take(line)

    def _take(self, line: bytes) -> None:
        if self._first_line:
            self._first_line = False
            line = line.removeprefix(UTF8_BOM)
        if not line:
            self._dispatch()
        elif line.startswith(b':'):
            self._comments += 1
        else:
            self._fields += 1
            field, _, value = line.partition(b':')
            value = value.removeprefix(b' ')
            if field == b'event':
                self._name = value
            elif field == b'data':
                self._data.append(value)

    def _dispatch(self) -> None:
        if not self._fields and not self._comments:
            return
        self._on_event(self._block_name(), self._size)
        self._size = 0
        self._name = b''
        self._data.clear()
        self._fields = 0
        self._comments = 0

    def _block_name(self) -> str:
        if not self._fields:
            return COMMENT_EVENT
        if not self._data:
            return NO_DATA_EVENT
        named = self._name.decode('utf-8', 'replace')
        if named and named != MESSAGE_EVENT:
            return named
        return json_event_name(b'\n'.join(self._data)) or MESSAGE_EVENT
