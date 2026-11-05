# pyright: strict
"""Turn the relay's log into per-window summaries for the TUI request probe.

Pure functions: a window counts the requests that started in it and the
server-sent events that arrived in it.
"""
from collections import Counter
from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass

import tui_request_log as record

NO_ANSWER = 'none'
STILL_OPEN = 'open'
TOP_REQUESTS = 5


@dataclass(frozen=True, slots=True)
class Window:
    label: str
    keys: str
    start: float
    end: float
    finished: bool


@dataclass(frozen=True, slots=True)
class Index:
    sent: Mapping[int, record.Sent]
    answered: Mapping[int, record.Answered]
    ended: Mapping[int, record.Ended]
    arrived: tuple[record.Arrived, ...]
    faults: tuple[tuple[float, str], ...]


def request_key(sent: record.Sent) -> str:
    query = '&'.join(sent.query)
    return f'{sent.method} {sent.path}' + (f'?{query}' if query else '')


def index_entries(entries: Iterable[record.Entry]) -> Index:
    sent: dict[int, record.Sent] = {}
    answered: dict[int, record.Answered] = {}
    ended: dict[int, record.Ended] = {}
    arrived: list[record.Arrived] = []
    faults: list[tuple[float, str]] = []
    for entry in entries:
        match entry:
            case record.Sent():
                sent[entry.exchange] = entry
            case record.Answered():
                answered[entry.exchange] = entry
            case record.Arrived():
                arrived.append(entry)
            case record.Ended():
                ended[entry.exchange] = entry
            case record.Fault():
                faults.append((entry.t, f'{entry.side.value}: {entry.detail}'))
            case record.Failed():
                faults.append((entry.t, f'relay: {entry.detail}'))
    return Index(sent, answered, ended, tuple(arrived), tuple(faults))


@dataclass(frozen=True, slots=True)
class RequestRow:
    request: str
    count: int
    streams: int
    statuses: dict[str, int]
    endings: dict[str, int]
    request_bytes: int
    response_bytes: int


@dataclass(frozen=True, slots=True)
class EventRow:
    event: str
    count: int
    bytes: int


@dataclass(frozen=True, slots=True)
class WindowSummary:
    label: str
    keys: str
    finished: bool
    start_s: float
    seconds: float
    requests: int
    requests_per_s: float | None
    request_bytes: int
    response_bytes: int
    events: int
    events_per_s: float | None
    event_bytes: int
    faults: int
    by_request: tuple[RequestRow, ...]
    by_event: tuple[EventRow, ...]


@dataclass(frozen=True, slots=True)
class StreamRow:
    request: str
    status: int
    opened_s: float
    ended_s: float | None
    ending: str
    events: int


@dataclass(frozen=True, slots=True)
class FaultRow:
    t_s: float
    detail: str


def tally(values: Iterable[str]) -> dict[str, int]:
    return dict(sorted(Counter(values).items()))


def rate(count: int, seconds: float) -> float | None:
    return count / seconds if seconds > 0 else None


def request_row(key: str, members: Sequence[record.Sent], index: Index) -> RequestRow:
    """One request shape in a window. Endings are counted even when they came later,
    and a stream's bytes are left to its events."""
    answers = [index.answered.get(sent.exchange) for sent in members]
    endings = [index.ended.get(sent.exchange) for sent in members]
    return RequestRow(
        request=key,
        count=len(members),
        streams=sum(1 for answer in answers if answer is not None and answer.stream),
        statuses=tally(NO_ANSWER if answer is None else str(answer.status) for answer in answers),
        endings=tally(STILL_OPEN if ended is None else ended.ending.value for ended in endings),
        request_bytes=sum(ended.request_bytes for ended in endings if ended is not None),
        response_bytes=sum(ended.response_bytes
                           for answer, ended in zip(answers, endings, strict=True)
                           if ended is not None and not (answer is not None and answer.stream)))


def summarize_window(index: Index, window: Window, origin: float) -> WindowSummary:
    """The requests that started in `window` and the events that arrived in it."""
    seconds = window.end - window.start
    inside = [sent for sent in index.sent.values() if window.start <= sent.t < window.end]
    groups: dict[str, list[record.Sent]] = {}
    for sent in inside:
        groups.setdefault(request_key(sent), []).append(sent)
    rows = tuple(sorted((request_row(key, members, index) for key, members in groups.items()),
                        key=lambda row: (-row.count, row.request)))
    arrived = [event for event in index.arrived if window.start <= event.t < window.end]
    named: dict[str, list[record.Arrived]] = {}
    for event in arrived:
        named.setdefault(f'{index.sent[event.exchange].path} {event.name}', []).append(event)
    events = tuple(sorted((EventRow(key, len(group), sum(event.size for event in group))
                           for key, group in named.items()),
                          key=lambda row: (-row.count, row.event)))
    return WindowSummary(
        label=window.label, keys=window.keys, finished=window.finished,
        start_s=window.start - origin, seconds=seconds,
        requests=len(inside), requests_per_s=rate(len(inside), seconds),
        request_bytes=sum(row.request_bytes for row in rows),
        response_bytes=sum(row.response_bytes for row in rows),
        events=len(arrived), events_per_s=rate(len(arrived), seconds),
        event_bytes=sum(row.bytes for row in events),
        faults=sum(1 for t, _ in index.faults if window.start <= t < window.end),
        by_request=rows, by_event=events)


def stream_rows(index: Index, origin: float) -> tuple[StreamRow, ...]:
    counts = Counter(event.exchange for event in index.arrived)
    rows: list[StreamRow] = []
    for exchange, answer in sorted(index.answered.items()):
        if not answer.stream:
            continue
        sent = index.sent[exchange]
        ended = index.ended.get(exchange)
        rows.append(StreamRow(request_key(sent), answer.status, sent.t - origin,
                              None if ended is None else ended.t - origin,
                              STILL_OPEN if ended is None else ended.ending.value,
                              counts[exchange]))
    return tuple(rows)


def per_second(value: float | None) -> str:
    return '-' if value is None else f'{value:.2f}'


def print_table(summaries: Sequence[WindowSummary]) -> None:
    print(f"{'window':<16} {'seconds':>8} {'requests':>8} {'req/s':>7} "
          f"{'resp_bytes':>11} {'events':>7} {'ev/s':>6}")
    for summary in summaries:
        print(f'{summary.label:<16} {summary.seconds:>8.2f} {summary.requests:>8} '
              f'{per_second(summary.requests_per_s):>7} {summary.response_bytes:>11} '
              f'{summary.events:>7} {per_second(summary.events_per_s):>6}')
        for row in summary.by_request[:TOP_REQUESTS]:
            print(f'    {row.count:>4}  {row.request}')
