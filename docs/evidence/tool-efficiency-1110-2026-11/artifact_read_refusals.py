#!/usr/bin/env python3
"""keeper_artifact_read calls that the tool refused with "artifact does not exist", and what the Keeper did next.

Read-only.

Usage:
    python3 -I docs/evidence/tool-efficiency-1110-2026-11/artifact_read_refusals.py SINCE_ISO END_ISO [BASE_PATH]

The window is [SINCE, END) in UTC by the time a row was built (ledger_window.py). BASE_PATH defaults to ~/me. The
ledger rows are read from BASE_PATH/.masc/tool_calls/YYYY-MM/*.jsonl. Every count is over the window; rows up to 300 s
after END are read only as follow-up reads, so a refusal just before END is not counted as "none" for lack of rows.

Prints one JSON object:
  calls             keeper_artifact_read rows in the window
  refused_missing   rows whose output says "artifact does not exist"
  refused_malformed rows whose output says the sha256 "is malformed"
  refusal_rate      refused_missing / calls
  cause             of the refused_missing rows that carry a sha256 input:
                      answer_fingerprint  the sha256 equals the output_fingerprint of an earlier ledger row of the
                                          same Keeper (a stored result's marker prints that value as answer_sha256=)
                      other               anything else
  after             the same Keeper's next keeper_artifact_read within 300 s of a refusal:
                      fixed (succeeded with another sha256) | repeated (same sha256) | other_error | none
  fix_delay_s       seconds from a refusal to the fixed call (median, p90)

output_fingerprint is the server's identity of a tool answer; for a stored result it is the same sha256 over the
answer JSON that the marker prints as answer_sha256=. Equality with a refused sha256 means the caller copied a value
it cannot compute itself. The marker (tool_output.ml, encode_for_agent_core) is the only place found that renders the
value into a tool result. No sample of model inputs was searched for the string.
"""

from __future__ import annotations

import collections
import dataclasses
import json
import pathlib
import sys
from collections.abc import Iterable

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import ledger_window as ledger  # noqa: E402

LOOKBACK_S = 48 * 3600
AFTER_WINDOW_S = 300.0
MISSING = "artifact does not exist"
MALFORMED = "is malformed"
HEAD_CHARS = 400


@dataclasses.dataclass(frozen=True, slots=True)
class Read:
    ts: float
    sha256: str | None
    in_window: bool
    missing: bool
    malformed: bool
    succeeded: bool


def measure(rows: Iterable[ledger.Row], since: float, end: float) -> dict[str, object]:
    """`rows` are the tool_call rows of every tool from `since - LOOKBACK_S` up to `end + AFTER_WINDOW_S`. Reads at or
    after `end` are follow-up candidates only and are not counted."""
    first_fingerprint: dict[tuple[str, str], float] = {}
    reads: dict[str, list[Read]] = collections.defaultdict(list)
    for row in rows:
        ts = ledger.number_of(row, "ts")
        keeper = ledger.keeper_of(row)
        fingerprint = row.get("output_fingerprint")
        if isinstance(fingerprint, str):
            key = (keeper, fingerprint)
            previous = first_fingerprint.get(key)
            first_fingerprint[key] = ts if previous is None else min(previous, ts)
        if row.get("tool") != "keeper_artifact_read" or ts < since:
            continue
        sha = ledger.input_of(row).get("sha256")
        head = ledger.text_of(row.get("output"))[:HEAD_CHARS]
        missing, malformed = MISSING in head, MALFORMED in head
        succeeded = row.get("disposition") == "completed" and not missing and not malformed
        reads[keeper].append(Read(ts, sha if isinstance(sha, str) else None, ts < end, missing, malformed, succeeded))

    calls = refused = malformed_count = 0
    cause: collections.Counter[str] = collections.Counter()
    after: collections.Counter[str] = collections.Counter()
    delays: list[float] = []
    for keeper, keeper_reads in reads.items():
        keeper_reads.sort(key=lambda read: read.ts)
        for index, read in enumerate(keeper_reads):
            if not read.in_window:
                continue
            calls += 1
            malformed_count += read.malformed
            if not read.missing:
                continue
            refused += 1
            if read.sha256 is not None:
                seen = first_fingerprint.get((keeper, read.sha256))
                cause["answer_fingerprint" if seen is not None and seen < read.ts else "other"] += 1
            following = next((r for r in keeper_reads[index + 1 :] if r.ts - read.ts <= AFTER_WINDOW_S), None)
            if following is None:
                after["none"] += 1
            elif following.sha256 == read.sha256:
                after["repeated"] += 1
            elif following.succeeded:
                after["fixed"] += 1
                delays.append(following.ts - read.ts)
            else:
                after["other_error"] += 1
    delays.sort()
    return {
        "calls": calls,
        "refused_missing": refused,
        "refused_malformed": malformed_count,
        "refusal_rate": round(refused / calls, 4) if calls else None,
        "cause": dict(cause),
        "after": dict(after),
        "fix_delay_s": {
            "median": round(delays[len(delays) // 2], 1) if delays else None,
            "p90": round(delays[int(len(delays) * 0.9)], 1) if delays else None,
        },
    }


def main() -> None:
    since, end = ledger.parse_utc(sys.argv[1]), ledger.parse_utc(sys.argv[2])
    base = pathlib.Path(sys.argv[3] if len(sys.argv) > 3 else "~/me").expanduser()
    window = {"since": sys.argv[1], "end": sys.argv[2], "hours": round((end - since) / 3600, 2)}
    result = measure(ledger.read_rows(base, since - LOOKBACK_S, end + AFTER_WINDOW_S), since, end)
    print(json.dumps({"window": window, **result}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
