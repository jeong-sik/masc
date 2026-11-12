"""Count Keeper turns that failed on a hard quota, before and after restarts.

Reads <base>/.masc/agent-core-events/<YYYY-MM>/<DD>.jsonl (agent_failed rows
whose error_code is provider_error_hard_quota) and the creation times of
<base>/.masc/logs/masc-start-*.log. A row names the Keeper, not the account.

Usage: python3 -I count.py <base> <YYYY-MM> <DD> [<DD> ...]
"""

import collections
import glob
import json
import os
import sys

HALF_HOUR = 1800.0


def main() -> None:
    base, month, days = sys.argv[1], sys.argv[2], sys.argv[3:]
    starts = sorted(
        os.stat(path).st_birthtime
        for path in glob.glob(os.path.join(base, ".masc/logs/masc-start-*.log"))
    )
    failures: list[tuple[float, str, float | None]] = []
    for day in days:
        path = os.path.join(base, ".masc/agent-core-events", month, day + ".jsonl")
        with open(path, errors="replace") as rows:
            for row in rows:
                if '"agent_core:agent_failed"' not in row[:60]:
                    continue
                event = json.loads(row)
                payload = event["payload"]
                if payload.get("error_code") != "provider_error_hard_quota":
                    continue
                detail = payload.get("error_detail") or {}
                failures.append(
                    (event["ts_unix"], payload["agent_name"], detail.get("retry_after_s"))
                )
    failures.sort()
    first, last = failures[0][0], failures[-1][0]
    span_days = (last - first) / 86400.0
    stated = sum(1 for _, _, retry_after in failures if retry_after)
    print(f"span_days={span_days:.2f} failures={len(failures)} with_retry_after={stated}")

    inside = [s for s in starts if first + HALF_HOUR <= s <= last - HALF_HOUR]
    # A restart less than an hour after the previous one shares its windows.
    apart = [s for i, s in enumerate(inside) if i == 0 or s - inside[i - 1] >= 2 * HALF_HOUR]

    def count(since: float, until: float) -> int:
        return sum(1 for at, _, _ in failures if since <= at < until)

    before = sum(count(s - HALF_HOUR, s) for s in apart)
    after = sum(count(s, s + HALF_HOUR) for s in apart)
    print(f"restarts={len(inside)} at_least_an_hour_apart={len(apart)}")
    print(f"failures_30m_before={before} failures_30m_after={after}")

    # A Keeper's first hard-quota failure in the half hour after a restart,
    # when its last failure before the restart stated a reset still ahead.
    repeats = 0
    keepers: collections.Counter[str] = collections.Counter()
    for start in inside:
        stated_until: dict[str, float] = {}
        for at, keeper, retry_after in failures:
            if at < start and retry_after:
                stated_until[keeper] = at + retry_after
        seen: set[str] = set()
        for at, keeper, _ in failures:
            if start <= at < start + HALF_HOUR and keeper not in seen:
                seen.add(keeper)
                if stated_until.get(keeper, 0.0) > at:
                    repeats += 1
                    keepers[keeper] += 1
    print(f"first_failure_after_restart_inside_a_stated_reset={repeats}")
    print("by_keeper=" + ", ".join(f"{k}:{n}" for k, n in keepers.most_common(8)))


main()
