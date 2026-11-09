"""ledger_result_bytes.py: per-tool result bytes, externalized blobs and raw add-on envelopes in the tool-call ledger.

Reads <base>/.masc/tool_calls/<YYYY-MM>/*.jsonl for rows whose `ts` lies in [--since, --end) and prints JSON:
- ledger: rows with an integer result_bytes and their sum
- externalized: rows whose output is {"_blob": {...}} and the bytes of the distinct blobs
- tools: per tool (the --top largest by result_bytes, plus every --tool): rows, result_bytes, blob rows,
  distinct blobs and their bytes, and envelope rows

An envelope row is one whose output is a string with the key "structuredContent" in its first 400
characters: the add-on worker's whole reply recorded as the result.
Usage: python3 ledger_result_bytes.py --base-path ~/me --since 2026-11-04T00:00:00Z --end 2026-11-10T00:00:00Z
"""

import argparse
import datetime
import json
import pathlib
import sys

ENVELOPE_PREFIX_CHARS = 400
ENVELOPE_KEY = '"structuredContent"'


def parse_utc(text):
    return datetime.datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()


def months_between(since, end):
    first = datetime.datetime.fromtimestamp(since, datetime.timezone.utc)
    last = datetime.datetime.fromtimestamp(end, datetime.timezone.utc)
    year, month = first.year, first.month
    while (year, month) <= (last.year, last.month):
        yield f"{year:04d}-{month:02d}"
        year, month = (year + 1, 1) if month == 12 else (year, month + 1)


def ledger_rows(base_path, since, end):
    for month in months_between(since, end):
        for path in sorted((pathlib.Path(base_path) / ".masc" / "tool_calls" / month).glob("*.jsonl")):
            with open(path, encoding="utf-8", errors="replace") as handle:
                for line in handle:
                    if '"tool_call"' not in line:
                        continue
                    try:
                        row = json.loads(line)
                    except ValueError:
                        continue
                    ts = row.get("ts")
                    if (row.get("record_kind") == "tool_call" and isinstance(ts, (int, float))
                            and since <= ts < end and isinstance(row.get("result_bytes"), int)):
                        yield row


def blob_of(output):
    blob = output.get("_blob") if isinstance(output, dict) else None
    if isinstance(blob, dict) and isinstance(blob.get("bytes"), int) and isinstance(blob.get("sha256"), str):
        return blob["sha256"], blob["bytes"]
    return None


def is_envelope(output):
    return isinstance(output, str) and ENVELOPE_KEY in output[:ENVELOPE_PREFIX_CHARS]


def census(base_path, since, end):
    tools = {}
    for row in ledger_rows(base_path, since, end):
        entry = tools.setdefault(row.get("tool"), {"rows": 0, "result_bytes": 0, "blob_rows": 0,
                                                    "blobs": {}, "envelope_rows": 0})
        entry["rows"] += 1
        entry["result_bytes"] += row["result_bytes"]
        blob = blob_of(row.get("output"))
        if blob is not None:
            entry["blob_rows"] += 1
            entry["blobs"][blob[0]] = blob[1]
        if is_envelope(row.get("output")):
            entry["envelope_rows"] += 1
    return tools


def report(tools, top, named):
    def summary(tool, entry):
        return {"tool": tool, "rows": entry["rows"], "result_bytes": entry["result_bytes"],
                "mean_result_bytes": entry["result_bytes"] // entry["rows"],
                "blob_rows": entry["blob_rows"], "distinct_blobs": len(entry["blobs"]),
                "blob_bytes": sum(entry["blobs"].values()), "envelope_rows": entry["envelope_rows"]}

    ranked = sorted(tools.items(), key=lambda item: (-item[1]["result_bytes"], str(item[0])))
    chosen = [item for index, item in enumerate(ranked) if index < top or item[0] in named]
    return {"ledger": {"rows": sum(e["rows"] for e in tools.values()),
                       "result_bytes": sum(e["result_bytes"] for e in tools.values())},
            "externalized": {"rows": sum(e["blob_rows"] for e in tools.values()),
                             "distinct_blob_bytes": sum(sum(e["blobs"].values()) for e in tools.values())},
            "tools": [summary(tool, entry) for tool, entry in chosen]}


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base-path", required=True)
    parser.add_argument("--since", required=True, help="UTC, e.g. 2026-11-04T00:00:00Z")
    parser.add_argument("--end", required=True, help="UTC, exclusive")
    parser.add_argument("--top", type=int, default=15)
    parser.add_argument("--tool", action="append", default=[])
    parser.add_argument("--json-out")
    args = parser.parse_args(argv)
    since, end = parse_utc(args.since), parse_utc(args.end)
    result = report(census(args.base_path, since, end), args.top, set(args.tool))
    result["window"] = {"since": args.since, "end": args.end}
    text = json.dumps(result, ensure_ascii=False, indent=1)
    if args.json_out:
        pathlib.Path(args.json_out).write_text(text + "\n", encoding="utf-8")
    print(text)


if __name__ == "__main__":
    main(sys.argv[1:])
