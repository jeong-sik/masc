#!/usr/bin/env python3
# pyright: strict
"""Count hard-quota refusals whose reset another refusal had already noted.

A provider that refuses a call with a stated reset has that reset noted in the
process's quota table. A Keeper waits until that reset only after its own turn
failed (`the next dispatch waits ...` line). Before that, its walk reads the
table for ordering only and still calls a resting candidate when nothing else
is left. This script reads the server's system log and judges each hard-quota
wait of a heartbeat turn: had a refusal on the same provider row already noted
the same or a later release before this Keeper dispatched?

- `known_from_another_keeper`: another Keeper's refusal in the same server
  process noted it first.
- `known_from_itself`: only this Keeper's own earlier refusal in the same
  process noted it.
- `known_before_restart`: only an earlier process noted it. The table lives in
  memory, so a restart forgets it.
- `first`: no refusal had noted it.
- `no_dispatch_mark`: the turn wrote no dispatch line under the Keeper's name,
  so the script cannot say when it dispatched. Agent Core HTTP runs log their
  start under `agent_core-<runtime>`, not the Keeper.

The provider row is the part of the runtime id before the first `.`. The
quota table keys by scope (a credential reference, client home or provider
row), and one provider row maps to one scope, so rows that share a scope are
counted apart here: the counts are lower bounds. Chat-lane turns, walk calls
that fell through to a later candidate, and lane cycles are not counted; their
lines do not name the provider row.

Inputs are the fixed-format lines the server writes:

- `<keeper>: the next dispatch waits <s>s for <runtime> to be released at <epoch>`
  (`lib/keeper/keeper_heartbeat_loop.ml`).
- `<keeper>: turn terminal (non-exhaustion error) — err=<error> runtime=<id>`
  (`lib/keeper/keeper_unified_turn_terminal_error.ml`). A hard quota renders as
  `Provider '<provider>' hard quota exhausted: ...`
  (`packages/agent_core/lib/llm_provider/error.ml`).
- `agent started agent=<name> ...` (`lib/keeper/keeper_event_bridge.ml`) and
  `<client> turn composition:` (official client runtimes) mark a dispatch.
- `<keeper>: keeper cycle FAILED runtime=...`, `... keeper cycle rested until=<t>
  waiting_on=<id> runtime=...` and `... keeper cycle <outcome> runtime_lane=...`
  end every unified turn (`lib/keeper/keeper_unified_turn.ml`,
  `lib/keeper/keeper_unified_turn_success.ml`).
- The `[Startup] retained checkpoint sweep` summary line marks a server start.

A wait takes the dispatch mark of the turn that just ended. A turn that wrote
no mark under the Keeper's name has none, even when an earlier turn did, so a
wait never pairs with an earlier turn's mark. One Keeper runs one turn at a
time, so its marks between two turn ends belong to one turn. The output names no Keeper and no provider
row, only the provider named in the error.
"""

from __future__ import annotations

import argparse
import bisect
import json
import pathlib
import re
import sys
from collections import Counter
from dataclasses import dataclass
from datetime import datetime
from typing import Literal, cast

DESCRIPTION = "Count hard-quota refusals whose reset another refusal had already noted."
WAIT = re.compile(r"the next dispatch waits \d+s for (\S+) to be released at (\d+)")
TERMINAL = "turn terminal (non-exhaustion error)"
HARD_QUOTA = re.compile(r"Provider '([^']+)' hard quota exhausted")
STARTED = "agent started"
COMPOSITION = "turn composition:"
# One of these three ends every boot's checkpoint sweep (`bin/main_eio.ml`). A
# sweep failure line shares the prefix, so the prefix alone is not a boot.
STARTUP = re.compile(r"^\[Startup\] retained checkpoint sweep(?:: removed=| raised: | skipped: )")
# The line that ends a unified turn: failed, rested, or any success outcome.
TURN_END = re.compile(
    r"^\S+: keeper cycle (?:FAILED|rested until=\d+ waiting_on=\S+) runtime=|^\S+: keeper cycle \S+ runtime_lane="
)

type Kind = Literal["restart", "started", "dispatched", "turn_end", "terminal", "wait"]
type Verdict = Literal[
    "first", "known_from_another_keeper", "known_from_itself", "known_before_restart", "no_dispatch_mark"
]


@dataclass(frozen=True, slots=True)
class Event:
    ts: str
    kind: Kind
    keeper: str | None
    provider: str | None = None
    provider_row: str | None = None
    release: int | None = None


@dataclass(frozen=True, slots=True)
class Wait:
    ts: str
    keeper: str
    provider: str
    provider_row: str
    release: int
    sent_at: str | None


@dataclass(frozen=True, slots=True)
class Noted:
    ts: str
    process: int
    keeper: str
    provider_row: str
    release: int


@dataclass(frozen=True, slots=True)
class Judged:
    wait: Wait
    process: int
    verdict: Verdict
    noted_at: str | None


def event_of_record(record: dict[str, object]) -> Event | None:
    message = record.get("message")
    ts = record.get("ts")
    if not isinstance(message, str) or not isinstance(ts, str):
        return None
    keeper_value = record.get("keeper_name")
    keeper = keeper_value if isinstance(keeper_value, str) else None
    if STARTUP.match(message):
        return Event(ts, "restart", None)
    if keeper is None:
        return None
    if STARTED in message:
        return Event(ts, "started", keeper)
    if COMPOSITION in message:
        return Event(ts, "dispatched", keeper)
    if TURN_END.match(message):
        return Event(ts, "turn_end", keeper)
    if TERMINAL in message:
        quota = HARD_QUOTA.search(message)
        return Event(ts, "terminal", keeper, provider=quota.group(1) if quota else None)
    found = WAIT.search(message)
    if found is not None:
        row = found.group(1).split(".", 1)[0]
        return Event(ts, "wait", keeper, provider_row=row, release=int(found.group(2)))
    return None


def read_events(paths: list[pathlib.Path]) -> list[Event]:
    events: list[Event] = []
    for path in paths:
        with path.open(encoding="utf-8") as handle:
            for line in handle:
                try:
                    record: object = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(record, dict):
                    event = event_of_record(cast(dict[str, object], record))
                    if event is not None:
                        events.append(event)
    return sorted(events, key=lambda event: event.ts)


def until(events: list[Event], cutoff: str | None) -> list[Event]:
    """Drop events at or after `cutoff`, an ISO UTC time like the log's `ts`."""
    return events if cutoff is None else [event for event in events if event.ts < cutoff]


def hard_quota_waits(events: list[Event]) -> tuple[list[str], list[Wait]]:
    """Server starts, and every wait whose turn ended on a hard quota. A wait
    takes the dispatch mark of the turn that ended before it and the terminal
    line its Keeper wrote since its previous wait, then consumes them."""
    restarts: list[str] = []
    waits: list[Wait] = []
    sent: dict[str, str] = {}
    ended_turn_mark: dict[str, str | None] = {}
    hard_quota_provider: dict[str, str] = {}
    for event in events:
        keeper = event.keeper
        match event.kind:
            case "restart":
                restarts.append(event.ts)
            case "started" | "dispatched":
                if keeper is not None:
                    sent[keeper] = event.ts
            case "turn_end":
                if keeper is not None:
                    ended_turn_mark[keeper] = sent.pop(keeper, None)
            case "terminal":
                if keeper is not None:
                    if event.provider is None:
                        hard_quota_provider.pop(keeper, None)
                    else:
                        hard_quota_provider[keeper] = event.provider
            case "wait":
                if keeper is None or event.provider_row is None or event.release is None:
                    continue
                provider = hard_quota_provider.pop(keeper, None)
                sent_at = ended_turn_mark.pop(keeper) if keeper in ended_turn_mark else sent.pop(keeper, None)
                if provider is not None:
                    waits.append(Wait(event.ts, keeper, provider, event.provider_row, event.release, sent_at))
    return restarts, waits


def judge(restarts: list[str], waits: list[Wait]) -> list[Judged]:
    """Known in this process wins over known before a restart; another Keeper
    wins over itself. Every wait is noted, judged or not."""

    def process_of(ts: str) -> int:
        return bisect.bisect_right(restarts, ts)

    noted: list[Noted] = []
    judged: list[Judged] = []
    for wait in waits:
        process = process_of(wait.ts)
        sent_at = wait.sent_at
        if sent_at is None:
            judged.append(Judged(wait, process, "no_dispatch_mark", None))
        else:
            earlier = [
                entry
                for entry in noted
                if entry.provider_row == wait.provider_row and entry.release >= wait.release and entry.ts < sent_at
            ]
            same_process = [entry for entry in earlier if entry.process == process]
            others = [entry for entry in same_process if entry.keeper != wait.keeper]
            if others:
                judged.append(Judged(wait, process, "known_from_another_keeper", others[0].ts))
            elif same_process:
                judged.append(Judged(wait, process, "known_from_itself", same_process[0].ts))
            elif earlier:
                judged.append(Judged(wait, process, "known_before_restart", earlier[0].ts))
            else:
                judged.append(Judged(wait, process, "first", None))
        noted.append(Noted(wait.ts, process, wait.keeper, wait.provider_row, wait.release))
    return judged


def seconds(ts: str) -> float:
    return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()


def summary(restarts: list[str], judged: list[Judged]) -> dict[str, object]:
    verdicts = Counter(item.verdict for item in judged)
    from_another = [item for item in judged if item.verdict == "known_from_another_keeper"]
    gaps = sorted(
        seconds(item.wait.sent_at) - seconds(item.noted_at)
        for item in from_another
        if item.wait.sent_at is not None and item.noted_at is not None
    )
    before_restart = [item for item in judged if item.verdict == "known_before_restart"]
    return {
        "server_starts": len(restarts),
        "hard_quota_waits": len(judged),
        "verdicts": dict(sorted(verdicts.items())),
        "by_provider": dict(sorted(Counter(item.wait.provider for item in judged).items())),
        "known_from_another_keeper": {
            "keepers": len({item.wait.keeper for item in from_another}),
            "by_provider": dict(sorted(Counter(item.wait.provider for item in from_another).items())),
            "seconds_from_note_to_dispatch": {
                "p50": gaps[len(gaps) // 2] if gaps else None,
                "max": gaps[-1] if gaps else None,
            },
            "by_day": dict(sorted(Counter(item.wait.ts[:10] for item in from_another).items())),
        },
        "known_before_restart": {
            "process_provider_row_pairs": len({(item.process, item.wait.provider_row) for item in before_restart}),
        },
    }


def judge_all(events: list[Event]) -> tuple[list[str], list[Judged]]:
    restarts, waits = hard_quota_waits(events)
    return restarts, judge(restarts, waits)


def measure(events: list[Event]) -> dict[str, object]:
    """Both dispatch marks. `composition`: an official client's send line, or
    the attempt's start when the runtime writes none. `start`: always the
    attempt's start, which a walk reading the table before each call sees."""
    without_composition = [event for event in events if event.kind != "dispatched"]
    return {
        "window": {"first": events[0].ts, "last": events[-1].ts} if events else None,
        "dispatch_mark": {
            "composition": summary(*judge_all(events)),
            "start": summary(*judge_all(without_composition)),
        },
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=DESCRIPTION)
    parser.add_argument("logs", nargs="+", type=pathlib.Path, help="system_log_*.jsonl files")
    parser.add_argument("--until", help="drop lines at or after this UTC time, e.g. 2026-11-15T10:00:00Z")
    args = parser.parse_args(argv)
    cutoff = cast(str | None, args.until)
    print(json.dumps(measure(until(read_events(cast(list[pathlib.Path], args.logs)), cutoff)), indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
