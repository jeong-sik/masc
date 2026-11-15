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
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Generic, TypeVar, Union


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


# -- Read results, put back together. ---------------------------------------

def assemble(marker: dict, chunks: list[dict]) -> dict:
    """The original result of a read that came back in pieces."""
    data = b""
    for chunk in chunks:
        if chunk.get("offset") != len(data) or chunk.get("encoding") != "base64":
            raise InvalidResult("result pieces do not follow each other")
        try:
            data += base64.b64decode(chunk["content"], validate=True)
        except (KeyError, TypeError, ValueError) as error:
            raise InvalidResult(f"a result piece is not base64: {error}") from error
    if len(data) != marker["bytes"] or hashlib.sha256(data).hexdigest() != marker["retained_sha256"]:
        raise InvalidResult("the result put together does not match its digest")
    try:
        result = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise InvalidResult(f"the result put together is not JSON: {error}") from error
    if not isinstance(result, dict):
        raise InvalidResult("the result put together is not an object")
    return result


def _assemble_whole(item: dict) -> dict:
    return assemble(item["marker"], item["chunks"])


def reads(entries: list[tuple[str, dict]], assemble: Callable[[dict], dict] = _assemble_whole) -> list[dict]:
    """Each read request of a session with its result, or with the pieces
    received so far when it came back too large for the frame. [entries]
    pairs each kept body with its digest, and each read names the digests it
    was put together from. [assemble] gives the result of a read whose last
    piece came."""
    out: list[dict] = []
    by_request: dict[str, dict] = {}
    for key, entry in entries:
        request, result = entry["request"], entry["result"]
        if request["kind"] == "read_result":
            target = by_request.get(request["original_request_id"])
            if target is None or target["marker"] is None:
                raise LogError(f"a piece of {request['original_request_id']}, which was not read in pieces")
            target["chunks"].append(result)
            target["digests"].append(key)
            continue
        item = {"request": request, "marker": None, "chunks": [], "result": None, "digests": [key]}
        if result["status"] == "result_exceeds_frame":
            item["marker"] = result
        else:
            item["result"] = result
        out.append(item)
        by_request[request["request_id"]] = item
    for item in out:
        if item["marker"] is not None and item["chunks"] and item["chunks"][-1].get("eof") is True:
            item["result"] = assemble(item)
    return out


# -- Material a model output may cite. --------------------------------------

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


def _entry(pin: Pin, result: dict, author: Any, at: Any, title: str, text: str) -> dict:
    return {"kind": pin_kind(pin), "source_id": result["source_id"], "pin": _cite(pin),
            "sha256": result["sha256"], "author": author, "at": at, "title": title, "text": text}


def _records_of(grant: Grant, result: dict, record: dict) -> list[dict]:
    """The citable records one host record holds. A pull request gives
    itself, each review that says something, and each review comment."""
    match grant.kind, record.get("kind"):
        case "board", "post":
            return [_entry(BoardPostPin(record["id"]), result, record["author"], record["created_at"],
                           record["title"], record["body"])]
        case "board", "comment":
            return [_entry(BoardCommentPin(record["post_id"], record["id"]), result, record["author"],
                           record["created_at"], "", record["body"])]
        case "repository", "commit":
            return [_entry(CommitPin(record["sha"]), result, record["author"], record["committed_at"],
                           record["subject"], record["body"])]
        case "wiki", "page":
            return [_entry(WikiPagePin(record["name"], record["revision"]), result, record["author"], 0,
                           record["title"], record["body"])]
        case "github_pulls", "pull_request":
            number = record["number"]
            reviews = record["reviews"]
            return ([_entry(PrPin(number, record["merge_commit"]), result, record["author"], record["merged_at"],
                            record["title"], record["body"])]
                    + [_entry(PrReviewPin(number, review["id"]), result, review["author"], review["submitted_at"],
                              "", review["body"]) for review in reviews if review["body"].strip()]
                    + [_entry(PrCommentPin(number, comment["id"]), result, comment["author"],
                              comment["created_at"], "", comment["body"])
                       for review in reviews for comment in review["comments"]])
        case kind, other:
            raise InvalidResult(f"a {kind} page holds a record of kind {other!r}")


def material(session_reads: list[dict], grants: dict[str, Grant]) -> list[dict]:
    """The records a request may cite, in the order read: what each grant's
    pages hold, and the text files read at a commit. The grant a read names
    says what its records are."""
    out: list[dict] = []
    for read in session_reads:
        request, result = read["request"], read["result"]
        grant = grants.get(request["source_id"])
        if grant is None:
            raise InvalidResult(f"a read of {request['source_id']}, which the session does not grant")
        if request["kind"] == "read_records" and result["status"] == "records":
            out += [entry for record in result["records"] for entry in _records_of(grant, result, record)]
        elif request["kind"] == "read_file" and result["status"] == "file" and result["encoding"] == "utf-8":
            out.append(_entry(RepoFilePin(result["commit"], result["path"]), result, "", 0, "", result["content"]))
    return out


def cited_record(cited: dict, input_material: list[dict]) -> dict | None:
    """The record of [input_material] that [cited] names by kind, grant and
    pin, or None when the request did not carry it."""
    return next((m for m in input_material if (m["kind"], m["source_id"], m["pin"])
                 == (cited["kind"], cited["source_id"], cited["pin"])), None)


def holds_quote(record: dict, quote: str) -> bool:
    """Whether the words are in the record's text or title as they stand."""
    return quote in record["text"] or quote in record["title"]


def summary(request: dict, result: dict, paths: tuple[str, ...]) -> dict:
    """What the listing uses of a result: its status and where reading goes
    next. Board records and file contents are left out; they are read again
    from disk only for a model request. A repository page keeps, of each
    commit, its id and the changed paths the grant covers [paths], which
    name the files still to read."""
    match request["kind"], result["status"]:
        case "read_records", "records":
            if paths:
                return result | {"records": [{"sha": record["sha"],
                                              "paths": [path for path in record["paths"] if covers(paths, path)]}
                                             for record in result["records"]]}
            return {key: value for key, value in result.items() if key != "records"}
        case ("read_file", "file") | ("read_result", "result_chunk"):
            return {key: value for key, value in result.items() if key != "content"}
        case _:
            return result


# -- Where reading goes next. ------------------------------------------------

def last_cursor(grant: Grant, earlier: list[tuple[bool, list[dict]]]) -> str | None:
    """Where the last earlier session that moves the cursor stopped reading
    this grant. [earlier] holds each earlier session's reads, oldest first,
    with whether that session moves the cursor; the package says which of
    its sessions do. Material of a session that does not is read again.

    A cursor the host refused for this grant (the branch no longer reaches
    it, or the grant now names another repository) is skipped, so the next
    session starts from the cursor before it, or from none."""
    refused = {(r["request"]["source_id"], r["request"]["after"])
               for _, session_reads in earlier for r in session_reads
               if r["request"]["kind"] == "read_records" and r["result"] is not None
               and r["result"]["status"] == "not_allowed"}
    for moves, session_reads in reversed(earlier):
        if not moves:
            continue
        pages = [r for r in session_reads if r["request"]["kind"] == "read_records"
                 and r["request"]["source_id"] == grant.source_id and r["result"] is not None
                 and r["result"]["status"] == "records"]
        if pages and (grant.source_id, pages[-1]["result"]["next_cursor"]) not in refused:
            return pages[-1]["result"]["next_cursor"]
    return None


def next_read(request_id: str, grants: tuple[Grant, ...], session_reads: list[dict],
              start: Callable[[Grant], dict]) -> dict | None:
    """The session's next read request, or None when everything is read: the
    next piece of a result that came back too large, then each grant's next
    page, then each file a repository grant covers at a commit read.
    [start] gives the fields that say where a grant's first page begins:
    after, and since when there is no cursor."""
    for read in session_reads:
        if read["marker"] is not None and read["result"] is None:
            offset = read["chunks"][-1]["next_offset"] if read["chunks"] else 0
            return {"kind": "read_result", "request_id": request_id,
                    "original_request_id": read["request"]["request_id"],
                    "source_id": read["marker"]["source_id"], "sha256": read["marker"]["retained_sha256"],
                    "offset": offset}
    for grant in grants:
        pages = [r for r in session_reads if r["request"]["kind"] == "read_records"
                 and r["request"]["source_id"] == grant.source_id]
        if not pages:
            return {"kind": "read_records", "request_id": request_id, "source_id": grant.source_id} | start(grant)
        if not pages[-1]["result"]["complete"]:
            return {"kind": "read_records", "request_id": request_id, "source_id": grant.source_id,
                    "after": pages[-1]["result"]["next_cursor"]}
        if grant.kind == "repository":
            done = {(r["request"]["commit"], r["request"]["path"]) for r in session_reads
                    if r["request"]["kind"] == "read_file" and r["request"]["source_id"] == grant.source_id}
            for page in pages:
                for record in page["result"]["records"]:
                    for path in record["paths"]:
                        if covers(grant.paths, path) and (record["sha"], path) not in done:
                            return {"kind": "read_file", "request_id": request_id, "source_id": grant.source_id,
                                    "commit": record["sha"], "path": path}
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
    with a summary of its result (see summary()). Only summaries stay in
    memory, so what the worker holds does not grow with what its sessions
    read (#44537). The kept bodies on disk stay whole, and are named by
    their digest, so what is derived from one never goes stale."""

    def __init__(self, blobs: Blobs):
        self.blobs = blobs
        self._entries: dict[tuple[str, tuple[str, ...]], dict] = {}
        self._summaries: dict[tuple[str, tuple[str, ...]], dict] = {}
        self._sources: dict[str, str | None] = {}

    @staticmethod
    def _paths(grants: dict[str, Grant], source: Any) -> tuple[str, ...]:
        grant = grants.get(source) if isinstance(source, str) else None
        return grant.paths if grant is not None and grant.kind == "repository" else ()

    def _entry(self, digest: str, grants: dict[str, Grant]) -> dict:
        source = self._sources.get(digest)
        paths = self._paths(grants, source)
        cached = self._entries.get((digest, paths))
        if cached is not None:
            return cached
        entry = self.blobs.read(digest)
        source = entry["request"].get("source_id")
        self._sources[digest] = source
        paths = self._paths(grants, source)
        self._entries[(digest, paths)] = {"request": entry["request"],
                                          "result": summary(entry["request"], entry["result"], paths)}
        return self._entries[(digest, paths)]

    def _assembled(self, grants: dict[str, Grant], item: dict) -> dict:
        """The summary of a read whose pieces have all come. The pieces are
        read again from disk once and dropped; the summary is kept under the
        digest of the whole result."""
        paths = self._paths(grants, item["request"].get("source_id"))
        key = (item["marker"]["retained_sha256"], paths)
        cached = self._summaries.get(key)
        if cached is None:
            pieces = [self.blobs.read(digest)["result"] for digest in item["digests"][1:]]
            cached = summary(item["request"], assemble(item["marker"], pieces), paths)
            self._summaries[key] = cached
        return cached

    def summaries(self, digests: list[str], grants: tuple[Grant, ...]) -> list[dict]:
        """A session's reads, in the order kept, each with the summary of its
        result."""
        by_source = {grant.source_id: grant for grant in grants}
        return reads([(digest, self._entry(digest, by_source)) for digest in digests],
                     lambda item: self._assembled(by_source, item))

    def whole(self, read: dict) -> list[dict]:
        """One read with its whole result, taken again from disk."""
        return reads([(digest, self.blobs.read(digest)) for digest in read["digests"]])
