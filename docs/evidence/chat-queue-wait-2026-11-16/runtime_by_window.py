"""Direct turns per runtime_profile, per Keeper, in two adjacent windows. Read-only.

Reads the tool-call ledger `<base-path>/.masc/tool_calls/<YYYY-MM>/<DD>.<NNN>.jsonl`. A direct turn
is one distinct (trace_id, turn) pair of records with turn_kind "direct". A turn that called no
tool has no ledger record and is not counted. Prints one JSON object with every profile per
Keeper and window, most turns first.

Usage: runtime_by_window.py --base-path <dir> --since <epoch> --mid <epoch> --end <epoch> <keeper>...
"""

from __future__ import annotations

import argparse
import datetime
import json
import pathlib
import sys


def ledger_files(base: pathlib.Path, since: float, end: float) -> list[pathlib.Path]:
    day = datetime.datetime.fromtimestamp(since, datetime.timezone.utc).date()
    last = datetime.datetime.fromtimestamp(end, datetime.timezone.utc).date()
    out: list[pathlib.Path] = []
    while day <= last:
        out.extend(sorted((base / ".masc" / "tool_calls" / day.strftime("%Y-%m")).glob(f"{day:%d}.*.jsonl")))
        day += datetime.timedelta(days=1)
    return out


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-path", type=pathlib.Path, required=True)
    parser.add_argument("--since", type=float, required=True)
    parser.add_argument("--mid", type=float, required=True)
    parser.add_argument("--end", type=float, required=True)
    parser.add_argument("keepers", nargs="+")
    args = parser.parse_args(argv)
    keepers = set(args.keepers)
    seen: dict[tuple[str, str, str], set[tuple[str, str]]] = {}
    for path in ledger_files(args.base_path, args.since, args.end):
        with path.open() as handle:
            for line in handle:
                record = json.loads(line)
                if record.get("turn_kind") != "direct" or record.get("keeper") not in keepers:
                    continue
                ts = record.get("ts")
                if not isinstance(ts, (int, float)):
                    continue
                if args.since <= ts < args.mid:
                    window = "earlier"
                elif args.mid <= ts < args.end:
                    window = "later"
                else:
                    continue
                key = (window, str(record["keeper"]), str(record.get("runtime_profile")))
                seen.setdefault(key, set()).add((str(record.get("trace_id")), str(record.get("turn"))))
    out: dict[str, dict[str, dict[str, int]]] = {}
    for (window, keeper, profile), turns in sorted(seen.items(), key=lambda kv: -len(kv[1])):
        out.setdefault(window, {}).setdefault(keeper, {})[profile] = len(turns)
    print(json.dumps(out, ensure_ascii=False, indent=1, sort_keys=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
