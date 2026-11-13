"""Where the time of long foreground Execute calls goes, and how a Keeper waits on GitHub inside one turn.

    python3 sleep_waits.py share  <since_utc> <end_utc> [base]
    python3 sleep_waits.py shapes <since_utc> <end_utc> [base]
    python3 sleep_waits.py turns  <since_utc> <end_utc> [base]
    python3 sleep_waits.py kinds  <since_utc> <end_utc> [base]

`base` defaults to `~/me`. All four read the tool-call ledger through `ledger_window.py` of the
`tool-efficiency-1110-2026-11` folder and write nothing. They print JSON.

- `share`: Execute calls, those whose input has `run_in_background` true, and the foreground calls of 60 s or
  more with their hours. Background calls per Keeper.
- `shapes`: the 60 s+ foreground calls by what they ran. A call is `sleep+gh`, `sleep+own background job` or
  `sleep only` when the literal `sleep <n>` values in its command add up to at least half of the call. A call
  with a sleep that adds up to less (a sleep in a loop of unknown count) is `sleep`. `sleep+gh` calls are split
  by what the `gh` reads: Actions runs, check runs, reviews and comments, PR state, other.
- `turns`: per Keeper, the `sleep+gh` calls grouped by `keeper_turn_id`: how many turns they fill, how many
  follow a `git push`, `gh workflow run` or `gh pr create|merge|ready` earlier in the same turn, how many sit in
  a turn with two or more of them, and how many `until_github_run` or `until_github_checks` schedules the Keeper
  created in the window.
- `kinds`: the Execute calls and the `sleep+gh` calls by `turn_kind`. `keeper_receipt_wait` is offered to a turn
  that serves a chat execution (`direct`) and not to an `autonomous` one (`descriptors_for_run` in
  `lib/keeper/keeper_run_tools_setup.ml`), so the `direct` share of the `sleep+gh` hours is the most the
  receipt wait can reach.

The classes come from the command text and are for counting. `Execute` does not interpret a command
(`config/tools/Execute.toml`), and no product rule uses them. A turn that reaches over an edge of the window is
counted from the rows inside it.
"""

from __future__ import annotations

import collections
import json
import pathlib
import re
import statistics
import sys
from collections.abc import Iterable

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "tool-efficiency-1110-2026-11"))
import ledger_window as ledger  # noqa: E402

LONG_MS = 60_000.0
BACKGROUND = re.compile(r'run_in_background\\?"\s*:\s*true')
SLEEP = re.compile(r"\bsleep\s+(\d+(?:\.\d+)?)")
GH = re.compile(r"\bgh\b")
OWN_JOB = re.compile(r"\b(nohup|setsid)\b|&\s*(sleep|$|;)")
PUSH = re.compile(r"git\s+push|gh\s+workflow\s+run|gh\s+pr\s+(create|merge|ready)|gh\s+run\s+rerun")
LEADING_CD = re.compile(r"^\s*cd\s+[^;&|]+(&&|;)\s*")
LEADING_ASSIGN = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*=\S*\s+)+")
GH_WAITS = (
    ("review/comments", re.compile(r"/pulls/[^\s\"']*/(reviews|comments)|/issues/[^\s\"']*/comments|pr view[^\n]*(reviews|comments)")),
    ("check-runs/pr checks", re.compile(r"check-runs|check-suites|pr checks|statusCheckRollup|/status\b")),
    ("actions run", re.compile(r"gh run\b|/actions/runs")),
    ("pr state", re.compile(r"pr view|pr list|/pulls/\d+(?![\d/])|mergeStateStatus|mergeable|merged")),
)
WATCH_FIELDS = ("until_github_run", "until_github_checks")
SCHEDULE_TOOLS = ("masc_schedule_create", "masc_schedule_update")
MARKERS = ('"tool":"Execute"', '"tool":"masc_schedule_create"', '"tool":"masc_schedule_update"')
TOP_KEEPERS = 8

type Row = dict[str, object]


def number(row: Row, key: str) -> float:
    value = row.get(key)
    return float(value) if isinstance(value, (int, float)) else 0.0


def input_text(row: Row) -> str:
    """The input as JSON text, whether the ledger kept an object or a string."""
    raw = row.get("input")
    return raw if isinstance(raw, str) else json.dumps(raw, ensure_ascii=False)


def command_of(row: Row) -> str:
    """The shell script of an Execute call: `command`, or the script of `["bash", "-lc", script]`."""
    raw = row.get("input")
    data: object = raw
    if isinstance(raw, str):
        try:
            data = json.loads(raw)
        except ValueError:
            return raw
    if not isinstance(data, dict):
        return ""
    argv = data.get("argv")
    if isinstance(argv, list) and argv:
        words = [str(word) for word in argv]
        shell = pathlib.PurePosixPath(words[0]).name in ("bash", "sh", "zsh")
        if len(words) >= 3 and shell and words[1] in ("-lc", "-c"):
            return words[2]
        return " ".join(words)
    return str(data.get("command") or data.get("cmd") or "")


def is_background(row: Row) -> bool:
    return BACKGROUND.search(input_text(row)) is not None


def is_long_foreground(row: Row) -> bool:
    return row.get("tool") == "Execute" and number(row, "duration_ms") >= LONG_MS and not is_background(row)


def sleep_group(command: str, duration_s: float) -> str | None:
    """`sleep+gh`, `sleep+own background job` or `sleep only` when the literal sleeps are half of the call."""
    literal = sum(float(value) for value in SLEEP.findall(command))
    if literal < 0.5 * duration_s:
        return None
    if GH.search(command):
        return "sleep+gh"
    if OWN_JOB.search(command):
        return "sleep+own background job"
    return "sleep only"


def gh_wait_kind(command: str) -> str:
    for name, pattern in GH_WAITS:
        if pattern.search(command):
            return name
    return "other gh"


def head_group(command: str) -> str:
    text = command
    for _ in range(3):
        text = LEADING_CD.sub("", text, count=1)
    text = LEADING_ASSIGN.sub("", text, count=1).strip()
    words = text.split()
    head = pathlib.PurePosixPath(words[0]).name if words else "(empty)"
    if head == "sleep" or re.search(r"\bsleep\s+\d", text):
        return "sleep"
    if head in ("opam", "dune") or re.search(r"\bdune\s+(build|runtest|exec)", text):
        return "dune/opam"
    return head


def share_of(rows: Iterable[Row]) -> dict[str, object]:
    total = background = long_calls = 0
    long_ms = 0.0
    per_keeper: collections.Counter[str] = collections.Counter()
    for row in rows:
        if row.get("tool") != "Execute":
            continue
        total += 1
        if is_background(row):
            background += 1
            per_keeper[str(row.get("keeper"))] += 1
        elif number(row, "duration_ms") >= LONG_MS:
            long_calls += 1
            long_ms += number(row, "duration_ms")
    return {
        "execute_calls": total,
        "background_calls": background,
        "background_percent": round(100 * background / total, 2) if total else 0.0,
        "foreground_60s_calls": long_calls,
        "foreground_60s_hours": round(long_ms / 3.6e6, 1),
        "background_by_keeper": per_keeper.most_common(TOP_KEEPERS),
    }


def is_sleep_gh(row: Row) -> bool:
    """A foreground call of 60 s or more whose literal sleeps are half of it and that reads GitHub."""
    return (
        is_long_foreground(row)
        and sleep_group(command_of(row), number(row, "duration_ms") / 1000) == "sleep+gh"
    )


def kinds_of(rows: Iterable[Row]) -> dict[str, object]:
    execute: collections.Counter[str] = collections.Counter()
    calls: collections.Counter[str] = collections.Counter()
    ms: collections.defaultdict[str, float] = collections.defaultdict(float)
    per_keeper: collections.defaultdict[str, collections.Counter[str]] = collections.defaultdict(collections.Counter)
    for row in rows:
        if row.get("tool") != "Execute":
            continue
        kind = str(row.get("turn_kind"))
        execute[kind] += 1
        if is_sleep_gh(row):
            calls[kind] += 1
            ms[kind] += number(row, "duration_ms")
            per_keeper[str(row.get("keeper"))][kind] += 1
    total_ms = sum(ms.values())
    return {
        "execute_calls_by_turn_kind": dict(execute),
        "sleep_gh_calls_by_turn_kind": dict(calls),
        "sleep_gh_hours_by_turn_kind": {kind: round(value / 3.6e6, 2) for kind, value in ms.items()},
        "sleep_gh_hours_percent_by_turn_kind": {
            kind: round(100 * value / total_ms, 1) for kind, value in ms.items()
        } if total_ms else {},
        "sleep_gh_by_keeper": [
            {"keeper": keeper, **dict(counts)}
            for keeper, counts in sorted(per_keeper.items(), key=lambda item: -sum(item[1].values()))[:TOP_KEEPERS]
        ],
    }


def shapes_of(rows: Iterable[Row]) -> dict[str, object]:
    hours: collections.defaultdict[str, float] = collections.defaultdict(float)
    calls: collections.Counter[str] = collections.Counter()
    seconds: collections.defaultdict[str, list[float]] = collections.defaultdict(list)
    gh_kinds: collections.defaultdict[str, float] = collections.defaultdict(float)
    gh_calls: collections.Counter[str] = collections.Counter()
    for row in rows:
        if not is_long_foreground(row):
            continue
        command = command_of(row)
        ms = number(row, "duration_ms")
        group = sleep_group(command, ms / 1000) or head_group(command)
        hours[group] += ms
        calls[group] += 1
        seconds[group].append(ms / 1000)
        if group == "sleep+gh":
            kind = gh_wait_kind(command)
            gh_kinds[kind] += ms
            gh_calls[kind] += 1

    def table(names: Iterable[str], ms: dict[str, float], count: collections.Counter[str],
              lengths: dict[str, list[float]] | None) -> list[dict[str, object]]:
        out: list[dict[str, object]] = []
        for name in sorted(names, key=lambda item: ms[item], reverse=True)[:TOP_KEEPERS * 2]:
            entry: dict[str, object] = {"group": name, "calls": count[name], "hours": round(ms[name] / 3.6e6, 1)}
            if lengths is not None:
                entry["median_s"] = round(statistics.median(lengths[name]))
            out.append(entry)
        return out

    return {
        "foreground_60s_calls": sum(calls.values()),
        "foreground_60s_hours": round(sum(hours.values()) / 3.6e6, 1),
        "groups": table(hours.keys(), hours, calls, seconds),
        "sleep_gh_by_what_gh_reads": table(gh_kinds.keys(), gh_kinds, gh_calls, None),
    }


def turns_of(rows: Iterable[Row]) -> dict[str, object]:
    by_turn: collections.defaultdict[tuple[str, str], list[Row]] = collections.defaultdict(list)
    watches: collections.Counter[str] = collections.Counter()
    for row in rows:
        keeper = str(row.get("keeper"))
        tool = row.get("tool")
        if tool in SCHEDULE_TOOLS and any(field in input_text(row) for field in WATCH_FIELDS):
            watches[keeper] += 1
        by_turn[(keeper, str(row.get("keeper_turn_id")))].append(row)
    calls: collections.Counter[str] = collections.Counter()
    ms: collections.defaultdict[str, float] = collections.defaultdict(float)
    turns: collections.Counter[str] = collections.Counter()
    after_push: collections.Counter[str] = collections.Counter()
    multi: collections.Counter[str] = collections.Counter()
    max_in_turn: collections.defaultdict[str, int] = collections.defaultdict(int)
    for (keeper, _), turn_rows in by_turn.items():
        turn_rows.sort(key=lambda row: (number(row, "ts"), number(row, "planned_index")))
        pushed = False
        sleeps = 0
        for row in turn_rows:
            if row.get("tool") != "Execute":
                continue
            command = command_of(row)
            if is_long_foreground(row) and sleep_group(command, number(row, "duration_ms") / 1000) == "sleep+gh":
                sleeps += 1
                calls[keeper] += 1
                ms[keeper] += number(row, "duration_ms")
                if pushed:
                    after_push[keeper] += 1
            if PUSH.search(command):
                pushed = True
        if sleeps:
            turns[keeper] += 1
            max_in_turn[keeper] = max(max_in_turn[keeper], sleeps)
            if sleeps >= 2:
                multi[keeper] += sleeps
    keepers = sorted(calls, key=lambda name: ms[name], reverse=True)[:TOP_KEEPERS]
    return {
        "sleep_gh_calls": sum(calls.values()),
        "sleep_gh_hours": round(sum(ms.values()) / 3.6e6, 1),
        "until_github_schedules_created": sum(watches.values()),
        "keepers_with_sleep_gh": len(calls),
        "keepers_with_sleep_gh_that_created_a_watch": sum(1 for name in calls if watches[name]),
        "by_keeper": [
            {
                "keeper": name,
                "sleep_gh_calls": calls[name],
                "hours": round(ms[name] / 3.6e6, 1),
                "turns": turns[name],
                "after_push_in_same_turn": after_push[name],
                "in_turns_with_2_or_more": multi[name],
                "most_in_one_turn": max_in_turn[name],
                "until_github_schedules_created": watches[name],
            }
            for name in keepers
        ],
    }


def main(argv: list[str]) -> int:
    if len(argv) < 4 or argv[1] not in ("share", "shapes", "turns", "kinds"):
        sys.stderr.write(__doc__ or "")
        return 2
    since, end = ledger.parse_utc(argv[2]), ledger.parse_utc(argv[3])
    base = pathlib.Path(argv[4] if len(argv) > 4 else "~/me").expanduser()
    rows = ledger.read_rows(base, since, end, MARKERS)
    window = {"since": argv[2], "end": argv[3], "hours": round((end - since) / 3600, 2)}
    result = {"share": share_of, "shapes": shapes_of, "turns": turns_of, "kinds": kinds_of}[argv[1]](rows)
    sys.stdout.write(json.dumps({"window": window, **result}, ensure_ascii=False, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
