#!/usr/bin/env python3
"""Check the writer's state table in the RFC text for completeness.

Usage: check_state_table.py RFC.md [pairs.tsv]

Reads the tables between the headings "### 9.3" and "### 9.4". The RFC text is
the only copy of the table; pairs.tsv is written from it for other tools.

Fails (exit 1) when
  - a state heading or an event name is not one of the declared names,
  - a (state, event) pair of the 7 x 12 matrix has no row,
  - a pair has two rows and one of them has no condition, or two conditions
    are the same text,
  - a pair has exactly one row and that row has a condition,
  - an (asked, result) pair of the ask-result table has no row or two rows,
  - a table row does not parse.
It does not judge whether the conditions of one pair cover every case; the
model does that.
"""
import re
import sys
from collections import defaultdict
from pathlib import Path

STATES = ("Booting", "Idle", "Asking", "Resting", "Refused_at_bottom", "Stopped", "Retired")
EVENTS = (
    "Boot_finished", "Turn_closed", "Pulse", "Write", "Ask_ended", "Declaration_changed",
    "Resume", "Skip_item", "Skip_line", "Restart_reading", "Adopt", "Retire",
)
READ_ASKS = ("Read_range wide", "Read_range one item", "Read_item_alone")
READ_RESULTS = (
    "Answered", "Nothing_to_ask", "Nothing_readable", "Span_unknown", "Memory_diverged",
    "Input_fault", "Ask_failed", "Refused_by_lane", "Silent_lane",
)
ROOM_RESULTS = ("Room_answered", "Room_refused", "Room_silent", "Room_failed", "Memory_diverged")
ASKED_CELLS = {
    "읽는 질문": READ_ASKS,
    "`Read_range`": READ_ASKS[:2],
    "`Read_range`, 한 항목보다 넓다": READ_ASKS[:1],
    "`Read_range`, 한 항목": READ_ASKS[1:2],
    "`Read_item_alone`": READ_ASKS[2:],
    "`Make_room`": ("Make_room",),
}
STATE_HEADING = re.compile(r"^\*\*`([A-Za-z_]+)[^`]*`\*\*$")
LEADING_SPANS = re.compile(r"^(`[A-Za-z_]+`(?:, `[A-Za-z_]+`)*)(?:, (.+))?$")
SPAN = re.compile(r"`([A-Za-z_]+)`")


def section(text: str) -> list[tuple[int, str]]:
    lines = text.splitlines()
    starts = [i for i, line in enumerate(lines) if line.startswith("### 9.3")]
    ends = [i for i, line in enumerate(lines) if line.startswith("### 9.4")]
    if len(starts) != 1 or len(ends) != 1 or ends[0] < starts[0]:
        sys.exit("the text must hold one '### 9.3' heading followed by one '### 9.4' heading")
    return [(i + 1, lines[i]) for i in range(starts[0] + 1, ends[0])]


def cells(line: str) -> list[str]:
    return [cell.strip() for cell in line.strip().strip("|").split("|")]


def main() -> int:
    text = Path(sys.argv[1]).read_text(encoding="utf-8")
    errors: list[str] = []
    pairs: dict[tuple[str, str], list[tuple[int, str, str]]] = defaultdict(list)
    asks: dict[tuple[str, str], list[int]] = defaultdict(list)
    state: str | None = None
    mode: str | None = None
    for number, line in section(text):
        heading = STATE_HEADING.match(line.strip())
        if heading:
            state, mode = heading.group(1), None
            if state not in STATES:
                errors.append(f"line {number}: unknown state {state}")
            continue
        if not line.startswith("|"):
            mode = None if not line.strip() else mode
            continue
        row = cells(line)
        if row[0] == "사건" and len(row) == 2:
            mode = "events"
            continue
        if row[0] == "물은 것" and len(row) == 3:
            mode = "asks"
            continue
        if set(line.strip()) <= set("|-: "):
            continue
        if mode == "events" and len(row) == 2 and state is not None:
            parsed = LEADING_SPANS.match(row[0])
            if not parsed:
                errors.append(f"line {number}: event cell does not parse: {row[0]}")
                continue
            guard = parsed.group(2) or ""
            for event in SPAN.findall(parsed.group(1)):
                if event not in EVENTS:
                    errors.append(f"line {number}: unknown event {event}")
                    continue
                pairs[(state, event)].append((number, guard, row[1]))
        elif mode == "asks" and len(row) == 3:
            if row[0] not in ASKED_CELLS:
                errors.append(f"line {number}: unknown asked cell: {row[0]}")
                continue
            results = SPAN.findall(row[1])
            if not results or row[1] != ", ".join(f"`{name}`" for name in results):
                errors.append(f"line {number}: result cell does not parse: {row[1]}")
                continue
            for asked in ASKED_CELLS[row[0]]:
                allowed = ROOM_RESULTS if asked == "Make_room" else READ_RESULTS
                for result in results:
                    if result not in allowed:
                        errors.append(f"line {number}: {result} is not a result of {asked}")
                        continue
                    asks[(asked, result)].append(number)
        else:
            errors.append(f"line {number}: table row outside a known table: {line.strip()[:60]}")
    for state_name in STATES:
        for event in EVENTS:
            rows = pairs.get((state_name, event), [])
            guards = [guard for _, guard, _ in rows]
            if not rows:
                errors.append(f"MISSING {state_name} x {event}")
            elif len(rows) == 1 and guards[0]:
                errors.append(f"PARTIAL {state_name} x {event}: one row, with a condition")
            elif len(rows) > 1 and ("" in guards or len(set(guards)) != len(guards)):
                errors.append(f"DOUBLED {state_name} x {event}: lines {[n for n, _, _ in rows]}")
    expected = [(asked, result) for asked in READ_ASKS for result in READ_RESULTS]
    expected += [("Make_room", result) for result in ROOM_RESULTS]
    for pair in expected:
        found = asks.get(pair, [])
        if len(found) != 1:
            errors.append(f"ASK {pair[0]} x {pair[1]}: {len(found)} rows {found}")
    for error in errors:
        print(error)
    if len(sys.argv) > 2:
        with open(sys.argv[2], "w", encoding="utf-8") as handle:
            handle.write("state\tevent\tcondition\taction\n")
            for state_name in STATES:
                for event in EVENTS:
                    for _, guard, action in pairs.get((state_name, event), []):
                        handle.write(f"{state_name}\t{event}\t{guard}\t{action}\n")
    rows_total = sum(len(rows) for rows in pairs.values())
    print(f"states {len(STATES)}, events {len(EVENTS)}, pairs {len(STATES) * len(EVENTS)}, "
          f"rows {rows_total}, ask-result pairs {len(expected)}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
