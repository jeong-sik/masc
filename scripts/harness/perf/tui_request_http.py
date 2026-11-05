# pyright: strict
"""HTTP/1.1 message framing for the TUI request relay.

Pure functions over bytes the relay has read: where a message body ends
(RFC 9112 section 6), what a request target names (section 3.2) and the
Host the server admits.
"""
from dataclasses import dataclass
import enum
import re
from urllib.parse import parse_qsl

HEAD_END = b'\r\n\r\n'
LINE_END = b'\r\n'
HTTP1 = 'HTTP/1.'
STATUS_CODE = re.compile(r'[0-9]{3}')
CHUNK_SIZE = re.compile(rb'[0-9A-Fa-f]+')
SWITCHING_PROTOCOLS = 101
FIRST_FINAL_STATUS = 200
FIRST_REDIRECTION_STATUS = 300
BODYLESS_STATUSES = frozenset((204, 304))
CONNECT = 'CONNECT'
ORIGIN_FORM_START = '/'
ASTERISK_FORM = '*'
OTHER_FORM = '<not origin-form>'
EVENT_STREAM = 'text/event-stream'


class Side(enum.Enum):
    CLIENT = 'client'
    SERVER = 'server'


@dataclass(frozen=True, slots=True)
class Closed:
    """`side` ended its connection."""
    side: Side


@dataclass(frozen=True, slots=True)
class Malformed:
    """`side` sent bytes this relay cannot frame as HTTP/1.1."""
    side: Side
    detail: str


type Stop = Closed | Malformed


@dataclass(frozen=True, slots=True)
class Fixed:
    """A body of exactly `length` bytes."""
    length: int


@dataclass(frozen=True, slots=True)
class Chunked:
    """A chunked body, ended by a zero-size chunk and its trailer section."""


@dataclass(frozen=True, slots=True)
class UntilClose:
    """A body that ends when the server closes the connection."""


type Framing = Fixed | Chunked | UntilClose


@dataclass(frozen=True, slots=True)
class Head:
    start: str
    fields: tuple[tuple[str, str], ...]

    def values(self, name: str) -> tuple[str, ...]:
        return tuple(value for key, value in self.fields if key == name)

    def tokens(self, name: str) -> tuple[str, ...]:
        return tuple(part.strip() for value in self.values(name)
                     for part in value.split(',') if part.strip())


def parse_head(raw: bytes, side: Side) -> Head | Malformed:
    """A message head as read through its blank line. Field names are lower-cased."""
    lines = raw.removesuffix(HEAD_END).lstrip(LINE_END).split(LINE_END)
    fields: list[tuple[str, str]] = []
    for line in lines[1:]:
        name, colon, value = line.partition(b':')
        if not colon or not name or name != name.strip():
            return Malformed(side, 'malformed header field line')
        fields.append((name.decode('latin-1').lower(), value.strip().decode('latin-1')))
    return Head(lines[0].decode('latin-1'), tuple(fields))


def length_framing(head: Head, side: Side, absent: Framing) -> Framing | Malformed:
    """The Content-Length body, or `absent` when the head declares none."""
    lengths = frozenset(head.tokens('content-length'))
    if not lengths:
        return absent
    if len(lengths) > 1:
        return Malformed(side, 'conflicting Content-Length values')
    length = next(iter(lengths))
    if not (length.isascii() and length.isdigit()):
        return Malformed(side, 'malformed Content-Length')
    return Fixed(int(length))


def transfer_codings(head: Head) -> tuple[str, ...]:
    return tuple(coding.lower() for coding in head.tokens('transfer-encoding'))


def request_framing(head: Head) -> Framing | Malformed:
    codings = transfer_codings(head)
    if not codings:
        return length_framing(head, Side.CLIENT, Fixed(0))
    if codings[-1] == 'chunked':
        return Chunked()
    return Malformed(Side.CLIENT, 'request transfer coding does not end in chunked')


def response_framing(head: Head, *, method: str, status: int) -> Framing | Malformed:
    """RFC 9112 section 6.3 message body length for a response to `method`."""
    if method == 'HEAD' or status < FIRST_FINAL_STATUS or status in BODYLESS_STATUSES:
        return Fixed(0)
    codings = transfer_codings(head)
    if not codings:
        return length_framing(head, Side.SERVER, UntilClose())
    return Chunked() if codings[-1] == 'chunked' else UntilClose()


def media_type(head: Head) -> str:
    found = head.values('content-type')
    return found[0].split(';', 1)[0].strip().lower() if found else ''


def split_target(target: str) -> tuple[str, tuple[str, ...]]:
    """The path and the sorted query names of a request target; values are dropped.

    Only origin-form (RFC 9112 section 3.2.1) has a path to keep: everything
    before the first `?`. Other forms are logged by their form, so an
    authority or user name in an absolute-form target stays out of the log."""
    if not target.startswith(ORIGIN_FORM_START):
        return (ASTERISK_FORM if target == ASTERISK_FORM else OTHER_FORM), ()
    path, _, query = target.partition('?')
    names = frozenset(name for name, _ in parse_qsl(query, keep_blank_values=True))
    return path, tuple(sorted(names))


@dataclass(frozen=True, slots=True)
class Request:
    method: str
    path: str
    query: tuple[str, ...]
    head: Head
    framing: Framing

    @property
    def switching(self) -> bool:
        """Whether an answer may turn the connection into a tunnel (RFC 9110 sections 7.8, 9.3.6)."""
        return self.method == CONNECT or bool(self.head.values('upgrade'))


def parse_request(raw: bytes) -> Request | Malformed:
    head = parse_head(raw, Side.CLIENT)
    if isinstance(head, Malformed):
        return head
    parts = head.start.split(' ')
    if len(parts) != 3 or not parts[0] or not parts[2].startswith(HTTP1):
        return Malformed(Side.CLIENT, 'not an HTTP/1.x request line')
    framing = request_framing(head)
    if isinstance(framing, Malformed):
        return framing
    path, query = split_target(parts[1])
    return Request(parts[0], path, query, head, framing)


@dataclass(frozen=True, slots=True)
class Response:
    status: int
    head: Head

    @property
    def final(self) -> bool:
        return self.status >= FIRST_FINAL_STATUS or self.status == SWITCHING_PROTOCOLS

    @property
    def events(self) -> bool:
        return media_type(self.head) == EVENT_STREAM


def parse_response(raw: bytes) -> Response | Malformed:
    head = parse_head(raw, Side.SERVER)
    if isinstance(head, Malformed):
        return head
    parts = head.start.split(' ', 2)
    if len(parts) < 2 or not parts[0].startswith(HTTP1) or not STATUS_CODE.fullmatch(parts[1]):
        return Malformed(Side.SERVER, 'not an HTTP/1.x status line')
    return Response(int(parts[1]), head)


def chunk_size(line: bytes) -> int | None:
    digits = line.removesuffix(LINE_END).split(b';', 1)[0].strip()
    return int(digits, 16) if CHUNK_SIZE.fullmatch(digits) else None


def with_authority(raw: bytes, authority: bytes) -> bytes:
    """`raw` with each Host field's value replaced by `authority`.

    The server admits an HTTP/1.1 request only when its Host names the
    server's own bind port (`configured_bind_matches` in
    lib/server/server_request_authority.ml) and answers 400
    `request_authority_untrusted` otherwise. A client of the relay names the
    relay's port, so the relay forwards the Host a direct client sends."""
    lines = raw.split(LINE_END)
    for index in range(1, len(lines)):
        name, colon, _ = lines[index].partition(b':')
        if colon and name.lower() == b'host':
            lines[index] = name + b': ' + authority
    return LINE_END.join(lines)
