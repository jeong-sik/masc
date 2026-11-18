# pyright: strict
"""Files the read-only relay and the frozen server write and read.

`JsonLog` is the decision log: one JSON object per line, each with `t`, the
Unix time it was written.

A recording is a directory. `index.jsonl` holds one JSON line per answer and
`bodies/` holds each body once, named by the first 24 hex digits of its
SHA-256. A line has `kind`, `key`, `status`, `headers` (the kept response
headers, lower-case names) and `body` (the file name under `bodies/`).

  kind `get`  key is the request target (path and query); the body is the
              answer as the server sent it, content encoding included
  kind `sse`  key is the target of an event stream; only its headers are kept
  kind `mcp`  key is the JSON-RPC method, the tool name and the resource URI
              joined by `|`

A later line for the same key replaces an earlier one. Bodies come from a live
server and hold workspace data: keep recordings outside the repository.
"""
from collections.abc import Callable, Iterable, Mapping
from dataclasses import dataclass
import enum
import hashlib
import json
from pathlib import Path
import re
import threading
import time
from typing import cast

INDEX_NAME = 'index.jsonl'
BODIES_NAME = 'bodies'
DIGEST_CHARS = 24
DIGEST_NAME = re.compile(f'[0-9a-f]{{{DIGEST_CHARS}}}')
# What a replay needs: how to read the body, the validator a 304 answers to,
# the MCP session, and the x-masc-* headers by which the server attests a read.
KEPT_HEADERS = frozenset({'content-type', 'content-encoding', 'etag', 'mcp-session-id'})
KEPT_PREFIX = 'x-masc-'
KEY_SEPARATOR = '|'


class Kind(enum.Enum):
    GET = 'get'
    STREAM = 'sse'
    MCP = 'mcp'


KINDS = {kind.value: kind for kind in Kind}


@dataclass(frozen=True, slots=True)
class Answer:
    status: int
    headers: Mapping[str, str]
    body: bytes


@dataclass(frozen=True, slots=True)
class Recording:
    exact: Mapping[str, Answer]
    by_path: Mapping[str, Answer]
    streams: Mapping[str, Mapping[str, str]]
    mcp: Mapping[str, Answer]


class JsonLog:
    """Appends one JSON line per entry. Safe to call from several threads."""

    def __init__(self, path: Path, clock: Callable[[], float] = time.time) -> None:
        self._file = path.open('a', encoding='utf-8', buffering=1)
        self._lock = threading.Lock()
        self._clock = clock

    def write(self, entry: Mapping[str, object]) -> None:
        line = json.dumps({**entry, 't': round(self._clock(), 3)}, ensure_ascii=False)
        with self._lock:
            self._file.write(line + '\n')

    def close(self) -> None:
        with self._lock:
            self._file.close()


def path_of(target: str) -> str:
    return target.split('?', 1)[0]


def json_object(value: object) -> dict[str, object] | None:
    if isinstance(value, dict):
        return cast(dict[str, object], value)
    return None


def key_part(params: Mapping[str, object], name: str) -> str:
    value = params.get(name)
    return str(value) if value else ''


def mcp_key(body: bytes) -> str | None:
    """The replay key of one JSON-RPC request; None for a batch or anything else."""
    try:
        message: object = json.loads(body.decode('utf-8') or 'null')
    except (UnicodeDecodeError, ValueError, RecursionError):
        return None
    fields = json_object(message)
    if fields is None:
        return None
    method = fields.get('method')
    if not isinstance(method, str):
        return None
    params = json_object(fields.get('params')) or {}
    return KEY_SEPARATOR.join((method, key_part(params, 'name'), key_part(params, 'uri')))


def kept_headers(headers: Iterable[tuple[str, str]]) -> dict[str, str]:
    return {name.lower(): value for name, value in headers
            if name.lower() in KEPT_HEADERS or name.lower().startswith(KEPT_PREFIX)}


class Recorder:
    """Appends answers to a recording directory. Safe to call from several threads."""

    def __init__(self, directory: Path) -> None:
        self._directory = directory
        self._lock = threading.Lock()
        (directory / BODIES_NAME).mkdir(parents=True, exist_ok=True)

    def append(self, kind: Kind, key: str, status: int,
               headers: Iterable[tuple[str, str]], body: bytes) -> None:
        digest = hashlib.sha256(body).hexdigest()[:DIGEST_CHARS]
        line = json.dumps({'kind': kind.value, 'key': key, 'status': status,
                           'headers': kept_headers(headers), 'body': digest}, ensure_ascii=False)
        with self._lock:
            (self._directory / BODIES_NAME / digest).write_bytes(body)
            with (self._directory / INDEX_NAME).open('a', encoding='utf-8') as index:
                index.write(line + '\n')


def text_map(value: object) -> dict[str, str] | None:
    fields = json_object(value)
    if fields is None:
        return None
    texts = {name: text for name, text in fields.items() if isinstance(text, str)}
    return texts if len(texts) == len(fields) else None


def parse_line(directory: Path, line: str) -> tuple[Kind, str, Answer] | str:
    try:
        decoded: object = json.loads(line)
    except (ValueError, RecursionError) as exc:
        return f'not JSON: {exc}'
    fields = json_object(decoded)
    if fields is None:
        return 'not a JSON object'
    kind_name, key, status = fields.get('kind'), fields.get('key'), fields.get('status')
    headers, body_name = text_map(fields.get('headers')), fields.get('body')
    kind = KINDS.get(kind_name) if isinstance(kind_name, str) else None
    if kind is None:
        return f'unknown kind {kind_name!r}'
    if not isinstance(key, str):
        return 'key is not a string'
    if not isinstance(status, int) or isinstance(status, bool):
        return 'status is not an integer'
    if headers is None:
        return 'headers is not an object of strings'
    if not isinstance(body_name, str) or DIGEST_NAME.fullmatch(body_name) is None:
        return f'body is not a {DIGEST_CHARS}-digit digest'
    try:
        body = (directory / BODIES_NAME / body_name).read_bytes()
    except OSError as exc:
        return f'body {body_name}: {exc.strerror}'
    return kind, key, Answer(status, headers, body)


def load(directory: Path) -> Recording | str:
    """The recording in `directory`, or why it cannot be read."""
    try:
        lines = (directory / INDEX_NAME).read_text(encoding='utf-8').splitlines()
    except OSError as exc:
        return f'{directory / INDEX_NAME}: {exc.strerror}'
    exact: dict[str, Answer] = {}
    by_path: dict[str, Answer] = {}
    streams: dict[str, Mapping[str, str]] = {}
    mcp: dict[str, Answer] = {}
    for number, line in enumerate(lines, 1):
        parsed = parse_line(directory, line)
        if isinstance(parsed, str):
            return f'{INDEX_NAME} line {number}: {parsed}'
        kind, key, answer = parsed
        match kind:
            case Kind.GET:
                exact[key] = answer
                by_path[path_of(key)] = answer
            case Kind.STREAM:
                streams[path_of(key)] = answer.headers
            case Kind.MCP:
                mcp[key] = answer
    return Recording(exact, by_path, streams, mcp)
