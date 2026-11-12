#!/usr/bin/env python3
"""What the stored usage reports said at a server restart.

usage: count.py <provider_usage_history dir> <restart unix seconds> <resolved.json>

Reads every window row observed before the restart, keeps the latest row per
(scope_id, source, kind), and prints it for each account of the given
/api/v1/runtime/resolved response, with the minutes until that account's
first report after the restart.
"""
import glob
import json
import os
import sys


def main() -> int:
    root, restart, resolved_path = sys.argv[1], float(sys.argv[2]), sys.argv[3]
    with open(resolved_path, encoding="utf-8") as handle:
        accounts = json.load(handle)["provider_usage_windows"]
    latest: dict[tuple[str, str, str], dict] = {}
    first_after: dict[str, float] = {}
    for path in sorted(glob.glob(os.path.join(root, "*", "*.jsonl"))):
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                try:
                    items = json.loads(line)
                except json.JSONDecodeError:
                    continue
                for item in items:
                    if "kind" not in item:
                        continue
                    scope, at = item["scope_id"], item["observed_at"]
                    if at < restart:
                        key = (scope, item["source"], item["kind"])
                        if key not in latest or latest[key]["observed_at"] < at:
                            latest[key] = item
                    else:
                        first_after[scope] = min(first_after.get(scope, at), at)
    for account in accounts:
        scope = account["scope_id"]
        providers = ",".join(p["id"] for p in account.get("providers", []))
        after = first_after.get(scope)
        wait = "none" if after is None else f"{(after - restart) / 60:.0f}min"
        print(f"{account['scope']} [{providers}] state={account['state']} first_report_after_restart={wait}")
        for (row_scope, source, kind), row in sorted(latest.items()):
            if row_scope != scope:
                continue
            reset = row.get("resets_at") or 0
            print(
                f"  {source} {kind} value={row.get('value')}{row.get('unit')}"
                f" observed={(restart - row['observed_at']) / 3600:.1f}h_before"
                f" reset={'ahead' if reset > restart else 'passed_or_none'}"
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
