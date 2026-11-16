"""What packages that read the workspace's records share (RFC
operator-lesson §5): the grants a session reads, the pin of each record it can
cite, the reads put back together, where reading goes next, and the
append-only log and kept bodies on the package's persistent volume.

Each image carries this file beside protocol.py; the package's own folder is
mounted at /addon. A package keeps its own events, sessions and rows.

A log is one JSON line per event. Events and their fields are closed sets: an
unknown event or field is an error naming the line, and a log that cannot be
read refuses every write. A write always ends with a newline, so a last
segment without one is a write the process did not finish. Reading skips it
and the next append cuts it off first; every complete line before it must
decode.
"""
from __future__ import annotations

import base64
import hashlib
import json
import math
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Generic, TypeVar, Union, cast


class LogError(Exception):
    """The log cannot be read as this package's history."""


class InvalidResult(ValueError):
    """A delivered result this package cannot consume. It is not accepted, so
    the host keeps it and shows the failed delivery."""


class InvalidBinding(ValueError):
    """The installation's binding does not name what a session reads."""


# -- Strict readers of a logged value. --------------------------------------

def exact(value: Any, keys: set[str], label: str) -> dict:
    if not isinstance(value, dict):
        raise LogError(f"{label} must be an object")
    extra = set(value) - keys
    missing = keys - set(value)
    if extra:
        raise LogError(f"{label} has unknown field {sorted(extra)[0]}")
    if missing:
        raise LogError(f"{label} is missing {sorted(missing)[0]}")
    return value


def text(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise LogError(f"{label} must be a non-blank string")
    return value


def count(value: Any, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        raise LogError(f"{label} must be a positive integer")
    return value


def index(value: Any, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise LogError(f"{label} must be a non-negative integer")
    return value


def number(value: Any, label: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or value != value:
        raise LogError(f"{label} must be a number")
    return float(value)


def texts(value: Any, label: str) -> tuple[str, ...]:
    if not isinstance(value, list):
        raise LogError(f"{label} must be an array")
    return tuple(text(item, label) for item in value)


def digest(value: Any) -> str:
    encoded = json.dumps(value, ensure_ascii=False, allow_nan=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()


# -- Pins: where a cited record lives, one shape per source kind. The
#    material writes each pin with pin_text and the log reads it back with
#    parse_pin, so a pin has one spelling.

_HEX = frozenset("0123456789abcdef")


def _hex_id(text: str, prefix: str) -> bool:
    """A Board id: the prefix, then lowercase hex."""
    return text.startswith(prefix) and len(text) > len(prefix) and set(text[len(prefix):]) <= _HEX


def _object_id(text: str) -> bool:
    """A full commit id, SHA-1 or SHA-256, as the host accepts it."""
    return len(text) in (40, 64) and set(text) <= _HEX


def _positive(text: str) -> int | None:
    return int(text) if text.isdigit() and text[0] != "0" else None


def _page_name(text: str) -> bool:
    """A wiki page name as the wiki writes it: lowercase a-z, digits and -,
    with no - at either end."""
    return (bool(text) and set(text) <= frozenset("abcdefghijklmnopqrstuvwxyz0123456789-")
            and text[0] != "-" and text[-1] != "-")


@dataclass(frozen=True, slots=True)
class BoardPostPin:
    post_id: str


@dataclass(frozen=True, slots=True)
class BoardCommentPin:
    post_id: str
    comment_id: str


@dataclass(frozen=True, slots=True)
class RepoFilePin:
    commit: str
    path: str


@dataclass(frozen=True, slots=True)
class CommitPin:
    commit: str


@dataclass(frozen=True, slots=True)
class WikiPagePin:
    name: str
    revision: int


@dataclass(frozen=True, slots=True)
class PrPin:
    number: int
    merge_commit: str


@dataclass(frozen=True, slots=True)
class PrReviewPin:
    number: int
    review_id: int


@dataclass(frozen=True, slots=True)
class PrCommentPin:
    number: int
    comment_id: int


Pin = Union[BoardPostPin, BoardCommentPin, RepoFilePin, CommitPin, WikiPagePin, PrPin, PrReviewPin, PrCommentPin]


def pin_kind(pin: Pin) -> str:
    match pin:
        case BoardPostPin():
            return "board_post"
        case BoardCommentPin():
            return "board_comment"
        case RepoFilePin():
            return "repo_file"
        case CommitPin():
            return "commit"
        case WikiPagePin():
            return "wiki_page"
        case PrPin():
            return "pr"
        case PrReviewPin() | PrCommentPin():
            return "pr_comment"


def pin_text(pin: Pin) -> str:
    match pin:
        case BoardPostPin(post_id):
            return post_id
        case BoardCommentPin(post_id, comment_id):
            return f"{post_id}/{comment_id}"
        case RepoFilePin(commit, path):
            return f"{commit}:{path}"
        case CommitPin(commit):
            return commit
        case WikiPagePin(name, revision):
            return f"{name}@{revision}"
        case PrPin(number, merge_commit):
            return f"{number}@{merge_commit}"
        case PrReviewPin(number, review_id):
            return f"{number}/r{review_id}"
        case PrCommentPin(number, comment_id):
            return f"{number}/c{comment_id}"


def _parse_pin(kind: str, text: str) -> Pin | None:
    match kind:
        case "board_post" if _hex_id(text, "p-"):
            return BoardPostPin(text)
        case "board_comment":
            post_id, _, comment_id = text.partition("/")
            if _hex_id(post_id, "p-") and _hex_id(comment_id, "c-"):
                return BoardCommentPin(post_id, comment_id)
        case "repo_file":
            commit, _, path = text.partition(":")
            if _object_id(commit) and path and not path.startswith("/") and ".." not in path.split("/"):
                return RepoFilePin(commit, path)
        case "commit" if _object_id(text):
            return CommitPin(text)
        case "wiki_page":
            name, _, revision = text.rpartition("@")
            number = _positive(revision)
            if _page_name(name) and number is not None:
                return WikiPagePin(name, number)
        case "pr":
            number_text, _, merge_commit = text.partition("@")
            number = _positive(number_text)
            if number is not None and _object_id(merge_commit):
                return PrPin(number, merge_commit)
        case "pr_comment":
            number_text, _, rest = text.partition("/")
            number = _positive(number_text)
            index = _positive(rest[1:]) if rest[:1] in ("r", "c") else None
            if number is not None and index is not None:
                return PrReviewPin(number, index) if rest[0] == "r" else PrCommentPin(number, index)
    return None


SOURCE_KINDS = {"board_post", "board_comment", "repo_file", "commit", "wiki_page", "pr", "pr_comment"}


def parse_pin(kind: str, text: str) -> Pin:
    """The pin [text] names for a source of [kind], read strictly: a text of
    another shape is not a pin."""
    if kind not in SOURCE_KINDS:
        raise LogError(f"source.kind {kind} is not a kind this package cites")
    pin = _parse_pin(kind, text)
    if pin is None:
        raise LogError(f"{text!r} is not a {kind} pin")
    return pin


# -- A cited record: its pin, the words quoted, and the retained bytes they
#    were checked against.

@dataclass(frozen=True, slots=True)
class Source:
    kind: str
    source_id: str  # the grant
    pin: str  # the pin_text of the record's pin; parse_pin reads it
    quote: str
    sha256: str  # the retained bytes the quote was checked against

    def to_json(self) -> dict:
        return {"kind": self.kind, "source_id": self.source_id, "pin": self.pin,
                "quote": self.quote, "sha256": self.sha256}

    @staticmethod
    def of_json(value: Any) -> "Source":
        fields = exact(value, {"kind", "source_id", "pin", "quote", "sha256"}, "source")
        kind = text(fields["kind"], "source.kind")
        pin = text(fields["pin"], "source.pin")
        parse_pin(kind, pin)
        # Kept byte for byte, spacing included, but whitespace alone cites nothing.
        if not isinstance(fields["quote"], str) or not fields["quote"].strip():
            raise LogError("source.quote must hold more than whitespace")
        return Source(kind, text(fields["source_id"], "source.source_id"), pin, fields["quote"],
                      text(fields["sha256"], "source.sha256"))


# -- The grants a session reads, fixed when it opens. The listing is then a
#    function of the log alone, even before this worker's first observation.

GRANT_KINDS = {"board", "repository", "wiki", "github_pulls"}


@dataclass(frozen=True, slots=True)
class Grant:
    source_id: str
    kind: str
    paths: tuple[str, ...]  # repository grants only: the files read for each new commit

    def to_json(self) -> dict:
        return {"source_id": self.source_id, "kind": self.kind, "paths": list(self.paths)}

    @staticmethod
    def of_json(value: Any) -> "Grant":
        fields = exact(value, {"source_id", "kind", "paths"}, "grant")
        kind = text(fields["kind"], "grant.kind")
        if kind not in GRANT_KINDS:
            raise LogError(f"grant.kind {kind} is not a kind this package reads")
        paths = texts(fields["paths"], "grant.paths")
        if (kind == "repository") != bool(paths):
            raise LogError("grant.paths is required for a repository grant and only for one")
        return Grant(text(fields["source_id"], "grant.source_id"), kind, paths)


def covers(paths: tuple[str, ...], path: str) -> bool:
    """The host's grant rule: a path ending in / covers what is under it."""
    return any(path.startswith(granted) if granted.endswith("/") else path == granted for granted in paths)


def grants_of_binding(binding: dict) -> tuple[Grant, ...]:
    """The grants a session reads. The host checks the grant itself; the
    package keeps the source ids, kinds and paths it lists requests for."""
    records = binding.get("records")
    if not isinstance(records, list) or not records:
        raise InvalidBinding("binding.records must name at least one grant")
    grants = []
    for record in records:
        if not isinstance(record, dict) or not isinstance(record.get("source_id"), str):
            raise InvalidBinding("each binding.records entry needs a source_id")
        match record.get("kind"):
            case "board":
                grants.append(Grant(record["source_id"], "board", ()))
            case "repository":
                paths = record.get("paths")
                if not isinstance(paths, list) or not paths or not all(isinstance(p, str) and p for p in paths):
                    raise InvalidBinding(f"repository grant {record['source_id']} needs paths")
                grants.append(Grant(record["source_id"], "repository", tuple(paths)))
            case "wiki" | "github_pulls":
                grants.append(Grant(record["source_id"], record["kind"], ()))
            case other:
                raise InvalidBinding(f"grant kind {other!r} is not one this package reads")
    if len({grant.source_id for grant in grants}) != len(grants):
        raise InvalidBinding("binding.records names a source twice")
    return tuple(grants)


def since_of_binding(binding: dict) -> float:
    """binding.since: the Unix time, in seconds, a first session reads from
    while no earlier session has moved the cursor. The lesson always reads it;
    a quiz reads it when it follows a lesson."""
    since = binding.get("since")
    problem = InvalidBinding("binding.since must be the Unix time, in seconds, the first session reads from")
    if isinstance(since, bool) or not isinstance(since, (int, float)):
        raise problem
    try:
        seconds = float(since)
    except OverflowError as error:
        raise problem from error
    if not math.isfinite(seconds) or seconds < 0:
        raise problem
    return seconds


# -- Read results, parsed where they are delivered. --------------------------
#
# The host answers a read with one of the results below. A result is parsed
# before anything of it is kept, so a kept body parses again whenever it is
# read back, and nothing after the parse reads the host's fields. What the
# listing keeps of a result holds no record text and no file content; those
# are read again from disk for a model request (#44537).

@dataclass(frozen=True, slots=True)
class Page:
    """A page of a grant's records. Of a repository page, [commits] holds each
    commit's id with the changed paths its grant covers, which name the files
    still to read; of any other page it is empty."""
    sha256: str
    next_cursor: str | None
    complete: bool
    commits: tuple[tuple[str, tuple[str, ...]], ...]


@dataclass(frozen=True, slots=True)
class File:
    """A file read at a commit."""
    sha256: str


@dataclass(frozen=True, slots=True)
class Refused:
    """The host refused the read by rule."""
    reason: str


@dataclass(frozen=True, slots=True)
class Retained:
    """A result too large for the frame, which the host keeps to be read in
    pieces."""
    source_id: str | None
    sha256: str
    size: int


@dataclass(frozen=True, slots=True)
class Piece:
    """One piece of a retained result."""
    offset: int
    next_offset: int
    eof: bool


Answer = Union[Page, File, Refused]  # what a read comes to
ReadResult = Union[Page, File, Refused, Retained, Piece]  # what one delivered result is


def _object(value: object, label: str) -> dict[str, object]:
    if not isinstance(value, dict):
        raise InvalidResult(f"{label} is not an object")
    return cast("dict[str, object]", value)


def _string(fields: dict[str, object], key: str, label: str) -> str:
    value = fields.get(key)
    if not isinstance(value, str):
        raise InvalidResult(f"{label} has no string {key}")
    return value


def _nullable_string(fields: dict[str, object], key: str, label: str) -> str | None:
    if key not in fields:
        raise InvalidResult(f"{label} has no {key}")
    value = fields[key]
    if value is not None and not isinstance(value, str):
        raise InvalidResult(f"{label} has a {key} that is neither a string nor null")
    return value


def _integer(fields: dict[str, object], key: str, label: str) -> int:
    value = fields.get(key)
    if isinstance(value, bool) or not isinstance(value, int):
        raise InvalidResult(f"{label} has no integer {key}")
    return value


def _number(fields: dict[str, object], key: str, label: str) -> int | float:
    value = fields.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise InvalidResult(f"{label} has no number {key}")
    return value


def _flag(fields: dict[str, object], key: str, label: str) -> bool:
    value = fields.get(key)
    if not isinstance(value, bool):
        raise InvalidResult(f"{label} has no boolean {key}")
    return value


def _array(fields: dict[str, object], key: str, label: str) -> list[object]:
    value = fields.get(key)
    if not isinstance(value, list):
        raise InvalidResult(f"{label} has no array {key}")
    return cast("list[object]", value)


def _strings(fields: dict[str, object], key: str, label: str) -> tuple[str, ...]:
    out: list[str] = []
    for item in _array(fields, key, label):
        if not isinstance(item, str):
            raise InvalidResult(f"{label} has a {key} entry that is not a string")
        out.append(item)
    return tuple(out)


def _cite(pin: Pin) -> str:
    """The pin of a record the host named, as the log will read it back. A
    record this package could not cite later is refused now, while it is
    still a result the host keeps."""
    text = pin_text(pin)
    try:
        parse_pin(pin_kind(pin), text)
    except LogError as error:
        raise InvalidResult(f"the host named a record this package cannot cite: {error}") from error
    return text


def _entry(pin: Pin, source_id: str, sha256: str, author: str | None, at: int | float | str | None,
           title: str, text: str) -> dict:
    """One record a model output may cite."""
    return {"kind": pin_kind(pin), "source_id": source_id, "pin": _cite(pin), "sha256": sha256,
            "author": author, "at": at, "title": title, "text": text}


def _records_of(grant: Grant, source_id: str, sha256: str, value: object) -> list[dict]:
    """The citable records one host record holds. The grant a read names says
    what its records are. A pull request gives itself, each review that says
    something, and each review comment."""
    record = _object(value, "a record")

    def entry(pin: Pin, author: str | None, at: int | float | str | None, title: str, text: str) -> dict:
        return _entry(pin, source_id, sha256, author, at, title, text)

    match grant.kind, record.get("kind"):
        case "board", "post":
            label = "a post"
            return [entry(BoardPostPin(_string(record, "id", label)), _string(record, "author", label),
                          _number(record, "created_at", label), _string(record, "title", label),
                          _string(record, "body", label))]
        case "board", "comment":
            label = "a comment"
            return [entry(BoardCommentPin(_string(record, "post_id", label), _string(record, "id", label)),
                          _string(record, "author", label), _number(record, "created_at", label), "",
                          _string(record, "body", label))]
        case "repository", "commit":
            label = "a commit"
            return [entry(CommitPin(_string(record, "sha", label)), _string(record, "author", label),
                          _integer(record, "committed_at", label), _string(record, "subject", label),
                          _string(record, "body", label))]
        case "wiki", "page":
            label = "a wiki page"
            return [entry(WikiPagePin(_string(record, "name", label), _integer(record, "revision", label)),
                          _string(record, "author", label), 0, _string(record, "title", label),
                          _string(record, "body", label))]
        case "github_pulls", "pull_request":
            label = "a pull request"
            number = _integer(record, "number", label)
            said = [entry(PrPin(number, _string(record, "merge_commit", label)),
                          _nullable_string(record, "author", label), _string(record, "merged_at", label),
                          _string(record, "title", label), _string(record, "body", label))]
            comments: list[dict] = []
            for item in _array(record, "reviews", label):
                review = _object(item, "a review")
                review_id = _integer(review, "id", "a review")
                author = _nullable_string(review, "author", "a review")
                submitted_at = _nullable_string(review, "submitted_at", "a review")
                body = _string(review, "body", "a review")
                if body.strip():
                    said.append(entry(PrReviewPin(number, review_id), author, submitted_at, "", body))
                for raw in _array(review, "comments", "a review"):
                    comment = _object(raw, "a review comment")
                    comments.append(entry(PrCommentPin(number, _integer(comment, "id", "a review comment")),
                                          _nullable_string(comment, "author", "a review comment"),
                                          _string(comment, "created_at", "a review comment"), "",
                                          _string(comment, "body", "a review comment")))
            return said + comments
        case kind, other:
            raise InvalidResult(f"a {kind} page holds a record of kind {other!r}")


def _changed(grant: Grant, value: object) -> tuple[str, tuple[str, ...]]:
    """A commit's id with the changed paths the grant covers."""
    record = _object(value, "a record")
    return (_string(record, "sha", "a commit"),
            tuple(path for path in _strings(record, "paths", "a commit") if covers(grant.paths, path)))


def _page(fields: dict[str, object], grant: Grant) -> tuple[Page, list[dict]]:
    label = "a page"
    source_id, sha256 = _string(fields, "source_id", label), _string(fields, "sha256", label)
    held = _array(fields, "records", label)
    material = [entry for record in held for entry in _records_of(grant, source_id, sha256, record)]
    commits = tuple(_changed(grant, record) for record in held) if grant.kind == "repository" else ()
    return Page(sha256, _nullable_string(fields, "next_cursor", label), _flag(fields, "complete", label),
                commits), material


def _file(fields: dict[str, object]) -> tuple[File, list[dict]]:
    label = "a file"
    source_id, sha256 = _string(fields, "source_id", label), _string(fields, "sha256", label)
    pin = RepoFilePin(_string(fields, "commit", label), _string(fields, "path", label))
    content = _string(fields, "content", label)
    match _string(fields, "encoding", label):
        case "utf-8":
            return File(sha256), [_entry(pin, source_id, sha256, "", 0, "", content)]
        case "base64":
            return File(sha256), []
        case other:
            raise InvalidResult(f"a file is encoded as {other!r}")


def _retained(fields: dict[str, object]) -> Retained:
    label = "a result too large for the frame"
    return Retained(_nullable_string(fields, "source_id", label), _string(fields, "retained_sha256", label),
                    _integer(fields, "bytes", label))


def _piece(fields: dict[str, object]) -> tuple[Piece, bytes]:
    """A piece and the bytes it carries."""
    label = "a result piece"
    if _string(fields, "encoding", label) != "base64":
        raise InvalidResult("a result piece is not base64")
    try:
        data = base64.b64decode(_string(fields, "content", label), validate=True)
    except ValueError as error:
        raise InvalidResult(f"a result piece is not base64: {error}") from error
    offset, next_offset = _integer(fields, "offset", label), _integer(fields, "next_offset", label)
    if next_offset != offset + len(data):
        raise InvalidResult("a result piece does not end at its next_offset")
    return Piece(offset, next_offset, _flag(fields, "eof", label)), data


def parse_result(request: dict, result: object, grants: tuple[Grant, ...]) -> tuple[ReadResult, list[dict]]:
    """A delivered result of one of the package's reads: what the listing
    keeps of it, and the records it holds that a model output may cite, in
    the order read. A result of another shape is not one this package can
    consume; it is refused here, before anything of it is kept."""
    grant = next((grant for grant in grants if grant.source_id == request["source_id"]), None)
    if grant is None:
        raise InvalidResult(f"a read of {request['source_id']}, which the session does not grant")
    fields = _object(result, "a read result")
    match request["kind"], fields.get("status"):
        case "read_records", "records":
            return _page(fields, grant)
        case "read_file", "file":
            return _file(fields)
        case ("read_records" | "read_file"), "result_exceeds_frame":
            return _retained(fields), []
        case "read_result", "result_chunk":
            return _piece(fields)[0], []
        case ("read_records" | "read_file" | "read_result"), "not_allowed":
            return Refused(_string(fields, "reason", "a refusal")), []
        case kind, status:
            raise InvalidResult(f"{kind} cannot end as {status}")


def _whole(request: dict, retained: Retained, pieces: list[object],
           grants: tuple[Grant, ...]) -> tuple[Answer, list[dict]]:
    """What a read that came back in pieces comes to: the original result put
    together, checked against its digest and parsed as the read's own."""
    data = b""
    for value in pieces:
        piece, part = _piece(_object(value, "a result piece"))
        if piece.offset != len(data):
            raise InvalidResult("result pieces do not follow each other")
        data += part
    if len(data) != retained.size or hashlib.sha256(data).hexdigest() != retained.sha256:
        raise InvalidResult("the result put together does not match its digest")
    try:
        original = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise InvalidResult(f"the result put together is not JSON: {error}") from error
    result, material = parse_result(request, original, grants)
    match result:
        case Page() | File() | Refused():
            return result, material
        case Retained() | Piece():
            raise InvalidResult("the result put together is not an answer to its read")


@dataclass(frozen=True, slots=True)
class Read:
    """One read request of a session with its result: the result the host
    gave, or the one its pieces put together once the last came, or None while
    pieces are missing. [digests] names the kept bodies it was read from, the
    marker first."""
    request: dict
    retained: Retained | None
    pieces: tuple[Piece, ...]
    result: Answer | None
    digests: tuple[str, ...]


# -- Material a model output may cite. --------------------------------------

def cited_record(cited: dict, input_material: list[dict]) -> dict | None:
    """The record of [input_material] that [cited] names by kind, grant and
    pin, or None when the request did not carry it."""
    return next((m for m in input_material if (m["kind"], m["source_id"], m["pin"])
                 == (cited["kind"], cited["source_id"], cited["pin"])), None)


def holds_quote(record: dict, quote: str) -> bool:
    """Whether the words are in the record's text or title as they stand."""
    return quote in record["text"] or quote in record["title"]


# -- Where reading goes next. ------------------------------------------------

def last_cursor(grant: Grant, earlier: list[tuple[bool, list[Read]]]) -> str | None:
    """Where the last earlier session that moves the cursor stopped reading
    this grant. [earlier] holds each earlier session's reads, oldest first,
    with whether that session moves the cursor; the package says which of
    its sessions do. Material of a session that does not is read again.

    A cursor the host refused for this grant (the branch no longer reaches
    it, or the grant now names another repository) is skipped, so the next
    session starts from the cursor before it, or from none."""
    refused = {(r.request["source_id"], r.request["after"])
               for _, session_reads in earlier for r in session_reads
               if r.request["kind"] == "read_records" and isinstance(r.result, Refused)}
    for moves, session_reads in reversed(earlier):
        if not moves:
            continue
        pages = [r.result for r in session_reads if r.request["kind"] == "read_records"
                 and r.request["source_id"] == grant.source_id and isinstance(r.result, Page)]
        if pages and (grant.source_id, pages[-1].next_cursor) not in refused:
            return pages[-1].next_cursor
    return None


def next_read(request_id: str, grants: tuple[Grant, ...], session_reads: list[Read],
              start: Callable[[Grant], dict]) -> dict | None:
    """The session's next read request, or None when everything is read: the
    next piece of a result that came back too large, then each grant's next
    page, then each file a repository grant covers at a commit read.
    [start] gives the fields that say where a grant's first page begins:
    after, and since when there is no cursor."""
    for read in session_reads:
        if read.retained is not None and read.result is None:
            offset = read.pieces[-1].next_offset if read.pieces else 0
            return {"kind": "read_result", "request_id": request_id,
                    "original_request_id": read.request["request_id"],
                    "source_id": read.retained.source_id, "sha256": read.retained.sha256, "offset": offset}
    for grant in grants:
        # Every read still in pieces was asked for above, so each page read
        # is answered: a refusal ends the session before it lists again.
        pages = [r.result for r in session_reads if r.request["kind"] == "read_records"
                 and r.request["source_id"] == grant.source_id and isinstance(r.result, Page)]
        if not pages:
            return {"kind": "read_records", "request_id": request_id, "source_id": grant.source_id} | start(grant)
        if not pages[-1].complete:
            return {"kind": "read_records", "request_id": request_id, "source_id": grant.source_id,
                    "after": pages[-1].next_cursor}
        if grant.kind == "repository":
            done = {(r.request["commit"], r.request["path"]) for r in session_reads
                    if r.request["kind"] == "read_file" and r.request["source_id"] == grant.source_id}
            for page in pages:
                for commit, paths in page.commits:
                    for path in paths:
                        if (commit, path) not in done:
                            return {"kind": "read_file", "request_id": request_id, "source_id": grant.source_id,
                                    "commit": commit, "path": path}
    return None


# -- The files. ---------------------------------------------------------------

def _fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _make_directory(path: Path) -> None:
    """Creates the folder and any missing parents, syncing each parent that
    gained an entry, so a new folder survives a crash with its contents."""
    if path.is_dir():
        return
    _make_directory(path.parent)
    path.mkdir()
    _fsync_directory(path.parent)


Event = TypeVar("Event")


def _line(event: Event, to_json: Callable[[Event], dict]) -> bytes:
    """The bytes one event is written as."""
    return (json.dumps(to_json(event), ensure_ascii=False, allow_nan=False, separators=(",", ":"))
            + "\n").encode("utf-8")


def unreadable(event: Event, to_json: Callable[[Event], dict], of_json: Callable[[Any], Event]) -> str | None:
    """Why this event would not read back as written, or None. It is checked
    through the bytes it would be written as: text UTF-8 cannot hold, such as
    a lone surrogate, never reaches the file."""
    try:
        if of_json(json.loads(_line(event, to_json).decode("utf-8"))) == event:
            return None
        return f"{type(event).__name__} reads back differently"
    except UnicodeEncodeError:
        return f"{type(event).__name__} holds text UTF-8 cannot encode"
    except (LogError, ValueError, TypeError) as error:
        return str(error)


class Log(Generic[Event]):
    """The append-only log at ``<directory>/log.jsonl``. [to_json] and
    [of_json] are the package's event codec."""

    def __init__(self, directory: Path, to_json: Callable[[Event], dict], of_json: Callable[[Any], Event]):
        self.directory = directory
        self.path = directory / "log.jsonl"
        self._to_json = to_json
        self._of_json = of_json
        # Lines already decoded, their byte length and the last of them.
        self._events: list[Event] = []
        self._complete = 0
        self._last_line = b""

    def _read(self) -> tuple[list[Event], int]:
        """Events and the byte length of the complete lines.

        Lines decoded before are kept and only the bytes after them are read:
        the worker is the log's only writer, so those bytes do not change. A
        shorter file, or a last line that is no longer where it was, means
        they did, and the whole file is decoded again."""
        try:
            with open(self.path, "rb") as handle:
                start = self._complete
                if start:
                    size = os.fstat(handle.fileno()).st_size
                    handle.seek(start - len(self._last_line) - 1)
                    if size < start or handle.read(len(self._last_line) + 1) != self._last_line + b"\n":
                        self._events, self._complete, self._last_line, start = [], 0, b"", 0
                handle.seek(start)
                data = handle.read()
        except FileNotFoundError:
            self._events, self._complete, self._last_line = [], 0, b""
            return [], 0
        complete = data.rfind(b"\n") + 1
        lines = data[:complete].split(b"\n")[:-1]
        events: list[Event] = []
        for number, line in enumerate(lines, start=len(self._events) + 1):
            try:
                events.append(self._of_json(json.loads(line.decode("utf-8"))))
            except (UnicodeDecodeError, json.JSONDecodeError) as error:
                raise LogError(f"line {number} of {self.path} is not JSON: {error}") from error
            except LogError as error:
                raise LogError(f"line {number} of {self.path}: {error}") from error
        if lines:
            self._events = self._events + events
            self._complete = start + complete
            self._last_line = lines[-1]
        return list(self._events), self._complete

    def read(self) -> list[Event]:
        return self._read()[0]

    def append(self, events: list[Event]) -> None:
        """Appends after the history decodes; the lines are synced before return."""
        if not events:
            return
        # A line that would not read back would make the whole log unreadable.
        for event in events:
            problem = unreadable(event, self._to_json, self._of_json)
            if problem is not None:
                raise LogError(problem)
        _, complete = self._read()
        payload = b"".join(_line(event, self._to_json) for event in events)
        created = not self.path.exists()
        _make_directory(self.directory)
        descriptor = os.open(self.path, os.O_WRONLY | os.O_CREAT, 0o600)
        try:
            os.ftruncate(descriptor, complete)  # cut off an unfinished write
            os.lseek(descriptor, complete, os.SEEK_SET)
            written = 0
            while written < len(payload):
                written += os.write(descriptor, payload[written:])
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        if created:
            _fsync_directory(self.directory)


class Blobs:
    """Bodies the log names by digest: the package's exact requests and the
    pages it read. Written whole before the event that names them."""

    def __init__(self, directory: Path):
        self.directory = directory

    def path(self, digest: str) -> Path:
        if not digest or any(c not in _HEX for c in digest):
            raise LogError(f"{digest!r} is not a digest")
        return self.directory / f"{digest}.json"

    def write(self, digest: str, value: Any) -> None:
        target = self.path(digest)
        if target.exists():
            return
        _make_directory(self.directory)
        temporary = target.with_suffix(".tmp")
        with open(temporary, "wb") as handle:
            handle.write(json.dumps(value, ensure_ascii=False, allow_nan=False, sort_keys=True).encode("utf-8"))
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, target)
        _fsync_directory(self.directory)

    def read(self, digest: str) -> Any:
        try:
            return json.loads(self.path(digest).read_bytes().decode("utf-8"))
        except FileNotFoundError as error:
            raise LogError(f"the log names {digest} and it is not kept") from error
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise LogError(f"{digest} is not JSON: {error}") from error


class Pages:
    """The kept reads of a package as its listing uses them: each request
    with what the listing keeps of its result (see parse_result). Only that
    stays in memory, so what the worker holds does not grow with what its
    sessions read (#44537). The kept bodies on disk stay whole, and are named
    by their digest, so what is derived from one never goes stale. What a
    body parses to depends on the grant it is read under, so it is kept per
    grant."""

    def __init__(self, blobs: Blobs):
        self.blobs = blobs
        self._kept: dict[tuple[str, Grant | None], tuple[dict, ReadResult]] = {}
        self._wholes: dict[tuple[str, Grant | None], Answer] = {}
        self._sources: dict[str, object] = {}

    @staticmethod
    def _grant(grants: tuple[Grant, ...], source: object) -> Grant | None:
        return next((grant for grant in grants if grant.source_id == source), None)

    def _parsed(self, digest: str, grants: tuple[Grant, ...]) -> tuple[dict, ReadResult, list[dict]]:
        """A kept body parsed again. It parsed when it was delivered, so one
        that does not now is not this package's history."""
        entry = self.blobs.read(digest)
        try:
            result, material = parse_result(entry["request"], entry["result"], grants)
        except InvalidResult as error:
            raise LogError(f"the kept read {digest} does not parse: {error}") from error
        return entry["request"], result, material

    def _read(self, digest: str, grants: tuple[Grant, ...]) -> tuple[dict, ReadResult]:
        if digest in self._sources:
            cached = self._kept.get((digest, self._grant(grants, self._sources[digest])))
            if cached is not None:
                return cached
        request, result, _ = self._parsed(digest, grants)
        self._sources[digest] = request["source_id"]
        self._kept[(digest, self._grant(grants, request["source_id"]))] = (request, result)
        return request, result

    def _assembled(self, request: dict, retained: Retained, pieces: tuple[str, ...],
                   grants: tuple[Grant, ...]) -> Answer:
        """What a read whose pieces have all come comes to. The pieces are
        read again from disk once and dropped; the result is kept under the
        digest of the whole. A whole that does not parse is refused with the
        delivery of its last piece."""
        key = (retained.sha256, self._grant(grants, request["source_id"]))
        cached = self._wholes.get(key)
        if cached is None:
            cached, _ = _whole(request, retained, [self.blobs.read(digest)["result"] for digest in pieces], grants)
            self._wholes[key] = cached
        return cached

    def summaries(self, digests: list[str], grants: tuple[Grant, ...]) -> list[Read]:
        """A session's reads, in the order kept, each with what the listing
        keeps of its result. A piece belongs to the read in pieces it names."""
        started: list[tuple[str, dict, Answer | Retained]] = []
        pieces: dict[str, list[tuple[str, Piece]]] = {}
        for digest in digests:
            request, result = self._read(digest, grants)
            match result:
                case Piece():
                    taken = pieces.get(request["original_request_id"])
                    if taken is None:
                        raise LogError(f"a piece of {request['original_request_id']}, which was not read in pieces")
                    taken.append((digest, result))
                case Retained():
                    pieces[request["request_id"]] = []
                    started.append((digest, request, result))
                case Page() | File() | Refused():
                    started.append((digest, request, result))
        out: list[Read] = []
        for digest, request, result in started:
            match result:
                case Retained():
                    taken = pieces[request["request_id"]]
                    parts = tuple(piece for _, piece in taken)
                    later = tuple(key for key, _ in taken)
                    whole = self._assembled(request, result, later, grants) if parts and parts[-1].eof else None
                    out.append(Read(request, result, parts, whole, (digest, *later)))
                case Page() | File() | Refused():
                    out.append(Read(request, None, (), result, (digest,)))
        return out

    def material(self, read: Read, grants: tuple[Grant, ...]) -> list[dict]:
        """The records [read] holds that a model output may cite, read again
        from disk. A refusal holds none, and neither does a read whose
        pieces have not all come."""
        if not isinstance(read.result, (Page, File)):
            return []
        if read.retained is None:
            return self._parsed(read.digests[0], grants)[2]
        pieces = [self.blobs.read(digest)["result"] for digest in read.digests[1:]]
        return _whole(read.request, read.retained, pieces, grants)[1]
